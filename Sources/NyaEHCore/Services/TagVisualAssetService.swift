// 本文件管理标签视觉卡片的本地图片资产、裁剪信息和可重建调色板缓存。

import AppKit
import CoreImage
import Foundation
import ImageIO
import SwiftUI

struct TagVisualAssetService {
    static let assetRootDirectoryName = "TagAssets"
    static let foregroundFilename = "show.png"
    static let backgroundFilename = "bg.jpg"
    static let legacyBackgroundFilename = "bg.png"
    static let heroBlurBackgroundFilename = "bg.hero-blur.png"
    static let backgroundPaletteFilename = "bg.palette.json"
    static let backgroundPaletteVersion = 2
    static let maximumForegroundSize = NSSize(width: 1280, height: 1280)
    static let maximumBackgroundSize = NSSize(width: 1920, height: 1080)
    static let maximumHeroBlurBackgroundSize = NSSize(width: 960, height: 540)
    static let maximumPaletteSampleSize = NSSize(width: 96, height: 96)
    static let backgroundJPEGCompressionQuality: CGFloat = 0.94
    static let heroBlurRadius = 18.0

    private let appDataRoot: URL
    private let fileManager: FileManager

    init(appDataRoot: URL, fileManager: FileManager = .default) {
        self.appDataRoot = appDataRoot
        self.fileManager = fileManager
    }

    static func appDefault(fileManager: FileManager = .default) throws -> TagVisualAssetService {
        try TagVisualAssetService(appDataRoot: AppDataDirectory.rootURL(fileManager: fileManager), fileManager: fileManager)
    }

    func storeForegroundImage(imageData: Data, tag: TagVisualAssetTarget) throws -> StoredTagVisualAsset {
        guard let image = NSImage(data: imageData),
              let pngData = Self.foregroundImageData(from: image, sourceData: imageData) else {
            throw NyaEHError.tagVisualAssetInvalid
        }

        return try storeEncodedImage(
            data: pngData,
            tag: tag,
            filename: Self.foregroundFilename,
            refreshHeroBlurCache: false,
            removesBackgroundSiblings: false
        )
    }

    func storeBackgroundImage(imageData: Data, tag: TagVisualAssetTarget) throws -> StoredTagVisualAsset {
        guard let image = NSImage(data: imageData),
              let background = Self.backgroundImageData(from: image, sourceData: imageData) else {
            throw NyaEHError.tagVisualAssetInvalid
        }

        return try storeEncodedImage(
            data: background.data,
            tag: tag,
            filename: background.filename,
            refreshHeroBlurCache: true,
            removesBackgroundSiblings: true
        )
    }

    private func storeEncodedImage(
        data: Data,
        tag: TagVisualAssetTarget,
        filename: String,
        refreshHeroBlurCache: Bool,
        removesBackgroundSiblings: Bool
    ) throws -> StoredTagVisualAsset {
        let directoryRelativePath = relativeDirectoryPath(namespace: tag.namespace, name: tag.name, tagID: tag.tagID)
        let directory = appDataRoot.appendingPathComponent(directoryRelativePath, isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)

        let fileURL = directory.appendingPathComponent(filename)
        try data.write(to: fileURL, options: .atomic)
        if removesBackgroundSiblings {
            try removeBackgroundSiblings(in: directory, keeping: filename)
        }
        if refreshHeroBlurCache {
            try? writeHeroBlurCache(backgroundImageData: data, backgroundURL: fileURL)
            try? writeBackgroundPaletteCache(backgroundImageData: data, backgroundURL: fileURL)
        }

        let themeColorHex = NSImage(data: data)
            .flatMap(CoverThemeColorExtractor.themeColor(from:))?
            .nyaehHexString
        return StoredTagVisualAsset(
            relativePath: directoryRelativePath + "/" + filename,
            themeColorHex: themeColorHex
        )
    }

    func resolvedURL(relativePath: String) -> URL {
        appDataRoot.appendingPathComponent(relativePath)
    }

