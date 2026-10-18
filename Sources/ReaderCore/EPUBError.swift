import Foundation

public enum EPUBError: Error, LocalizedError, Equatable, Sendable {
    case notZip
    case zip64Unsupported
    case corrupt(String)
    case missingFile(String)
    case noContainer
    case noPackage
    case protected
    case noText
    case unsupportedCompression(Int)

    public var errorDescription: String? {
        switch self {
        case .notZip:
            "This file isn't a valid EPUB. It isn't a zip archive or an EPUB folder."
        case .zip64Unsupported:
            "This EPUB uses a very large archive format that the reader can't open yet."
        case .corrupt(let what):
            "This EPUB looks damaged (\(what))."
        case .missingFile(let path):
            "This EPUB is missing a file: \(path)."
        case .noContainer:
            "This EPUB has no META-INF/container.xml, so the reader can't find the book inside it."
        case .noPackage:
            "This EPUB's package file (the .opf) couldn't be read."
        case .protected:
            "This book is copy-protected (DRM), so only Apple Books can open it."
        case .noText:
            "No readable text was found in this book."
        case .unsupportedCompression(let method):
            "This EPUB uses a compression method the reader doesn't support (\(method))."
        }
    }
}
