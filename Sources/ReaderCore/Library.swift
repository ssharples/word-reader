import Foundation

/// A book on the library shelf. Only metadata is read; the text loads when it's opened.
public struct BookInfo: Identifiable, Hashable, Sendable {
    public let url: URL
    public let title: String
    public let author: String?
    public let isProtected: Bool
    /// Names this book on every device, wherever its file is kept. See `BookInfo.key(...)`.
    public let key: String

    /// Where the file is on this device.
    public var id: String { url.path(percentEncoded: false) }

    public init(url: URL, title: String, author: String?, isProtected: Bool, key: String) {
        self.url = url
        self.title = title
        self.author = author
        self.isProtected = isProtected
        self.key = key
    }

    public init(package: EPUBPackage) {
        let author = package.authors.isEmpty ? nil : package.authors.joined(separator: ", ")
        self.init(
            url: package.url,
            title: package.displayTitle,
            author: author,
            isProtected: package.isProtected,
            key: Self.key(identifier: package.identifier, title: package.title, author: author, fileName: package.url.lastPathComponent)
        )
    }

    /// The same book gives the same key whether it's an unzipped folder in Apple Books
    /// or a zipped copy on an iPhone, because both come from the book's own metadata.
    /// Identifiers alone aren't enough: converters often give every book the same one.
    public static func key(identifier: String?, title: String?, author: String?, fileName: String) -> String {
        func tidy(_ text: String?) -> String {
            (text ?? "").lowercased().split(whereSeparator: \.isWhitespace).joined(separator: " ")
        }
        guard identifier != nil || title != nil else { return "file:" + tidy(fileName) }
        return [tidy(identifier), tidy(title), tidy(author)].joined(separator: "|")
    }
}

public enum Library {
    #if os(macOS)
    /// Where Apple Books keeps imported EPUBs. Its library database (BKLibrary) points
    /// every imported book's ZPATH here, one unzipped `.epub` folder per book.
    public static var appleBooksFolder: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appending(path: "Library/Mobile Documents/iCloud~com~apple~iBooks/Documents", directoryHint: .isDirectory)
    }
    #endif

    /// Every `.epub` file or folder directly inside `folder`.
    public static func epubs(in folder: URL) throws -> [URL] {
        try FileManager.default
            .contentsOfDirectory(at: folder, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
            .filter { $0.pathExtension.lowercased() == "epub" }
    }

    /// Reads title and author for each book. Books that fail to open are left out.
    public static func scan(_ urls: [URL]) -> [BookInfo] {
        urls.compactMap { url in
            (try? EPUBPackage.open(url)).map(BookInfo.init(package:))
        }
    }
}
