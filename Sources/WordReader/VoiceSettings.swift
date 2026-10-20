import ReaderCore
import ReaderKit
import SwiftUI

/// The Settings window: the ElevenLabs key, voice and model for reading aloud.
struct VoiceSettings: View {
    @AppStorage(Prefs.voiceID) private var voiceID = ReadAloud.defaultVoice
    @AppStorage(Prefs.voiceModel) private var model = VoiceModel.flash.rawValue

    @State private var hasKey = ReadAloud.apiKey != nil
    @State private var keyDraft = ""
    @State private var voices = ReadAloud.premadeVoices
    @State private var voiceNote: String?

    var body: some View {
        Form {
            Section {
                if hasKey {
                    LabeledContent("API key") {
                        HStack {
                            Text(Keychain.read() == nil ? "Taken from ELEVENLABS_API_KEY" : "Saved in your keychain")
                                .foregroundStyle(.secondary)
                            if Keychain.read() != nil {
                                Button("Remove") {
                                    Keychain.delete()
                                    hasKey = ReadAloud.apiKey != nil
                                    voices = ReadAloud.premadeVoices
                                }
                            }
                        }
                    }
                } else {
                    HStack {
                        SecureField("API key", text: $keyDraft, prompt: Text("Paste your key here"))
                            .onSubmit(saveKey)
                        Button("Save", action: saveKey)
                            .disabled(keyDraft.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }
            } header: {
                Text("ElevenLabs")
            } footer: {
                Text("Make a key at [elevenlabs.io](https://elevenlabs.io/app/settings/api-keys) under Developers → API Keys. It needs Text to Speech access. Give it Voices read access too and your own voices appear below.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section {
                Picker("Voice", selection: $voiceID) {
                    ForEach(voices) { voice in
                        Text(voice.name).tag(voice.voiceId)
                    }
                    if !voices.contains(where: { $0.voiceId == voiceID }) {
                        Text("Voice \(voiceID)").tag(voiceID)
                    }
                }
                TextField("Voice ID", text: $voiceID, prompt: Text("Paste a voice ID from your ElevenLabs library"))
                Picker("Model", selection: $model) {
                    ForEach(VoiceModel.allCases) { model in
                        Text(model.label).tag(model.rawValue)
                    }
                }
            } footer: {
                VStack(alignment: .leading, spacing: 6) {
                    if let voiceNote {
                        Text(voiceNote)
                    }
                    Text("Reading aloud sends the text to ElevenLabs and uses your account's credits. Each passage is saved on this Mac, so hearing it again costs nothing.")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
        .formStyle(.grouped)
        .frame(width: 460)
        .fixedSize(horizontal: false, vertical: true)
        .task(id: hasKey) { await loadVoices() }
    }

    private func saveKey() {
        let key = keyDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return }
        Keychain.save(key)
        keyDraft = ""
        hasKey = true
    }

    /// Adds the account's own voices to the list, when the key is allowed to read them.
    private func loadVoices() async {
        guard ReadAloud.apiKey != nil else { return }
        (voices, voiceNote) = await ReadAloud.voices()
    }
}
