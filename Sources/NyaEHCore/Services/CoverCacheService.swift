// 本文件管理从 archive 提取出的封面缩略图缓存，避免浏览时重复读取原始压缩包。

import AppKit
import CryptoKit
import Foundation

protocol CoverCaching {
    func cacheCover(originalData: Data) throws -> CachedCover?
    func cachedCoverExists(path: String?) -> Bool
    func removeCachedCover(path: String?) throws
}

struct CachedCover: Equatable, Sendable {
    var path: String
    var hash: String
}

struct CoverCacheService: CoverCaching {
    private let rootDirectory: URL
    private let fileManager: FileManager

    init(rootDirectory: URL, fileManager: FileManager = .default) {
        self.rootDirectory = rootDirectory
        self.fileManager = fileManager
    }

    static func appDefault(fileManager: FileManager = .default) throws -> CoverCacheService {
        let root = try AppDataDirectory.rootURL(fileManager: fileManager)
            .appendingPathComponent("Covers", isDirectory: true)
        return CoverCacheService(rootDirectory: root, fileManager: fileManager)
    }

    func cachePath(for book: LibraryBook) -> String? {
        book.coverPath
    }

    func cacheCover(originalData: Data) throws -> CachedCover? {
        guard let image = NSImage(data: originalData),
              let jpegData = Self.jpegThumbnailData(from: image) else {
            return nil
        }

        let hash = Self.sha1Hex(originalData)
        let shard = String(hash.prefix(2))
        let directory = rootDirectory.appendingPathComponent(shard, isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)

        let fileURL = directory.appendingPathComponent("\(hash).jpg")
        if !fileManager.fileExists(atPath: fileURL.path) {
            try jpegData.write(to: fileURL, options: .atomic)
        }

        return CachedCover(path: fileURL.path, hash: hash)
    }

    func cachedCoverExists(path: String?) -> Bool {
        guard let path, !path.isEmpty else {
            return false
        }

        return fileManager.fileExists(atPath: path)
    }

    func removeCachedCover(path: String?) throws {
        guard let path, !path.isEmpty, fileManager.fileExists(atPath: path) else {
            return
        }

        try fileManager.removeItem(atPath: path)
    }

    private static func jpegThumbnailData(from image: NSImage) -> Data? {
        let maxSide: CGFloat = 360
        let imageSize = image.size
        guard imageSize.width > 0, imageSize.height > 0 else {
            return nil
        }

        let scale = min(maxSide / imageSize.width, maxSide / imageSize.height, 1)
        let thumbnailSize = NSSize(width: imageSize.width * scale, height: imageSize.height * scale)
        let thumbnail = NSImage(size: thumbnailSize)
        thumbnail.lockFocus()
        NSColor.clear.setFill()
        NSRect(origin: .zero, size: thumbnailSize).fill()
        image.draw(
            in: NSRect(origin: .zero, size: thumbnailSize),
            from: NSRect(origin: .zero, size: imageSize),
            operation: .copy,
            fraction: 1
        )
        thumbnail.unlockFocus()

        guard let tiffData = thumbnail.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiffData) else {
            return nil
        }

        return bitmap.representation(
            using: .jpeg,
            properties: [.compressionFactor: 0.72]
        )
    }

    private static func sha1Hex(_ data: Data) -> String {
        Insecure.SHA1.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
