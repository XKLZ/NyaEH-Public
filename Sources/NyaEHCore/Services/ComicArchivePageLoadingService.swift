// 本文件按需从 .zip/.cbz 原文件加载漫画页面，阅读器和预览都通过它访问源 archive。

import Foundation
import ZIPFoundation

struct ComicArchivePageData: Identifiable, Equatable, Sendable {
    var index: Int
    var path: String
    var data: Data

    var id: Int {
        index
    }
}

struct ComicArchivePageBatch: Equatable, Sendable {
    var pages: [ComicArchivePageData]
    var totalCount: Int
}

struct ComicArchivePageLoadingService: Sendable {
    func loadPages(
        from archiveURL: URL,
        startIndex: Int,
        limit: Int,
        securityScopedRootURL: URL? = nil
    ) throws -> ComicArchivePageBatch {
        let accessGranted = securityScopedRootURL?.startAccessingSecurityScopedResource() ?? false
        defer {
            if accessGranted {
                securityScopedRootURL?.stopAccessingSecurityScopedResource()
            }
        }

        guard FileManager.default.fileExists(atPath: archiveURL.path) else {
            throw NyaEHError.unreadableArchive(archiveURL.path)
        }

        let archive = try Archive(url: archiveURL, accessMode: .read)
        let entries = imageEntries(in: archive)

        guard !entries.isEmpty else {
            throw NyaEHError.archiveContainsNoImages
        }

        let lowerBound = max(startIndex, 0)
        let upperBound = limit == 0 ? entries.count : min(lowerBound + max(limit, 0), entries.count)
        guard lowerBound < upperBound else {
            return ComicArchivePageBatch(pages: [], totalCount: entries.count)
        }

        let pages = try entries[lowerBound..<upperBound].enumerated().map { offset, entry in
            ComicArchivePageData(
                index: lowerBound + offset,
                path: entry.path,
                data: try data(for: entry, in: archive)
            )
        }

        return ComicArchivePageBatch(pages: pages, totalCount: entries.count)
    }

    private func imageEntries(in archive: Archive) -> [Entry] {
        archive.compactMap { entry in
            guard ComicArchiveImagePath.isSupported(entry.path) else {
                return nil
            }
            return entry
        }
        .sorted { lhs, rhs in
            lhs.path.localizedStandardCompare(rhs.path) == .orderedAscending
        }
    }

    private func data(for entry: Entry, in archive: Archive) throws -> Data {
        var output = Data()
        _ = try archive.extract(entry) { data in
            output.append(data)
        }
        return output
    }
}

private enum ComicArchiveImagePath {
    private static let supportedExtensions: Set<String> = [
        "jpg", "jpeg", "png", "webp", "gif", "bmp", "avif"
    ]

    static func isSupported(_ path: String) -> Bool {
        let ext = URL(fileURLWithPath: path).pathExtension.lowercased()
        return supportedExtensions.contains(ext)
    }
}
