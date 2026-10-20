import ReaderCore
import Security
import SwiftUI

/// The Settings window: the ElevenLabs key, voice and model for reading aloud.
struct VoiceSettings: View {
    @AppStorage(Prefs.voiceID) private var voiceID = VoiceSettings.defaultVoice
    @AppStorage(Prefs.voiceModel) private var model = VoiceModel.flash.rawValue

    @State private var hasKey = VoiceSettings.apiKey != nil
    @State private var keyDraft = ""
    @State private var voices = VoiceSettings.premadeVoices
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
                                    hasKey = VoiceSettings.apiKey != nil
                                    voices = VoiceSettings.premadeVoices
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
        guard let key = VoiceSettings.apiKey else { return }
        do {
            let mine = try await ElevenLabs(apiKey: key).voices()
            let premade = Set(VoiceSettings.premadeVoices.map(\.voiceId))
            voices = VoiceSettings.premadeVoices + mine.filter { !premade.contains($0.voiceId) }
                .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            voiceNote = nil
        } catch {
            voiceNote = "Showing ElevenLabs' standard voices. Your key can't list the voices on your account."
        }
    }

    // MARK: Shared settings

    nonisolated static let defaultVoice = "JBFqnCBsd6RMkjVDRZzb"

    /// Voices every ElevenLabs account has.
    static let premadeVoices = [
        ElevenLabs.Voice(voiceId: "JBFqnCBsd6RMkjVDRZzb", name: "George: British, warm storyteller"),
        ElevenLabs.Voice(voiceId: "hpp4J3VqNfWAUOO0d1Us", name: "Bella: American, bright and warm"),
        ElevenLabs.Voice(voiceId: "EXAVITQu4vr4xnSDxMaL", name: "Sarah: American, reassuring"),
        ElevenLabs.Voice(voiceId: "SAz9YHcvj6GT2YYXdXww", name: "River: American, calm"),
        ElevenLabs.Voice(voiceId: "CwhRBWXzGAHq8TQ4Fs17", name: "Roger: American, laid-back"),
        ElevenLabs.Voice(voiceId: "IKne3meq5aSn9XLyUdCD", name: "Charlie: Australian, lively"),
    ]

    /// The key from the keychain, or from the environment when run from Terminal.
    static var apiKey: String? {
        if let key = Keychain.read() { return key }
        let key = ProcessInfo.processInfo.environment["ELEVENLABS_API_KEY"]
        return key?.isEmpty == false ? key : nil
    }

    static func loader() -> SpeechLoader? {
        guard let key = apiKey else { return nil }
        let defaults = UserDefaults.standard
        let voice = defaults.string(forKey: Prefs.voiceID)?.trimmingCharacters(in: .whitespaces) ?? ""
        return SpeechLoader(
            client: ElevenLabs(apiKey: key),
            voice: voice.isEmpty ? defaultVoice : voice,
            model: defaults.string(forKey: Prefs.voiceModel) ?? VoiceModel.flash.rawValue
        )
    }
}

enum VoiceModel: String, CaseIterable, Identifiable {
    case flash = "eleven_flash_v2_5"
    case multilingual = "eleven_multilingual_v2"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .flash: "Flash: quick, uses fewer credits"
        case .multilingual: "Multilingual v2: richer, uses more credits"
        }
    }
}

/// Keeps the ElevenLabs key in the login keychain rather than in preferences.
enum Keychain {
    private static var query: [String: Any] { [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: "Word Reader ElevenLabs",
        kSecAttrAccount as String: "api-key",
    ] }

    static func read() -> String? {
        var search = query
        search[kSecReturnData as String] = true
        search[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        guard SecItemCopyMatching(search as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func save(_ value: String) {
        delete()
        var item = query
        item[kSecValueData as String] = Data(value.utf8)
        SecItemAdd(item as CFDictionary, nil)
    }

    static func delete() {
        SecItemDelete(query as CFDictionary)
    }
}
