import Foundation
import Testing
@testable import NyaEHCore

@Suite("Library backup service")
struct LibraryBackupServiceTests {
    @Test("export validates and restore replaces database safely")
    func exportValidateAndRestore() throws {
        let context = try makeContext()
        let original = try context.books.insert(book(title: "Before Backup", filepath: "/tmp/backup-before.cbz"))
        let packageURL = context.root.appendingPathComponent("manual.nyaehbackup", isDirectory: true)

        let exported = try context.backups.export(to: packageURL)
        #expect(exported.manifest.formatVersion == LibraryBackupManifest.formatVersion)
        #expect(try context.backups.validate(packageURL: packageURL) == exported.manifest)

        _ = try context.books.insert(book(title: "After Backup", filepath: "/tmp/backup-after.cbz"))
        _ = try context.backups.restore(from: packageURL)

        let restored = try context.books.fetchAll()
        #expect(restored.map(\.databaseID) == [original.databaseID])
        #expect(restored.map(\.title) == ["Before Backup"])
        #expect(try context.database.integrityCheck() == ["ok"])
        #expect(try context.database.foreignKeyCheck().isEmpty)
    }

    @Test("invalid package is rejected without changing current data")
    func invalidPackageDoesNotChangeData() throws {
        let context = try makeContext()
        let original = try context.books.insert(book(title: "Keep Me", filepath: "/tmp/backup-keep.cbz"))
        let invalid = context.root.appendingPathComponent("invalid.nyaehbackup", isDirectory: true)
        try FileManager.default.createDirectory(at: invalid, withIntermediateDirectories: true)

        #expect(throws: Error.self) { try context.backups.restore(from: invalid) }
        #expect(try context.books.fetchAll().map(\.databaseID) == [original.databaseID])
    }

    @Test("automatic backups are limited to one daily and weekly package")
    func automaticBackupCadence() throws {
        let context = try makeContext()
        _ = try context.books.insert(book(title: "Automatic", filepath: "/tmp/backup-auto.cbz"))
        let now = Date(timeIntervalSince1970: 1_788_000_000)

        try context.backups.createAutomaticBackupsIfNeeded(now: now)
        try context.backups.createAutomaticBackupsIfNeeded(now: now)

        let backupDirectory = context.root.appendingPathComponent("Backups", isDirectory: true)
        let names = try FileManager.default.contentsOfDirectory(atPath: backupDirectory.path)
        #expect(names.filter { $0.hasPrefix("daily-") }.count == 1)
        #expect(names.filter { $0.hasPrefix("weekly-") }.count == 1)
    }

    private func makeContext() throws -> BackupTestContext {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let database = try DatabaseManager(path: root.appendingPathComponent("NyaEH.sqlite").path)
        return .init(
            root: root,
            database: database,
            books: SQLiteLibraryBookRepository(dbQueue: database.dbQueue),
            backups: LibraryBackupService(databaseManager: database, appDataURL: root)
        )
    }

    private func book(title: String, filepath: String) -> LibraryBook {
        LibraryBook(
            title: title,
            hash: UUID().uuidString,
            filepath: filepath,
            type: .archive,
            status: .correct,
            date: Timestamp.nowMilliseconds(),
            tags: "[]"
        )
    }
}

private struct BackupTestContext {
    let root: URL
    let database: DatabaseManager
    let books: SQLiteLibraryBookRepository
    let backups: LibraryBackupService
}
