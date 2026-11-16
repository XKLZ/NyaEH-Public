// 本文件提供 CoverImageCache 支撑工具，承载格式化、环境值、缓存或本地化等横切逻辑。

import AppKit
import Foundation

struct CachedCoverImage: @unchecked Sendable {
    let image: NSImage
    let pixelBucket: Int
}

final class CoverImageCache: @unchecked Sendable {
    static let shared = CoverImageCache()
    static let costLimit = 192 * 1_024 * 1_024

    private let cache = NSCache<NSString, NSImage>()
    private var keysByPath: [String: Set<String>] = [:]
    private let lock = NSLock()
    private let memoryPressureSource: DispatchSourceMemoryPressure

    private init() {
        cache.countLimit = 600
        cache.totalCostLimit = Self.costLimit
        let source = DispatchSource.makeMemoryPressureSource(
            eventMask: [.warning, .critical],
            queue: .main
        )
        memoryPressureSource = source
        source.setEventHandler { [weak self] in
            self?.removeAllImages()
        }
        source.resume()
    }

    func image(for path: String, pixelBucket: Int) -> NSImage? {
        cachedImage(for: path, minimumPixelBucket: pixelBucket)?.image
    }

    func cachedImage(for path: String, minimumPixelBucket: Int) -> CachedCoverImage? {
        for bucket in Self.candidateBuckets(minimumPixelBucket: minimumPixelBucket) {
            let key = Self.cacheKey(path: path, pixelBucket: bucket)
            if let image = cache.object(forKey: key as NSString) {
                return CachedCoverImage(image: image, pixelBucket: bucket)
            }
        }
        return nil
    }

    func store(_ image: NSImage, for path: String, pixelBucket: Int, cost: Int) {
        let key = Self.cacheKey(path: path, pixelBucket: pixelBucket)
        lock.withLock {
            cache.setObject(image, forKey: key as NSString, cost: max(cost, 1))
            keysByPath[path, default: []].insert(key)
        }
    }

    func removeImage(for path: String) {
        lock.withLock {
            let keys = keysByPath.removeValue(forKey: path) ?? []
            for key in keys {
                cache.removeObject(forKey: key as NSString)
            }
        }
    }

    func removeAllImages() {
        lock.withLock {
            cache.removeAllObjects()
            keysByPath.removeAll(keepingCapacity: true)
        }
    }

    private static func cacheKey(path: String, pixelBucket: Int) -> String {
        "\(path)#\(pixelBucket)"
    }

    private static func candidateBuckets(minimumPixelBucket: Int) -> [Int] {
        switch minimumPixelBucket {
        case ...128: [128, 256, 512]
        case ...256: [256, 512]
        default: [512]
        }
    }
}
