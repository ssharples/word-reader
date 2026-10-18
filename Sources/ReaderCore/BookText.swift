import Foundation

public struct BookChapter: Hashable, Sendable {
    public let title: String
    public let wordIndex: Int
    /// Nesting depth in the book's table of contents (0 is top level).
    public let level: Int
}

/// A whole book as a flat list of words, ready to show one at a time.
public struct BookText: Sendable {
    public static let paragraphEnd: UInt8 = 1 << 0
    public static let chapterStart: UInt8 = 1 << 1

    public let words: [String]
    public let flags: [UInt8]
    public let chapters: [BookChapter]
    /// Where a new reader should begin: the first page of the text proper,
    /// past the cover, copyright and contents pages.
    public let startIndex: Int

    public init(words: [String], flags: [UInt8], chapters: [BookChapter], startIndex: Int = 0) {
        self.words = words
        self.flags = flags
        self.chapters = chapters
        self.startIndex = startIndex
    }

    public var count: Int { words.count }

    public func isParagraphEnd(_ index: Int) -> Bool { flags[index] & Self.paragraphEnd != 0 }
    public func isChapterStart(_ index: Int) -> Bool { flags[index] & Self.chapterStart != 0 }

    /// The chapter that contains `wordIndex`, found by binary search.
    public func chapterIndex(at wordIndex: Int) -> Int? {
        var low = 0
        var high = chapters.count - 1
        var found: Int?
        while low <= high {
            let mid = (low + high) / 2
            if chapters[mid].wordIndex <= wordIndex {
                found = mid
                low = mid + 1
            } else {
                high = mid - 1
            }
        }
        return found
    }

    /// True when the word ends a sentence (or a paragraph).
    public func endsSentence(_ index: Int) -> Bool {
        isParagraphEnd(index) || WordTiming.trailingPunctuation(of: words[index]).map { ".!?…".contains($0) } == true
    }
}

/// Collects words while a book is being read in.
struct BookBuilder {
    var words: [String] = []
    var flags: [UInt8] = []

    /// Splits a paragraph's text into words and marks the last one as a paragraph end.
    mutating func appendParagraph(_ text: String) {
        let before = words.count
        Self.splitWords(text, into: &words)
        guard words.count > before else { return }
        flags.append(contentsOf: repeatElement(0, count: words.count - before))
        flags[words.count - 1] |= BookText.paragraphEnd
    }

    static func countWords(_ text: String) -> Int {
        var scratch: [String] = []
        splitWords(text, into: &scratch)
        return scratch.count
    }

    static func splitWords(_ text: String, into words: inout [String]) {
        let cleaned = text.contains("\u{AD}") ? text.replacingOccurrences(of: "\u{AD}", with: "") : text
        for token in cleaned.split(whereSeparator: { $0.isWhitespace || $0 == "\u{200B}" || $0 == "\u{FEFF}" }) {
            let characters = Array(token)
            var current = ""
            for (i, character) in characters.enumerated() {
                current.append(character)
                guard i + 1 < characters.count, current.count > 1 else { continue }
                let next = characters[i + 1]
                if character == "—" || character == "―" {
                    // "word—word" reads better as two flashes: "word—" then "word".
                    if next != "—", next != "―" { words.append(current); current = "" }
                } else if character == "-", characters[i - 1] == "-", next != "-" {
                    // Plain-text books write a dash as "--".
                    words.append(current)
                    current = ""
                } else if ".!?".contains(character), characters[i - 1].isLowercase,
                          next.isUppercase, i + 2 < characters.count, characters[i + 2].isLowercase {
                    // Converted PDFs often lose the space after a full stop: "results.If".
                    words.append(current)
                    current = ""
                }
            }
            if !current.isEmpty { words.append(current) }
        }
    }
}
