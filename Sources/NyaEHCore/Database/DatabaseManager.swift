// 本文件创建主 SQLite 连接、运行迁移并暴露手动维护命令；NyaEH.sqlite 是业务数据源。

import Foundation
import GRDB

final class DatabaseManager {
    let dbQueue: any DatabaseWriter
    let path: String

    init(path: String) throws {
        self.path = path
        let databaseExisted = FileManager.default.fileExists(atPath: path)
        var configuration = Configuration()
        configuration.busyMode = .timeout(5)
        configuration.prepareDatabase { db in
            try db.execute(sql: "PRAGMA foreign_keys = ON")
            try db.execute(sql: "PRAGMA journal_mode = WAL")
        }
        dbQueue = try DatabasePool(path: path, configuration: configuration)
        if databaseExisted, try Self.needsMigrationBackup(dbQueue) {
            let schema = try dbQueue.read { db in
                try String.fetchAll(db, sql: "SELECT identifier FROM grdb_migrations").compactMap { id in
                    id.first == "v" ? Int(id.dropFirst().prefix { $0.isNumber }) : nil
                }.max() ?? 0
            }
            let root = URL(fileURLWithPath: path).deletingLastPathComponent()
            let backups = LibraryBackupService(databaseManager: self, appDataURL: root)
            try backups.protectedOperation(.preMigration, schema: schema) { _ in
                try DatabaseMigrator.nyaeh.migrate(dbQueue)
            }
        } else {
            try DatabaseMigrator.nyaeh.migrate(dbQueue)
        }
        try optimize()
    }

    static func appDefault() throws -> DatabaseManager {
        let appDirectory = try AppDataDirectory.rootURL()
        let databaseURL = try activeDatabaseURL(in: appDirectory)
        return try DatabaseManager(path: databaseURL.path)
    }

    static func activeDatabaseURL(in directory: URL) throws -> URL {
        let fileManager = FileManager.default
        let current = directory.appendingPathComponent(LibraryBackupService.databaseFilename)
        let previous = directory.appendingPathComponent(LegacyNaming.databaseFilename)
        guard !fileManager.fileExists(atPath: current.path),
              fileManager.fileExists(atPath: previous.path) else { return current }

        let staging = directory.appendingPathComponent(".database-migration-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: staging, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? fileManager.removeItem(at: staging) }
        let snapshot = staging.appendingPathComponent(current.lastPathComponent)
        var configuration = Configuration()
        configuration.readonly = true
        configuration.busyMode = .timeout(5)
        let source = try DatabaseQueue(path: previous.path, configuration: configuration)
        let destination = try DatabaseQueue(path: snapshot.path)
        try source.backup(to: destination)
        try destination.read { db in
            guard try String.fetchAll(db, sql: "PRAGMA integrity_check") == ["ok"],
                  try db.tableExists("library_books"),
                  try db.tableExists("grdb_migrations") else {
                throw NyaEHError.databaseInvariantViolation("The previous database could not be verified.")
            }
        }
        try destination.close()
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: snapshot.path)
        // Publish the closed snapshot without replacing another instance's database.
        do {
            try fileManager.linkItem(at: snapshot, to: current)
        } catch let error as CocoaError where error.code == .fileWriteFileExists {
            guard fileManager.fileExists(atPath: current.path) else { throw error }
        }
        return current
    }

    func optimize() throws {
        try dbQueue.write { db in
            try db.execute(sql: "PRAGMA optimize")
        }
    }

    func integrityCheck() throws -> [String] {
        try dbQueue.read { db in
            try String.fetchAll(db, sql: "PRAGMA integrity_check")
        }
    }

    func foreignKeyCheck() throws -> [DatabaseForeignKeyViolation] {
        try dbQueue.read { db in
            try Row.fetchAll(db, sql: "PRAGMA foreign_key_check").map { row in
                DatabaseForeignKeyViolation(
                    table: row["table"],
                    rowID: row["rowid"],
                    parent: row["parent"],
                    foreignKeyIndex: row["fkid"]
                )
            }
        }
    }

    func vacuum() throws {
        try dbQueue.writeWithoutTransaction { db in
            try db.execute(sql: "VACUUM")
        }
    }

    private static func needsMigrationBackup(_ dbQueue: any DatabaseWriter) throws -> Bool {
        try dbQueue.read { db in
            guard try db.tableExists("grdb_migrations") else { return false }
            let identifiers = try String.fetchAll(db, sql: "SELECT identifier FROM grdb_migrations")
            return !Set(DatabaseMigrator.nyaeh.migrations).isSubset(of: Set(identifiers))
        }
    }


}

struct DatabaseForeignKeyViolation: Equatable, Sendable {
    var table: String
    var rowID: Int64?
    var parent: String
    var foreignKeyIndex: Int
}
