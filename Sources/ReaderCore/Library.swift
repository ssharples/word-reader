import Foundation

/// A book on the library shelf. Only metadata is read; the text loads when it's opened.
public struct BookInfo: Identifiable, Hashable, Sendable {
    public let url: URL
    public let title: String
    public let author: String?
    public let isProtected: Bool

    public var id: String { url.path(percentEncoded: false) }

    public init(url: URL, title: String, author: String?, isProtected: Bool) {
        self.url = url
        self.title = title
        self.author = author
        self.isProtected = isProtected
    }

    public init(package: EPUBPackage) {
        self.init(
            url: package.url,
            title: package.displayTitle,
            author: package.authors.isEmpty ? nil : package.authors.joined(separator: ", "),
            isProtected: package.isProtected
        )
    }
}

public enum Library {
    /// Where Apple Books keeps imported EPUBs. Its library database (BKLibrary) points
    /// every imported book's ZPATH here, one unzipped `.epub` folder per book.
    public static var appleBooksFolder: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appending(path: "Library/Mobile Documents/iCloud~com~apple~iBooks/Documents", directoryHint: .isDirectory)
    }

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
