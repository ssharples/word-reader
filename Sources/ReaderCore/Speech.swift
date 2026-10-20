import CryptoKit
import Foundation

/// A stretch of a book sent to the voice service in one request.
public struct SpeechPassage: Hashable, Sendable {
    /// How long a passage should be, in letters.
    public struct Length: Sendable {
        /// End at a paragraph break once the passage is this long.
        public let minimum: Int
        /// End at a full stop once the passage is this long.
        public let target: Int
        /// End at any word once the passage is this long.
        public let maximum: Int

        /// Short, so the voice starts quickly.
        public static let opening = Length(minimum: 1, target: 120, maximum: 600)
        /// Longer, fetched while the one before it plays.
        public static let flowing = Length(minimum: 300, target: 900, maximum: 2000)
    }

    /// The words it covers.
    public let words: Range<Int>
    /// The words joined into text, with a line break after each paragraph.
    public let text: String
    /// Where each word starts in `text`, counted in Unicode scalars, the unit
    /// ElevenLabs uses for its timings.
    public let offsets: [Int]

    public init(from start: Int, in book: BookText, length: Length) {
        var text = ""
        var offsets: [Int] = []
        var scalars = 0
        var end = start
        while end < book.count {
            let word = book.words[end]
            if end > start {
                let gap = book.isParagraphEnd(end - 1) ? "\n" : " "
                text += gap
                scalars += 1
            }
            offsets.append(scalars)
            text += word
            scalars += word.unicodeScalars.count
            end += 1
            if scalars >= length.maximum { break }
            if book.endsSentence(end - 1) {
                if scalars >= length.target { break }
                if book.isParagraphEnd(end - 1), scalars >= length.minimum { break }
            }
            // A chapter heading starts a passage of its own.
            if end < book.count, book.isChapterStart(end) { break }
        }
        self.words = start..<end
        self.text = text
        self.offsets = offsets
    }

    /// The first word of the sentence that holds `index`, so speech starts at a natural place.
    public static func sentenceStart(of index: Int, in book: BookText) -> Int {
        var start = index
        while start > 0, index - start < 80, !book.endsSentence(start - 1) { start -= 1 }
        return start
    }

    /// When each word starts, in seconds from the start of the audio.
    public func startTimes(_ alignment: SpeechAlignment) -> [Double] {
        let times = alignment.characterStartTimesSeconds
        guard !times.isEmpty else { return offsets.map { _ in 0 } }
        let length = text.unicodeScalars.count
        var previous = 0.0
        return offsets.map { offset in
            // The timings line up letter for letter with the text sent. If they ever
            // don't, fall back to the same proportion of the way through.
            let position = times.count == length ? offset : offset * times.count / max(length, 1)
            previous = max(previous, times[min(position, times.count - 1)])
            return previous
        }
    }

    /// The word being spoken `seconds` into the audio, as an offset into `words`.
    public static func word(at seconds: Double, startTimes: [Double]) -> Int {
        var low = 0
        var high = startTimes.count - 1
        var found = 0
        while low <= high {
            let mid = (low + high) / 2
            if startTimes[mid] <= seconds {
                found = mid
                low = mid + 1
            } else {
                high = mid - 1
            }
        }
        return found
    }
}

/// When each letter of the text is spoken.
public struct SpeechAlignment: Codable, Hashable, Sendable {
    public let characters: [String]
    public let characterStartTimesSeconds: [Double]
    public let characterEndTimesSeconds: [Double]

    public init(characters: [String], characterStartTimesSeconds: [Double], characterEndTimesSeconds: [Double]) {
        self.characters = characters
        self.characterStartTimesSeconds = characterStartTimesSeconds
        self.characterEndTimesSeconds = characterEndTimesSeconds
    }
}

/// The ElevenLabs text-to-speech API.
public struct ElevenLabs: Sendable {
    public static let audioFormat = "mp3_44100_64"

    public struct Speech: Sendable {
        public let audio: Data
        public let alignment: SpeechAlignment
    }

    public struct Voice: Decodable, Hashable, Identifiable, Sendable {
        public let voiceId: String
        public let name: String
        public var id: String { voiceId }

        public init(voiceId: String, name: String) {
            self.voiceId = voiceId
            self.name = name
        }
    }

    public enum Failure: LocalizedError {
        case noKey
        case refused(status: Int, message: String)

        public var errorDescription: String? {
            switch self {
            case .noKey:
                "Add your ElevenLabs API key in Settings to hear books read aloud."
            case .refused(let status, let message):
                status == 401 ? "ElevenLabs didn't accept your API key. \(message)" : "ElevenLabs said: \(message)"
            }
        }
    }

    let apiKey: String
    let session: URLSession

    public init(apiKey: String, session: URLSession = .shared) {
        self.apiKey = apiKey
        self.session = session
    }

    /// Speaks `text`, with the time each letter starts. `previousText` is the text just
    /// before it, which helps the voice carry on in the same tone.
    public func speak(_ text: String, voice: String, model: String, previousText: String?) async throws -> Speech {
        var components = URLComponents(string: "https://api.elevenlabs.io/v1/text-to-speech")!
        components.path += "/\(voice)/with-timestamps"
        components.queryItems = [URLQueryItem(name: "output_format", value: Self.audioFormat)]
        var body: [String: String] = ["text": text, "model_id": model]
        body["previous_text"] = previousText
        let data = try await send(components.url!, body: try JSONEncoder().encode(body))
        return try Self.decodeSpeech(data)
    }

