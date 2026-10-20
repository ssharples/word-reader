import AppKit
import Observation
import ReaderCore
import ReaderKit
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
    /// Books that are in the sync folder, so on the iPhone too.
    private(set) var syncedKeys: Set<String> = []
    /// The sync folder's own copies on the shelf: books added on the iPhone.
    private var syncedCopies: Set<String> = []

    let progress = ProgressStore()
    let sync: BookSync

    private static let addedBooksKey = "addedBooks"
    /// Reads books from another folder instead of Apple Books', for trying things out.
    private static let libraryFolderKey = "libraryFolder"

    init() {
        sync = BookSync(progress: progress, deviceName: Host.current().localizedName ?? "Mac")
    }

    /// Books added with Open EPUB… or drag and drop, outside the Apple Books folder.
    private var addedPaths: [String] {
        get { UserDefaults.standard.stringArray(forKey: Self.addedBooksKey) ?? [] }
        set { UserDefaults.standard.set(newValue, forKey: Self.addedBooksKey) }
    }

    /// Connects to the sync folder, then loads the library and any book named on the
    /// command line.
    func start() async {
        await connectSync()
        async let library: Void = loadLibrary()
        await handleLaunchArguments()
        await library
        if sync.folder != nil {
            await sync.pull()
            await sync.push()
        }
    }

    // MARK: Library

    func loadLibrary() async {
        isLoadingLibrary = true
        let folder = UserDefaults.standard.string(forKey: Self.libraryFolderKey)
            .map { URL(fileURLWithPath: $0, isDirectory: true) } ?? Library.appleBooksFolder
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
        let shared = await sync.books()
        // Keep any book added while the scan was running.
        let foundIDs = Set(found.map(\.id))
        let addedIDs = Set(addedPaths)
        let addedMeanwhile = books.filter { addedIDs.contains($0.id) && !foundIDs.contains($0.id) }
        setBooks(found + addedMeanwhile, shared: shared)
        progress.adoptPathKeys(of: books)
        libraryProblem = problem
        isLoadingLibrary = false
    }

    /// Picks up books added on the iPhone without rescanning the whole library.
    func refreshSyncedBooks() async {
        let shared = await sync.books()
        setBooks(books.filter { !syncedCopies.contains($0.id) }, shared: shared)
    }

    /// Shows each book once. A book here and in the sync folder shows the copy here.
    private func setBooks(_ local: [BookInfo], shared: [BookInfo]) {
        var seen: Set<String> = []
        books = (local + shared)
            .filter { seen.insert($0.key).inserted }
            .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        syncedKeys = Set(shared.map(\.key))
        syncedCopies = Set(shared.map(\.id))
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
                if !books.contains(where: { $0.id == info.id || $0.key == info.key }) {
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
        progress.forget(book)
    }

    // MARK: Sync

    var isSyncing: Bool { sync.folder != nil }

    /// The folder to sync with: iCloud Drive › Word Reader unless another was chosen.
    var syncFolderURL: URL {
        UserDefaults.standard.string(forKey: Prefs.syncFolderPath)
            .map { URL(fileURLWithPath: $0, isDirectory: true) } ?? SyncFolder.iCloudDrive
    }

    private func connectSync() async {
        let on = UserDefaults.standard.bool(forKey: Prefs.syncEnabled)
        await sync.connect(to: on ? SyncFolder(root: syncFolderURL) : nil)
    }

    func setSyncing(_ on: Bool) async {
        UserDefaults.standard.set(on, forKey: Prefs.syncEnabled)
        await connectSync()
        if on {
            await sync.pull()
            // The book you're reading goes over straight away.
            if let book = session?.book { await addToSync(book) }
            await sync.push()
        }
        await refreshSyncedBooks()
    }

    func chooseSyncFolder() {
        let panel = NSOpenPanel()
        panel.title = "Choose a Sync Folder"
        panel.message = "Choose a folder your iPhone can see too, such as one in iCloud Drive or Dropbox."
        panel.prompt = "Choose"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.directoryURL = syncFolderURL.deletingLastPathComponent()
        guard panel.runModal() == .OK, let picked = panel.url else { return }
        UserDefaults.standard.set(SyncFolder.folder(forPicked: picked).path(percentEncoded: false), forKey: Prefs.syncFolderPath)
        Task { await setSyncing(true) }
    }

    func showSyncFolder() {
        NSWorkspace.shared.activateFileViewerSelecting([syncFolderURL])
    }

    /// Copies a book to the sync folder, so it's on the iPhone too.
    func addToSync(_ book: BookInfo) async {
        guard isSyncing, !syncedKeys.contains(book.key) else { return }
        syncedKeys.insert(book.key)
        do {
            _ = try await sync.add(book.url)
        } catch {
            syncedKeys.remove(book.key)
            alert = AppAlert(title: "Can't copy “\(book.title)” to the sync folder", message: error.localizedDescription)
        }
    }

    /// Back at the Mac: take any progress made on the iPhone, and any books added there.
    func appBecameActive() async {
        guard isSyncing else { return }
        let changed = await sync.pull()
        if let session, !session.isPlaying, changed.contains(session.book.key),
           let entry = progress.progress(for: session.book), entry.index != session.index {
            session.move(to: entry.index)
        }
        await refreshSyncedBooks()
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
            async let loading = Task.detached(priority: .userInitiated) {
                try EPUBPackage.open(url).loadText()
            }.value
            // Pick up where you stopped on the iPhone.
            await sync.pull(waitingAtMost: .seconds(2))
            let text = try await loading
            let saved = progress.progress(for: book)?.index
            let start = min(max(wordIndex ?? saved ?? text.startIndex, 0), text.count - 1)
            session?.pause()
            session = ReaderSession(book: book, text: text, startAt: start, progress: progress)
            progress.update(book, index: start, total: text.count)
            Task { await addToSync(book) }
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
