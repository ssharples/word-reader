import ReaderKit
import SwiftUI

/// Reading and text settings, and from the library, the sync folder too.
struct SettingsScreen: View {
    @Environment(PhoneModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    var inReader = false

    @AppStorage(Prefs.wordsPerMinute) private var wordsPerMinute = 300
    @AppStorage(Prefs.naturalPauses) private var naturalPauses = true
    @AppStorage(Prefs.fontSize) private var fontSize = Prefs.defaultFontSize
    @AppStorage(Prefs.fontStyle) private var fontStyle = ReaderFont.serif.rawValue
    @AppStorage(Prefs.showFocusLetter) private var showFocusLetter = true
    @State private var choosingFolder = false
    @State private var confirmStop = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    LabeledContent("Speed") {
                        Text("\(wordsPerMinute) words a minute")
                            .monospacedDigit()
                    }
                    Slider(value: speedValue, in: Double(Prefs.speedRange.lowerBound)...Double(Prefs.speedRange.upperBound)) {
                        Text("Speed")
                    } minimumValueLabel: {
                        Image(systemName: "tortoise.fill").foregroundStyle(.secondary)
                    } maximumValueLabel: {
                        Image(systemName: "hare.fill").foregroundStyle(.secondary)
                    }
                    Toggle("Pause at punctuation", isOn: $naturalPauses)
                } header: {
                    Text("Reading")
                } footer: {
                    Text("Pausing at punctuation holds a word a little longer after a comma or full stop, the way you'd pause reading aloud.")
                }

                Section("Text") {
                    LabeledContent("Size") {
                        Text("\(Int(fontSize)) pt").monospacedDigit()
                    }
                    Slider(value: $fontSize, in: Prefs.fontSizeRange, step: 2) {
                        Text("Size")
                    } minimumValueLabel: {
                        Image(systemName: "textformat.size.smaller").foregroundStyle(.secondary)
                    } maximumValueLabel: {
                        Image(systemName: "textformat.size.larger").foregroundStyle(.secondary)
                    }
                    Picker("Font", selection: $fontStyle) {
                        ForEach(ReaderFont.allCases) { font in
                            Text(font.label).tag(font.rawValue)
                        }
                    }
                    .pickerStyle(.segmented)
                    Toggle("Colour the focus letter", isOn: $showFocusLetter)
                }

                if !inReader {
                    syncSection
                    Section {
                        Link(destination: URL(string: "https://github.com/ssharples/word-reader")!) {
                            Label("Word Reader on GitHub", systemImage: "chevron.left.forwardslash.chevron.right")
                        }
                    } footer: {
                        Text("Word Reader is free and open source. Your books stay on your devices and in your own iCloud Drive.")
                    }
                }
            }
            .navigationTitle(inReader ? "Reading" : "Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .fileImporter(isPresented: $choosingFolder, allowedContentTypes: [.folder]) { result in
                if case .success(let url) = result {
                    Task { await model.useSyncFolder(url) }
                }
            }
            .confirmationDialog("Stop syncing?", isPresented: $confirmStop, titleVisibility: .visible) {
                Button("Stop Syncing", role: .destructive) {
                    Task { await model.stopSyncing() }
                }
            } message: {
                Text("Books in the sync folder stay there, but this iPhone won't show them or share your place in them until you choose the folder again.")
            }
        }
    }

    @ViewBuilder private var syncSection: some View {
        Section {
            if let name = model.syncFolderName {
                LabeledContent("Folder", value: name)
                if let problem = model.sync.problem {
                    Label(problem, systemImage: "exclamationmark.icloud")
                        .foregroundStyle(.red)
                } else if let synced = model.sync.lastSynced {
                    LabeledContent("Last synced") {
                        Text(synced, format: .relative(presentation: .named))
                    }
                }
                Button("Choose Another Folder") { choosingFolder = true }
                Button("Stop Syncing", role: .destructive) { confirmStop = true }
            } else {
                Button {
                    choosingFolder = true
                } label: {
                    Label("Choose Sync Folder", systemImage: "folder.badge.gearshape")
                }
            }
        } header: {
            Text("Sync with Mac")
        } footer: {
            Text("On your Mac, open Word Reader, click the cloud button and turn on Sync with iPhone. Then choose iCloud Drive › Word Reader here. Books you add on either one show up on both, and each opens where you stopped.")
        }
    }

    private var speedValue: Binding<Double> {
        Binding(
            get: { Double(wordsPerMinute) },
            set: { wordsPerMinute = Int(($0 / Double(Prefs.speedStep)).rounded()) * Prefs.speedStep }
        )
    }
}
