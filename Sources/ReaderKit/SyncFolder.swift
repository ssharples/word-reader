import Foundation
import ReaderCore

/// One device's reading progress, as saved in the sync folder.
public struct DeviceProgress: Codable, Sendable, Equatable {
    public var device: String
    public var updated: Date
    public var books: [String: ReadingProgress]

    public init(device: String, updated: Date, books: [String: ReadingProgress]) {
        self.device = device
        self.updated = updated
        self.books = books
    }
}

/// A folder that every device can see, such as iCloud Drive › Word Reader:
///
///     Word Reader/
///       Books/            the books, as EPUB files
///       Progress/         one file per device: <device id>.json
///
/// Each device writes only its own progress file and reads everyone else's, taking
/// the newest place in each book. Nothing is ever written to the same file from two
/// devices, so iCloud never has a conflict to sort out. It works with any service
/// that syncs a folder (iCloud Drive, Dropbox and so on) and needs no server.
public struct SyncFolder: Sendable, Equatable {
    public let root: URL

    public init(root: URL) {
        self.root = root
    }

    public static let folderName = "Word Reader"

    #if os(macOS)
    /// iCloud Drive › Word Reader.
    public static var iCloudDrive: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appending(path: "Library/Mobile Documents/com~apple~CloudDocs", directoryHint: .isDirectory)
            .appending(path: folderName, directoryHint: .isDirectory)
    }
    #endif

    /// The folder to sync with when someone picks `picked`: the folder itself if it's
    /// already a Word Reader folder, otherwise a "Word Reader" folder inside it.
    public static func folder(forPicked picked: URL) -> URL {
        let manager = FileManager.default
        let isOurs = picked.lastPathComponent == folderName
            || manager.fileExists(atPath: picked.appending(path: "Progress").path(percentEncoded: false))
            || manager.fileExists(atPath: picked.appending(path: "Books").path(percentEncoded: false))
        return isOurs ? picked : picked.appending(path: folderName, directoryHint: .isDirectory)
    }

    public var booksFolder: URL { root.appending(path: "Books", directoryHint: .isDirectory) }
    public var progressFolder: URL { root.appending(path: "Progress", directoryHint: .isDirectory) }

    /// Makes the Books and Progress folders if they aren't there yet.
    public func prepare() throws {
        for folder in [booksFolder, progressFolder] {
            if FileManager.default.fileExists(atPath: folder.path(percentEncoded: false)) { continue }
            try Self.coordinatedWrite(folder) {
                try FileManager.default.createDirectory(at: $0, withIntermediateDirectories: true)
            }
        }
    }

    // MARK: Books

    /// The EPUB files in Books, including ones iCloud hasn't downloaded to this device yet.
    public func bookFiles() -> [URL] {
        Self.files(in: booksFolder, withExtension: "epub")
    }

    /// Copies a book into Books and returns the copy. Unzipped `.epub` folders are zipped
    /// on the way. A different book with the same file name gets a number added.
    public func addBook(_ source: URL) throws -> URL {
        try prepare()
        var isFolder: ObjCBool = false
        FileManager.default.fileExists(atPath: source.path(percentEncoded: false), isDirectory: &isFolder)
        let base = source.deletingPathExtension().lastPathComponent
        var target = booksFolder.appending(path: base + ".epub")
        var number = 2
        let taken = Set(bookFiles().map(\.lastPathComponent))
        while taken.contains(target.lastPathComponent) {
            target = booksFolder.appending(path: "\(base) \(number).epub")
            number += 1
        }

        var file = source
        var temporary: URL?
        if isFolder.boolValue {
            let zipped = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString + ".epub")
            try Self.coordinatedRead(source) { try ZipWriter.zip(folder: $0, to: zipped) }
            file = zipped
            temporary = zipped
        }
        defer { if let temporary { try? FileManager.default.removeItem(at: temporary) } }
        try Self.coordinatedRead(file) { readable in
            try Self.coordinatedWrite(target) { try FileManager.default.copyItem(at: readable, to: $0) }
        }
        return target
    }

    public func removeBook(_ url: URL) throws {
        try Self.coordinatedDelete(url) { try FileManager.default.removeItem(at: $0) }
    }

    /// Makes sure a file in the sync folder is on this device, downloading it if need be.
    /// It waits for the download, so call it away from the main thread.
    public static func download(_ url: URL) throws {
        try coordinatedRead(url) { _ in }
    }

    // MARK: Progress

    /// Every other device's progress. Files that can't be read yet are skipped.
    public func readProgress(except deviceID: String) -> [DeviceProgress] {
        Self.files(in: progressFolder, withExtension: "json")
            .filter { $0.deletingPathExtension().lastPathComponent != deviceID }
            .compactMap { url in
                try? Self.coordinatedRead(url) { try Self.decoder.decode(DeviceProgress.self, from: Data(contentsOf: $0)) }
            }
    }

    public func write(_ progress: DeviceProgress, deviceID: String) throws {
        try prepare()
        let data = try Self.encoder.encode(progress)
        let url = progressFolder.appending(path: deviceID + ".json")
        try Self.coordinatedWrite(url, options: .forReplacing) { try data.write(to: $0, options: .atomic) }
    }

    /// The newest entry for each book across these devices.
    public static func newest(_ devices: [DeviceProgress]) -> [String: ReadingProgress] {
        var newest: [String: ReadingProgress] = [:]
        for device in devices {
            for (key, entry) in device.books where (newest[key]?.lastOpened ?? .distantPast) < entry.lastOpened {
                newest[key] = entry
            }
        }
        return newest
    }

    // MARK: Files

    /// Files in a folder, by their real names. Files iCloud hasn't downloaded yet can show
    /// up as hidden `.Name.epub.icloud` placeholders, which count too.
    static func files(in folder: URL, withExtension pathExtension: String) -> [URL] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path(percentEncoded: false))) ?? []
        var found: Set<String> = []
        for var name in names {
            if name.hasPrefix(".") {
                guard name.hasSuffix(".icloud") else { continue }
                name = String(name.dropFirst().dropLast(".icloud".count))
            }
            if (name as NSString).pathExtension.lowercased() == pathExtension { found.insert(name) }
        }
        return found.sorted().map { folder.appending(path: $0) }
    }

    /// UTC to the millisecond, such as 2026-10-20T23:04:47.765Z, so close saves still sort right.
    private static let dateStyle = Date.ISO8601FormatStyle(includingFractionalSeconds: true)

    static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(date.formatted(dateStyle))
        }
        return encoder
    }()

    static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let text = try decoder.singleValueContainer().decode(String.self)
            if let date = try? Date(text, strategy: dateStyle) {
                return date
            }
            return try Date(text, strategy: .iso8601)
        }
        return decoder
    }()

    // NSFileCoordinator tells iCloud and other apps what we're doing, and a coordinated
    // read downloads the file first if it's only in the cloud.

    static func coordinatedRead<T>(_ url: URL, _ body: (URL) throws -> T) throws -> T {
        var failure: NSError?
        var result: Result<T, any Error>?
        NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: &failure) { url in
            result = Result { try body(url) }
        }
        if let failure { throw failure }
        guard let result else { throw CocoaError(.fileReadUnknown) }
        return try result.get()
    }

    static func coordinatedWrite(_ url: URL, options: NSFileCoordinator.WritingOptions = [], _ body: (URL) throws -> Void) throws {
        var failure: NSError?
        var result: Result<Void, any Error>?
        NSFileCoordinator().coordinate(writingItemAt: url, options: options, error: &failure) { url in
            result = Result { try body(url) }
        }
        if let failure { throw failure }
        try result?.get()
    }

    static func coordinatedDelete(_ url: URL, _ body: (URL) throws -> Void) throws {
        try coordinatedWrite(url, options: .forDeleting, body)
    }
}
