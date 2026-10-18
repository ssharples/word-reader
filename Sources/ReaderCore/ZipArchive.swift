import Compression
import Foundation

/// A small read-only zip reader, enough for EPUB files.
///
/// It reads the central directory once, then inflates single entries on demand.
/// Stored (method 0) and deflated (method 8) entries are supported; zip64 and
/// encrypted entries are not.
public struct ZipArchive: Sendable {
    struct Entry: Sendable {
        let method: Int
        let flags: Int
        let compressedSize: Int
        let uncompressedSize: Int
        let localHeaderOffset: Int
    }

    private let bytes: [UInt8]
    private let entries: [String: Entry]
    private let caseFolded: [String: String]

    public var paths: [String] { entries.keys.sorted() }

    public init(url: URL) throws {
        try self.init(data: Data(contentsOf: url, options: .mappedIfSafe))
    }

    public init(data: Data) throws {
        let b = [UInt8](data)
        bytes = b
        guard b.count >= 22 else { throw EPUBError.notZip }

        // The end-of-central-directory record sits in the last 64 KB.
        var eocd = -1
        var offset = b.count - 22
        let lowest = max(0, b.count - 22 - 0xFFFF)
        while offset >= lowest {
            if b[offset] == 0x50, b[offset + 1] == 0x4B, b[offset + 2] == 0x05, b[offset + 3] == 0x06 {
                eocd = offset
                break
            }
            offset -= 1
        }
        guard eocd >= 0 else { throw EPUBError.notZip }

        let count = Self.u16(b, eocd + 10)
        let directoryOffset = Self.u32(b, eocd + 16)
        if count == 0xFFFF || directoryOffset == 0xFFFF_FFFF { throw EPUBError.zip64Unsupported }

        var map: [String: Entry] = [:]
        var p = directoryOffset
        for _ in 0..<count {
            guard p + 46 <= b.count, Self.u32(b, p) == 0x0201_4B50 else {
                throw EPUBError.corrupt("bad central directory")
            }
            let nameLength = Self.u16(b, p + 28)
            let extraLength = Self.u16(b, p + 30)
            let commentLength = Self.u16(b, p + 32)
            let nameEnd = p + 46 + nameLength
            guard nameEnd <= b.count else { throw EPUBError.corrupt("bad file name") }
            let nameBytes = b[(p + 46)..<nameEnd]
            let name = String(bytes: nameBytes, encoding: .utf8)
                ?? String(bytes: nameBytes, encoding: .isoLatin1)
                ?? ""
            map[name] = Entry(
                method: Self.u16(b, p + 10),
                flags: Self.u16(b, p + 8),
                compressedSize: Self.u32(b, p + 20),
                uncompressedSize: Self.u32(b, p + 24),
                localHeaderOffset: Self.u32(b, p + 42)
            )
            p = nameEnd + extraLength + commentLength
        }
        entries = map
        caseFolded = Dictionary(map.keys.map { ($0.lowercased(), $0) }, uniquingKeysWith: { first, _ in first })
    }

    public func contains(_ path: String) -> Bool { key(for: path) != nil }

    public func data(for path: String) throws -> Data {
        guard let key = key(for: path), let entry = entries[key] else { throw EPUBError.missingFile(path) }
        if entry.flags & 1 != 0 { throw EPUBError.protected }

        let header = entry.localHeaderOffset
        guard header + 30 <= bytes.count, Self.u32(bytes, header) == 0x0403_4B50 else {
            throw EPUBError.corrupt("bad entry header for \(path)")
        }
        let start = header + 30 + Self.u16(bytes, header + 26) + Self.u16(bytes, header + 28)
        let end = start + entry.compressedSize
        guard end <= bytes.count else { throw EPUBError.corrupt("truncated entry \(path)") }

        switch entry.method {
        case 0:
            return Data(bytes[start..<end])
        case 8:
            if entry.uncompressedSize == 0 { return Data() }
            var output = Data(count: entry.uncompressedSize)
            let written = output.withUnsafeMutableBytes { destination in
                bytes.withUnsafeBufferPointer { source in
                    // COMPRESSION_ZLIB is raw DEFLATE, which is what zip stores.
                    compression_decode_buffer(
                        destination.bindMemory(to: UInt8.self).baseAddress!, entry.uncompressedSize,
                        source.baseAddress! + start, entry.compressedSize,
                        nil, COMPRESSION_ZLIB
                    )
                }
            }
            guard written == entry.uncompressedSize else { throw EPUBError.corrupt("couldn't inflate \(path)") }
            return output
        default:
            throw EPUBError.unsupportedCompression(entry.method)
        }
    }

    private func key(for path: String) -> String? {
        if entries[path] != nil { return path }
        // Some EPUBs reference files with the wrong letter case.
        return caseFolded[path.lowercased()]
    }

    static func u16(_ b: [UInt8], _ o: Int) -> Int {
        Int(b[o]) | Int(b[o + 1]) << 8
    }

    static func u32(_ b: [UInt8], _ o: Int) -> Int {
        Int(b[o]) | Int(b[o + 1]) << 8 | Int(b[o + 2]) << 16 | Int(b[o + 3]) << 24
    }
}
