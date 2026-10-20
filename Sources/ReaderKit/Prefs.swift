import SwiftUI
#if canImport(AppKit)
import AppKit
#else
import UIKit
#endif

/// Saved reader preferences. Views read them with @AppStorage; playback reads UserDefaults directly.
public enum Prefs {
    public static let wordsPerMinute = "wordsPerMinute"
    public static let naturalPauses = "naturalPauses"
    public static let showFocusLetter = "showFocusLetter"
    public static let fontSize = "fontSize"
    public static let fontStyle = "fontStyle"
    public static let readAloud = "readAloud"
    public static let voiceID = "voiceID"
    public static let voiceModel = "voiceModel"
    /// Only set from the command line, to check reading aloud without sound.
    public static let voiceVolume = "voiceVolume"

    /// On the Mac: whether books and progress go to the sync folder.
    public static let syncEnabled = "syncEnabled"
    /// A sync folder chosen by path, instead of iCloud Drive's "Word Reader" folder.
    public static let syncFolderPath = "syncFolderPath"
    /// On iPhone: the sync folder picked in Files, kept as a bookmark.
    public static let syncFolderBookmark = "syncFolderBookmark"
    /// Names this device's progress file in the sync folder.
    public static let syncDeviceID = "syncDeviceID"

    public static let speedRange = 100...1000
    public static let speedStep = 25
    #if os(macOS)
    public static let fontSizeRange = 32.0...120.0
    public static let defaultFontSize = 72.0
    #else
    public static let fontSizeRange = 28.0...96.0
    public static let defaultFontSize = 52.0
    #endif

    public static func registerDefaults() {
        UserDefaults.standard.register(defaults: [
            wordsPerMinute: 300,
            naturalPauses: true,
            showFocusLetter: true,
            fontSize: defaultFontSize,
            fontStyle: ReaderFont.serif.rawValue,
            readAloud: false,
            voiceID: ReadAloud.defaultVoice,
            voiceModel: VoiceModel.flash.rawValue,
        ])
    }
}

public enum ReaderFont: String, CaseIterable, Identifiable, Sendable {
    case serif, sans, rounded, mono

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .serif: "Serif"
        case .sans: "Sans"
        case .rounded: "Rounded"
        case .mono: "Mono"
        }
    }

    public var design: Font.Design {
        switch self {
        case .serif: .serif
        case .sans: .default
        case .rounded: .rounded
        case .mono: .monospaced
        }
    }

    #if canImport(AppKit)
    /// The matching AppKit font, for measuring words before they're drawn.
    public func platformFont(size: CGFloat) -> NSFont {
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
    #else
    /// The matching UIKit font, for measuring words before they're drawn.
    public func platformFont(size: CGFloat) -> UIFont {
        let base = UIFont.systemFont(ofSize: size)
        let design: UIFontDescriptor.SystemDesign = switch self {
        case .serif: .serif
        case .sans: .default
        case .rounded: .rounded
        case .mono: .monospaced
        }
        guard let descriptor = base.fontDescriptor.withDesign(design) else { return base }
        return UIFont(descriptor: descriptor, size: size)
    }
    #endif
}

/// Reading colours: warm paper in light mode, soft black in dark mode.
public enum Theme {
    public static let paper = dynamic(light: (0.976, 0.961, 0.925), dark: (0.106, 0.106, 0.114))
    public static let ink = dynamic(light: (0.13, 0.12, 0.11), dark: (0.90, 0.89, 0.86))
    public static let focus = dynamic(light: (0.80, 0.18, 0.14), dark: (1.00, 0.45, 0.38))
    public static let guide = dynamic(light: (0, 0, 0, 0.14), dark: (1, 1, 1, 0.16))

    private static func dynamic(light: (Double, Double, Double), dark: (Double, Double, Double)) -> Color {
        dynamic(light: (light.0, light.1, light.2, 1), dark: (dark.0, dark.1, dark.2, 1))
    }

    private static func dynamic(light: (Double, Double, Double, Double), dark: (Double, Double, Double, Double)) -> Color {
        #if canImport(AppKit)
        let light = NSColor(srgbRed: light.0, green: light.1, blue: light.2, alpha: light.3)
        let dark = NSColor(srgbRed: dark.0, green: dark.1, blue: dark.2, alpha: dark.3)
        return Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
        })
        #else
        let light = UIColor(red: light.0, green: light.1, blue: light.2, alpha: light.3)
        let dark = UIColor(red: dark.0, green: dark.1, blue: dark.2, alpha: dark.3)
        return Color(uiColor: UIColor { $0.userInterfaceStyle == .dark ? dark : light })
        #endif
    }
}
