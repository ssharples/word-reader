import Foundation
import Testing
@testable import ReaderCore

@Suite struct SpeechTests {
    /// Two short chapters: a heading, then a paragraph of three sentences.
    static func book() -> BookText {
        var builder = BookBuilder()
        builder.appendParagraph("Chapter One")
        builder.appendParagraph("It was late. “Who’s there?” she said. Nobody answered.")
        builder.appendParagraph("Chapter Two")
        builder.appendParagraph("Morning came.")
        var flags = builder.flags
        flags[0] |= BookText.chapterStart
        flags[11] |= BookText.chapterStart
        return BookText(words: builder.words, flags: flags, chapters: [
            BookChapter(title: "Chapter One", wordIndex: 0, level: 0),
            BookChapter(title: "Chapter Two", wordIndex: 11, level: 0),
        ])
    }

    @Test func joinsWordsWithLineBreaksBetweenParagraphs() {
        let passage = SpeechPassage(from: 0, in: Self.book(), length: .flowing)
        #expect(passage.words == 0..<11)
        #expect(passage.text == "Chapter One\nIt was late. “Who’s there?” she said. Nobody answered.")
        let scalars = Array(passage.text.unicodeScalars)
        let words = passage.offsets.map { offset in
            String(String.UnicodeScalarView(scalars[offset...].prefix { $0 != " " && $0 != "\n" }))
        }
        #expect(words == Self.book().words[0..<11].map { $0 })
    }

    @Test func endsAtAFullStopOnceLongEnough() {
        let short = SpeechPassage.Length(minimum: 1, target: 5, maximum: 100)
        let passage = SpeechPassage(from: 2, in: Self.book(), length: short)
        #expect(passage.text == "It was late.")
        let capped = SpeechPassage(from: 2, in: Self.book(), length: .init(minimum: 1, target: 50, maximum: 5))
        #expect(capped.text == "It was")
    }

    @Test func startsAtTheSentenceStart() {
        let book = Self.book()
        #expect(SpeechPassage.sentenceStart(of: 6, in: book) == 5)  // "there?”" → "“Who’s"
        #expect(SpeechPassage.sentenceStart(of: 5, in: book) == 5)
        #expect(SpeechPassage.sentenceStart(of: 3, in: book) == 2)
        #expect(SpeechPassage.sentenceStart(of: 10, in: book) == 9)
    }

    @Test func mapsLetterTimingsToWords() {
        let passage = SpeechPassage(from: 2, in: Self.book(), length: .init(minimum: 1, target: 5, maximum: 100))
        // "It was late." is 12 letters; give letter n the start time n / 10.
        let letters = passage.text.unicodeScalars.map { String($0) }
        let times = letters.indices.map { Double($0) / 10 }
        let alignment = SpeechAlignment(characters: letters, characterStartTimesSeconds: times, characterEndTimesSeconds: times)
        let starts = passage.startTimes(alignment)
        #expect(starts == [0, 0.3, 0.7])
        #expect(SpeechPassage.word(at: 0.05, startTimes: starts) == 0)
        #expect(SpeechPassage.word(at: 0.3, startTimes: starts) == 1)
        #expect(SpeechPassage.word(at: 9, startTimes: starts) == 2)

        // If the timings ever come back a different length, the words still move forward.
        let squashed = SpeechAlignment(characters: Array(letters.prefix(6)),
                                       characterStartTimesSeconds: Array(times.prefix(6)),
                                       characterEndTimesSeconds: Array(times.prefix(6)))
        let rough = passage.startTimes(squashed)
        #expect(rough == rough.sorted())
        #expect(rough.count == 3)
    }

    @Test func readsTheTimestampsReply() throws {
        let reply = """
        {"audio_base64": "SGk=", "alignment": {"characters": ["H", "i"],
         "character_start_times_seconds": [0, 0.1], "character_end_times_seconds": [0.1, 0.2]},
         "normalized_alignment": null}
        """
        let speech = try ElevenLabs.decodeSpeech(Data(reply.utf8))
        #expect(speech.audio == Data("Hi".utf8))
        #expect(speech.alignment.characterStartTimesSeconds == [0, 0.1])
        let refusal = #"{"detail":{"status":"missing_permissions","message":"Missing voices_read."}}"#
        #expect(ElevenLabs.errorMessage(Data(refusal.utf8)) == "Missing voices_read.")
        #expect(ElevenLabs.errorMessage(Data(#"{"detail":"Bad voice."}"#.utf8)) == "Bad voice.")
    }

    @Test func cacheKeepsRecentPassages() throws {
        let cache = SpeechCache(folder: FileManager.default.temporaryDirectory
            .appending(path: "word-reader-speech-\(UUID().uuidString)", directoryHint: .isDirectory))
        defer { try? FileManager.default.removeItem(at: cache.folder) }
        let alignment = SpeechAlignment(characters: ["a"], characterStartTimesSeconds: [0], characterEndTimesSeconds: [1])
        let old = SpeechCache.key(text: "old", voice: "v", model: "m")
        let new = SpeechCache.key(text: "new", voice: "v", model: "m")
        #expect(old != new)
        #expect(cache.alignment(old) == nil)
        try cache.save(.init(audio: Data(count: 1000), alignment: alignment), key: old)
        try cache.save(.init(audio: Data(count: 1000), alignment: alignment), key: new)
        let past = Date(timeIntervalSinceNow: -60)
        for file in ["\(old).mp3", "\(old).json"] {
            try FileManager.default.setAttributes([.modificationDate: past], ofItemAtPath: cache.folder.appending(path: file).path)
        }
        #expect(cache.alignment(new) == alignment)
        cache.trim(toBytes: 1500)
        #expect(cache.alignment(old) == nil)
        #expect(cache.alignment(new) == alignment)
    }
}
