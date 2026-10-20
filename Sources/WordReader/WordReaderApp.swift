import AppKit
import ReaderCore
import ReaderKit
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

    func applicationDidBecomeActive(_ notification: Notification) {
        Task { await model.appBecameActive() }
    }

    func applicationDidResignActive(_ notification: Notification) {
        Task { await model.sync.pushIfPending() }
    }

    func applicationWillTerminate(_ notification: Notification) {
        model.session?.pause()
        model.sync.pushBeforeQuitting()
    }

    /// Books opened from Finder ("Open With") or dropped on the Dock icon.
    func application(_ application: NSApplication, open urls: [URL]) {
        Task { await model.add(urls) }
    }
}