    /// The voices on the account. Needs a key with permission to read voices.
    public func voices() async throws -> [Voice] {
        struct List: Decodable { let voices: [Voice] }
        let data = try await send(URL(string: "https://api.elevenlabs.io/v1/voices")!, body: nil)
        return try Self.decoder.decode(List.self, from: data).voices
    }

    private func send(_ url: URL, body: Data?) async throws -> Data {
        var request = URLRequest(url: url)
        request.setValue(apiKey, forHTTPHeaderField: "xi-api-key")
        if let body {
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = body
        }
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            throw Failure.refused(status: status, message: Self.errorMessage(data) ?? "Error \(status).")
        }
        return data
    }

    static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return decoder
    }()

    static func decodeSpeech(_ data: Data) throws -> Speech {
        struct Response: Decodable {
            let audioBase64: String
            let alignment: SpeechAlignment?
        }
        let response = try decoder.decode(Response.self, from: data)
        guard let audio = Data(base64Encoded: response.audioBase64), let alignment = response.alignment else {
            throw Failure.refused(status: 200, message: "The reply had no audio or timings.")
        }
        return Speech(audio: audio, alignment: alignment)
    }

    /// The message in an error reply: `{"detail": {"message": …}}` or `{"detail": "…"}`.
    static func errorMessage(_ data: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        if let detail = object["detail"] as? [String: Any] { return detail["message"] as? String }
        return object["detail"] as? String
    }
}

/// Spoken passages saved on disk, so listening again costs nothing.
public struct SpeechCache: Sendable {
    public let folder: URL

    public init(folder: URL) {
        self.folder = folder
    }

    public static let standard = SpeechCache(
        folder: URL.cachesDirectory.appending(path: "com.ssharples.WordReader/Speech", directoryHint: .isDirectory)
    )

    public static func key(text: String, voice: String, model: String) -> String {
        let digest = SHA256.hash(data: Data("\(voice)\n\(model)\n\(ElevenLabs.audioFormat)\n\(text)".utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    public func audioURL(_ key: String) -> URL { folder.appending(path: "\(key).mp3") }
    private func timingURL(_ key: String) -> URL { folder.appending(path: "\(key).json") }

    public func alignment(_ key: String) -> SpeechAlignment? {
        guard FileManager.default.fileExists(atPath: audioURL(key).path),
              let data = try? Data(contentsOf: timingURL(key)) else { return nil }
        // Mark it as recently used, so trimming keeps it.
        try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: timingURL(key).path)
        return try? JSONDecoder().decode(SpeechAlignment.self, from: data)
    }

    public func save(_ speech: ElevenLabs.Speech, key: String) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try speech.audio.write(to: audioURL(key), options: .atomic)
        try JSONEncoder().encode(speech.alignment).write(to: timingURL(key), options: .atomic)
    }

    /// Deletes the least recently used passages until the cache fits in `bytes`.
    public func trim(toBytes bytes: Int) {
        let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey]
        guard let files = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: keys) else { return }
        struct Entry { let key: String; let size: Int; let used: Date }
        var entries: [String: Entry] = [:]
        for file in files {
            let values = try? file.resourceValues(forKeys: Set(keys))
            let key = file.deletingPathExtension().lastPathComponent
            let old = entries[key]
            entries[key] = Entry(
                key: key,
                size: (old?.size ?? 0) + (values?.fileSize ?? 0),
                used: max(old?.used ?? .distantPast, values?.contentModificationDate ?? .distantPast)
            )
        }
        var total = entries.values.reduce(0) { $0 + $1.size }
        for entry in entries.values.sorted(by: { $0.used < $1.used }) where total > bytes {
            try? FileManager.default.removeItem(at: audioURL(entry.key))
            try? FileManager.default.removeItem(at: timingURL(entry.key))
            total -= entry.size
        }
    }
}

/// Fetches spoken passages, from the cache when it has them.
public struct SpeechLoader: Sendable {
    public struct Clip: Sendable {
        public let passage: SpeechPassage
        public let audio: URL
        public let startTimes: [Double]
    }

    let client: ElevenLabs
    let cache: SpeechCache
    let voice: String
    let model: String

    public init(client: ElevenLabs, cache: SpeechCache = .standard, voice: String, model: String) {
        self.client = client
        self.cache = cache
        self.voice = voice
        self.model = model
    }

    public func load(_ passage: SpeechPassage, after previous: SpeechPassage?) async throws -> Clip {
        let key = SpeechCache.key(text: passage.text, voice: voice, model: model)
        let alignment: SpeechAlignment
        if let saved = cache.alignment(key) {
            alignment = saved
        } else {
            // The last few hundred letters are enough to carry the tone over.
            let previousText = previous.map { String($0.text.suffix(300)) }
            let speech = try await client.speak(passage.text, voice: voice, model: model, previousText: previousText)
            try cache.save(speech, key: key)
            alignment = speech.alignment
        }
        return Clip(passage: passage, audio: cache.audioURL(key), startTimes: passage.startTimes(alignment))
    }
}
