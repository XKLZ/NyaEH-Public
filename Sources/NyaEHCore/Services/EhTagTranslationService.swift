// 本文件负责 EhTagTranslation release 缓存、解析和本地已知标签的翻译物化。

import Foundation

struct EhTagTranslationManifest: Codable, Equatable, Sendable {
    var source: String
    var repositoryURL: String
    var branch: String
    var revision: String
    var downloadedAt: Int64
    var status: String
    var message: String?
}

struct EhTagTranslationDownload: Equatable, Sendable {
    var data: Data
    var revision: String
}

struct EhTagTranslationHTTPError: LocalizedError, Equatable, Sendable {
    var statusCode: Int
    var url: URL?

    var errorDescription: String? {
        if let url {
            return "Tag translation download failed with HTTP \(statusCode): \(url.absoluteString)"
        }
        return "Tag translation download failed with HTTP \(statusCode)."
    }
}

protocol EhTagTranslationRemoteClient: Sendable {
    func downloadDatabase(proxySettings: NetworkProxySettings) async throws -> EhTagTranslationDownload
}

extension EhTagTranslationRemoteClient {
    func downloadDatabase() async throws -> EhTagTranslationDownload {
        try await downloadDatabase(proxySettings: NetworkProxySettings())
    }
}

struct GitHubEhTagTranslationRemoteClient: EhTagTranslationRemoteClient {
    let repository = "EhTagTranslation/Database"
    let branch = "release"

    func downloadDatabase(proxySettings: NetworkProxySettings = NetworkProxySettings()) async throws -> EhTagTranslationDownload {
        // 只下载 release 产物 db.text.json；解析后仅物化本地已知 tag，避免把整个远端词库塞进主库。
        var request = URLRequest(url: url)
        request.setValue("NyaEH", forHTTPHeaderField: "User-Agent")
        let session = URLSession(configuration: .nyaehDefault(proxySettings: proxySettings))
        let (data, response) = try await session.data(for: request)
        let revision = try Self.revisionToken(from: response, downloadedAt: Timestamp.nowMilliseconds())
        return EhTagTranslationDownload(data: data, revision: revision)
    }

    var url: URL {
        URL(string: "https://github.com/\(repository)/releases/latest/download/db.text.json")!
    }

    static func revisionToken(from response: URLResponse, downloadedAt: Int64) throws -> String {
        guard let response = response as? HTTPURLResponse,
              200..<300 ~= response.statusCode else {
            throw EhTagTranslationHTTPError(
                statusCode: (response as? HTTPURLResponse)?.statusCode ?? -1,
                url: response.url
            )
        }

        if let etag = response.value(forHTTPHeaderField: "ETag")?.trimmingCharacters(in: .whitespacesAndNewlines),
           !etag.isEmpty {
            return etag
        }

        if let lastModified = response.value(forHTTPHeaderField: "Last-Modified")?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !lastModified.isEmpty {
            return lastModified
        }

        return "downloaded-\(downloadedAt)"
    }
}

struct EhTagTranslationJSONParser {
    private struct Database: Decodable {
        var data: [NamespaceBlock]
    }

    private struct NamespaceBlock: Decodable {
        var namespace: String
        var data: [String: Entry]
    }

    private struct Entry: Decodable {
        var name: String
        var intro: String?
    }

    func parse(data: Data) throws -> [ExternalTagTranslation] {
        let decoder = JSONDecoder()
        if let database = try? decoder.decode(Database.self, from: data) {
            return database.data.flatMap { block in
                parse(namespace: block.namespace, entries: block.data)
            }
        }

        let database = try decoder.decode([String: [String: Entry]].self, from: data)
        return database.flatMap { namespace, entries in
            parse(namespace: namespace, entries: entries)
        }
    }

    func parse(json: String) throws -> [ExternalTagTranslation] {
        try parse(data: Data(json.utf8))
    }

    private func parse(namespace: String, entries: [String: Entry]) -> [ExternalTagTranslation] {
        let normalizedNamespace = namespace
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard normalizedNamespace != "rows" else {
            return []
        }

        return entries.compactMap { rawName, entry in
            let name = rawName
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
            let translatedName = cleanText(entry.name)
            let intro = entry.intro.map(cleanText)
            guard !normalizedNamespace.isEmpty, !name.isEmpty, !translatedName.isEmpty else {
                return nil
            }

            return ExternalTagTranslation(
                namespace: normalizedNamespace,
                name: name,
                translatedName: translatedName,
                intro: intro?.isEmpty == false ? intro : nil,
                links: []
            )
        }
    }

