// 本文件提供 CoverThemeColorExtractor 支撑工具，承载格式化、环境值、缓存或本地化等横切逻辑。

import AppKit
import SwiftUI

enum CoverThemeColorExtractor {
    static let fallbackColor = NSColor.controlAccentColor

    static func themeColor(for book: LibraryBook) -> NSColor {
        guard let coverPath = book.coverPath else {
            return fallbackColor
        }

        return themeColor(coverPath: coverPath) ?? fallbackColor
    }

    static func themeColor(coverPath: String) -> NSColor? {
        guard let image = NSImage(contentsOfFile: coverPath) else {
            return nil
        }

        return themeColor(from: image)
    }

    static func themeColor(from image: NSImage) -> NSColor? {
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return nil
        }

        let width = 1
        let height = 1
        var pixel = [UInt8](repeating: 0, count: 4)
        guard let context = CGContext(
            data: &pixel,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return nil
        }

        context.interpolationQuality = .medium
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))

        let red = CGFloat(pixel[0]) / 255
        let green = CGFloat(pixel[1]) / 255
        let blue = CGFloat(pixel[2]) / 255
        let alpha = CGFloat(pixel[3]) / 255
        guard alpha > 0.05 else {
            return nil
        }

        return NSColor(
            calibratedHue: NSColor(calibratedRed: red, green: green, blue: blue, alpha: 1).hueComponent,
            saturation: max(0.28, NSColor(calibratedRed: red, green: green, blue: blue, alpha: 1).saturationComponent),
            brightness: max(0.38, NSColor(calibratedRed: red, green: green, blue: blue, alpha: 1).brightnessComponent),
            alpha: 1
        )
    }
}

struct CoverThemeColorResolution: Equatable {
    let color: NSColor
    let cacheHit: Bool
    let costMilliseconds: Double
}

final class CoverThemeColorCache: @unchecked Sendable {
    static let shared = CoverThemeColorCache()

    typealias Resolver = @Sendable (String) -> String?

    private let lock = NSLock()
    private let resolver: Resolver
    private var colorHexByCoverPath: [String: String] = [:]

    init(resolver: @escaping Resolver = { coverPath in
        CoverThemeColorExtractor.themeColor(coverPath: coverPath)?.nyaehHexString
    }) {
        self.resolver = resolver
    }

    func cachedColor(coverPath: String?) -> NSColor? {
        guard let coverPath else {
            return nil
        }
        lock.lock()
        let hex = colorHexByCoverPath[coverPath]
        lock.unlock()
        return hex.flatMap(NSColor.nyaehColor(hex:))
    }

    func fallbackColor(coverPath: String?) -> NSColor {
        cachedColor(coverPath: coverPath) ?? CoverThemeColorExtractor.fallbackColor
    }

    func resolveColor(coverPath: String?) async -> CoverThemeColorResolution {
        guard let coverPath else {
            return CoverThemeColorResolution(color: CoverThemeColorExtractor.fallbackColor, cacheHit: true, costMilliseconds: 0)
        }

        if let cached = cachedColor(coverPath: coverPath) {
            return CoverThemeColorResolution(color: cached, cacheHit: true, costMilliseconds: 0)
        }

        let startedAt = ContinuousClock.now
        let resolver = resolver
        let hex = await Task.detached(priority: .utility) {
            resolver(coverPath)
        }.value
        let components = startedAt.duration(to: .now).components
        let cost = Double(components.seconds) * 1_000
            + Double(components.attoseconds) / 1_000_000_000_000_000
        let color = hex.flatMap(NSColor.nyaehColor(hex:)) ?? CoverThemeColorExtractor.fallbackColor

        if let hex {
            store(hex: hex, coverPath: coverPath)
        }

        return CoverThemeColorResolution(color: color, cacheHit: false, costMilliseconds: cost)
    }

    func removeAll() {
        lock.lock()
        colorHexByCoverPath.removeAll()
        lock.unlock()
    }

    private func store(hex: String, coverPath: String) {
        lock.lock()
        colorHexByCoverPath[coverPath] = hex
        lock.unlock()
    }
}
