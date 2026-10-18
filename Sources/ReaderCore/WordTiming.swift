import Foundation

/// How long each word stays on screen, and which letter the eye should fix on.
public enum WordTiming {
    /// Seconds to show the word at `index`, given a words-per-minute speed.
    public static func duration(of index: Int, in text: BookText, wordsPerMinute: Int, naturalPauses: Bool) -> Double {
        let base = 60.0 / Double(max(wordsPerMinute, 1))
        guard naturalPauses else { return base }
        return base * multiplier(
            for: text.words[index],
            endsParagraph: text.isParagraphEnd(index),
            startsChapter: text.isChapterStart(index)
        )
    }

    /// Longer words and punctuation get more time, like a reader's natural pauses.
    public static func multiplier(for word: String, endsParagraph: Bool, startsChapter: Bool) -> Double {
        var factor = 1.0
        let letters = word.reduce(0) { $1.isLetter || $1.isNumber ? $0 + 1 : $0 }
        if letters > 8 { factor += min(0.8, Double(letters - 8) * 0.1) }

        if let mark = trailingPunctuation(of: word) {
            if ".!?…".contains(mark) {
                factor += 1.0
            } else if ",;:—–".contains(mark) {
                factor += 0.5
            }
        }
        if endsParagraph { factor = max(factor, 2.5) }
        if startsChapter { factor = max(factor, 3.0) }
        return factor
    }

    /// The last punctuation mark, looking past closing quotes and brackets.
    public static func trailingPunctuation(of word: String) -> Character? {
        for character in word.reversed() {
            if "\"'”’»)]}".contains(character) { continue }
            return character.isLetter || character.isNumber ? nil : character
        }
        return nil
    }

    /// Splits a word around its focus letter (the "optimal recognition point").
    ///
    /// The focus letter sits a little left of the middle; keeping it in the same
    /// place on screen means the eye doesn't have to move between words.
    public static func focusSplit(_ word: String) -> (before: String, focus: String, after: String) {
        let characters = Array(word)
        guard !characters.isEmpty else { return ("", "", "") }
        let firstLetter = characters.firstIndex(where: { $0.isLetter || $0.isNumber }) ?? 0
        let letters = characters.reduce(0) { $1.isLetter || $1.isNumber ? $0 + 1 : $0 }
        let offset: Int
        switch letters {
        case 0...1: offset = 0
        case 2...5: offset = 1
        case 6...9: offset = 2
        case 10...13: offset = 3
        default: offset = 4
        }
        let focus = min(firstLetter + offset, characters.count - 1)
        return (
            String(characters[..<focus]),
            String(characters[focus]),
            String(characters[(focus + 1)...])
        )
    }

    /// Rough minutes left to read, including the extra time for pauses.
    public static func minutesLeft(words: Int, wordsPerMinute: Int, naturalPauses: Bool) -> Double {
        Double(words) / Double(max(wordsPerMinute, 1)) * (naturalPauses ? 1.2 : 1.0)
    }
}
