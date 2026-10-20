import AppKit
import ReaderCore
import SwiftUI

@main
struct WordReaderApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    init() {
        Prefs.registerDefaults()
    }

    var body: some Scene {
        Window("Word Reader", id: "main") {
            RootView()
                .environment(delegate.model)
        }
        .defaultSize(width: 1120, height: 760)
        .windowToolbarStyle(.unified)
        .commands {
            BookCommands(app: delegate.model)
        }

        Settings {
            VoiceSettings()
        }
    }
}

struct BookCommands: Commands {
    let app: AppModel

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("Open EPUB…") { app.showOpenPanel() }
                .keyboardShortcut("o")
            Button("Back to Library") { app.closeBook() }
                .keyboardShortcut("l", modifiers: [.command, .shift])
                .disabled(app.session == nil)
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = AppModel()

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Run straight from `swift run`, there's no app bundle to make this a normal app.
        if Bundle.main.bundleIdentifier == nil {
            NSApp.setActivationPolicy(.regular)
        }
        Task.detached(priority: .background) {
            SpeechCache.standard.trim(toBytes: 1_000_000_000)
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationWillTerminate(_ notification: Notification) {
        model.session?.pause()
    }

    /// Books opened from Finder ("Open With") or dropped on the Dock icon.
    func application(_ application: NSApplication, open urls: [URL]) {
        Task { await model.add(urls) }
    }
}

/// Saved reader preferences. Views read them with @AppStorage; playback reads UserDefaults directly.
enum Prefs {
    static let wordsPerMinute = "wordsPerMinute"
    static let naturalPauses = "naturalPauses"
    static let showFocusLetter = "showFocusLetter"
    static let fontSize = "fontSize"
    static let fontStyle = "fontStyle"
    static let readAloud = "readAloud"
    static let voiceID = "voiceID"
    static let voiceModel = "voiceModel"
    /// Only set from the command line, to check reading aloud without sound.
    static let voiceVolume = "voiceVolume"

    static let speedRange = 100...1000
    static let speedStep = 25
    static let fontSizeRange = 32.0...120.0

    static func registerDefaults() {
        UserDefaults.standard.register(defaults: [
            wordsPerMinute: 300,
            naturalPauses: true,
            showFocusLetter: true,
            fontSize: 72.0,
            fontStyle: ReaderFont.serif.rawValue,
            readAloud: false,
            voiceID: VoiceSettings.defaultVoice,
            voiceModel: VoiceModel.flash.rawValue,
        ])
    }
}

enum ReaderFont: String, CaseIterable, Identifiable {
    case serif, sans, rounded, mono

    var id: String { rawValue }

    var label: String {
        switch self {
        case .serif: "Serif"
        case .sans: "Sans"
        case .rounded: "Rounded"
        case .mono: "Mono"
        }
    }

    var design: Font.Design {
        switch self {
        case .serif: .serif
        case .sans: .default
        case .rounded: .rounded
        case .mono: .monospaced
        }
    }

    /// The matching AppKit font, for measuring words before they're drawn.
    func nsFont(size: CGFloat) -> NSFont {
        let base = NSFont.systemFont(ofSize: size)
        let design: NSFontDescriptor.SystemDesign = switch self {
        case .serif: .serif
        case .sans: .default
        case .rounded: .rounded
        case .mono: .monospaced
        }
        guard let descriptor = base.fontDescriptor.withDesign(design) else { return base }
        return NSFont(descriptor: descriptor, size: size) ?? base
    }
}

/// Reading colours: warm paper in light mode, soft black in dark mode.
enum Theme {
    static let paper = dynamic(light: NSColor(srgbRed: 0.976, green: 0.961, blue: 0.925, alpha: 1),
                               dark: NSColor(srgbRed: 0.106, green: 0.106, blue: 0.114, alpha: 1))
    static let ink = dynamic(light: NSColor(srgbRed: 0.13, green: 0.12, blue: 0.11, alpha: 1),
                             dark: NSColor(srgbRed: 0.90, green: 0.89, blue: 0.86, alpha: 1))
    static let focus = dynamic(light: NSColor(srgbRed: 0.80, green: 0.18, blue: 0.14, alpha: 1),
                               dark: NSColor(srgbRed: 1.00, green: 0.45, blue: 0.38, alpha: 1))
    static let guide = dynamic(light: NSColor(white: 0, alpha: 0.14), dark: NSColor(white: 1, alpha: 0.16))

    private static func dynamic(light: NSColor, dark: NSColor) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
        })
    }
}
