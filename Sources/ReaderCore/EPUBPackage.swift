import Foundation

/// An opened EPUB: its metadata, file list and reading order.
///
/// This follows the same route Apple Books' BookEPUB framework takes:
/// `META-INF/container.xml` → `rootfile full-path` → the package (.opf) →
/// the spine's `itemref`s, reading only the linear ones.
public struct EPUBPackage: Sendable {
    struct ManifestItem: Sendable {
        let path: String
        let mediaType: String
        let properties: Set<String>
    }

    struct SpineItem: Sendable {
        let idref: String
        let linear: Bool
    }

    struct TOCEntry: Sendable {
        let title: String
        let path: String
        let fragment: String?
        let level: Int
    }

    public let url: URL
    public let title: String?
    public let authors: [String]
    public let coverPath: String?
    public let isProtected: Bool

    let storage: any EPUBStorage
    let packagePath: String
    let manifest: [String: ManifestItem]
    let spine: [SpineItem]
    let navPath: String?
    let ncxPath: String?
    /// EPUB 2 `<guide>` link to where the text proper begins.
    let guideStart: String?

    // MARK: Opening

    public static func open(_ url: URL) throws -> EPUBPackage {
        var isFolder: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path(percentEncoded: false), isDirectory: &isFolder) else {
            throw EPUBError.missingFile(url.lastPathComponent)
        }
        let storage: any EPUBStorage = isFolder.boolValue
            ? FolderStorage(root: url)
            : ZipStorage(archive: try ZipArchive(url: url))

