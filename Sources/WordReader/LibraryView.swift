import AppKit
import ImageIO
import ReaderCore
import ReaderKit
import SwiftUI

struct LibraryView: View {
    @Environment(AppModel.self) private var app
    @State private var query = ""
    @State private var isDropTarget = false
    @State private var slowScan = false
    @State private var showSync = false

    private let columns = [GridItem(.adaptive(minimum: 140, maximum: 180), spacing: 24, alignment: .top)]

    private var matches: [BookInfo] {
        let terms = query.trimmingCharacters(in: .whitespaces)
        guard !terms.isEmpty else { return app.books }
        return app.books.filter {
            $0.title.localizedStandardContains(terms) || ($0.author?.localizedStandardContains(terms) ?? false)
        }
    }

    /// Books opened before, most recent first.
    private var recent: [BookInfo] {
        app.books
            .compactMap { book in app.progress.progress(for: book).map { (book, $0.lastOpened) } }
            .sorted { $0.1 > $1.1 }
            .prefix(6)
            .map(\.0)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 36) {
                if let problem = app.libraryProblem {
                    Label(problem, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.secondary)
                }
                if query.isEmpty, !recent.isEmpty {
                    shelf("Continue Reading", recent)
                }
                if !matches.isEmpty {
                    shelf(query.isEmpty ? "All Books" : "Results", matches)
                }
            }
            .padding(.horizontal, 32)
            .padding(.vertical, 24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .overlay { emptyState }
        .overlay {
            if isDropTarget {
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(Color.accentColor, lineWidth: 3)
                    .padding(8)
                    .allowsHitTesting(false)
            }
        }
        .navigationTitle("Library")
        .navigationSubtitle(app.books.isEmpty ? "" : "\(app.books.count) books")
        .searchable(text: $query, placement: .toolbar, prompt: "Title or author")
        .toolbar {
            ToolbarItem {
                Button {
                    showSync.toggle()
                } label: {
                    Label("Sync", systemImage: app.sync.problem != nil ? "exclamationmark.icloud" : app.isSyncing ? "checkmark.icloud" : "icloud")
                }
                .help("Sync books and progress with iPhone")
                .popover(isPresented: $showSync, arrowEdge: .bottom) {
                    SyncSettings()
                }
            }
            ToolbarItem {
                Button {
                    Task { await app.loadLibrary() }
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .help("Look for new books")
                .disabled(app.isLoadingLibrary)
            }
            ToolbarItem {
                Button {
                    app.showOpenPanel()
                } label: {
                    Label("Open EPUB…", systemImage: "plus")
                }
                .help("Add EPUB books (⌘O)")
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            let books = urls.filter { $0.pathExtension.lowercased() == "epub" }
            guard !books.isEmpty else { return false }
            Task { await app.add(books) }
            return true
        } isTargeted: {
            isDropTarget = $0
        }
    }

    private func shelf(_ title: String, _ books: [BookInfo]) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(title)
                .font(.title2.weight(.semibold))
            LazyVGrid(columns: columns, alignment: .leading, spacing: 28) {
                ForEach(books) { book in
                    BookCard(book: book)
                }
            }
        }
    }

    @ViewBuilder private var emptyState: some View {
        if app.books.isEmpty {
            if app.isLoadingLibrary {
                VStack(spacing: 12) {
                    ProgressView("Looking for books…")
                    if slowScan {
                        Text("If macOS asks, allow Word Reader to use iCloud Drive. Apple Books keeps your books there.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: 340)
                    }
                }
                .task {
                    try? await Task.sleep(for: .seconds(3))
                    slowScan = true
                }
            } else {
                ContentUnavailableView {
                    Label("No Books Yet", systemImage: "books.vertical")
                } description: {
                    Text("Books you add to Apple Books show up here. You can also drop EPUB files on this window.")
                } actions: {
                    Button("Open EPUB…") { app.showOpenPanel() }
                }
            }
        } else if matches.isEmpty {
            ContentUnavailableView.search(text: query)
        }
    }
}

struct BookCard: View {
    @Environment(AppModel.self) private var app
    let book: BookInfo
    @State private var hovering = false

