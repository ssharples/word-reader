import Compression
import Foundation

/// Packs an unzipped `.epub` folder, as Apple Books keeps them, into a normal EPUB file.
///
/// A single file syncs through iCloud Drive or Dropbox far more reliably than a folder
/// of hundreds of small ones. `mimetype` goes first and uncompressed, as the EPUB
/// standard asks; everything else is deflated unless that doesn't make it smaller.
public enum ZipWriter {
    public static func zip(folder: URL, to output: URL) throws {
        let root = folder.standardizedFileURL
        var paths: [String] = []
        let keys: [URLResourceKey] = [.isRegularFileKey]
        guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys) else {
            throw EPUBError.missingFile(folder.lastPathComponent)
        }
        let prefix = root.path(percentEncoded: false).count + (root.path(percentEncoded: false).hasSuffix("/") ? 0 : 1)
        for case let url as URL in walker {
            guard (try? url.resourceValues(forKeys: Set(keys)))?.isRegularFile == true else { continue }
            let path = String(url.standardizedFileURL.path(percentEncoded: false).dropFirst(prefix))
            if path.split(separator: "/").contains(where: { $0.hasPrefix(".") || $0 == "__MACOSX" }) { continue }
            paths.append(path)
        }
        paths.sort()
        if let mimetype = paths.firstIndex(of: "mimetype") {
            paths.insert(paths.remove(at: mimetype), at: 0)
        }

        var archive = Data()
        var directory = Data()
        for path in paths {
            let contents = try Data(contentsOf: root.appending(path: path))
            let name = Data(path.utf8)
            let checksum = crc32(contents)
            let packed = path == "mimetype" ? nil : deflate(contents)
            let method: UInt16 = packed == nil ? 0 : 8
            let stored = packed ?? contents
            guard archive.count < Int(UInt32.max), stored.count < Int(UInt32.max) else { throw EPUBError.zip64Unsupported }
            let offset = UInt32(archive.count)

            // Local file header.
            archive.append(le32: 0x0403_4B50)
            archive.append(le16: 20)                 // version needed
            archive.append(le16: 0x0800)             // names are UTF-8
            archive.append(le16: method)
            archive.append(le16: 0)                  // time
            archive.append(le16: 0x21)               // date: 1 Jan 1980
            archive.append(le32: checksum)
            archive.append(le32: UInt32(stored.count))
            archive.append(le32: UInt32(contents.count))
            archive.append(le16: UInt16(name.count))
            archive.append(le16: 0)
            archive.append(name)
            archive.append(stored)

            // Its central directory entry.
            directory.append(le32: 0x0201_4B50)
            directory.append(le16: 20)               // made by
            directory.append(le16: 20)
            directory.append(le16: 0x0800)
            directory.append(le16: method)
            directory.append(le16: 0)
            directory.append(le16: 0x21)
            directory.append(le32: checksum)
            directory.append(le32: UInt32(stored.count))
            directory.append(le32: UInt32(contents.count))
            directory.append(le16: UInt16(name.count))
            directory.append(le16: 0)                // extra
            directory.append(le16: 0)                // comment
            directory.append(le16: 0)                // disk
            directory.append(le16: 0)                // internal attributes
            directory.append(le32: 0)                // external attributes
            directory.append(le32: offset)
            directory.append(name)
        }
        guard paths.count < Int(UInt16.max) else { throw EPUBError.zip64Unsupported }
        let directoryOffset = UInt32(archive.count)
        archive.append(directory)
        archive.append(le32: 0x0605_4B50)
        archive.append(le16: 0)
        archive.append(le16: 0)
        archive.append(le16: UInt16(paths.count))
        archive.append(le16: UInt16(paths.count))
        archive.append(le32: UInt32(directory.count))
        archive.append(le32: directoryOffset)
        archive.append(le16: 0)
        try archive.write(to: output, options: .atomic)
    }

    /// Raw DEFLATE, or nil when it wouldn't save anything (pictures are usually packed already).
    static func deflate(_ data: Data) -> Data? {
        guard data.count > 64 else { return nil }
        var output = Data(count: data.count)
        let written = output.withUnsafeMutableBytes { destination in
            data.withUnsafeBytes { source in
                compression_encode_buffer(
                    destination.bindMemory(to: UInt8.self).baseAddress!, data.count,
                    source.bindMemory(to: UInt8.self).baseAddress!, data.count,
                    nil, COMPRESSION_ZLIB
                )
            }
        }
        guard written > 0, written < data.count else { return nil }
        return output.prefix(written)
    }

    private static let crcTable: [UInt32] = (0..<256).map { n in
        var c = UInt32(n)
        for _ in 0..<8 { c = c & 1 != 0 ? 0xEDB8_8320 ^ (c >> 1) : c >> 1 }
        return c
    }

    static func crc32(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in data { crc = crcTable[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8) }
        return crc ^ 0xFFFF_FFFF
    }
}

private extension Data {
    mutating func append(le16 value: UInt16) {
        Swift.withUnsafeBytes(of: value.littleEndian) { append(contentsOf: $0) }
    }

    mutating func append(le32 value: UInt32) {
        Swift.withUnsafeBytes(of: value.littleEndian) { append(contentsOf: $0) }
    }
}
