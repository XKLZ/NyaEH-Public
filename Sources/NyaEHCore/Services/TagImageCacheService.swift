// 本文件提供标签视觉图片的轻量缓存，避免 SwiftUI 列表滚动时重复解码图片。

import CryptoKit
import Foundation

actor TagImageCacheService {
    static let shared = TagImageCacheService()

    private let fileManager: FileManager
    private let urlSession: URLSession
    private let rootURLProvider: @Sendable () throws -> URL

    init(
        fileManager: FileManager = .default,
        urlSession: URLSession = .shared,
        rootURLProvider: @escaping @Sendable () throws -> URL = {
            try AppDataDirectory.rootURL()
                .appendingPathComponent("TagImageCache", isDirectory: true)
        }
    ) {
        self.fileManager = fileManager
        self.urlSession = urlSession
        self.rootURLProvider = rootURLProvider
    }

    func imageData(for url: URL) async -> Data? {
        guard let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else {
            return nil
        }

        do {
            let cacheURL = try cacheURL(for: url)
            if fileManager.fileExists(atPath: cacheURL.path) {
                return try Data(contentsOf: cacheURL)
            }

            let (data, response) = try await urlSession.data(from: url)
            guard let httpResponse = response as? HTTPURLResponse,
                  200..<300 ~= httpResponse.statusCode else {
                return nil
            }

            try data.write(to: cacheURL, options: .atomic)
            return data
        } catch {
            return nil
        }
    }

    private func cacheURL(for url: URL) throws -> URL {
        let rootURL = try rootURLProvider()
        try fileManager.createDirectory(at: rootURL, withIntermediateDirectories: true)
        let hash = SHA256.hash(data: Data(url.absoluteString.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        return rootURL.appendingPathComponent("\(hash).data")
    }
}