    func heroBlurBackgroundURL(relativeBackgroundPath: String) throws -> URL {
        let backgroundURL = resolvedURL(relativePath: relativeBackgroundPath)
        let blurURL = heroBlurURL(forBackgroundURL: backgroundURL)

        if try needsHeroBlurRefresh(backgroundURL: backgroundURL, blurURL: blurURL) {
            let data = try Data(contentsOf: backgroundURL)
            try writeHeroBlurCache(backgroundImageData: data, backgroundURL: backgroundURL)
        }

        return blurURL
    }

    func backgroundPalette(relativeBackgroundPath: String) throws -> TagVisualBackgroundPalette? {
        let backgroundURL = resolvedURL(relativePath: relativeBackgroundPath)
        let paletteURL = paletteURL(forBackgroundURL: backgroundURL)

        if try needsDerivedAssetRefresh(backgroundURL: backgroundURL, derivedURL: paletteURL) {
            let data = try Data(contentsOf: backgroundURL)
            try writeBackgroundPaletteCache(backgroundImageData: data, backgroundURL: backgroundURL)
        }

        do {
            let data = try Data(contentsOf: paletteURL)
            let palette = try JSONDecoder().decode(TagVisualBackgroundPalette.self, from: data)
            if palette.isValid {
                return palette
            }
            let backgroundData = try Data(contentsOf: backgroundURL)
            try writeBackgroundPaletteCache(backgroundImageData: backgroundData, backgroundURL: backgroundURL)
        } catch {
            let data = try Data(contentsOf: backgroundURL)
            try writeBackgroundPaletteCache(backgroundImageData: data, backgroundURL: backgroundURL)
        }

        let repairedData = try Data(contentsOf: paletteURL)
        let repairedPalette = try JSONDecoder().decode(TagVisualBackgroundPalette.self, from: repairedData)
        return repairedPalette.isValid ? repairedPalette : nil
    }

    static func generatedBackgroundHex(tagID: Tag.DatabaseID, rawValue: String) -> String {
        let seed = "\(tagID):\(rawValue)"
        let hash = seed.utf8.reduce(UInt64(14_695_981_039_346_656_037)) { partial, byte in
            (partial ^ UInt64(byte)) &* 1_099_511_628_211
        }
        let hue = CGFloat(hash % 360) / 360
        let saturation = CGFloat(62 + (hash >> 9) % 18) / 100
        let brightness = CGFloat(72 + (hash >> 17) % 14) / 100
        return NSColor(calibratedHue: hue, saturation: saturation, brightness: brightness, alpha: 1).nyaehHexString
    }

    static func effectiveBackgroundHex(for tag: TagDisplaySummary) -> String {
        if let profileHex = tag.visualProfile?.backgroundColorHex,
           NSColor.nyaehColor(hex: profileHex) != nil {
            return profileHex
        }
        return generatedBackgroundHex(tagID: tag.id, rawValue: tag.rawValue)
    }

    static func slug(namespaceOrName value: String) -> String {
        let lowercased = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        var result = ""
        var lastWasSeparator = false

        for scalar in lowercased.unicodeScalars {
            if CharacterSet.alphanumerics.contains(scalar) {
                result.unicodeScalars.append(scalar)
                lastWasSeparator = false
            } else if !lastWasSeparator {
                result.append("-")
                lastWasSeparator = true
            }
        }

        let trimmed = result.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return String(trimmed.prefix(80)).isEmpty ? "tag" : String(trimmed.prefix(80))
    }

    private func relativeDirectoryPath(namespace: String, name: String, tagID: Tag.DatabaseID) -> String {
        [
            Self.assetRootDirectoryName,
            Self.slug(namespaceOrName: namespace),
            "\(Self.slug(namespaceOrName: name))-\(tagID)"
        ].joined(separator: "/")
    }

    private func heroBlurURL(forBackgroundURL backgroundURL: URL) -> URL {
        backgroundURL
            .deletingLastPathComponent()
            .appendingPathComponent(Self.heroBlurBackgroundFilename)
    }

    private func paletteURL(forBackgroundURL backgroundURL: URL) -> URL {
        backgroundURL
            .deletingLastPathComponent()
            .appendingPathComponent(Self.backgroundPaletteFilename)
    }

