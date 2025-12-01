import SwiftUI

final class ImageCache {
    static let shared = ImageCache()
    private var cache = NSCache<NSURL, UIImage>()

    private init() {}

    // Store UIImage
    func set(_ image: UIImage, for url: URL) {
        cache.setObject(image, forKey: url as NSURL)
    }

    // Retrieve as SwiftUI Image
    func get(for url: URL) -> Image? {
        if let uiImage = cache.object(forKey: url as NSURL) {
            return Image(uiImage: uiImage)
        }
        return nil
    }
}

extension Image {
    var asUIImage: UIImage? {
        let mirror = Mirror(reflecting: self)
        for child in mirror.children {
            if let uiImage = child.value as? UIImage {
                return uiImage
            }
        }
        return nil
    }
}