import Observation
import ReaderCore
import ReaderKit
import UIKit
import UniformTypeIdentifiers

struct PhoneAlert: Identifiable {
    let id = UUID()
    let title: String
    let message: String
}

/// The library, the book that's open and the sync folder.
///
/// Books live in the sync folder when there is one, so the Mac sees them too, and in
/// the app's own Documents folder otherwise (Files › On My iPhone › Word Reader).
@MainActor @Observable
final class PhoneModel {
    private(set) var books: [BookInfo] = []
    private(set) var hasLoaded = false
    private(set) var session: ReaderSession?
    private(set) var openingBookID: String?
    /// A short note over the reader, such as where sync moved you to.
    private(set) var notice: String?
    var alert: PhoneAlert?

    let progress = ProgressStore()
    let sync: BookSync

    @ObservationIgnored private var scopedFolder: URL?
    @ObservationIgnored private var started = false
    @ObservationIgnored private var noticeTask: Task<Void, Never>?
    @ObservationIgnored private var backgroundTask = UIBackgroundTaskIdentifier.invalid

    static let bookTypes: [UTType] = [UTType("org.idpf.epub-container"), UTType(filenameExtension: "epub")].compactMap { $0 }

    init() {
        sync = BookSync(progress: progress, deviceName: UIDevice.current.name)
    }

    func start() async {
        guard !started else { return }
        started = true
        await reconnect()
        await loadLibrary()
        if isSyncing {
            await sync.pull()
            await sync.push()
        }
    }

    /// Back in the app: take progress made on the Mac, and any books added there.
    func becameActive() async {
        guard started, isSyncing else { return }
        let changed = await sync.pull()
        if let session, !session.isPlaying, changed.contains(session.book.key),
           let entry = progress.progress(for: session.book), entry.index != session.index {
            session.move(to: entry.index)
            show("Moved to where you stopped on your other device")
        }
        await loadLibrary()
    }