    private func needsHeroBlurRefresh(backgroundURL: URL, blurURL: URL) throws -> Bool {
        try needsDerivedAssetRefresh(backgroundURL: backgroundURL, derivedURL: blurURL)
    }

    private func needsDerivedAssetRefresh(backgroundURL: URL, derivedURL: URL) throws -> Bool {
        guard fileManager.fileExists(atPath: backgroundURL.path) else {
            throw NyaEHError.tagVisualAssetInvalid
        }
        guard fileManager.fileExists(atPath: derivedURL.path) else {
            return true
        }

        let backgroundDate = try modificationDate(for: backgroundURL)
        let derivedDate = try modificationDate(for: derivedURL)
        return derivedDate < backgroundDate
    }

    private func modificationDate(for url: URL) throws -> Date {
        let attributes = try fileManager.attributesOfItem(atPath: url.path)
        return attributes[.modificationDate] as? Date ?? .distantPast
    }

    private func removeBackgroundSiblings(in directory: URL, keeping filename: String) throws {
        for candidate in [Self.backgroundFilename, Self.legacyBackgroundFilename] where candidate != filename {
            let url = directory.appendingPathComponent(candidate)
            if fileManager.fileExists(atPath: url.path) {
                try fileManager.removeItem(at: url)
            }
        }
    }

