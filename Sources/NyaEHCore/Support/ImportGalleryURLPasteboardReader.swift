// 本文件将 macOS 剪贴板内容收窄为导入流水线支持的画廊网址。

import AppKit
import Foundation

enum ImportGalleryURLPasteboardReader {
    static func read(from pasteboard: NSPasteboard = .general) -> URL? {
        var candidates = (pasteboard.readObjects(forClasses: [NSURL.self]) as? [URL] ?? [])
            .map(\.absoluteString)
        if let text = pasteboard.string(forType: .string) {
            candidates.append(text)
        }
        return firstSupportedURL(in: candidates)
    }

    static func firstSupportedURL(in candidates: [String]) -> URL? {
        for candidate in candidates {
            let trimmed = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
            guard
                let url = URL(string: trimmed),
                GalleryMetadataFetchService.isSupportedGalleryURL(url)
            else {
                continue
            }
            return url
        }
        return nil
    }
}
