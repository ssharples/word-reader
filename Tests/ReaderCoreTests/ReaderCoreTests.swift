import Foundation
import Testing
@testable import ReaderCore

@Suite struct TextTests {
    @Test func decodesEntities() {
        #expect(Entities.decode("Tom &amp; Jerry&#8212;&#x2014; &bogus; &") == "Tom & Jerry—— &bogus; &")
        #expect(Entities.decode("co&shy;operate") == "cooperate")
    }

    @Test func extractsParagraphsAndSkipsNoise() {
        let html = """
        <?xml version="1.0"?><!DOCTYPE html>
        <html><head><title>Not read</title><style>p { color: red }</style></head>
        <body>
          <h1 id="top">Chapter One</h1>
          <p>It was a <i>dark</i> and stormy night.<sup><a href="#n1">1</a></sup></p>
          <span epub:type="pagebreak" title="12">12</span>
          <script>var ignored = "<p>no</p>";</script>
          <p id="second">Rain&nbsp;fell<br/>again &amp; again.</p>
          <aside epub:type="footnote"><p>A footnote.</p></aside>
        </body></html>
        """
        var book = BookBuilder()
        let result = TextExtractor.extract(Data(html.utf8), wantedAnchors: ["second"], into: &book)
        #expect(book.words == ["Chapter", "One", "It", "was", "a", "dark", "and", "stormy", "night.",
                               "Rain", "fell", "again", "&", "again."])
        #expect(result.firstHeading == "Chapter One")
        #expect(result.anchors["second"] == 9)
        let ends = book.words.indices.filter { book.flags[$0] & BookText.paragraphEnd != 0 }
        #expect(ends == [1, 8, 10, 13])
    }

    @Test func splitsDashesAndMissingSpaces() {
        var words: [String] = []
        BookBuilder.splitWords("self—control improving--every results.If the U.S.A. —quote word—", into: &words)
        #expect(words == ["self—", "control", "improving--", "every", "results.", "If", "the", "U.S.A.", "—quote", "word—"])
    }
}

@Suite struct TimingTests {
    @Test func focusLetterSitsLeftOfCentre() {
        #expect(WordTiming.focusSplit("a") == ("", "a", ""))
        #expect(WordTiming.focusSplit("reading") == ("re", "a", "ding"))
        #expect(WordTiming.focusSplit("“Hello,") == ("“H", "e", "llo,"))
    }

    @Test func punctuationAddsTime() {
        let plain = WordTiming.multiplier(for: "word", endsParagraph: false, startsChapter: false)
        let comma = WordTiming.multiplier(for: "word,", endsParagraph: false, startsChapter: false)
        let stop = WordTiming.multiplier(for: "word.”", endsParagraph: false, startsChapter: false)
        let paragraph = WordTiming.multiplier(for: "word", endsParagraph: true, startsChapter: false)
        #expect(plain == 1.0)
        #expect(comma == 1.5)
        #expect(stop == 2.0)
        #expect(paragraph == 2.5)
    }
}

