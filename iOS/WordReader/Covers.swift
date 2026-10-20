import ImageIO
import ReaderCore
import ReaderKit
import SwiftUI
import UIKit

/// A book's cover, or a plain one made from its title.
struct CoverImage: View {
    let book: BookInfo
    var titleSize = 12.0
    @State private var image: UIImage?

    var body: some View {
        Color.clear
            .aspectRatio(2.0 / 3.0, contentMode: .fit)
            .overlay {
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                } else {
                    PlaceholderCover(title: book.title, author: book.author, titleSize: titleSize)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
            .task(id: book.id) {
                image = await CoverCache.shared.cover(for: book)
            }
    }
}

/// Small cover images, made once per book and kept in memory.
@MainActor
final class CoverCache {
    static let shared = CoverCache()
    private let images = NSCache<NSString, UIImage>()
    private var missing: Set<String> = []

    private struct Thumbnail: @unchecked Sendable {
        let image: CGImage
    }

    func cover(for book: BookInfo) async -> UIImage? {
        if let image = images.object(forKey: book.id as NSString) { return image }
        if missing.contains(book.id) { return nil }
        let url = book.url
        let thumbnail = await Task.detached(priority: .utility) { () -> Thumbnail? in
            guard let data = try? EPUBPackage.open(url).coverData(),
                  let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 480,
            ]
            return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary).map(Thumbnail.init)
        }.value
        guard let thumbnail else {
            missing.insert(book.id)
            return nil
        }
        let image = UIImage(cgImage: thumbnail.image)
        images.setObject(image, forKey: book.id as NSString)
        return image
    }
}
