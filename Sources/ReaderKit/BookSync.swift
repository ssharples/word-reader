import Foundation
import Observation
import ReaderCore

/// Keeps books and reading progress in step with other devices through a `SyncFolder`.
///
/// Progress goes out a couple of seconds after it changes, and at most every 15 seconds
/// while you read. It comes in when the app asks: on launch, when the app comes back to
/// the front, and just before a book opens.
@MainActor @Observable
public final class BookSync {
    public private(set) var folder: SyncFolder?
    public private(set) var lastSynced: Date?
    public private(set) var problem: String?

    @ObservationIgnored private let progress: ProgressStore
    @ObservationIgnored private let deviceName: String
    @ObservationIgnored public let deviceID: String
    @ObservationIgnored private var pushTask: Task<Void, Never>?
    @ObservationIgnored private var lastPush: ContinuousClock.Instant?

    public init(progress: ProgressStore, deviceName: String, defaults: UserDefaults = .standard) {
        self.progress = progress
        self.deviceName = deviceName
        if let id = defaults.string(forKey: Prefs.syncDeviceID) {
            deviceID = id
        } else {
            deviceID = UUID().uuidString
            defaults.set(deviceID, forKey: Prefs.syncDeviceID)
        }
        progress.onChange = { [weak self] in self?.schedulePush() }
    }

    /// Starts syncing with `folder`, or stops when it's nil.
    public func connect(to folder: SyncFolder?) async {
        pushTask?.cancel()
        pushTask = nil
        self.folder = folder
        problem = nil
        lastSynced = nil
        guard let folder else { return }
        do {
            try await Task.detached { try folder.prepare() }.value
        } catch {
            problem = "Can't use the sync folder: \(error.localizedDescription)"
        }
    }

    /// Takes newer progress from other devices. Returns the books whose place changed.
    @discardableResult
    public func pull() async -> Set<String> {
        guard let folder else { return [] }
        let id = deviceID
        let devices = await Task.detached(priority: .userInitiated) { folder.readProgress(except: id) }.value
        guard folder == self.folder else { return [] }
        lastSynced = .now
        return progress.merge(SyncFolder.newest(devices))
    }

    /// Pulls, but gives up waiting after `limit` so a slow network doesn't hold up opening
    /// a book. A slow pull still finishes in the background.
    @discardableResult
    public func pull(waitingAtMost limit: Duration) async -> Set<String> {
        await firstResult(within: limit) { await self.pull() } ?? []
    }

    /// Saves this device's progress to the sync folder now.
    public func push() async {
        pushTask?.cancel()
        pushTask = nil
        guard let folder else { return }
        lastPush = .now
        let snapshot = DeviceProgress(device: deviceName, updated: .now, books: progress.syncedEntries)
        let id = deviceID
        do {
            try await Task.detached(priority: .utility) { try folder.write(snapshot, deviceID: id) }.value
            lastSynced = .now
            problem = nil
        } catch {
            problem = "Can't save progress to the sync folder: \(error.localizedDescription)"
        }
    }

    /// Saves progress now if a save was waiting.
    public func pushIfPending() async {
        if pushTask != nil { await push() }
    }

    /// Saves progress without waiting for the main thread to come back, for when the app quits.
    public func pushBeforeQuitting() {
        guard let folder, pushTask != nil else { return }
        pushTask?.cancel()
        pushTask = nil
        let snapshot = DeviceProgress(device: deviceName, updated: .now, books: progress.syncedEntries)
        try? folder.write(snapshot, deviceID: deviceID)
    }

    public func schedulePush() {
        guard folder != nil, pushTask == nil else { return }
        let sinceLast = lastPush.map { ContinuousClock.now - $0 } ?? .seconds(3600)
        let wait = max(.seconds(2), .seconds(15) - sinceLast)
        pushTask = Task { [weak self] in
            try? await Task.sleep(for: wait)
            guard !Task.isCancelled else { return }
            self?.pushTask = nil
            await self?.push()
        }
    }

    // MARK: Books

    /// Books in the sync folder, downloaded to this device first where needed.
    public func books() async -> [BookInfo] {
        guard let folder else { return [] }
        return await Task.detached(priority: .userInitiated) {
            folder.bookFiles().compactMap { url in
                try? SyncFolder.download(url)
                return (try? EPUBPackage.open(url)).map(BookInfo.init(package:))
            }
        }.value
    }

    /// Copies a book into the sync folder.
    public func add(_ book: URL) async throws -> BookInfo {
        guard let folder else { throw CocoaError(.fileNoSuchFile) }
        return try await Task.detached(priority: .userInitiated) {
            BookInfo(package: try EPUBPackage.open(try folder.addBook(book)))
        }.value
    }

    public func remove(_ book: BookInfo) async throws {
        guard let folder else { return }
        let url = book.url
        try await Task.detached { try folder.removeBook(url) }.value
    }

    /// Whether `book` is the sync folder's own copy.
    public func holds(_ book: BookInfo) -> Bool {
        guard let folder else { return false }
        return book.url.deletingLastPathComponent().standardizedFileURL.path(percentEncoded: false)
            == folder.booksFolder.standardizedFileURL.path(percentEncoded: false)
    }
}

/// Runs `operation`, but returns nil if it takes longer than `limit`. The operation
/// carries on; its result is dropped.
func firstResult<T: Sendable>(within limit: Duration, _ operation: @escaping @Sendable () async -> T) async -> T? {
    await withCheckedContinuation { (continuation: CheckedContinuation<T?, Never>) in
        let gate = ResumeOnce(continuation)
        Task { gate.resume(await operation()) }
        Task {
            try? await Task.sleep(for: limit)
            gate.resume(nil)
        }
    }
}

private final class ResumeOnce<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T?, Never>?

    init(_ continuation: CheckedContinuation<T?, Never>) {
        self.continuation = continuation
    }

    func resume(_ value: T?) {
        lock.lock()
        let waiting = continuation
        continuation = nil
        lock.unlock()
        waiting?.resume(returning: value)
    }
}
