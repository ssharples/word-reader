import Foundation
import Testing
import ReaderCore
@testable import ReaderKit

private func scratchFolder() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appending(path: "word-reader-sync-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private func freshDefaults() -> UserDefaults {
    let name = "word-reader-tests-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: name)!
    defaults.removePersistentDomain(forName: name)
    return defaults
}

private func book(_ key: String, at path: String = "/books/a.epub") -> BookInfo {
    BookInfo(url: URL(fileURLWithPath: path), title: "A", author: nil, isProtected: false, key: key)
}

/// A minimal EPUB as an unzipped folder.
private func writeBook(titled title: String, in folder: URL) throws -> URL {
    let root = folder.appending(path: "\(title).epub", directoryHint: .isDirectory)
    let files = [
        "mimetype": "application/epub+zip",
        "META-INF/container.xml": #"<container><rootfiles><rootfile full-path="content.opf" media-type="application/oebps-package+xml"/></rootfiles></container>"#,
        "content.opf": """
        <package unique-identifier="id"><metadata><dc:identifier id="id">id-\(title)</dc:identifier><dc:title>\(title)</dc:title></metadata>
        <manifest><item id="t" href="t.xhtml" media-type="application/xhtml+xml"/></manifest><spine><itemref idref="t"/></spine></package>
        """,
        "t.xhtml": "<html><body><p>One two three four five.</p></body></html>",
    ]
    for (path, text) in files {
        let url = root.appending(path: path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }
    return root
}

@MainActor @Suite struct ProgressTests {
    @Test func movesOldPathKeysToBookKeys() {
        let defaults = freshDefaults()
        let old = ReadingProgress(index: 6077, total: 175_233, lastOpened: .now)
        defaults.set(try! JSONEncoder().encode(["/books/a.epub/": old]), forKey: "readingProgress")
        let store = ProgressStore(defaults: defaults)
        let yogi = book("id|yogi|", at: "/books/a.epub/")

        #expect(store.progress(for: yogi)?.index == 6077)
        store.adoptPathKeys(of: [yogi])
        #expect(store.entries.keys.sorted() == ["id|yogi|"])
        #expect(ProgressStore(defaults: defaults).progress(for: yogi) == old)
    }

    @Test func takesNewerProgressFromOtherDevices() {
        let store = ProgressStore(defaults: freshDefaults())
        let a = book("a"), b = book("b")
        store.update(a, index: 10, total: 100)
        store.update(b, index: 50, total: 100)
        let mine = store.entries["a"]!.lastOpened

        let changed = store.merge([
            "a": ReadingProgress(index: 80, total: 100, lastOpened: mine.addingTimeInterval(60)),
            "b": ReadingProgress(index: 5, total: 100, lastOpened: mine.addingTimeInterval(-60)),
            "c": ReadingProgress(index: 30, total: 60, lastOpened: mine),
        ])
        #expect(changed == ["a", "c"])
        #expect(store.progress(for: a)?.index == 80)
        #expect(store.progress(for: b)?.index == 50)
        #expect(store.entries["c"]?.index == 30)
    }

    @Test func keepsThePlaceWhenWordCountsDiffer() {
        let store = ProgressStore(defaults: freshDefaults())
        store.update(book("a"), index: 0, total: 201)
        store.merge(["a": ReadingProgress(index: 50, total: 101, lastOpened: .now.addingTimeInterval(5))])
        #expect(store.entries["a"]?.index == 100)
        #expect(store.entries["a"]?.total == 201)
    }

    @Test func startOverSpreadsToOtherDevices() {
        let phone = ProgressStore(defaults: freshDefaults())
        let mac = ProgressStore(defaults: freshDefaults())
        let a = book("a")
        mac.update(a, index: 40, total: 100)
        phone.merge(mac.syncedEntries)
        #expect(phone.progress(for: a)?.index == 40)

        phone.forget(a)
        #expect(phone.progress(for: a) == nil)
        mac.merge(phone.syncedEntries)
        #expect(mac.progress(for: a) == nil)
    }
}

@Suite struct SyncFolderTests {
    @Test func picksOrMakesAWordReaderFolder() throws {
        let scratch = try scratchFolder()
        defer { try? FileManager.default.removeItem(at: scratch) }
        #expect(SyncFolder.folder(forPicked: scratch).lastPathComponent == "Word Reader")
        let named = scratch.appending(path: "Word Reader")
        #expect(SyncFolder.folder(forPicked: named) == named)
        let other = scratch.appending(path: "Shared")
        try FileManager.default.createDirectory(at: other.appending(path: "Progress"), withIntermediateDirectories: true)
        #expect(SyncFolder.folder(forPicked: other) == other)
    }

    @Test func writesAndReadsEachDevicesProgress() throws {
        let scratch = try scratchFolder()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let folder = SyncFolder(root: scratch)
        let when = Date(timeIntervalSince1970: 1_800_000_000.25)
        let mac = DeviceProgress(device: "Mac", updated: when, books: ["a": ReadingProgress(index: 1, total: 9, lastOpened: when)])
        let phone = DeviceProgress(device: "iPhone", updated: when, books: [
            "a": ReadingProgress(index: 7, total: 9, lastOpened: when.addingTimeInterval(1)),
            "b": ReadingProgress(index: 2, total: 9, lastOpened: when, cleared: true),
        ])
        try folder.write(mac, deviceID: "mac")
        try folder.write(phone, deviceID: "phone")

        #expect(folder.readProgress(except: "mac") == [phone])
        let all = folder.readProgress(except: "nobody")
        #expect(all.count == 2)
        // Times keep their fractions of a second, so close saves still order correctly.
        #expect(all.contains(mac))
        let newest = SyncFolder.newest(all)
        #expect(newest["a"]?.index == 7)
        #expect(newest["b"]?.cleared == true)
    }

    @Test func countsBooksStillInICloud() throws {
        let scratch = try scratchFolder()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let folder = SyncFolder(root: scratch)
        try folder.prepare()
        for name in ["Here.epub", ".Away.epub.icloud", ".DS_Store", "notes.txt"] {
            try Data().write(to: folder.booksFolder.appending(path: name))
        }
        #expect(folder.bookFiles().map(\.lastPathComponent) == ["Away.epub", "Here.epub"])
    }

    @Test func addsBooksAsSingleFiles() throws {
        let scratch = try scratchFolder()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let folder = SyncFolder(root: scratch.appending(path: "Word Reader"))
        let original = try writeBook(titled: "Dune", in: scratch)

        let copy = try folder.addBook(original)
        let second = try folder.addBook(original)
        #expect(copy.lastPathComponent == "Dune.epub")
        #expect(second.lastPathComponent == "Dune 2.epub")
        var isFolder: ObjCBool = true
        #expect(FileManager.default.fileExists(atPath: copy.path, isDirectory: &isFolder) && !isFolder.boolValue)
        #expect(BookInfo(package: try EPUBPackage.open(copy)).key == BookInfo(package: try EPUBPackage.open(original)).key)
        try EPUBPackage.open(copy).loadText().words.forEach { _ in }
    }
}

@MainActor @Suite struct BookSyncTests {
    @Test func progressMovesBetweenTwoDevices() async throws {
        let scratch = try scratchFolder()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let folder = SyncFolder(root: scratch)
        let macStore = ProgressStore(defaults: freshDefaults())
        let phoneStore = ProgressStore(defaults: freshDefaults())
        let mac = BookSync(progress: macStore, deviceName: "Mac", defaults: freshDefaults())
        let phone = BookSync(progress: phoneStore, deviceName: "iPhone", defaults: freshDefaults())
        await mac.connect(to: folder)
        await phone.connect(to: folder)

        let original = try writeBook(titled: "Emma", in: scratch)
        let onPhone = try await mac.add(original)
        #expect(await phone.books().map(\.key) == [onPhone.key])

        macStore.update(onPhone, index: 3, total: 5)
        await mac.push()
        #expect(await phone.pull() == [onPhone.key])
        #expect(phoneStore.progress(for: onPhone)?.index == 3)

        try await Task.sleep(for: .milliseconds(20))
        phoneStore.update(onPhone, index: 4, total: 5)
        await phone.push()
        await mac.pull()
        #expect(macStore.progress(for: onPhone)?.index == 4)
        // Reading your own file back changes nothing.
        #expect(await phone.pull().isEmpty)
    }

    @Test func givesUpWaitingForASlowPull() async {
        let started = ContinuousClock.now
        let result = await firstResult(within: .milliseconds(50)) { () -> Int in
            try? await Task.sleep(for: .seconds(5))
            return 1
        }
        #expect(result == nil)
        #expect(ContinuousClock.now - started < .seconds(1))
    }
}
