import Foundation
import ReaderCore
import Security

/// The ElevenLabs key, voice and model that Read Aloud uses, on the Mac and iPhone alike.
public enum ReadAloud {
    public static let defaultVoice = "JBFqnCBsd6RMkjVDRZzb"

    /// Voices every ElevenLabs account has.
    public static let premadeVoices = [
        ElevenLabs.Voice(voiceId: "JBFqnCBsd6RMkjVDRZzb", name: "George: British, warm storyteller"),
        ElevenLabs.Voice(voiceId: "hpp4J3VqNfWAUOO0d1Us", name: "Bella: American, bright and warm"),
        ElevenLabs.Voice(voiceId: "EXAVITQu4vr4xnSDxMaL", name: "Sarah: American, reassuring"),
        ElevenLabs.Voice(voiceId: "SAz9YHcvj6GT2YYXdXww", name: "River: American, calm"),
        ElevenLabs.Voice(voiceId: "CwhRBWXzGAHq8TQ4Fs17", name: "Roger: American, laid-back"),
        ElevenLabs.Voice(voiceId: "IKne3meq5aSn9XLyUdCD", name: "Charlie: Australian, lively"),
    ]

    /// The key from the keychain, or from the environment when run from Terminal.
    public static var apiKey: String? {
        if let key = Keychain.read() { return key }
        let key = ProcessInfo.processInfo.environment["ELEVENLABS_API_KEY"]
        return key?.isEmpty == false ? key : nil
    }

    public static func loader() -> SpeechLoader? {
        guard let key = apiKey else { return nil }
        let defaults = UserDefaults.standard
        let voice = defaults.string(forKey: Prefs.voiceID)?.trimmingCharacters(in: .whitespaces) ?? ""
        return SpeechLoader(
            client: ElevenLabs(apiKey: key),
            voice: voice.isEmpty ? defaultVoice : voice,
            model: defaults.string(forKey: Prefs.voiceModel) ?? VoiceModel.flash.rawValue
        )
    }

    /// The premade voices plus the account's own, when the key is allowed to list them.
    /// The note says why only the premade ones are shown, if that's the case.
    public static func voices() async -> (voices: [ElevenLabs.Voice], note: String?) {
        guard let key = apiKey else { return (premadeVoices, nil) }
        do {
            let mine = try await ElevenLabs(apiKey: key).voices()
            let premade = Set(premadeVoices.map(\.voiceId))
            let extra = mine.filter { !premade.contains($0.voiceId) }
                .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            return (premadeVoices + extra, nil)
        } catch {
            return (premadeVoices, "Showing ElevenLabs' standard voices. Your key can't list the voices on your account.")
        }
    }
}

public enum VoiceModel: String, CaseIterable, Identifiable, Sendable {
    case flash = "eleven_flash_v2_5"
    case multilingual = "eleven_multilingual_v2"

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .flash: "Flash: quick, uses fewer credits"
        case .multilingual: "Multilingual v2: richer, uses more credits"
        }
    }
}

/// Keeps the ElevenLabs key in the keychain rather than in preferences.
public enum Keychain {
    private static var query: [String: Any] { [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: "Word Reader ElevenLabs",
        kSecAttrAccount as String: "api-key",
    ] }

    public static func read() -> String? {
        var search = query
        search[kSecReturnData as String] = true
        search[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        guard SecItemCopyMatching(search as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    public static func save(_ value: String) {
        delete()
        var item = query
        item[kSecValueData as String] = Data(value.utf8)
        #if os(iOS)
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        #endif
        SecItemAdd(item as CFDictionary, nil)
    }

    public static func delete() {
        SecItemDelete(query as CFDictionary)
    }
}