    func enteredBackground() {
        session?.pause()
        guard isSyncing else { return }
        // A moment to save progress, so the Mac has it when you sit down.
        backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "Save reading progress") { [weak self] in
            self?.endBackgroundTask()
        }
        Task {
            await sync.pushIfPending()
            endBackgroundTask()
        }
    }

    private func endBackgroundTask() {
        guard backgroundTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTask)
        backgroundTask = .invalid
    }

    // MARK: Library

    func loadLibrary() async {
        let documents = URL.documentsDirectory
        let local = await Task.detached(priority: .userInitiated) {
            Library.scan((try? Library.epubs(in: documents)) ?? [])
        }.value
        let shared = await sync.books()
        // A book here and in the sync folder shows once: the synced copy.
        var seen: Set<String> = []
        books = (shared + local)
            .filter { seen.insert($0.key).inserted }
            .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        hasLoaded = true
    }

    func refresh() async {
        if isSyncing { await sync.pull() }
        await loadLibrary()
    }

    /// Adds books picked in Files or opened from another app. A single book opens straight away.
    func importBooks(_ urls: [URL]) async {
        var added: [BookInfo] = []
        for url in urls where url.pathExtension.lowercased() == "epub" {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            do {
                let info = try await Task.detached { BookInfo(package: try EPUBPackage.open(url)) }.value
                if let existing = books.first(where: { $0.key == info.key }) {
                    added.append(existing)
                } else if isSyncing {
                    added.append(try await sync.add(url))
                } else {
                    added.append(try await Task.detached { try Self.copyIntoDocuments(url) }.value)
                }
            } catch {
                alert = PhoneAlert(title: "Can't add “\(url.lastPathComponent)”", message: error.localizedDescription)
            }
        }
        await loadLibrary()
        if added.count == 1, let book = books.first(where: { $0.key == added[0].key }) {
            await open(book)
        }
    }

    nonisolated private static func copyIntoDocuments(_ source: URL) throws -> BookInfo {
        let folder = URL.documentsDirectory
        let name = source.deletingPathExtension().lastPathComponent
        var target = folder.appending(path: name + ".epub")
        var number = 2
        while FileManager.default.fileExists(atPath: target.path(percentEncoded: false)) {
            target = folder.appending(path: "\(name) \(number).epub")
            number += 1
        }
        try FileManager.default.copyItem(at: source, to: target)
        return BookInfo(package: try EPUBPackage.open(target))
    }

    func delete(_ book: BookInfo) async {
        do {
            if sync.holds(book) {
                try await sync.remove(book)
            } else {
                try FileManager.default.removeItem(at: book.url)
            }
        } catch {
            alert = PhoneAlert(title: "Can't delete “\(book.title)”", message: error.localizedDescription)
        }
        await loadLibrary()
    }

    func startOver(_ book: BookInfo) {
        progress.forget(book)
    }

    // MARK: Sync folder

    var isSyncing: Bool { sync.folder != nil }

    /// "iCloud Drive › Word Reader" rather than the path behind it.
    var syncFolderName: String? {
        guard let root = sync.folder?.root else { return nil }
        let parent = root.deletingLastPathComponent().lastPathComponent
        let place = parent == "com~apple~CloudDocs" ? "iCloud Drive" : parent
        return "\(place) › \(root.lastPathComponent)"
    }

    /// Starts syncing with a folder picked in Files. Books only on this iPhone go into it.
    func useSyncFolder(_ picked: URL) async {
        guard picked.startAccessingSecurityScopedResource() else {
            alert = PhoneAlert(title: "Can't use that folder", message: "Word Reader wasn't given access to it. Try choosing it again.")
            return
        }
        scopedFolder?.stopAccessingSecurityScopedResource()
        scopedFolder = picked
        if let bookmark = try? picked.bookmarkData(options: .minimalBookmark, includingResourceValuesForKeys: nil, relativeTo: nil) {
            UserDefaults.standard.set(bookmark, forKey: Prefs.syncFolderBookmark)
        }
        await sync.connect(to: SyncFolder(root: SyncFolder.folder(forPicked: picked)))
        let shared = Set(await sync.books().map(\.key))
        for book in books where !shared.contains(book.key) && !book.isProtected {
            _ = try? await sync.add(book.url)
        }
        await sync.pull()
        await sync.push()
        await loadLibrary()
    }

    func stopSyncing() async {
        UserDefaults.standard.removeObject(forKey: Prefs.syncFolderBookmark)
        await sync.connect(to: nil)
        scopedFolder?.stopAccessingSecurityScopedResource()
        scopedFolder = nil
        await loadLibrary()
    }

    /// Opens the sync folder chosen last time.
    private func reconnect() async {
        #if targetEnvironment(simulator)
        // For trying sync out: a folder on the Mac that runs the simulator.
        if let path = UserDefaults.standard.string(forKey: Prefs.syncFolderPath) {
            await sync.connect(to: SyncFolder(root: URL(fileURLWithPath: path, isDirectory: true)))
            return
        }
        #endif
        guard let bookmark = UserDefaults.standard.data(forKey: Prefs.syncFolderBookmark) else { return }
        do {
            var stale = false
            let url = try URL(resolvingBookmarkData: bookmark, bookmarkDataIsStale: &stale)
            guard url.startAccessingSecurityScopedResource() else { throw CocoaError(.fileReadNoPermission) }
            scopedFolder = url
            if stale, let fresh = try? url.bookmarkData(options: .minimalBookmark, includingResourceValuesForKeys: nil, relativeTo: nil) {
                UserDefaults.standard.set(fresh, forKey: Prefs.syncFolderBookmark)
            }
            await sync.connect(to: SyncFolder(root: SyncFolder.folder(forPicked: url)))
        } catch {
            alert = PhoneAlert(
                title: "Can't reach the sync folder",
                message: "Choose it again in Settings. \(error.localizedDescription)"
            )
        }
    }

    // MARK: Reading

    func open(_ book: BookInfo) async {
        if book.isProtected {
            alert = PhoneAlert(title: "Can't open “\(book.title)”", message: EPUBError.protected.localizedDescription)
            return
        }
        guard openingBookID == nil else { return }
        openingBookID = book.id
        defer { openingBookID = nil }
        let url = book.url
        do {
            async let loading = Task.detached(priority: .userInitiated) {
                try? SyncFolder.download(url)
                return try EPUBPackage.open(url).loadText()
            }.value
            // Pick up where you stopped on the Mac.
            await sync.pull(waitingAtMost: .seconds(2))
            let text = try await loading
            let saved = progress.progress(for: book)?.index
            let start = min(max(saved ?? text.startIndex, 0), text.count - 1)
            session = ReaderSession(book: book, text: text, startAt: start, progress: progress)
            progress.update(book, index: start, total: text.count)
        } catch {
            alert = PhoneAlert(title: "Can't open “\(book.title)”", message: error.localizedDescription)
        }
    }

    func closeBook() {
        session?.pause()
        session = nil
        Task { await sync.pushIfPending() }
    }

    private func show(_ message: String) {
        notice = message
        noticeTask?.cancel()
        noticeTask = Task {
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }
            notice = nil
        }
    }
}
