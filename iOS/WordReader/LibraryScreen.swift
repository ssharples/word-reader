import ReaderCore
import ReaderKit
import SwiftUI

struct LibraryScreen: View {
    @Environment(PhoneModel.self) private var model
    @State private var query = ""
    @State private var importing = false
    @State private var choosingFolder = false
    @State private var showSettings = false
    @State private var deleting: BookInfo?
    @AppStorage("hideSyncCard") private var hideSyncCard = false

    private let columns = [GridItem(.adaptive(minimum: 100, maximum: 150), spacing: 18, alignment: .top)]

    private var matches: [BookInfo] {
        let terms = query.trimmingCharacters(in: .whitespaces)
        guard !terms.isEmpty else { return model.books }
        return model.books.filter {
            $0.title.localizedStandardContains(terms) || ($0.author?.localizedStandardContains(terms) ?? false)
        }
    }

    /// Books opened before, most recent first.
    private var recent: [BookInfo] {
        model.books
            .compactMap { book in model.progress.progress(for: book).map { (book, $0.lastOpened) } }
            .sorted { $0.1 > $1.1 }
            .prefix(8)
            .map(\.0)
    }

    var body: some View {
        @Bindable var model = model
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 30) {
                    if !model.isSyncing, !hideSyncCard, !model.books.isEmpty {
                        SyncCard(choose: { choosingFolder = true }, dismiss: { withAnimation { hideSyncCard = true } })
                    }
                    if query.isEmpty, !recent.isEmpty {
                        continueReading
                    }
                    if !matches.isEmpty {
                        VStack(alignment: .leading, spacing: 14) {
                            Text(query.isEmpty ? "All Books" : "Results")
                                .font(.title3.weight(.semibold))
                            LazyVGrid(columns: columns, alignment: .leading, spacing: 24) {
                                ForEach(matches) { book in
                                    BookCell(book: book, deleting: $deleting)
                                }
                            }
                        }
                    }
                }
                // Full width even with no books, or the scroll view shrinks and
                // squeezes the empty-library message into a thin column.
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 20)
                .padding(.top, 8)
                .padding(.bottom, 32)
            }
            .overlay { emptyState }
            .navigationTitle("Library")
            .searchable(text: $query, prompt: "Title or author")
            .refreshable { await model.refresh() }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showSettings = true
                    } label: {
                        Label("Settings", systemImage: model.sync.problem != nil ? "exclamationmark.icloud" : "gearshape")
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        importing = true
                    } label: {
                        Label("Add Books", systemImage: "plus")
                    }
                }
            }
            .fileImporter(isPresented: $importing, allowedContentTypes: PhoneModel.bookTypes, allowsMultipleSelection: true) { result in
                if case .success(let urls) = result {
                    Task { await model.importBooks(urls) }
                }
            }
            .sheet(isPresented: $showSettings) {
                SettingsScreen()
            }
            .confirmationDialog(
                "Delete “\(deleting?.title ?? "")”?",
                isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
                titleVisibility: .visible,
                presenting: deleting
            ) { book in
                Button("Delete Book", role: .destructive) {
                    Task { await model.delete(book) }
                }
            } message: { _ in
                Text(model.isSyncing
                     ? "It's removed from the sync folder, so from your other devices too. Books in Apple Books on your Mac stay there."
                     : "It's removed from this iPhone.")
            }
        }
        // A second file picker can't share a view with the first.
        .background {
            Color.clear.fileImporter(isPresented: $choosingFolder, allowedContentTypes: [.folder]) { result in
                if case .success(let url) = result {
                    Task { await model.useSyncFolder(url) }
                }
            }
        }
        .fullScreenCover(isPresented: Binding(get: { model.session != nil }, set: { if !$0 { model.closeBook() } })) {
            if let session = model.session {
                ReaderScreen(session: session)
                    .environment(model)
            }
        }
        .alert(model.alert?.title ?? "", isPresented: Binding(get: { model.alert != nil }, set: { if !$0 { model.alert = nil } }), presenting: model.alert) { _ in
            Button("OK") {}
        } message: { alert in
            Text(alert.message)
        }
    }

    private var continueReading: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Continue Reading")
                .font(.title3.weight(.semibold))
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: 18) {
                    ForEach(recent) { book in
                        BookCell(book: book, deleting: $deleting)
                            .frame(width: 128)
                    }
                }
                .padding(.horizontal, 20)
            }
            .padding(.horizontal, -20)
        }
    }

    @ViewBuilder private var emptyState: some View {
        if !model.hasLoaded {
            ProgressView("Looking for books…")
        } else if model.books.isEmpty {
            ContentUnavailableView {
                Label("No Books Yet", systemImage: "books.vertical")
            } description: {
                Text("Add EPUB books from Files, or sync with Word Reader on your Mac to read the same books on both.")
            } actions: {
                Button("Add Books") { importing = true }
                    .prominentButton()
                if !model.isSyncing {
                    Button("Sync with Mac") { choosingFolder = true }
                }
            }
        } else if matches.isEmpty {
            ContentUnavailableView.search(text: query)
        }
    }
}

