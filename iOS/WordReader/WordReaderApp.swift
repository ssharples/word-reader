import ReaderKit
import SwiftUI

@main
struct WordReaderApp: App {
    @State private var model = PhoneModel()
    @Environment(\.scenePhase) private var scenePhase

    init() {
        Prefs.registerDefaults()
    }

    var body: some Scene {
        WindowGroup {
            LibraryScreen()
                .environment(model)
                .task { await model.start() }
                // Books shared from Files, Mail or Safari with "Open in Word Reader".
                .onOpenURL { url in
                    Task { await model.importBooks([url]) }
                }
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active: Task { await model.becameActive() }
            case .background: model.enteredBackground()
            default: break
            }
        }
    }
}
