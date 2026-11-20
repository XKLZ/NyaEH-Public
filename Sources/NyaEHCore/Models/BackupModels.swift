// 本文件定义可移植备份包 manifest 与数据健康检查结果。

import Foundation

enum LibraryBackupKind: String, Codable, Sendable {
    case manual
    case automatic
    case daily
    case weekly
    case preImport
    case preMigration
    case preRestore
    case preRepair
}

struct LibraryBackupManifest: Codable, Equatable, Sendable {
    static let formatVersion = 1

    var formatVersion: Int
    var appName: String
    var appVersion: String
    var schemaVersion: Int
    var createdAt: Int64
    var kind: LibraryBackupKind
    var includesTagAssets: Bool
    var excludedAssets: [String]
    var backupID: UUID?
}

struct LibraryBackupResult: Equatable, Sendable {
    var packageURL: URL
    var manifest: LibraryBackupManifest
}

struct DataHealthIssue: Identifiable, Equatable, Sendable {
    enum Severity: String, Sendable {
        case warning
        case error
    }

    var id: String
    var severity: Severity
    var title: String
    var detail: String
    var repairable: Bool
}

struct DataHealthReport: Equatable, Sendable {
    var checkedAt: Int64
    var issues: [DataHealthIssue]
    var repairedIssueCount: Int = 0

    var isHealthy: Bool { issues.isEmpty }
}

enum BackupCommand: Sendable {
    case export(URL, images: Bool)
    case restoreFile(URL)
    case restoreEntry(UUID)
    case delete(Set<UUID>)
    case destination(URL?)

    var isRestore: Bool {
        switch self {
        case .restoreFile, .restoreEntry: true
        default: false
        }
    }

    func perform(using service: LibraryBackupService) throws -> String? {
        switch self {
        case let .export(url, images): return try service.export(to: url, includeImages: images).packageURL.path
        case let .restoreFile(url): _ = try service.restore(from: url)
        case let .restoreEntry(id): _ = try service.restore(id: id)
        case let .delete(ids): try service.delete(ids)
        case let .destination(url): try service.chooseLocation(url)
        }
        return nil
    }
}