struct BookCell: View {
    @Environment(PhoneModel.self) private var model
    let book: BookInfo
    @Binding var deleting: BookInfo?

    var body: some View {
        let progress = model.progress.progress(for: book)
        Button {
            Task { await model.open(book) }
        } label: {
            VStack(alignment: .leading, spacing: 5) {
                CoverImage(book: book)
                    .overlay {
                        if model.openingBookID == book.id {
                            ZStack {
                                Color.black.opacity(0.35)
                                ProgressView().tint(.white)
                            }
                            .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                        }
                    }
                    .overlay(alignment: .topTrailing) {
                        if book.isProtected {
                            Image(systemName: "lock.fill")
                                .font(.caption2)
                                .padding(5)
                                .background(.thickMaterial, in: Circle())
                                .padding(5)
                        }
                    }
                    .shadow(color: .black.opacity(0.18), radius: 4, y: 2)
                    .padding(.bottom, 3)
                Text(book.title)
                    .font(.footnote.weight(.medium))
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                if let author = book.author {
                    Text(author)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                if let progress {
                    HStack(spacing: 6) {
                        ProgressView(value: progress.fraction)
                        Text(progress.fraction, format: .percent.precision(.fractionLength(0)))
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    .padding(.top, 1)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button("Read", systemImage: "book") { Task { await model.open(book) } }
            if progress != nil {
                Button("Start Over", systemImage: "arrow.counterclockwise") { model.startOver(book) }
            }
            Button("Delete", systemImage: "trash", role: .destructive) { deleting = book }
        } preview: {
            CoverImage(book: book, titleSize: 18)
                .frame(width: 220)
        }
        .accessibilityLabel([book.title, book.author].compactMap { $0 }.joined(separator: ", "))
    }
}

/// Suggests syncing with the Mac app until you do it or say no.
struct SyncCard: View {
    let choose: () -> Void
    let dismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: "laptopcomputer.and.iphone")
                .font(.title2)
                .foregroundStyle(.tint)
                .frame(width: 34)
            VStack(alignment: .leading, spacing: 6) {
                Text("Read on your Mac too")
                    .font(.headline)
                Text("Turn on Sync in Word Reader on your Mac, then choose iCloud Drive › Word Reader here. Your books and your place in each stay the same on both.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Choose Sync Folder", action: choose)
                    .prominentButton()
                    .padding(.top, 6)
            }
            Spacer(minLength: 0)
        }
        .padding(16)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(alignment: .topTrailing) {
            Button(action: dismiss) {
                Image(systemName: "xmark")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.secondary)
                    .frame(width: 32, height: 32)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(6)
            .accessibilityLabel("Not now")
        }
    }
}

extension View {
    /// A filled button. iOS draws it paler in dark mode, so its text takes the paper
    /// colour: light on the red in light mode, dark on the pale red in dark mode.
    func prominentButton() -> some View {
        buttonStyle(.borderedProminent).foregroundStyle(Theme.paper)
    }
}
