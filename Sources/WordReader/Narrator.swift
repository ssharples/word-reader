import AVFoundation
import Observation
import OSLog
import ReaderCore

/// Reads the book aloud with ElevenLabs and reports which word is being spoken,
/// so the word on screen always matches the voice.
@MainActor @Observable
final class Narrator {
    /// True while waiting for the voice to start.
    private(set) var isLoading = false

    @ObservationIgnored var onWord: (Int) -> Void = { _ in }
    @ObservationIgnored var onFinish: () -> Void = {}
    @ObservationIgnored var onFailure: (Error) -> Void = { _ in }

    @ObservationIgnored private let text: BookText
    @ObservationIgnored private var playing: (clip: SpeechLoader.Clip, player: AVAudioPlayer)?
    @ObservationIgnored private var loop: Task<Void, Never>?
    /// The word playback started from in the current passage. Seeking in an MP3 can land
    /// a little early, and this stops the word before it flashing up.
    @ObservationIgnored private var firstWord = 0
    /// Passages spoken lately. Starting again inside one reuses its saved audio.
    @ObservationIgnored private var recent: [SpeechPassage] = []

    private static let log = Logger(subsystem: "com.ssharples.WordReader", category: "voice")

    init(text: BookText) {
        self.text = text
    }

    func start(at index: Int) {
        stop()
        loop = Task { [weak self] in await self?.run(from: index) }
    }

    func stop() {
        loop?.cancel()
        loop = nil
        playing?.player.stop()
        playing = nil
        isLoading = false
    }

    /// Jumps within the passage being spoken, or starts again from `index`.
    func seek(to index: Int) {
        guard loop != nil else { return }
        if let playing, playing.clip.passage.words.contains(index) {
            firstWord = index - playing.clip.passage.words.lowerBound
            playing.player.currentTime = playing.clip.startTimes[firstWord]
        } else {
            start(at: index)
        }
    }

    private func run(from index: Int) async {
        guard let loader = VoiceSettings.loader() else {
            onFailure(ElevenLabs.Failure.noKey)
            return
        }
        var passage = recent.last { $0.words.contains(index) }
            ?? SpeechPassage(from: SpeechPassage.sentenceStart(of: index, in: text), in: text, length: .opening)
        var previous: SpeechPassage?
        var seekTo: Int? = index
        var next: Task<SpeechLoader.Clip, Error>?
        defer { next?.cancel() }

        while !Task.isCancelled {
            let clip: SpeechLoader.Clip
            let player: AVAudioPlayer
            do {
                isLoading = next == nil
                let pending = next ?? Task { [passage, previous] in try await loader.load(passage, after: previous) }
                clip = try await pending.value
                player = try AVAudioPlayer(contentsOf: clip.audio)
                isLoading = false
            } catch {
                isLoading = false
                if !Task.isCancelled { onFailure(error) }
                return
            }
            guard !Task.isCancelled else { return }

            // Fetch the next passage while this one plays.
            let following = clip.passage.words.upperBound < text.count
                ? SpeechPassage(from: clip.passage.words.upperBound, in: text, length: .flowing) : nil
            next = following.map { following in Task { try await loader.load(following, after: clip.passage) } }

            player.enableRate = true
            player.volume = Float(UserDefaults.standard.object(forKey: Prefs.voiceVolume) as? Double ?? 1)
            player.prepareToPlay()
            firstWord = 0
            if let seekTo, clip.passage.words.contains(seekTo) {
                firstWord = seekTo - clip.passage.words.lowerBound
                player.currentTime = clip.startTimes[firstWord]
            }
            seekTo = nil
            recent = (recent.filter { $0 != clip.passage } + [clip.passage]).suffix(8)
            setRate(of: player, for: clip)
            playing = (clip, player)
            player.play()
            Self.log.info("speaking words \(clip.passage.words.lowerBound)..<\(clip.passage.words.upperBound), \(clip.passage.text.count) letters, \(player.duration, format: .fixed(precision: 1)) s")

            var spoken = -1
            while player.isPlaying, !Task.isCancelled {
                setRate(of: player, for: clip)
                let word = max(SpeechPassage.word(at: player.currentTime, startTimes: clip.startTimes), firstWord)
                if word != spoken {
                    spoken = word
                    onWord(clip.passage.words.lowerBound + word)
                    Self.log.debug("word \(clip.passage.words.lowerBound + word) due \(clip.startTimes[word], format: .fixed(precision: 3)) shown \(player.currentTime, format: .fixed(precision: 3))")
                }
                try? await Task.sleep(for: .milliseconds(15))
            }
            guard !Task.isCancelled else { return }
            playing = nil
            guard let following else {
                loop = nil
                onWord(text.count - 1)
                onFinish()
                return
            }
            previous = clip.passage
            passage = following
        }
    }

    /// Speeds the voice up or slows it down to match the words-a-minute setting,
    /// within what still sounds natural.
    private func setRate(of player: AVAudioPlayer, for clip: SpeechLoader.Clip) {
        let seconds = player.duration
        guard seconds > 0 else { return }
        let natural = Double(clip.passage.words.count) / seconds * 60
        let wanted = Double(UserDefaults.standard.integer(forKey: Prefs.wordsPerMinute))
        let rate = Float(min(max(wanted / natural, 0.5), 2.0))
        if abs(player.rate - rate) > 0.01 { player.rate = rate }
    }
}
