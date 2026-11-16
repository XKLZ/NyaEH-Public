// 本文件为一次阅读窗口持有一个 archive 会话，避免翻页时重复打开并枚举压缩包。

import AppKit
import Foundation
import ImageIO
import ZIPFoundation

struct ReaderDecodedPage: Identifiable, @unchecked Sendable {
    let index: Int
    let path: String
    let image: NSImage?
    let decodedCost: Int

    var id: Int { index }
}

struct ReaderDecodedPageBatch: @unchecked Sendable {
    let pages: [ReaderDecodedPage]
    let totalCount: Int
}

struct ReaderDecodedThumbnail: Identifiable, @unchecked Sendable {
    let index: Int
    let path: String
    let image: NSImage?
    let decodedCost: Int

    var id: Int { index }
}

struct ReaderDecodedThumbnailBatch: @unchecked Sendable {
    let thumbnails: [ReaderDecodedThumbnail]
    let totalCount: Int
}

actor ReaderArchiveSession {
    private let securityScopedRootURL: URL?
    private let hasSecurityScope: Bool
    private let archive: Archive
    private let entries: [Entry]

    init(archiveURL: URL, securityScopedRootURL: URL?) throws {
        let granted = securityScopedRootURL?.startAccessingSecurityScopedResource() ?? false
        do {
            guard FileManager.default.fileExists(atPath: archiveURL.path) else {
                throw NyaEHError.unreadableArchive(archiveURL.path)
            }
            let archive = try Archive(url: archiveURL, accessMode: .read)
            let entries = archive.compactMap { entry -> Entry? in
                let ext = URL(fileURLWithPath: entry.path).pathExtension.lowercased()
                return Self.supportedExtensions.contains(ext) ? entry : nil
            }
            .sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
            guard !entries.isEmpty else { throw NyaEHError.archiveContainsNoImages }
            self.securityScopedRootURL = securityScopedRootURL
            self.hasSecurityScope = granted
            self.archive = archive
            self.entries = entries
        } catch {
            if granted { securityScopedRootURL?.stopAccessingSecurityScopedResource() }
            throw error
        }
    }

    deinit {
        if hasSecurityScope {
            securityScopedRootURL?.stopAccessingSecurityScopedResource()
        }
    }

    func pageCount() -> Int {
        entries.count
    }

    func load(indices: [Int]) throws -> ReaderDecodedPageBatch {
        let validIndices = Array(Set(indices.filter { entries.indices.contains($0) })).sorted()
        let pages = try validIndices.map { index in
            try Task.checkCancellation()
            let entry = entries[index]
            var data = Data()
            _ = try archive.extract(entry) { chunk in
                try Task.checkCancellation()
                data.append(chunk)
            }
            try Task.checkCancellation()
            return Self.decode(index: index, path: entry.path, data: data)
        }
        return ReaderDecodedPageBatch(pages: pages, totalCount: entries.count)
    }

    func loadThumbnails(
        indices: [Int],
        maximumPixelSize: Int = ReaderThumbnailCachePolicy.maximumPixelSize
    ) -> ReaderDecodedThumbnailBatch {
        let validIndices = Array(Set(indices.filter { entries.indices.contains($0) })).sorted()
        let thumbnails: [ReaderDecodedThumbnail] = validIndices.compactMap { index in
            guard !Task.isCancelled else { return nil }
            let entry = entries[index]
            do {
                var data = Data()
                _ = try archive.extract(entry) { chunk in
                    try Task.checkCancellation()
                    data.append(chunk)
                }
                try Task.checkCancellation()
                return Self.decodeThumbnail(
                    index: index,
                    path: entry.path,
                    data: data,
                    maximumPixelSize: maximumPixelSize
                )
            } catch {
                guard !Task.isCancelled else { return nil }
                return ReaderDecodedThumbnail(
                    index: index,
                    path: entry.path,
                    image: nil,
                    decodedCost: 0
                )
            }
        }
        return ReaderDecodedThumbnailBatch(thumbnails: thumbnails, totalCount: entries.count)
    }

    nonisolated private static let supportedExtensions: Set<String> = [
        "jpg", "jpeg", "png", "webp", "gif", "bmp", "avif"
    ]

    nonisolated private static func decode(index: Int, path: String, data: Data) -> ReaderDecodedPage {
        autoreleasepool {
            guard let source = CGImageSourceCreateWithData(data as CFData, nil),
                  let image = CGImageSourceCreateImageAtIndex(
                    source,
                    0,
                    [kCGImageSourceShouldCacheImmediately: true] as CFDictionary
                  ) else {
                return ReaderDecodedPage(index: index, path: path, image: nil, decodedCost: 0)
            }
            return ReaderDecodedPage(
                index: index,
                path: path,
                image: NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height)),
                decodedCost: image.bytesPerRow * image.height
            )
        }
    }

    nonisolated private static func decodeThumbnail(
        index: Int,
        path: String,
        data: Data,
        maximumPixelSize: Int
    ) -> ReaderDecodedThumbnail {
        autoreleasepool {
            guard maximumPixelSize > 0,
                  let source = CGImageSourceCreateWithData(data as CFData, nil),
                  let image = CGImageSourceCreateThumbnailAtIndex(
                    source,
                    0,
                    [
                        kCGImageSourceCreateThumbnailFromImageAlways: true,
                        kCGImageSourceCreateThumbnailWithTransform: true,
                        kCGImageSourceThumbnailMaxPixelSize: maximumPixelSize,
                        kCGImageSourceShouldCacheImmediately: true
                    ] as CFDictionary
                  ) else {
                return ReaderDecodedThumbnail(
                    index: index,
                    path: path,
                    image: nil,
                    decodedCost: 0
                )
            }
            return ReaderDecodedThumbnail(
                index: index,
                path: path,
                image: NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height)),
                decodedCost: image.bytesPerRow * image.height
            )
        }
    }
}
