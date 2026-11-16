// 本文件提供 TagVisualImageCache 支撑工具，承载格式化、环境值、缓存或本地化等横切逻辑。

import AppKit
import Foundation

@MainActor
final class TagVisualImageCache {
    static let shared = TagVisualImageCache()

    private let cache = NSCache<NSString, NSImage>()
    private let portraitCache = NSCache<NSString, NSImage>()

    private init() {
        cache.countLimit = 240
        portraitCache.countLimit = 64
        portraitCache.totalCostLimit = 96 * 1024 * 1024
    }

    func image(for url: URL) async -> NSImage? {
        let key = url.path as NSString
        if let cached = cache.object(forKey: key) {
            return cached
        }

        let data = await Task.detached(priority: .utility) {
            try? Data(contentsOf: url)
        }.value
        guard let data, let image = NSImage(data: data) else {
            return nil
        }

        cache.setObject(image, forKey: key)
        return image
    }

    func removeImage(for url: URL) {
        cache.removeObject(forKey: url.path as NSString)
    }

    func portraitImage(for url: URL, version: Int64) async -> NSImage? {
        let key = "\(url.path):\(version)" as NSString
        if let cached = portraitCache.object(forKey: key) {
            return cached
        }

        let worker = Task.detached(priority: .utility) {
            guard let data = try? Data(contentsOf: url) else { return nil as Data? }
            guard !Task.isCancelled else { return nil }
            return CharacterPortraitImageProcessor.displayData(from: data)
        }
        let displayData = await withTaskCancellationHandler {
            await worker.value
        } onCancel: {
            worker.cancel()
        }
        guard !Task.isCancelled else { return nil }
        guard let displayData, let image = NSImage(data: displayData) else {
            return nil
        }

        let cost = Int(image.size.width * image.size.height * 4)
        portraitCache.setObject(image, forKey: key, cost: cost)
        return image
    }
}

enum CharacterPortraitImageProcessor {
    static let alphaThreshold: UInt8 = 8
    static let marginFraction = 0.03

    static func displayData(from sourceData: Data) -> Data? {
        guard let bitmap = NSBitmapImageRep(data: sourceData),
              bitmap.pixelsWide > 0, bitmap.pixelsHigh > 0 else {
            return nil
        }
        guard bitmap.hasAlpha,
              bitmap.bitsPerSample == 8,
              !bitmap.isPlanar,
              bitmap.samplesPerPixel >= 4,
              let pixels = bitmap.bitmapData else {
            return sourceData
        }

        let width = bitmap.pixelsWide
        let height = bitmap.pixelsHigh
        let alphaIndex = bitmap.bitmapFormat.contains(.alphaFirst) ? 0 : bitmap.samplesPerPixel - 1
        let alphaBytes = UnsafeBufferPointer(start: pixels, count: bitmap.bytesPerRow * height)
        guard let visible = visibleBounds(
            pixels: alphaBytes,
            width: width,
            height: height,
            bytesPerRow: bitmap.bytesPerRow,
            samplesPerPixel: bitmap.samplesPerPixel,
            alphaIndex: alphaIndex
        ) else {
            return nil
        }

        let crop = paddedBounds(visible, canvasWidth: width, canvasHeight: height)
        guard crop.width < CGFloat(width) || crop.height < CGFloat(height) else {
            return sourceData
        }
        guard let cgImage = bitmap.cgImage?.cropping(to: crop),
              let data = NSBitmapImageRep(cgImage: cgImage).representation(using: .png, properties: [:]) else {
            return sourceData
        }
        return data
    }

    static func visibleBounds(
        pixels: UnsafeBufferPointer<UInt8>,
        width: Int,
        height: Int,
        bytesPerRow: Int,
        samplesPerPixel: Int,
        alphaIndex: Int
    ) -> CGRect? {
        guard width > 0, height > 0, samplesPerPixel > alphaIndex,
              bytesPerRow >= width * samplesPerPixel,
              pixels.count >= bytesPerRow * height else {
            return nil
        }
        var minX = width
        var minY = height
        var maxX = -1
        var maxY = -1
        for y in 0..<height {
            let row = y * bytesPerRow
            for x in 0..<width where pixels[row + x * samplesPerPixel + alphaIndex] > alphaThreshold {
                minX = min(minX, x)
                minY = min(minY, y)
                maxX = max(maxX, x)
                maxY = max(maxY, y)
            }
        }
        guard maxX >= minX, maxY >= minY else { return nil }
        return CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
    }

    static func paddedBounds(_ bounds: CGRect, canvasWidth: Int, canvasHeight: Int) -> CGRect {
        let padX = max(2, Int(ceil(bounds.width * marginFraction)))
        let padY = max(2, Int(ceil(bounds.height * marginFraction)))
        let minX = max(0, Int(bounds.minX) - padX)
        let minY = max(0, Int(bounds.minY) - padY)
        let maxX = min(canvasWidth, Int(bounds.maxX) + padX)
        let maxY = min(canvasHeight, Int(bounds.maxY) + padY)
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }
}
