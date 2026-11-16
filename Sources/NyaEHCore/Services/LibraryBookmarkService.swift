// 本文件封装安全书签保存与解析，沙盒版读取原始书库目录时必须经过这里。

import Foundation

enum LibraryBookmarkService {
    static func bookmarkData(for url: URL) throws -> Data {
        try TestRuntime.validateSourceRoot(url)
        do {
            return try url.bookmarkData(
                options: [.withSecurityScope],
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
        } catch {
            return try url.bookmarkData(
                options: [],
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
        }
    }

    static func resolveBookmark(_ data: Data) throws -> (url: URL, isStale: Bool) {
        var isStale = false
        let url = try URL(
            resolvingBookmarkData: data,
            options: [.withSecurityScope],
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        )
        try TestRuntime.validateSourceRoot(url)
        return (url, isStale)
    }
}
