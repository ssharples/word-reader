import AppKit
import Observation
import ReaderCore
import UniformTypeIdentifiers

struct AppAlert: Identifiable {
    let id = UUID()
    let title: String
    let message: String
}

/// The library shelf and the book that's open, if any.
@MainActor @Observable
final class AppModel {
    private(set) var books: [BookInfo] = []
    private(set) var isLoadingLibrary = false
    private(set) var libraryProblem: String?
    private(set) var session: ReaderSession?
    private(set) var openingBookID: String?
    var alert: AppAlert?

    let progress = ProgressStore()

    private static let addedBooksKey = "addedBooks"

    /// Books added with Open EPUB… or drag and drop, outside the Apple Books folder.
    private var addedPaths: [String] {
        get { UserDefaults.standard.stringArray(forKey: Self.addedBooksKey) ?? [] }
        set { UserDefaults.standard.set(newValue, forKey: Self.addedBooksKey) }
    }

    // MARK: Library

    func loadLibrary() async {
        isLoadingLibrary = true
        let folder = Library.appleBooksFolder
        let added = addedPaths.map { URL(fileURLWithPath: $0) }
        let (found, problem) = await Task.detached(priority: .userInitiated) { () -> ([BookInfo], String?) in
            var urls: [URL] = []
            var problem: String?
            do {
                urls = try Library.epubs(in: folder)
            } catch {
                problem = "Word Reader couldn't read your Apple Books folder. Use Open EPUB… to add books instead."
            }
            let known = Set(urls.map(\.path))
            urls += added.filter { !known.contains($0.path) && FileManager.default.fileExists(atPath: $0.path) }
            return (Library.scan(urls), problem)
        }.value
        // Keep any book added while the scan was running.
        let foundIDs = Set(found.map(\.id))
        let addedIDs = Set(addedPaths)
        let addedMeanwhile = books.filter { addedIDs.contains($0.id) && !foundIDs.contains($0.id) }
        books = (found + addedMeanwhile).sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        libraryProblem = problem
        isLoadingLibrary = false
    }

    func showOpenPanel() {
        let panel = NSOpenPanel()
        panel.title = "Add EPUB Books"
        panel.message = "Choose one or more EPUB books."
        panel.prompt = "Add"
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = ["org.idpf.epub-container", "org.idpf.epub-folder", "com.apple.ibooks.epub"]
            .compactMap { UTType($0) } + [UTType(filenameExtension: "epub")].compactMap { $0 }
        guard panel.runModal() == .OK else { return }
        let urls = panel.urls
        Task { await add(urls) }
    }

    /// Adds books to the shelf. A single book opens straight away.
    func add(_ urls: [URL]) async {
        var added: [BookInfo] = []
        for url in urls where url.pathExtension.lowercased() == "epub" {
            do {
                let info = try await Task.detached { BookInfo(package: try EPUBPackage.open(url)) }.value
                added.append(info)
                if !books.contains(where: { $0.id == info.id }) {
                    books.append(info)
                    if !addedPaths.contains(info.id) { addedPaths.append(info.id) }
                }
            } catch {
                alert = AppAlert(title: "Can't add “\(url.lastPathComponent)”", message: error.localizedDescription)
            }
        }
        books.sort { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        if added.count == 1 { await open(added[0]) }
    }

    func showInFinder(_ book: BookInfo) {
        NSWorkspace.shared.activateFileViewerSelecting([book.url])
    }

    func startOver(_ book: BookInfo) {
        progress.forget(book.id)
    }

    // MARK: Reading

    func open(_ book: BookInfo, at wordIndex: Int? = nil) async {
        if book.isProtected {
            alert = AppAlert(title: "Can't open “\(book.title)”", message: EPUBError.protected.localizedDescription)
            return
        }
        guard openingBookID == nil else { return }
        openingBookID = book.id
        defer { openingBookID = nil }
        let url = book.url
        do {
            let text = try await Task.detached(priority: .userInitiated) {
                try EPUBPackage.open(url).loadText()
            }.value
            let saved = progress.progress(for: book.id)?.index
            let start = min(max(wordIndex ?? saved ?? text.startIndex, 0), text.count - 1)
            session?.pause()
            session = ReaderSession(book: book, text: text, startAt: start, progress: progress)
            progress.update(book.id, index: start, total: text.count)
        } catch {
            alert = AppAlert(title: "Can't open “\(book.title)”", message: error.localizedDescription)
        }
    }

    func closeBook() {
        session?.pause()
        session = nil
    }

    /// Supports `--open <path> [--word <n>] [--play]` on launch, handy from the Terminal.
    func handleLaunchArguments() async {
        let arguments = ProcessInfo.processInfo.arguments
        guard let flag = arguments.firstIndex(of: "--open"), flag + 1 < arguments.count else { return }
        let url = URL(fileURLWithPath: arguments[flag + 1])
        let word = arguments.firstIndex(of: "--word").flatMap { $0 + 1 < arguments.count ? Int(arguments[$0 + 1]) : nil }
        guard let info = try? await Task.detached(operation: { BookInfo(package: try EPUBPackage.open(url)) }).value else {
            return
        }
        await open(info, at: word)
        if arguments.contains("--play") { session?.play() }
    }
}

struct ReadingProgress: Codable, Sendable {
    var index: Int
    var total: Int
    var lastOpened: Date

    var fraction: Double { total > 1 ? Double(index) / Double(total - 1) : 0 }
}

/// Where you are in each book, kept in UserDefaults.
@MainActor @Observable
final class ProgressStore {
    private static let key = "readingProgress"
    private(set) var entries: [String: ReadingProgress]

    init() {
        let data = UserDefaults.standard.data(forKey: Self.key)
        entries = data.flatMap { try? JSONDecoder().decode([String: ReadingProgress].self, from: $0) } ?? [:]
    }

    func progress(for id: String) -> ReadingProgress? { entries[id] }

    func update(_ id: String, index: Int, total: Int) {
        entries[id] = ReadingProgress(index: index, total: total, lastOpened: .now)
        save()
    }

    func forget(_ id: String) {
        entries[id] = nil
        save()
    }

    private func save() {
        if let data = try? JSONEncoder().encode(entries) {
            UserDefaults.standard.set(data, forKey: Self.key)
        }
    }
}