@Suite struct PackageTests {
    /// Writes a small EPUB 3 as a folder, the way Apple Books stores imported books.
    static func makeFolderBook() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "word-reader-tests-\(UUID().uuidString)/Sample.epub", directoryHint: .isDirectory)
        let files: [String: String] = [
            "mimetype": "application/epub+zip",
            "META-INF/container.xml": """
            <?xml version="1.0"?>
            <container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
              <rootfiles><rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/></rootfiles>
            </container>
            """,
            "OEBPS/content.opf": """
            <?xml version="1.0" encoding="UTF-8"?>
            <package xmlns="http://www.idpf.org/2007/opf" version="3.0">
              <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
                <dc:title>A Small Book</dc:title><dc:creator>Ann Author</dc:creator>
              </metadata>
              <manifest>
                <item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/>
                <item id="copy" href="Text/copyright.xhtml" media-type="application/xhtml+xml"/>
                <item id="ch1" href="Text/chapter%201.xhtml" media-type="application/xhtml+xml"/>
                <item id="notes" href="Text/notes.xhtml" media-type="application/xhtml+xml"/>
                <item id="cover" href="Images/cover.jpg" media-type="image/jpeg" properties="cover-image"/>
              </manifest>
              <spine><itemref idref="copy"/><itemref idref="ch1"/><itemref idref="notes" linear="no"/></spine>
            </package>
            """,
            "OEBPS/nav.xhtml": """
            <html xmlns:epub="http://www.idpf.org/2007/ops"><body>
              <nav epub:type="toc"><ol>
                <li><a href="Text/chapter%201.xhtml">Part One</a>
                  <ol><li><a href="Text/chapter%201.xhtml#later">Later On</a></li></ol></li>
              </ol></nav>
              <nav epub:type="landmarks"><ol>
                <li><a epub:type="bodymatter" href="Text/chapter%201.xhtml">Start</a></li>
              </ol></nav>
            </body></html>
            """,
            "OEBPS/Text/copyright.xhtml": "<html><body><p>Copyright 2026.</p></body></html>",
            "OEBPS/Text/chapter 1.xhtml": """
            <html><body><h1>Part One</h1><p>First words here.</p><h2 id="later">Later</h2><p>More words.</p></body></html>
            """,
            "OEBPS/Text/notes.xhtml": "<html><body><p>Notes are not read.</p></body></html>",
            "OEBPS/Images/cover.jpg": "not really a jpeg",
        ]
        try write(files, to: root)
        return root
    }

    static func write(_ files: [String: String], to root: URL) throws {
        for (path, contents) in files {
            let url = root.appending(path: path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(contents.utf8).write(to: url)
        }
    }

    /// Zips the folder the way EPUBs are packed: mimetype first and stored, the rest deflated.
    static func zip(_ folder: URL) throws -> URL {
        let output = folder.deletingLastPathComponent().appending(path: "Sample-zipped.epub")
        for arguments in [["-X0", output.path, "mimetype"], ["-Xr9D", output.path, "META-INF", "OEBPS"]] {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
            process.currentDirectoryURL = folder
            process.arguments = ["-q"] + arguments
            try process.run()
            process.waitUntilExit()
            #expect(process.terminationStatus == 0)
        }
        return output
    }

    @Test func readsFolderAndZippedBooksTheSame() throws {
        let folder = try Self.makeFolderBook()
        defer { try? FileManager.default.removeItem(at: folder.deletingLastPathComponent()) }
        let zipped = try Self.zip(folder)

        for url in [folder, zipped] {
            let package = try EPUBPackage.open(url)
            #expect(package.title == "A Small Book")
            #expect(package.authors == ["Ann Author"])
            #expect(package.coverPath == "OEBPS/Images/cover.jpg")
            #expect(package.coverData() == Data("not really a jpeg".utf8))

            let text = try package.loadText()
            // The non-linear notes page is left out, as Apple Books does.
            #expect(text.words == ["Copyright", "2026.", "Part", "One", "First", "words", "here.", "Later", "More", "words."])
            #expect(text.chapters.map(\.title) == ["Opening pages", "Part One", "Later On"])
            #expect(text.chapters.map(\.wordIndex) == [0, 2, 7])
            #expect(text.chapters.map(\.level) == [0, 0, 1])
            #expect(text.startIndex == 2)
            #expect(text.isChapterStart(7))
            #expect(text.chapterIndex(at: 8) == 2)
        }
    }

    /// Calibre's PDF conversions name the book by ISBN, list "Unknown" as the author
    /// and mark no cover, but the first page has the real details.
    @Test func takesMissingDetailsFromTheFirstPage() throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "word-reader-tests-\(UUID().uuidString)/9781401945015.epub", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        try Self.write([
            "META-INF/container.xml": """
            <container><rootfiles><rootfile full-path="content.opf" media-type="application/oebps-package+xml"/></rootfiles></container>
            """,
            "content.opf": """
            <package xmlns="http://www.idpf.org/2007/opf" version="2.0">
              <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
                <dc:creator>Unknown</dc:creator><dc:title>9781401945015</dc:title>
              </metadata>
              <manifest>
                <item href="index_split_000.html" id="page" media-type="application/xhtml+xml"/>
                <item href="index-1_1.jpg" id="id6" media-type="image/jpeg"/>
                <item href="index-2_1.jpg" id="id7" media-type="image/jpeg"/>
              </manifest>
              <spine><itemref idref="page"/></spine>
            </package>
            """,
            "index_split_000.html": """
            <html><head><title>Letting Go: The Pathway of Surrender</title><meta name="author" content="David R. Hawkins"/></head>
            <body><p><a id="p1"></a><img src="index-1_1.jpg"/></p><p><img src="index-2_1.jpg"/></p><p>ALSO BY DAVID R. HAWKINS</p></body></html>
            """,
            "index-1_1.jpg": "cover",
            "index-2_1.jpg": "page two",
        ], to: root)

        let package = try EPUBPackage.open(root)
        #expect(package.title == "Letting Go: The Pathway of Surrender")
        #expect(package.authors == ["David R. Hawkins"])
        #expect(package.coverPath == "index-1_1.jpg")
    }

    @Test func ignoresPicturesAfterTheTextStarts() {
        let page = Data("""
        <html><head><title>Cover</title></head><body><h1>Chapter One</h1>
        <p>It was a dark and stormy night, and the rain fell in torrents.</p><img src="../Images/logo.png"/></body></html>
        """.utf8)
        let details = EPUBPackage.firstPageDetails(page, base: "OEBPS/Text")
        #expect(details.title == nil)
        #expect(details.author == nil)
        #expect(details.image == nil)
    }

    @Test func skipsFrontMatterWhenThereIsNoStartMarker() {
        let chapters = [
            BookChapter(title: "Opening pages", wordIndex: 0, level: 0),
            BookChapter(title: "Copyright", wordIndex: 40, level: 0),
            BookChapter(title: "Also by Ann Author", wordIndex: 90, level: 0),
            BookChapter(title: "Epigraph", wordIndex: 120, level: 0),
            BookChapter(title: "Chapter One", wordIndex: 150, level: 0),
        ]
        #expect(EPUBPackage.firstChapterPastFrontMatter(chapters, wordCount: 10_000) == 120)
        // Too far in to be sure it's still front matter: start at the beginning.
        #expect(EPUBPackage.firstChapterPastFrontMatter(chapters, wordCount: 1_000) == nil)
        #expect(EPUBPackage.firstChapterPastFrontMatter([BookChapter(title: "One", wordIndex: 0, level: 0)], wordCount: 100) == nil)

        #expect(EPUBPackage.isFrontMatter("Half-Title Page"))
        #expect(EPUBPackage.isFrontMatter("Words of Praise for the Book"))
        #expect(EPUBPackage.isFrontMatter("Learning React", bookTitle: "Learning React (Third Edition)"))
        #expect(!EPUBPackage.isFrontMatter("Foreword by Dr. Wayne W. Dyer"))
        #expect(!EPUBPackage.isFrontMatter("Titles and Honours"))
    }

    @Test func spotsCopyProtection() throws {
        let folder = try Self.makeFolderBook()
        defer { try? FileManager.default.removeItem(at: folder.deletingLastPathComponent()) }
        try Data("<sinf/>".utf8).write(to: folder.appending(path: "META-INF/sinf.xml"))
        let package = try EPUBPackage.open(folder)
        #expect(package.isProtected)
        #expect(throws: EPUBError.protected) { try package.loadText() }
    }

    @Test func rejectsFilesThatAreNotEPUBs() throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "not-a-book-\(UUID().uuidString).epub")
        try Data("hello".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(throws: EPUBError.notZip) { try EPUBPackage.open(url) }
    }
}
