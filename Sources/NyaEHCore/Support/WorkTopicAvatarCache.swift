import Foundation
import ImageIO

struct WorkTopicAvatarRequest: Equatable, Sendable {
    let url: URL
    let revision: Int64
    let pixels: Int
}

/// Decode only visible avatars. The actor serializes short thumbnail decodes outside
/// the main actor, with a bounded cache distinct from full-size portrait artwork.
actor WorkTopicAvatarCache {
    static let shared = WorkTopicAvatarCache()
    private static let portraits = WorkTopicAvatarCache(costLimit: 48 * 1024 * 1024, countLimit: 24)

    static func stageImage(for request: WorkTopicAvatarRequest) async -> CGImage? {
        await portraits.image(for: request)
    }

    private let cache = NSCache<NSString, CGImage>()

    init(costLimit: Int = 8 * 1024 * 1024, countLimit: Int = 192) {
        cache.totalCostLimit = costLimit
        cache.countLimit = countLimit
    }

    func image(for request: WorkTopicAvatarRequest) -> CGImage? {
        guard !Task.isCancelled, request.pixels > 0 else { return nil }
        let key = "\(request.url.path):\(request.revision):\(request.pixels)" as NSString
        if let existing = cache.object(forKey: key) { return existing }

        let options = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithURL(request.url as CFURL, options) else { return nil }
        let thumbnailOptions: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: request.pixels
        ]
        guard let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbnailOptions as CFDictionary),
              !Task.isCancelled, let portrait = Self.croppedPortrait(thumbnail) else { return nil }
        cache.setObject(portrait, forKey: key, cost: thumbnail.bytesPerRow * thumbnail.height)
        return portrait
    }

    private static func croppedPortrait(_ image: CGImage) -> CGImage? {
        switch image.alphaInfo {
        case .none, .noneSkipFirst, .noneSkipLast: return image
        default: break
        }
        let width = image.width, height = image.height
        let rowBytes = width * 4
        let format = CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
        guard let bitmap = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                     bytesPerRow: rowBytes, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: format),
              let pixels = bitmap.data?.assumingMemoryBound(to: UInt8.self) else { return image }
        bitmap.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let visible = CharacterPortraitImageProcessor.visibleBounds(
            pixels: UnsafeBufferPointer(start: pixels, count: rowBytes * height), width: width, height: height,
            bytesPerRow: rowBytes, samplesPerPixel: 4, alphaIndex: 3
        ) else { return nil }
        let crop = CharacterPortraitImageProcessor.paddedBounds(visible, canvasWidth: width, canvasHeight: height)
        return image.cropping(to: crop)
    }
}
