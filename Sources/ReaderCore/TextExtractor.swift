import Foundation

/// Turns one XHTML chapter into words.
enum TextExtractor {
    struct Result {
        /// Word index for each requested `id`, so table-of-contents links can land mid-file.
        var anchors: [String: Int] = [:]
        /// Text of the first h1–h3, used as a chapter title when there's no table of contents.
        var firstHeading: String?
    }

    static let blockTags: Set<String> = [
        "address", "article", "aside", "blockquote", "body", "br", "caption", "center", "dd", "div", "dl",
        "dt", "figcaption", "figure", "footer", "h1", "h2", "h3", "h4", "h5", "h6", "header", "hr", "html",
        "li", "main", "nav", "ol", "p", "pre", "section", "table", "tbody", "td", "th", "thead", "tr", "ul",
    ]

    /// Elements whose content is never read aloud.
    static let skippedTags: Set<String> = [
        "head", "iframe", "math", "noscript", "object", "rp", "rt", "script", "style", "svg", "template", "title",
    ]

    static let voidTags: Set<String> = [
        "area", "base", "br", "col", "embed", "hr", "image", "img", "input", "link", "meta", "param", "source",
        "track", "wbr",
    ]

    /// `epub:type` / `role` values for footnote markers, page numbers and note sections.
    static let skippedTypes: Set<String> = [
        "noteref", "pagebreak", "footnote", "footnotes", "endnote", "endnotes", "rearnote", "rearnotes",
        "doc-noteref", "doc-pagebreak", "doc-footnote", "doc-endnote", "doc-endnotes", "doc-backlink",
    ]

    static let headingTags: Set<String> = ["h1", "h2", "h3"]

    static func extract(_ data: Data, wantedAnchors: Set<String>, into book: inout BookBuilder) -> Result {
        var result = Result()
        var stack: [(name: String, skipped: Bool)] = []
        var skipDepth = 0
        var superscriptDepth = 0
        var headingDepth = 0
        var headingText = ""
        var paragraph = ""

        func flush() {
            if !paragraph.isEmpty {
                book.appendParagraph(paragraph)
                paragraph = ""
            }
        }

        MarkupScanner.scan(data) { event in
            switch event {
            case .text(let text):
                guard skipDepth == 0 else { return }
                if superscriptDepth > 0, isNoteMarker(text) { return }
                paragraph += text
                if headingDepth > 0, result.firstHeading == nil { headingText += text }

            case .tag(let tag) where tag.isClosing:
                guard let open = stack.lastIndex(where: { $0.name == tag.name }) else { return }
                for element in stack[open...] {
                    if element.skipped { skipDepth -= 1 }
                    if element.name == "sup" { superscriptDepth -= 1 }
                    if headingTags.contains(element.name) { headingDepth -= 1 }
                }
                stack.removeSubrange(open...)
                if blockTags.contains(tag.name) { flush() }
                if headingTags.contains(tag.name), headingDepth == 0, result.firstHeading == nil {
                    let heading = collapseSpaces(headingText)
                    if !heading.isEmpty { result.firstHeading = heading }
                    headingText = ""
                }

            case .tag(let tag):
                if blockTags.contains(tag.name) { flush() }
                if skipDepth == 0, !wantedAnchors.isEmpty {
                    for key in ["id", "name"] {
                        if let id = tag.attributes[key], wantedAnchors.contains(id), result.anchors[id] == nil {
                            result.anchors[id] = book.words.count + BookBuilder.countWords(paragraph)
                        }
                    }
                }
                if tag.isSelfClosing || voidTags.contains(tag.name) { return }
                let skipped = skippedTags.contains(tag.name) || tag.hasType(skippedTypes)
                stack.append((tag.name, skipped))
                if skipped { skipDepth += 1 }
                if tag.name == "sup" { superscriptDepth += 1 }
                if headingTags.contains(tag.name) { headingDepth += 1 }
            }
        }
        flush()
        return result
    }

    /// Footnote numbers such as "12", "[3]" or "*" set in superscript.
    static func isNoteMarker(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 6 else { return false }
        let core = trimmed.trimmingCharacters(in: CharacterSet(charactersIn: "[]()"))
        if !core.isEmpty, core.allSatisfy(\.isNumber) { return true }
        return trimmed.allSatisfy { "*†‡§".contains($0) }
    }

    static func collapseSpaces(_ text: String) -> String {
        text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
}
