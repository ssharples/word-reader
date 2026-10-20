import Foundation
import Observation
import ReaderCore

/// Plays an open book one word at a time.
@MainActor @Observable
final class ReaderSession {
    let book: BookInfo
    let text: BookText

    private(set) var index: Int {
        didSet {
            let chapter = text.chapterIndex(at: index)
            if chapter != chapterIndex { chapterIndex = chapter }
        }
    }
    /// Stored apart from `index` so views that only show the chapter don't redraw on every word.
    private(set) var chapterIndex: Int?
    private(set) var isPlaying = false
    private(set) var reachedEnd = false
    /// The voice that reads the book aloud, made the first time it plays with Read Aloud on.
    private(set) var narrator: Narrator?
    /// Why reading aloud stopped, shown once.
    var voiceProblem: String?

    @ObservationIgnored private let progress: ProgressStore
    @ObservationIgnored private var playback: Task<Void, Never>?
    @ObservationIgnored private var wordsSinceSave = 0

    init(book: BookInfo, text: BookText, startAt index: Int, progress: ProgressStore) {
        self.book = book
        self.text = text
        self.index = index
        self.chapterIndex = text.chapterIndex(at: index)
        self.progress = progress
    }

    var word: String { text.words[index] }
    var fraction: Double { text.count > 1 ? Double(index) / Double(text.count - 1) : 1 }
    var chapterTitle: String? { chapterIndex.map { text.chapters[$0].title } }

    // MARK: Playback

    func togglePlayback() {
        isPlaying ? pause() : play()
    }

    func play() {
        guard !isPlaying else { return }
        if index >= text.count - 1 { index = text.startIndex }
        reachedEnd = false
        isPlaying = true
        if UserDefaults.standard.bool(forKey: Prefs.readAloud) {
            readingNarrator().start(at: index)
        } else {
            playback = Task { [weak self] in await self?.run() }
        }
    }

    func pause() {
        guard isPlaying else { return }
        isPlaying = false
        playback?.cancel()
        playback = nil
        narrator?.stop()
        save()
    }

    /// Kept for the whole book, so pausing and playing again reuses the audio it has.
    private func readingNarrator() -> Narrator {
        if let narrator { return narrator }
        let narrator = Narrator(text: text)
        narrator.onWord = { [weak self] in self?.advance(to: $0) }
        narrator.onFinish = { [weak self] in self?.finish() }
        narrator.onFailure = { [weak self] error in
            self?.pause()
            self?.voiceProblem = error.localizedDescription
        }
        self.narrator = narrator
        return narrator
    }

    /// Turns Read Aloud on or off, carrying on from the same word if playing.
    func setReadAloud(_ on: Bool) {
        UserDefaults.standard.set(on, forKey: Prefs.readAloud)
        guard isPlaying else { return }
        pause()
        play()
    }

    private func run() async {
        let clock = ContinuousClock()
        var deadline = clock.now
        var warmUp = 3
        while isPlaying, !Task.isCancelled {
            let defaults = UserDefaults.standard
            var seconds = WordTiming.duration(
                of: index, in: text,
                wordsPerMinute: defaults.integer(forKey: Prefs.wordsPerMinute),
                naturalPauses: defaults.bool(forKey: Prefs.naturalPauses)
            )
            // Ease in over the first few words after pressing play.
            if warmUp > 0 {
                seconds *= 1 + 0.25 * Double(warmUp)
                warmUp -= 1
            }
            // Timing runs off fixed deadlines so small delays don't add up,
            // but after a long stall it starts afresh rather than racing to catch up.
            let now = clock.now
            if deadline < now - .milliseconds(100) { deadline = now }
            deadline += .seconds(seconds)
            do {
                try await clock.sleep(until: deadline, tolerance: .milliseconds(2))
            } catch {
                return
            }
            guard isPlaying, !Task.isCancelled else { return }
            if index + 1 >= text.count {
                finish()
                return
            }
            advance(to: index + 1)
        }
    }

    private func advance(to newIndex: Int) {
        guard newIndex != index else { return }
        index = newIndex
        wordsSinceSave += 1
        if wordsSinceSave >= 25 { save() }
    }

    private func finish() {
        isPlaying = false
        reachedEnd = true
        playback = nil
        save()
    }

    // MARK: Moving around

    func move(to newIndex: Int) {
        index = min(max(newIndex, 0), text.count - 1)
        reachedEnd = false
        if isPlaying { narrator?.seek(to: index) }
        save()
    }

    func step(_ delta: Int) {
        move(to: index + delta)
    }

    /// Back to the start of this sentence, or the one before if already there.
    func previousSentence() {
        guard index > 0 else { return }
        var i = index - 1
        while i > 0, !text.endsSentence(i - 1) { i -= 1 }
        move(to: i)
    }

    func nextSentence() {
        var i = index
        while i < text.count - 1, !text.endsSentence(i) { i += 1 }
        move(to: i + 1)
    }

    /// Back to the start of this chapter, or the previous one if just started.
    func previousChapter() {
        let starts = text.chapters.map(\.wordIndex)
        let current = starts.last { $0 <= index } ?? 0
        if index - current > 20 {
            move(to: current)
        } else {
            move(to: starts.last { $0 < current } ?? 0)
        }
    }

    func nextChapter() {
        if let next = text.chapters.first(where: { $0.wordIndex > index }) {
            move(to: next.wordIndex)
        }
    }

    func jump(toChapter number: Int) {
        guard text.chapters.indices.contains(number) else { return }
        move(to: text.chapters[number].wordIndex)
    }

    /// Words around the current one, within its paragraph, for showing while paused.
    func context(radius: Int = 28) -> (before: String, word: String, after: String) {
        var start = index
        while start > 0, index - start < radius, !text.isParagraphEnd(start - 1) { start -= 1 }
        var end = index
        while end < text.count - 1, end - index < radius, !text.isParagraphEnd(end) { end += 1 }
        var before = text.words[start..<index].joined(separator: " ")
        var after = text.words[(index + 1)..<(end + 1)].joined(separator: " ")
        if start > 0, !text.isParagraphEnd(start - 1) { before = "…" + before }
        if end < text.count - 1, !text.isParagraphEnd(end) { after += "…" }
        return (before, word, after)
    }

    private func save() {
        wordsSinceSave = 0
        progress.update(book.id, index: index, total: text.count)
    }
}
