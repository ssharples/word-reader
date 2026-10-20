import Foundation
import Observation
import ReaderCore

public struct ReadingProgress: Codable, Sendable, Equatable {
    public var index: Int
    public var total: Int
    /// When the book was last read or opened, here or on the device this entry came from.
    public var lastOpened: Date
    /// Set by Start Over, so other devices forget their place in the book too.
    public var cleared: Bool?

    public init(index: Int, total: Int, lastOpened: Date, cleared: Bool? = nil) {
        self.index = index
        self.total = total
        self.lastOpened = lastOpened
        self.cleared = cleared
    }

    public var fraction: Double { total > 1 ? Double(index) / Double(total - 1) : 0 }
}

/// Where you are in each book, kept in UserDefaults under each book's sync key.
@MainActor @Observable
public final class ProgressStore {
    private static let key = "readingProgress"
    public private(set) var entries: [String: ReadingProgress]
    /// Called after you read, open or start over a book, so it can be synced.
    @ObservationIgnored public var onChange: (() -> Void)?
    @ObservationIgnored private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let data = defaults.data(forKey: Self.key)
        entries = data.flatMap { try? JSONDecoder().decode([String: ReadingProgress].self, from: $0) } ?? [:]
    }

    public func progress(for book: BookInfo) -> ReadingProgress? {
        // Versions before sync saved progress under the file's path.
        guard let entry = entries[book.key] ?? entries[book.id], entry.cleared != true else { return nil }
        return entry
    }

    public func update(_ book: BookInfo, index: Int, total: Int) {
        entries[book.id] = nil
        entries[book.key] = ReadingProgress(index: index, total: total, lastOpened: .now)
        save()
        onChange?()
    }

    public func forget(_ book: BookInfo) {
        let total = entries[book.key]?.total ?? entries[book.id]?.total ?? 0
        entries[book.id] = nil
        entries[book.key] = ReadingProgress(index: 0, total: total, lastOpened: .now, cleared: true)
        save()
        onChange?()
    }

    /// Moves progress saved under file paths, before sync existed, to the books' keys.
    public func adoptPathKeys(of books: [BookInfo]) {
        var changed = false
        for book in books {
            guard let old = entries[book.id] else { continue }
            if let current = entries[book.key], current.lastOpened >= old.lastOpened {
                // Already moved.
            } else {
                entries[book.key] = old
            }
            entries[book.id] = nil
            changed = true
        }
        if changed { save() }
    }

    /// Entries keyed by book rather than by path: the ones worth syncing.
    public var syncedEntries: [String: ReadingProgress] {
        entries.filter { !$0.key.hasPrefix("/") }
    }

    /// Takes each entry another device saved more recently than this one. Returns the
    /// keys that changed.
    @discardableResult
    public func merge(_ remote: [String: ReadingProgress]) -> Set<String> {
        var changed: Set<String> = []
        for (key, theirs) in remote where !key.hasPrefix("/") {
            let mine = entries[key]
            if let mine, mine.lastOpened >= theirs.lastOpened { continue }
            var taken = theirs
            // The same book should always have the same number of words, but if a newer
            // version splits them differently, keep the same place by fraction.
            if let mine, mine.total > 1, theirs.total > 1, mine.total != theirs.total, theirs.cleared != true {
                taken.index = Int((theirs.fraction * Double(mine.total - 1)).rounded())
                taken.total = mine.total
            }
            entries[key] = taken
            changed.insert(key)
        }
        if !changed.isEmpty { save() }
        return changed
    }

    private func save() {
        if let data = try? JSONEncoder().encode(entries) {
            defaults.set(data, forKey: Self.key)
        }
    }
}
