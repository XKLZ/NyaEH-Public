// 本文件定义只由开发宿主显式启用的调试工具配置；正式 NyaEH 壳不传入该配置。

import Foundation

public struct NyaEHDevelopmentConfiguration: Equatable, Sendable {
    public static let comicArchiveEnvironmentKey = "NYAEH_DEVELOPMENT_COMIC_PATH"

    public let readerTestArchiveURL: URL

    public init(readerTestArchiveURL: URL) {
        self.readerTestArchiveURL = readerTestArchiveURL.standardizedFileURL
    }

    public static func resolved(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        currentDirectoryURL: URL = URL(
            fileURLWithPath: FileManager.default.currentDirectoryPath,
            isDirectory: true
        )
    ) -> NyaEHDevelopmentConfiguration {
        let archiveURL: URL
        if let configuredPath = environment[comicArchiveEnvironmentKey]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !configuredPath.isEmpty {
            let expandedPath = (configuredPath as NSString).expandingTildeInPath
            if (expandedPath as NSString).isAbsolutePath {
                archiveURL = URL(fileURLWithPath: expandedPath)
            } else {
                archiveURL = currentDirectoryURL.appendingPathComponent(expandedPath)
            }
        } else {
            archiveURL = currentDirectoryURL
                .appendingPathComponent(".nyaeh-dev", isDirectory: true)
                .appendingPathComponent("comic", isDirectory: true)
                .appendingPathComponent("comictest.zip", isDirectory: false)
        }

        return NyaEHDevelopmentConfiguration(readerTestArchiveURL: archiveURL)
    }
}
