import ReaderKit
import SwiftUI

/// Turns syncing with the iPhone app on and off, and picks the folder it goes through.
struct SyncSettings: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        Form {
            Section {
                Toggle("Sync with iPhone", isOn: syncing)
            } footer: {
                Text("Books you open, and your place in each, go to a folder that Word Reader on your iPhone reads too. Right-click a book and choose Add to iPhone to send one without opening it.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Section {
                LabeledContent("Folder") {
                    Text(folderName)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(app.syncFolderURL.path(percentEncoded: false))
                }
                HStack {
                    Button("Change…") { app.chooseSyncFolder() }
                    Button("Show in Finder") { app.showSyncFolder() }
                        .disabled(!app.isSyncing)
                }
                if let problem = app.sync.problem {
                    Label(problem, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                } else if app.isSyncing {
                    LabeledContent("Last synced") {
                        if let date = app.sync.lastSynced {
                            Text(date, format: .relative(presentation: .named))
                        } else {
                            Text("Not yet")
                        }
                    }
                }
            } footer: {
                Text("On your iPhone, open Word Reader, tap Sync and choose this folder in Files.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .formStyle(.grouped)
        .frame(width: 380)
        .fixedSize(horizontal: false, vertical: true)
    }

    private var syncing: Binding<Bool> {
        Binding(get: { app.isSyncing }, set: { on in Task { await app.setSyncing(on) } })
    }

    /// "iCloud Drive › Word Reader" rather than the long path behind it.
    private var folderName: String {
        let path = app.syncFolderURL.path(percentEncoded: false)
        let iCloud = SyncFolder.iCloudDrive.deletingLastPathComponent().path(percentEncoded: false)
        guard path.hasPrefix(iCloud) else { return (path as NSString).abbreviatingWithTildeInPath }
        let rest = path.dropFirst(iCloud.count).split(separator: "/")
        return (["iCloud Drive"] + rest.map(String.init)).joined(separator: " › ")
    }
}
