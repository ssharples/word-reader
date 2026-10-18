import Foundation

/// Where an EPUB's files live.
///
/// Apple Books keeps imported books as unzipped `.epub` folders (its Info.plist
/// declares both `org.idpf.epub-container` and `org.idpf.epub-folder`), while
/// downloaded books are usually zipped `.epub` files. Both read the same way.
public protocol EPUBStorage: Sendable {
    func data(at path: String) throws -> Data
    func contains(_ path: String) -> Bool
}

struct FolderStorage: EPUBStorage {
    let root: URL

    func data(at path: String) throws -> Data {
        do {
            return try Data(contentsOf: root.appending(path: path))
        } catch {
            throw EPUBError.missingFile(path)
        }
    }

    func contains(_ path: String) -> Bool {
        FileManager.default.fileExists(atPath: root.appending(path: path).path(percentEncoded: false))
    }
}

struct ZipStorage: EPUBStorage {
    let archive: ZipArchive

    func data(at path: String) throws -> Data { try archive.data(for: path) }
    func contains(_ path: String) -> Bool { archive.contains(path) }
}

/// Path helpers for hrefs inside an EPUB package.
enum EPUBPath {
    static func directory(of path: String) -> String {
        guard let slash = path.lastIndex(of: "/") else { return "" }
        return String(path[..<slash])
    }

    /// Resolves `href` against the folder `base`, dropping any `#fragment`.
    static func resolve(_ href: String, from base: String) -> String {
        var target = href
        if let hash = target.firstIndex(of: "#") { target = String(target[..<hash]) }
        target = target.removingPercentEncoding ?? target
        if target.hasPrefix("/") { return normalize(String(target.dropFirst())) }
        return normalize(base.isEmpty ? target : base + "/" + target)
    }

    static func fragment(of href: String) -> String? {
        guard let hash = href.firstIndex(of: "#") else { return nil }
        let fragment = String(href[href.index(after: hash)...])
        return fragment.isEmpty ? nil : (fragment.removingPercentEncoding ?? fragment)
    }

    static func normalize(_ path: String) -> String {
        var parts: [Substring] = []
        for part in path.split(separator: "/") {
            if part == "." { continue }
            if part == ".." {
                if !parts.isEmpty { parts.removeLast() }
                continue
            }
            parts.append(part)
        }
        return parts.joined(separator: "/")
    }
}