    private func writeHeroBlurCache(backgroundImageData: Data, backgroundURL: URL) throws {
        guard let blurredData = Self.blurredPNGData(from: backgroundImageData) else {
            throw NyaEHError.tagVisualAssetInvalid
        }
        let blurURL = heroBlurURL(forBackgroundURL: backgroundURL)
        try fileManager.createDirectory(at: blurURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try blurredData.write(to: blurURL, options: .atomic)
    }

    private func writeBackgroundPaletteCache(backgroundImageData: Data, backgroundURL: URL) throws {
        guard let palette = Self.palette(from: backgroundImageData), palette.isValid else {
            throw NyaEHError.tagVisualAssetInvalid
        }
        let paletteURL = paletteURL(forBackgroundURL: backgroundURL)
        let data = try JSONEncoder().encode(palette)
        try fileManager.createDirectory(at: paletteURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: paletteURL, options: .atomic)
    }

    private static func foregroundImageData(from image: NSImage, sourceData: Data) -> Data? {
        if sourceDataLooksLikePNG(sourceData),
           let dimensions = sourcePixelSize(sourceData),
           fits(dimensions, within: maximumForegroundSize) {
            return sourceData
        }

        return resizedBitmap(from: image, maximumSize: maximumForegroundSize)?
            .representation(using: .png, properties: [:])
    }

    private static func backgroundImageData(from image: NSImage, sourceData: Data) -> EncodedTagVisualImage? {
        if sourceDataLooksLikeJPEG(sourceData),
           let dimensions = sourcePixelSize(sourceData),
           fits(dimensions, within: maximumBackgroundSize) {
            return EncodedTagVisualImage(filename: Self.backgroundFilename, data: sourceData)
        }

        guard let bitmap = resizedBitmap(from: image, maximumSize: maximumBackgroundSize) else {
            return nil
        }

        if bitmapContainsVisibleAlpha(bitmap) {
            guard let pngData = bitmap.representation(using: .png, properties: [:]) else {
                return nil
            }
            return EncodedTagVisualImage(filename: Self.legacyBackgroundFilename, data: pngData)
        }

        if let jpegData = bitmap.representation(
            using: .jpeg,
            properties: [.compressionFactor: backgroundJPEGCompressionQuality]
        ) {
            return EncodedTagVisualImage(filename: Self.backgroundFilename, data: jpegData)
        }

        guard let pngData = bitmap.representation(using: .png, properties: [:]) else {
            return nil
        }
        return EncodedTagVisualImage(filename: Self.legacyBackgroundFilename, data: pngData)
    }

    private static func sourceDataLooksLikeJPEG(_ data: Data) -> Bool {
        data.starts(with: [0xFF, 0xD8, 0xFF])
    }

    private static func sourceDataLooksLikePNG(_ data: Data) -> Bool {
        data.starts(with: [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
    }

    private static func sourcePixelSize(_ data: Data) -> NSSize? {
        if let source = CGImageSourceCreateWithData(data as CFData, nil),
           let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
           let width = pixelDimension(properties[kCGImagePropertyPixelWidth]),
           let height = pixelDimension(properties[kCGImagePropertyPixelHeight]),
           width > 0,
           height > 0 {
            return NSSize(width: width, height: height)
        }

        guard let bitmap = NSBitmapImageRep(data: data),
              bitmap.pixelsWide > 0,
              bitmap.pixelsHigh > 0 else {
            return nil
        }
        return NSSize(width: bitmap.pixelsWide, height: bitmap.pixelsHigh)
    }

    private static func pixelDimension(_ value: Any?) -> CGFloat? {
        if let value = value as? CGFloat {
            return value
        }
        if let value = value as? Double {
            return CGFloat(value)
        }
        if let value = value as? Int {
            return CGFloat(value)
        }
        if let value = value as? NSNumber {
            return CGFloat(truncating: value)
        }
        return nil
    }

    private static func fits(_ size: NSSize, within maximumSize: NSSize) -> Bool {
        size.width <= maximumSize.width && size.height <= maximumSize.height
    }

    private static func resizedBitmap(from image: NSImage, maximumSize: NSSize) -> NSBitmapImageRep? {
        let imageSize = image.size
        guard imageSize.width > 0, imageSize.height > 0 else {
            return nil
        }

        let scale = min(maximumSize.width / imageSize.width, maximumSize.height / imageSize.height, 1)
        let outputSize = NSSize(
            width: max(1, round(imageSize.width * scale)),
            height: max(1, round(imageSize.height * scale))
        )

        guard let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(outputSize.width),
            pixelsHigh: Int(outputSize.height),
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else {
            return nil
        }
        bitmap.size = outputSize

        NSGraphicsContext.saveGraphicsState()
        guard let context = NSGraphicsContext(bitmapImageRep: bitmap) else {
            NSGraphicsContext.restoreGraphicsState()
            return nil
        }
        context.imageInterpolation = .high
        NSGraphicsContext.current = context
        NSColor.clear.setFill()
        NSRect(origin: .zero, size: outputSize).fill()
        image.draw(
            in: NSRect(origin: .zero, size: outputSize),
            from: NSRect(origin: .zero, size: imageSize),
            operation: .copy,
            fraction: 1
        )
        NSGraphicsContext.restoreGraphicsState()
        return bitmap
    }

    private static func bitmapContainsVisibleAlpha(_ bitmap: NSBitmapImageRep) -> Bool {
        guard bitmap.hasAlpha else {
            return false
        }

        if bitmap.bitsPerSample == 8,
           !bitmap.isPlanar,
           bitmap.samplesPerPixel >= 4,
           let data = bitmap.bitmapData {
            let alphaIndex = bitmap.bitmapFormat.contains(.alphaFirst) ? 0 : bitmap.samplesPerPixel - 1
            for y in 0..<bitmap.pixelsHigh {
                let rowOffset = y * bitmap.bytesPerRow
                for x in 0..<bitmap.pixelsWide {
                    if data[rowOffset + x * bitmap.samplesPerPixel + alphaIndex] < 255 {
                        return true
                    }
                }
            }
            return false
        }

        for y in 0..<bitmap.pixelsHigh {
            for x in 0..<bitmap.pixelsWide {
                if let alpha = bitmap.colorAt(x: x, y: y)?.alphaComponent,
                   alpha < 0.999 {
                    return true
                }
            }
        }
        return false
    }

    private static func blurredPNGData(from imageData: Data) -> Data? {
        guard let sourceImage = CIImage(data: imageData) else {
            return nil
        }
        let sourceExtent = sourceImage.extent
        guard sourceExtent.width > 0, sourceExtent.height > 0 else {
            return nil
        }

        let scale = min(
            maximumHeroBlurBackgroundSize.width / sourceExtent.width,
            maximumHeroBlurBackgroundSize.height / sourceExtent.height,
            1
        )
        let inputImage = sourceImage.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let inputExtent = inputImage.extent.integral

        let filter = CIFilter(name: "CIGaussianBlur")
        filter?.setValue(inputImage.clampedToExtent(), forKey: kCIInputImageKey)
        filter?.setValue(heroBlurRadius, forKey: kCIInputRadiusKey)

        guard let outputImage = filter?.outputImage?.cropped(to: inputExtent) else {
            return nil
        }

        let context = CIContext(options: nil)
        guard let cgImage = context.createCGImage(outputImage, from: inputExtent) else {
            return nil
        }

        let bitmap = NSBitmapImageRep(cgImage: cgImage)
        return bitmap.representation(using: .png, properties: [:])
    }

    private static func palette(from imageData: Data) -> TagVisualBackgroundPalette? {
        guard let image = NSImage(data: imageData),
              let bitmap = resizedBitmap(from: image, maximumSize: maximumPaletteSampleSize) else {
            return nil
        }

        let colors = dominantPaletteColors(from: bitmap)
        guard !colors.isEmpty else {
            return nil
        }

        return TagVisualBackgroundPalette(sourceHexColors: colors.map(\.nyaehHexString))
    }

    private static func dominantPaletteColors(from bitmap: NSBitmapImageRep) -> [NSColor] {
        var buckets: [PaletteBucketKey: PaletteBucket] = [:]

        for y in 0..<bitmap.pixelsHigh {
            for x in 0..<bitmap.pixelsWide {
                guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB),
                      color.alphaComponent > 0.08 else {
                    continue
                }

                let saturation = color.saturationComponent
                let brightness = color.brightnessComponent
                guard brightness > 0.08 else {
                    continue
                }

                let key = PaletteBucketKey(
                    hue: Int((color.hueComponent * 12).rounded(.down)),
                    saturation: Int((saturation * 4).rounded(.down)),
                    brightness: Int((brightness * 4).rounded(.down))
                )
                let weight = max(0.1, saturation) * max(0.18, brightness)
                buckets[key, default: PaletteBucket()].add(color: color, weight: weight)
            }
        }

        let candidates = buckets.values
            .filter { $0.weight > 0 }
            .map { $0.averageColor }
            .sorted { lhs, rhs in
                let lhsScore = lhs.saturationComponent * 0.55 + lhs.brightnessComponent * 0.35
                let rhsScore = rhs.saturationComponent * 0.55 + rhs.brightnessComponent * 0.35
                return lhsScore > rhsScore
            }

        var selected: [NSColor] = []
        for candidate in candidates {
            guard selected.allSatisfy({ paletteDistance($0, candidate) >= 0.18 }) else {
                continue
            }
            selected.append(candidate)
            if selected.count == 3 {
                break
            }
        }

        if selected.isEmpty, let first = candidates.first {
            selected.append(first)
        }

        while selected.count < 3, let base = selected.first {
            selected.append(base.rotatingHue(by: CGFloat(selected.count) * 0.08))
        }

        return Array(selected.prefix(3))
    }

    static func backgroundMeshPalette(
        palette: TagVisualBackgroundPalette?,
        fallbackHex: String?
    ) -> WorkDetailBackgroundPalette {
        if let palette, palette.isValid {
            let colors = palette.sourceHexColors.compactMap(NSColor.nyaehColor(hex:))
            return WorkDetailBackgroundPalette(sourceColors: colors)
        }
        if let fallbackHex,
           let color = NSColor.nyaehColor(hex: fallbackHex) {
            return WorkDetailBackgroundPalette(sourceColors: [color])
        }
        return .white
    }

    private static func paletteDistance(_ lhs: NSColor, _ rhs: NSColor) -> CGFloat {
        let hueDelta = abs(lhs.hueComponent - rhs.hueComponent)
        let circularHueDelta = min(hueDelta, 1 - hueDelta)
        return circularHueDelta * 1.5
            + abs(lhs.saturationComponent - rhs.saturationComponent) * 0.5
            + abs(lhs.brightnessComponent - rhs.brightnessComponent) * 0.35
    }
}

struct TagVisualBackgroundPalette: Codable, Equatable, Sendable {
    var version: Int
    var sourceHexColors: [String]

    init(sourceHexColors: [String], version: Int = TagVisualAssetService.backgroundPaletteVersion) {
        self.version = version
        self.sourceHexColors = sourceHexColors
    }

    var isValid: Bool {
        version == TagVisualAssetService.backgroundPaletteVersion
            && sourceHexColors.count == 3
            && sourceHexColors.allSatisfy { NSColor.nyaehColor(hex: $0) != nil }
    }
}

struct WorkDetailBackgroundPalette: Equatable {
    var sourceColors: [NSColor]
    var isWhiteFallback: Bool

    static let white = WorkDetailBackgroundPalette(sourceColors: [.white, .white, .white], isWhiteFallback: true)

    init(sourceColors: [NSColor]) {
        var colors = sourceColors.compactMap { $0.usingColorSpace(.sRGB) }
        colors = colors.isEmpty ? [.white] : colors
        while colors.count < 3 {
            let base = colors[colors.count % max(colors.count, 1)]
            colors.append(base.rotatingHue(by: CGFloat(colors.count) * 0.08))
        }
        self.sourceColors = Array(colors.prefix(3))
        self.isWhiteFallback = false
    }

    private init(sourceColors: [NSColor], isWhiteFallback: Bool) {
        self.sourceColors = sourceColors
        self.isWhiteFallback = isWhiteFallback
    }

    func baseColor(colorScheme: ColorScheme) -> NSColor {
        switch colorScheme {
        case .dark:
            return NSColor(srgbRed: 0.055, green: 0.057, blue: 0.064, alpha: 1)
        default:
            return .white
        }
    }

    func meshColors(colorScheme: ColorScheme) -> [NSColor] {
        guard !isWhiteFallback else {
            let base = baseColor(colorScheme: colorScheme)
            return [base, base, base]
        }

        return sourceColors.map { sourceColor in
            Self.adaptedColor(sourceColor, colorScheme: colorScheme)
        }
    }

    private static func adaptedColor(_ sourceColor: NSColor, colorScheme: ColorScheme) -> NSColor {
        let color = sourceColor.usingColorSpace(.sRGB) ?? sourceColor
        switch colorScheme {
        case .dark:
            return NSColor(
                calibratedHue: color.hueComponent,
                saturation: min(max(color.saturationComponent * 0.48, 0.14), 0.46),
                brightness: min(max(color.brightnessComponent * 0.32 + 0.12, 0.18), 0.40),
                alpha: 1
            )
        default:
            return NSColor(
                calibratedHue: color.hueComponent,
                saturation: min(max(color.saturationComponent * 0.55, 0.18), 0.48),
                brightness: min(max(color.brightnessComponent * 0.42 + 0.52, 0.72), 0.94),
                alpha: 1
            )
        }
    }
}

private struct EncodedTagVisualImage {
    let filename: String
    let data: Data
}

private struct PaletteBucketKey: Hashable {
    var hue: Int
    var saturation: Int
    var brightness: Int
}

private struct PaletteBucket {
    private(set) var red: CGFloat = 0
    private(set) var green: CGFloat = 0
    private(set) var blue: CGFloat = 0
    private(set) var weight: CGFloat = 0

    mutating func add(color: NSColor, weight: CGFloat) {
        red += color.redComponent * weight
        green += color.greenComponent * weight
        blue += color.blueComponent * weight
        self.weight += weight
    }

    var averageColor: NSColor {
        guard weight > 0 else {
            return .white
        }
        return NSColor(
            srgbRed: red / weight,
            green: green / weight,
            blue: blue / weight,
            alpha: 1
        )
    }
}

private extension NSColor {
    func rotatingHue(by amount: CGFloat) -> NSColor {
        let color = usingColorSpace(.sRGB) ?? self
        var hue = color.hueComponent + amount
        while hue > 1 {
            hue -= 1
        }
        return NSColor(
            calibratedHue: hue,
            saturation: color.saturationComponent,
            brightness: color.brightnessComponent,
            alpha: color.alphaComponent
        )
    }
}