        guard let container = try? storage.data(at: "META-INF/container.xml") else { throw EPUBError.noContainer }
        var packagePath: String?
        MarkupScanner.scan(container) { event in
            guard packagePath == nil, case .tag(let tag) = event, !tag.isClosing, tag.name == "rootfile" else { return }
            let mediaType = tag.attributes["media-type"] ?? "application/oebps-package+xml"
            if mediaType == "application/oebps-package+xml", let path = tag.attributes["full-path"] {
                packagePath = EPUBPath.normalize(path.removingPercentEncoding ?? path)
            }
        }
        guard let packagePath, let packageData = try? storage.data(at: packagePath) else { throw EPUBError.noPackage }
        return parsePackage(packageData, at: packagePath, storage: storage, url: url)
    }

    private static func parsePackage(_ data: Data, at packagePath: String, storage: any EPUBStorage, url: URL) -> EPUBPackage {
        let base = EPUBPath.directory(of: packagePath)
        var inMetadata = false
        var field: String?
        var buffer = ""
        var title: String?
        var authors: [String] = []
        var coverID: String?
        var tocID: String?
        var manifest: [String: ManifestItem] = [:]
        var spine: [SpineItem] = []
        var guideStart: String?

        MarkupScanner.scan(data) { event in
            switch event {
            case .text(let text):
                if field != nil { buffer += text }
            case .tag(let tag) where tag.isClosing:
                if tag.name == "metadata" { inMetadata = false }
                if tag.name == field {
                    let value = TextExtractor.collapseSpaces(buffer)
                    if !value.isEmpty {
                        if tag.name == "title", title == nil { title = value }
                        if tag.name == "creator" { authors.append(value) }
                    }
                    field = nil
                }
            case .tag(let tag):
                switch tag.name {
                case "metadata":
                    inMetadata = true
                case "title", "creator":
                    if inMetadata, !tag.isSelfClosing {
                        field = tag.name
                        buffer = ""
                    }
                case "meta":
                    if tag.attributes["name"] == "cover" { coverID = tag.attributes["content"] }
                case "item":
                    if let id = tag.attributes["id"], let href = tag.attributes["href"] {
                        manifest[id] = ManifestItem(
                            path: EPUBPath.resolve(href, from: base),
                            mediaType: tag.attributes["media-type"]?.lowercased() ?? "",
                            properties: Set((tag.attributes["properties"] ?? "").split(separator: " ").map(String.init))
                        )
                    }
                case "spine":
                    tocID = tag.attributes["toc"]
                case "itemref":
                    if let idref = tag.attributes["idref"] {
                        spine.append(SpineItem(idref: idref, linear: tag.attributes["linear"]?.lowercased() != "no"))
                    }
                case "reference":
                    let type = tag.attributes["type"]?.lowercased() ?? ""
                    if guideStart == nil, type == "text" || type == "start" || type == "bodymatter",
                       let href = tag.attributes["href"] {
                        guideStart = EPUBPath.resolve(href, from: base) + (EPUBPath.fragment(of: href).map { "#" + $0 } ?? "")
                    }
                default:
                    break
                }
            }
        }

        let images = manifest.values.filter { $0.mediaType.hasPrefix("image/") }
        let cover = manifest.values.first { $0.properties.contains("cover-image") }
            ?? coverID.flatMap { manifest[$0] }.flatMap { $0.mediaType.hasPrefix("image/") ? $0 : nil }
            ?? images.first { $0.path.lowercased().contains("cover") }

        return EPUBPackage(
            url: url,
            title: title,
            authors: Array(authors.prefix(3)),
            coverPath: cover?.path,
            isProtected: detectProtection(storage),
            storage: storage,
            packagePath: packagePath,
            manifest: manifest,
            spine: spine,
            navPath: manifest.values.first { $0.properties.contains("nav") }?.path,
            ncxPath: (tocID.flatMap { manifest[$0] } ?? manifest.values.first { $0.mediaType == "application/x-dtbncx+xml" })?.path,
            guideStart: guideStart
        )
    }

    /// Store-bought books carry FairPlay (`sinf.xml`) or Adobe encryption over their text.
    /// Font obfuscation also uses encryption.xml, so that alone doesn't count.
    private static func detectProtection(_ storage: any EPUBStorage) -> Bool {
        if storage.contains("META-INF/sinf.xml") { return true }
        guard let data = try? storage.data(at: "META-INF/encryption.xml") else { return false }
        let fontObfuscation: Set<String> = ["http://www.idpf.org/2008/embedding", "http://ns.adobe.com/pdf/enc#RC"]
        var algorithm = ""
        var encryptsText = false
        MarkupScanner.scan(data) { event in
            guard case .tag(let tag) = event, !tag.isClosing else { return }
            if tag.name == "encryptionmethod" { algorithm = tag.attributes["algorithm"] ?? "" }
            if tag.name == "cipherreference", !fontObfuscation.contains(algorithm) {
                let uri = (tag.attributes["uri"] ?? "").lowercased()
                if uri.hasSuffix("html") || uri.hasSuffix(".htm") || uri.hasSuffix(".xml") { encryptsText = true }
            }
        }
        return encryptsText
    }

    // MARK: Reading

    public var displayTitle: String {
        title ?? url.deletingPathExtension().lastPathComponent
    }

    public func coverData() -> Data? {
        coverPath.flatMap { try? storage.data(at: $0) }
    }

    /// Reads every linear chapter into one flat list of words.
    public func loadText() throws -> BookText {
        if isProtected { throw EPUBError.protected }
        let toc = tableOfContents()
        let start = startLocation()
        var wanted: [String: Set<String>] = [:]
        for entry in toc {
            if let fragment = entry.fragment { wanted[entry.path, default: []].insert(fragment) }
        }
        if let start, let fragment = start.fragment { wanted[start.path, default: []].insert(fragment) }

        var builder = BookBuilder()
        var documentStart: [String: Int] = [:]
        var anchors: [String: [String: Int]] = [:]
        var documents: [(start: Int, heading: String?)] = []

        for item in spine where item.linear {
            guard let entry = manifest[item.idref], Self.isText(entry.mediaType),
                  let data = try? storage.data(at: entry.path) else { continue }
            let start = builder.words.count
            let result = TextExtractor.extract(data, wantedAnchors: wanted[entry.path] ?? [], into: &builder)
            guard builder.words.count > start else { continue }
            documentStart[entry.path] = start
            anchors[entry.path] = result.anchors
            documents.append((start, result.firstHeading))
        }
        guard !builder.words.isEmpty else { throw EPUBError.noText }
        let last = builder.words.count - 1

        var chapters: [(order: Int, chapter: BookChapter)] = []
        for (order, entry) in toc.enumerated() {
            guard let start = documentStart[entry.path] else { continue }
            let index = entry.fragment.flatMap { anchors[entry.path]?[$0] } ?? start
            chapters.append((order, BookChapter(title: entry.title, wordIndex: min(index, last), level: entry.level)))
        }
        var sorted = chapters
            .sorted { ($0.chapter.wordIndex, $0.order) < ($1.chapter.wordIndex, $1.order) }
            .map(\.chapter)

        if sorted.isEmpty {
            sorted = documents.enumerated().map { number, document in
                BookChapter(title: document.heading ?? "Section \(number + 1)", wordIndex: document.start, level: 0)
            }
        } else if sorted[0].wordIndex > 0 {
            sorted.insert(BookChapter(title: documents.first?.heading ?? "Opening pages", wordIndex: 0, level: 0), at: 0)
        }

        for chapter in sorted { builder.flags[chapter.wordIndex] |= BookText.chapterStart }
        let startIndex = start.flatMap { location in
            location.fragment.flatMap { anchors[location.path]?[$0] } ?? documentStart[location.path]
        } ?? Self.firstChapterPastFrontMatter(sorted, wordCount: builder.words.count, bookTitle: title) ?? 0
        return BookText(words: builder.words, flags: builder.flags, chapters: sorted, startIndex: min(startIndex, last))
    }

    /// For books with no start marker: the first chapter that isn't front matter
    /// (cover, title page, copyright and so on), if it comes early in the book.
    static func firstChapterPastFrontMatter(_ chapters: [BookChapter], wordCount: Int, bookTitle: String? = nil) -> Int? {
        guard let chapter = chapters.first(where: { !isFrontMatter($0.title, bookTitle: bookTitle) }),
              chapter.wordIndex > 0, chapter.wordIndex < wordCount / 10 else { return nil }
        return chapter.wordIndex
    }

    static func isFrontMatter(_ title: String, bookTitle: String? = nil) -> Bool {
        let name = simplified(title)
        // A contents entry that just repeats the book's name is its title page.
        if let bookTitle, name.count >= 4, simplified(bookTitle).hasPrefix(name) { return true }
        let names: Set<String> = [
            "cover", "cover page", "front cover", "title", "title page", "half title", "half title page",
            "halftitle", "halftitle page", "copyright", "copyright page", "contents", "table of contents",
            "brief contents", "dedication", "frontispiece", "imprint", "opening pages", "also by", "praise",
            "about this ebook", "about this book",
        ]
        let prefixes = ["also by ", "books by ", "other books by ", "praise ", "words of praise", "copyright ",
                        "table of contents ", "brief table of contents"]
        return names.contains(name) || prefixes.contains { name.hasPrefix($0) }
    }

    /// Lowercase words with punctuation turned into single spaces: "Half-Title Page:" → "half title page".
    private static func simplified(_ text: String) -> String {
        text.lowercased()
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .joined(separator: " ")
    }

    static func isText(_ mediaType: String) -> Bool {
        mediaType.isEmpty || mediaType.contains("html") || mediaType == "application/x-dtbook+xml"
    }

    // MARK: Table of contents

    /// Where the text proper begins, as Apple Books opens a new book: the EPUB 3
    /// `bodymatter` landmark, or the EPUB 2 guide's `text` reference.
    func startLocation() -> (path: String, fragment: String?)? {
        var href: String?
        if let navPath, let data = try? storage.data(at: navPath) {
            href = Self.parseLandmark(data, base: EPUBPath.directory(of: navPath))
        }
        guard let link = href ?? guideStart else { return nil }
        return (EPUBPath.resolve(link, from: ""), EPUBPath.fragment(of: link))
    }

    /// Finds `<a epub:type="bodymatter">` inside `<nav epub:type="landmarks">`.
    static func parseLandmark(_ data: Data, base: String) -> String? {
        var inLandmarks = false
        var found: String?
        MarkupScanner.scan(data) { event in
            guard found == nil, case .tag(let tag) = event else { return }
            if tag.name == "nav" {
                inLandmarks = !tag.isClosing && tag.hasType(["landmarks"])
            } else if inLandmarks, !tag.isClosing, tag.name == "a", tag.hasType(["bodymatter", "start"]),
                      let href = tag.attributes["href"] {
                found = EPUBPath.resolve(href, from: base) + (EPUBPath.fragment(of: href).map { "#" + $0 } ?? "")
            }
        }
        return found
    }

    func tableOfContents() -> [TOCEntry] {
        if let navPath, let data = try? storage.data(at: navPath) {
            let entries = Self.parseNav(data, base: EPUBPath.directory(of: navPath))
            if !entries.isEmpty { return entries }
        }
        if let ncxPath, let data = try? storage.data(at: ncxPath) {
            return Self.parseNCX(data, base: EPUBPath.directory(of: ncxPath))
        }
        return []
    }

    /// EPUB 3: `<nav epub:type="toc">` with nested `<ol>` lists of links.
    static func parseNav(_ data: Data, base: String) -> [TOCEntry] {
        var entries: [TOCEntry] = []
        var navDepth = 0
        var listDepth = 0
        var finished = false
        var href: String?
        var text = ""

        MarkupScanner.scan(data) { event in
            guard !finished else { return }
            switch event {
            case .text(let value):
                if href != nil { text += value }
            case .tag(let tag) where tag.isClosing:
                guard navDepth > 0 else { return }
                switch tag.name {
                case "nav":
                    navDepth -= 1
                    if navDepth == 0 { finished = true }
                case "ol":
                    listDepth -= 1
                case "a":
                    if let link = href {
                        let title = TextExtractor.collapseSpaces(text)
                        if !title.isEmpty {
                            entries.append(TOCEntry(
                                title: title,
                                path: EPUBPath.resolve(link, from: base),
                                fragment: EPUBPath.fragment(of: link),
                                level: max(0, listDepth - 1)
                            ))
                        }
                    }
                    href = nil
                default:
                    break
                }
            case .tag(let tag):
                if tag.name == "nav" {
                    if navDepth > 0 {
                        navDepth += 1
                    } else if tag.hasType(["toc", "doc-toc"]) {
                        navDepth = 1
                    }
                } else if navDepth > 0, !tag.isSelfClosing {
                    if tag.name == "ol" { listDepth += 1 }
                    if tag.name == "a" {
                        href = tag.attributes["href"]
                        text = ""
                    }
                }
            }
        }
        return entries
    }

    /// EPUB 2: `toc.ncx` with nested `<navPoint>`s.
    static func parseNCX(_ data: Data, base: String) -> [TOCEntry] {
        var entries: [TOCEntry] = []
        var depth = 0
        var inLabel = false
        var label = ""

        MarkupScanner.scan(data) { event in
            switch event {
            case .text(let value):
                if inLabel { label += value }
            case .tag(let tag) where tag.isClosing:
                if tag.name == "navpoint" { depth -= 1 }
                if tag.name == "navlabel" { inLabel = false }
            case .tag(let tag):
                switch tag.name {
                case "navpoint":
                    if !tag.isSelfClosing { depth += 1 }
                    label = ""
                case "navlabel":
                    inLabel = true
                    label = ""
                case "content":
                    let title = TextExtractor.collapseSpaces(label)
                    if depth > 0, !title.isEmpty, let source = tag.attributes["src"] {
                        entries.append(TOCEntry(
                            title: title,
                            path: EPUBPath.resolve(source, from: base),
                            fragment: EPUBPath.fragment(of: source),
                            level: depth - 1
                        ))
                    }
                default:
                    break
                }
            }
        }
        return entries
    }
}