    var body: some View {
        let progress = app.progress.progress(for: book)
        Button {
            Task { await app.open(book) }
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                CoverView(book: book)
                    .overlay {
                        if app.openingBookID == book.id {
                            ZStack {
                                Color.black.opacity(0.35)
                                ProgressView().controlSize(.large)
                            }
                        }
                    }
                    .overlay(alignment: .topLeading) {
                        if app.isSyncing, app.syncedKeys.contains(book.key) {
                            Image(systemName: "iphone")
                                .font(.caption2.weight(.semibold))
                                .frame(width: 22, height: 22)
                                .background(.thickMaterial, in: Circle())
                                .padding(6)
                                .help("In the sync folder, so on your iPhone too")
                        }
                    }
                    .overlay(alignment: .topTrailing) {
                        if book.isProtected {
                            Image(systemName: "lock.fill")
                                .font(.caption)
                                .padding(6)
                                .background(.thickMaterial, in: Circle())
                                .padding(6)
                                .help("Protected by copy protection, so it can't be read here")
                        }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 4))
                    .shadow(color: .black.opacity(hovering ? 0.32 : 0.18), radius: hovering ? 10 : 4, y: hovering ? 5 : 2)
                    .scaleEffect(hovering ? 1.02 : 1)
                    .padding(.bottom, 4)
                Text(book.title)
                    .font(.callout.weight(.medium))
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                if let author = book.author {
                    Text(author)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                if let progress {
                    HStack(spacing: 6) {
                        ProgressView(value: progress.fraction)
                            .controlSize(.mini)
                        Text(progress.fraction, format: .percent.precision(.fractionLength(0)))
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { inside in
            withAnimation(.easeOut(duration: 0.15)) { hovering = inside }
        }
        .contextMenu {
            Button("Read") { Task { await app.open(book) } }
            if progress != nil {
                Button("Start Over") {
                    app.startOver(book)
                    Task { await app.open(book) }
                }
            }
            if app.isSyncing, !app.syncedKeys.contains(book.key), !book.isProtected {
                Button("Add to iPhone") { Task { await app.addToSync(book) } }
            }
            Divider()
            Button("Show in Finder") { app.showInFinder(book) }
        }
        .help([book.title, book.author].compactMap { $0 }.joined(separator: " — "))
    }
}

struct CoverView: View {
    let book: BookInfo
    @State private var image: NSImage?

    var body: some View {
        Color.clear
            .aspectRatio(2.0 / 3.0, contentMode: .fit)
            .overlay {
                if let image {
                    Image(nsImage: image)
                        .resizable()
                        .scaledToFill()
                } else {
                    PlaceholderCover(title: book.title, author: book.author)
                }
            }
            .clipped()
            .task(id: book.id) {
                image = await CoverCache.shared.cover(for: book)
            }
    }
}

/// Small cover images, made once per book and kept in memory.
@MainActor
final class CoverCache {
    static let shared = CoverCache()
    private let images = NSCache<NSString, NSImage>()
    private var missing: Set<String> = []

    private struct Thumbnail: @unchecked Sendable {
        let image: CGImage
    }

    func cover(for book: BookInfo) async -> NSImage? {
        if let image = images.object(forKey: book.id as NSString) { return image }
        if missing.contains(book.id) { return nil }
        let url = book.url
        let thumbnail = await Task.detached(priority: .utility) { () -> Thumbnail? in
            guard let data = try? EPUBPackage.open(url).coverData(),
                  let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 540,
            ]
            return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary).map(Thumbnail.init)
        }.value
        guard let thumbnail else {
            missing.insert(book.id)
            return nil
        }
        let image = NSImage(cgImage: thumbnail.image, size: .zero)
        images.setObject(image, forKey: book.id as NSString)
        return image
    }
}
