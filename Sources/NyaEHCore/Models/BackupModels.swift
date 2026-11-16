// 本文件定义可移植备份包 manifest 与数据健康检查结果。

import Foundation

enum LibraryBackupKind: String, Codable, Sendable {
    case manual
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
