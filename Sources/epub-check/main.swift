import Foundation
import ReaderCore

// Opens EPUBs the same way the app does and reports what it found.
//
//   epub-check [--sample] <book.epub | folder of books>...
//
// With no paths it checks your Apple Books library.

var arguments = Array(CommandLine.arguments.dropFirst())
let showSample = arguments.contains("--sample")
arguments.removeAll { $0.hasPrefix("--") }

var books: [URL] = []
let targets = arguments.isEmpty ? [Library.appleBooksFolder] : arguments.map { URL(fileURLWithPath: $0) }
for target in targets {
    if target.pathExtension.lowercased() == "epub" {
        books.append(target)
    } else if let found = try? Library.epubs(in: target) {
        books.append(contentsOf: found.sorted { $0.lastPathComponent < $1.lastPathComponent })
    } else {
        print("Can't read \(target.path)")
    }
}

var failures = 0
var totalWords = 0
let started = Date()
for url in books {
    let clock = Date()
    do {
        let package = try EPUBPackage.open(url)
        let text = try package.loadText()
        totalWords += text.count
        let ms = Int(Date().timeIntervalSince(clock) * 1000)
        print("OK   \(package.displayTitle) — \(text.count) words, \(text.chapters.count) chapters, \(ms) ms")
        if showSample {
            print("     by \(package.authors.isEmpty ? "(no author)" : package.authors.joined(separator: ", ")), cover: \(package.coverPath ?? "(none)")")
            let middle = text.count / 2
            let sample = text.words[middle..<min(text.count, middle + 40)].joined(separator: " ")
            print("     chapters: \(text.chapters.prefix(5).map(\.title).joined(separator: " | "))")
            let opening = text.words[text.startIndex..<min(text.count, text.startIndex + 12)].joined(separator: " ")
            print("     starts at word \(text.startIndex): \(opening)")
            print("     sample: \(sample)")
        }
    } catch {
        failures += 1
        print("FAIL \(url.lastPathComponent): \(error.localizedDescription)")
    }
}
let seconds = Date().timeIntervalSince(started)
print("\n\(books.count - failures) of \(books.count) books opened, \(totalWords) words, \(String(format: "%.1f", seconds)) s")
exit(failures == 0 ? 0 : 1)