    private func cleanText(_ text: String) -> String {
        text
            .replacingOccurrences(
                of: #"!\[[^\]]*\]\([^)]*\)"#,
                with: "",
                options: .regularExpression
            )
            .replacingOccurrences(
                of: #"!\[[^\]]*\]\(?"#,
                with: "",
                options: .regularExpression
            )
            .replacingOccurrences(
                of: #"<img\b[^>]*>"#,
                with: "",
                options: [.regularExpression, .caseInsensitive]
            )
            .replacingOccurrences(
                of: #"<br\s*/?>"#,
                with: " ",
                options: [.regularExpression, .caseInsensitive]
            )
            .replacingOccurrences(
                of: #"\s+"#,
                with: " ",
                options: .regularExpression
            )
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

struct EhTagTranslationCache {
    static let source = "ehtagtranslation"
    static let repositoryURL = "https://github.com/EhTagTranslation/Database"
    static let branch = "release"
    static let languageCode = "zh-Hans"

    let rootURL: URL
    var manifestURL: URL { rootURL.appendingPathComponent("manifest.json") }
    var databaseURL: URL { rootURL.appendingPathComponent("db.text.json") }

    init(appDataRoot: URL) {
        rootURL = appDataRoot
            .appendingPathComponent("TagTranslations", isDirectory: true)
            .appendingPathComponent("EhTagTranslation", isDirectory: true)
    }

    func manifest(fileManager: FileManager = .default) throws -> EhTagTranslationManifest? {
        guard fileManager.fileExists(atPath: manifestURL.path) else {
            return nil
        }

        let data = try Data(contentsOf: manifestURL)
        return try JSONDecoder().decode(EhTagTranslationManifest.self, from: data)
    }

    func databaseData(fileManager: FileManager = .default) throws -> Data {
        guard fileManager.fileExists(atPath: databaseURL.path) else {
            return Data()
        }
        return try Data(contentsOf: databaseURL)
    }

    func replaceCache(
        databaseData: Data,
        manifest: EhTagTranslationManifest,
        fileManager: FileManager = .default
    ) throws {
        let temporaryRoot = rootURL
            .deletingLastPathComponent()
            .appendingPathComponent("EhTagTranslation.tmp.\(UUID().uuidString)", isDirectory: true)

        try fileManager.createDirectory(at: temporaryRoot, withIntermediateDirectories: true)
        try databaseData.write(to: temporaryRoot.appendingPathComponent("db.text.json"), options: .atomic)

        let manifestData = try JSONEncoder().encode(manifest)
        try manifestData.write(to: temporaryRoot.appendingPathComponent("manifest.json"), options: .atomic)

        if fileManager.fileExists(atPath: rootURL.path) {
            try fileManager.removeItem(at: rootURL)
        }
        try fileManager.createDirectory(
            at: rootURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try fileManager.moveItem(at: temporaryRoot, to: rootURL)
    }
}

struct EhTagTranslationUpdateService {
    let cache: EhTagTranslationCache
    let remoteClient: any EhTagTranslationRemoteClient
    let parser = EhTagTranslationJSONParser()
    let fileManager: FileManager

    init(
        appDataRoot: URL,
        remoteClient: any EhTagTranslationRemoteClient = GitHubEhTagTranslationRemoteClient(),
        fileManager: FileManager = .default
    ) {
        cache = EhTagTranslationCache(appDataRoot: appDataRoot)
        self.remoteClient = remoteClient
        self.fileManager = fileManager
    }

    static func appDefault() throws -> EhTagTranslationUpdateService {
        try EhTagTranslationUpdateService(appDataRoot: AppDataDirectory.rootURL())
    }

    func cachedManifest() throws -> EhTagTranslationManifest? {
        try cache.manifest(fileManager: fileManager)
    }

    @MainActor
    func update(
        repository: any TagRepository,
        proxySettings: NetworkProxySettings = NetworkProxySettings()
    ) async throws -> TagTranslationUpdateResult {
        let download = try await remoteClient.downloadDatabase(proxySettings: proxySettings)
        let revision = download.revision
        if let manifest = try cache.manifest(fileManager: fileManager),
           manifest.revision == revision {
            let translations = try parseTranslations(from: try cache.databaseData(fileManager: fileManager))
            let materialized = try repository.materializeTranslations(
                translations,
                languageCode: EhTagTranslationCache.languageCode,
                source: EhTagTranslationCache.source,
                sourceRevision: revision
            )
            return TagTranslationUpdateResult(
                revision: revision,
                downloaded: false,
                files: 1,
                parsedTranslations: translations.count,
                materializedTranslations: materialized
            )
        }

        let databaseData = download.data
        let translations = try parseTranslations(from: databaseData)

        let manifest = EhTagTranslationManifest(
            source: EhTagTranslationCache.source,
            repositoryURL: EhTagTranslationCache.repositoryURL,
            branch: EhTagTranslationCache.branch,
            revision: revision,
            downloadedAt: Timestamp.nowMilliseconds(),
            status: "success",
            message: nil
        )
        try cache.replaceCache(databaseData: databaseData, manifest: manifest, fileManager: fileManager)
        let materialized = try repository.materializeTranslations(
            translations,
            languageCode: EhTagTranslationCache.languageCode,
            source: EhTagTranslationCache.source,
            sourceRevision: revision
        )

        return TagTranslationUpdateResult(
            revision: revision,
            downloaded: true,
            files: 1,
            parsedTranslations: translations.count,
            materializedTranslations: materialized
        )
    }

    func materializeCachedTranslations(repository: any TagRepository) throws -> Int {
        guard let manifest = try cache.manifest(fileManager: fileManager) else {
            return 0
        }

        let translations = try parseTranslations(from: try cache.databaseData(fileManager: fileManager))
        return try repository.materializeTranslations(
            translations,
            languageCode: EhTagTranslationCache.languageCode,
            source: EhTagTranslationCache.source,
            sourceRevision: manifest.revision
        )
    }

    private func parseTranslations(from data: Data) throws -> [ExternalTagTranslation] {
        guard !data.isEmpty else {
            throw NyaEHError.tagTranslationArchiveInvalid
        }

        do {
            let translations = try parser.parse(data: data)
            guard !translations.isEmpty else {
                throw NyaEHError.tagTranslationArchiveInvalid
            }
            return translations
        } catch NyaEHError.tagTranslationArchiveInvalid {
            throw NyaEHError.tagTranslationArchiveInvalid
        } catch {
            throw NyaEHError.tagTranslationArchiveInvalid
        }
    }
}
