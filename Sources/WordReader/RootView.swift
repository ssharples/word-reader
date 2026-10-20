import ReaderKit
import SwiftUI

/// Shows the library, or the reader when a book is open.
struct RootView: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        Group {
            if let session = app.session {
                ReaderView(session: session)
                    .id(ObjectIdentifier(session))
            } else {
                LibraryView()
            }
        }
        .frame(minWidth: 760, minHeight: 520)
        .task {
            await app.start()
        }
        .alert(app.alert?.title ?? "", isPresented: alertShown, presenting: app.alert) { _ in
            Button("OK") {}
        } message: { alert in
            Text(alert.message)
        }
    }

    private var alertShown: Binding<Bool> {
        Binding(get: { app.alert != nil }, set: { if !$0 { app.alert = nil } })
    }
}
