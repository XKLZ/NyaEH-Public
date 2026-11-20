import Foundation
import GRDB
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
        let contents = try FileManager.default.contentsOfDirectory(atPath: packageURL.path)
        #expect(Set(contents) == ["NyaEH.sqlite", "manifest.json"])
        let header = try Data(contentsOf: packageURL.appendingPathComponent("NyaEH.sqlite")).prefix(20)
        #expect(Array(header.suffix(2)) == [1, 1])

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

    @Test("A committed membership change triggers at 168 hours, not when opening on day eight")
    func automaticBackupCadence() throws {
        let c = try makeContext()
        let day = 86400.0
        let start = Date(timeIntervalSince1970: 1_788_000_000)
        try c.backups.reconcile(now: start)
        #expect(try c.backups.listing().entries.isEmpty)
        func insert(_ title: String, on n: Int) throws -> LibraryBook {
            let saved = try c.books.insert(book(title: title, filepath: "/fixture/" + title))
            try c.setEvent(start.addingTimeInterval(Double(n) * day))
            return saved
        }
        let first = try insert("one", on: 0)
        try c.backups.reconcile(now: start)
        _ = try insert("two", on: 6)
        try c.backups.reconcile(now: start.addingTimeInterval(6 * day))
        let id = try #require(first.databaseID)
        _ = try c.books.incrementReadCount(bookID: id)
        var missing = first
        missing.exist = false
        _ = try c.books.update(missing)
        try c.backups.reconcile(now: start.addingTimeInterval(8 * day))
        #expect(try c.backups.listing().entries.count == 1)
        _ = try insert("three", on: 9)
        _ = try insert("four", on: 9)
        try c.backups.reconcile(now: start.addingTimeInterval(9 * day))
        var entries = try c.backups.listing().entries
        #expect(entries.count == 2)
        let db = try DatabaseQueue(path: c.root.appendingPathComponent("Backups/" + entries[0].name + "/NyaEH.sqlite").path)
        #expect(try db.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM library_books") } == 4)
        try c.books.delete(id: id)
        try c.setEvent(start.addingTimeInterval(16 * day))
        try c.backups.reconcile(now: start.addingTimeInterval(16 * day))
        entries = try c.backups.listing().entries
        #expect(entries.first?.createdAt == start.addingTimeInterval(16 * day))
        try c.backups.delete(Set(entries.map(\.id)))
        try c.backups.reconcile(now: start.addingTimeInterval(30 * day))
        #expect(try c.backups.listing().entries.isEmpty)
    }

    @Test("Custom backup folders persist and inaccessible destinations leave a durable retry")
    func externalRetryAndRetention() throws {
        let c = try makeContext()
        let destination = c.root.appendingPathComponent("external")
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false)
        try c.backups.chooseLocation(destination)
        _ = try c.books.insert(book(title: "first", filepath: "/fixture/a"))
        let work = URL(fileURLWithPath: try c.backups.listing().destination)
        // A non-directory at the chosen destination deterministically simulates unavailable storage.
        try Data().write(to: work)
        #expect(throws: Error.self) { try c.backups.reconcile() }
        let reopened = c.reopen()
        #expect(try reopened.listing().pending)
        try FileManager.default.removeItem(at: work)
        try reopened.reconcile()
        let first = try #require(reopened.listing().entries.first)
        #expect(FileManager.default.fileExists(atPath: work.appendingPathComponent(first.name).path))
        try reopened.chooseLocation(nil)
        let foreign = work.appendingPathComponent("notes.txt")
        try Data([2]).write(to: foreign)
        try reopened.protectedOperation(.preImport) { _ in }
        try reopened.protectedOperation(.preRepair) { _ in
            #expect(FileManager.default.fileExists(atPath: work.appendingPathComponent(first.name).path))
        }
        #expect(try reopened.listing().entries.map(\.kind).contains(.automatic) == false)
        #expect(try Data(contentsOf: foreign) == Data([2]))
        #expect(try reopened.listing().pending == false)
    }

    @Test("Overlapping checks publish one automatic backup and deferred rotation retries safely")
    func overlappingChecksAndDeferredRotation() async throws {
        let c = try makeContext()
        _ = try c.books.insert(book(title: "first", filepath: "/fixture/concurrent"))
        let service = c.backups
        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<4 { group.addTask { try service.reconcile() } }
            try await group.waitForAll()
        }
        let firstEntries = try c.backups.listing().entries
        #expect(firstEntries.count == 1)
        let auto = try #require(firstEntries.first)
        let unavailable = LibraryBackupService(databaseManager: c.database, appDataURL: c.root,
            trash: { _ in throw CocoaError(.fileWriteNoPermission) })
        try unavailable.protectedOperation(.preRepair) { _ in }
        try unavailable.protectedOperation(.preImport) { _ in }
        let pending = try unavailable.listing()
        #expect(pending.entries.count == 3)
        #expect(pending.entries.first(where: { $0.id == auto.id })?.pendingRemoval == true)
        try c.reopen().reconcile()
        let finished = try c.backups.listing()
        #expect(finished.entries.count == 2)
        #expect(finished.entries.allSatisfy { !$0.pendingRemoval && $0.id != auto.id })
        #expect(finished.issue == nil)
    }

    @Test("Legacy snapshots seed the clock, stay outside rotation, and remain restorable")
    func legacyUpgrade() throws {
        let c = try makeContext()
        let old = c.root.appendingPathComponent("Backups/daily-2026-11-01.nyaehbackup")
        try FileManager.default.createDirectory(at: old, withIntermediateDirectories: true)
        let oldDB = try DatabaseQueue(path: old.appendingPathComponent(LegacyNaming.databaseFilename).path)
        try c.database.dbQueue.backup(to: oldDB)
        try oldDB.close()
        let baseline = Date(timeIntervalSince1970: 1_788_000_000)
        let manifest = LibraryBackupManifest(formatVersion: 1, appName: "TreeC", appVersion: "1", schemaVersion: 22,
            createdAt: Int64(baseline.timeIntervalSince1970 * 1000), kind: .daily, includesTagAssets: false, excludedAssets: [])
        try JSONEncoder().encode(manifest).write(to: old.appendingPathComponent("manifest.json"))
        _ = try c.books.insert(book(title: "after", filepath: "/fixture/after"))
        try c.setEvent(baseline.addingTimeInterval(60))
        try c.backups.reconcile(now: baseline.addingTimeInterval(60))
        let legacy = try #require(c.backups.listing().entries.first)
        #expect(legacy.legacy)
        for kind in [LibraryBackupKind.preRepair, .preImport, .preRestore] {
            try c.backups.protectedOperation(kind) { _ in }
        }
        #expect(try c.backups.listing().entries.count == 3)
        _ = try c.backups.restore(id: legacy.id)
        #expect(try c.books.fetchAll().isEmpty)
        #expect(try c.backups.listing().entries.contains(where: { $0.id == legacy.id }))
    }

    @Test("Exports select original images and restoring a database-only backup preserves images")
    func imagePolicy() throws {
        let c = try makeContext()
        let relative = "TagAssets/tag/example/show.png"
        let original = c.root.appendingPathComponent(relative)
        let folder = original.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data([1]).write(to: original)
        try Data([9]).write(to: folder.appendingPathComponent("bg.hero-blur.png"))
        try c.database.dbQueue.write { db in
            try db.execute(sql: "INSERT INTO tags (id, raw_value, namespace, name, created_at, updated_at) VALUES (1, 'tag:example', 'tag', 'example', 1, 1)")
            try db.execute(sql: "INSERT INTO tag_visual_profiles(tag_id, foreground_asset_path, created_at, updated_at) VALUES (1, ?, 1, 1)", arguments: [relative])
        }
        let light = try c.backups.export(to: c.root.appendingPathComponent("light.nyaehbackup"))
        let full = try c.backups.export(to: c.root.appendingPathComponent("full.nyaehbackup"), includeImages: true)
        #expect(!light.manifest.includesTagAssets && full.manifest.includesTagAssets)
        #expect(!FileManager.default.fileExists(atPath: light.packageURL.appendingPathComponent("TagAssets").path))
        #expect(!FileManager.default.fileExists(atPath: full.packageURL.appendingPathComponent(relative).deletingLastPathComponent().appendingPathComponent("bg.hero-blur.png").path))
        try Data([2]).write(to: original)
        _ = try c.backups.restore(from: light.packageURL)
        #expect(try Data(contentsOf: original) == Data([2]))
        _ = try c.backups.restore(from: full.packageURL)
        #expect(try Data(contentsOf: original) == Data([1]))
        #expect(try c.backups.listing().entries.allSatisfy { !$0.includesImages })
    }

    @Test("Failed migration during restore rolls back the main database and preserves local tag images")
    func failedRestoreRollsBack() throws {
        let c = try makeContext()
        let original = try c.books.insert(book(title: "keep", filepath: "/fixture/keep"))
        let archive = try c.backups.export(to: c.root.appendingPathComponent("bad-migration.nyaehbackup"))
        let incoming = try DatabaseQueue(path: archive.packageURL.appendingPathComponent("NyaEH.sqlite").path)
        try incoming.write { db in
            try db.execute(sql: "UPDATE library_books SET title = 'unexpected'")
            // Replaying a non-idempotent historical migration fails after the backup copy.
            try db.execute(sql: "DELETE FROM grdb_migrations WHERE identifier = 'v20_deletion_consistency'")
        }
        try incoming.close()
        let images = c.root.appendingPathComponent("TagAssets")
        try FileManager.default.createDirectory(at: images, withIntermediateDirectories: false)
        try Data([7]).write(to: images.appendingPathComponent("existing.png"))
        let packaged = archive.packageURL.appendingPathComponent("TagAssets")
        try FileManager.default.createDirectory(at: packaged, withIntermediateDirectories: false)
        try Data([8]).write(to: packaged.appendingPathComponent("other.png"))
        var manifest = archive.manifest
        manifest.includesTagAssets = true
        try JSONEncoder().encode(manifest).write(to: archive.packageURL.appendingPathComponent("manifest.json"))
        #expect(throws: Error.self) { try c.backups.restore(from: archive.packageURL) }
        #expect(try c.books.fetch(id: #require(original.databaseID))?.title == "keep")
        #expect(try Data(contentsOf: images.appendingPathComponent("existing.png")) == Data([7]))
        #expect(!FileManager.default.fileExists(atPath: images.appendingPathComponent("other.png").path))
    }

    private func makeContext() throws -> BackupTestContext {
        let root = TestRunResources.directory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let database = try DatabaseManager(path: root.appendingPathComponent("NyaEH.sqlite").path)
        return .init(
            root: root,
            database: database,
            books: SQLiteLibraryBookRepository(dbQueue: database.dbQueue),
            backups: BackupTestContext.service(database, root)
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

private extension BackupTestContext {
    func setEvent(_ date: Date) throws {
        try database.dbQueue.write { db in
            try db.execute(sql: "UPDATE backup_membership_event SET changed_at = ?", arguments: [Int64(date.timeIntervalSince1970 * 1000)])
            #expect(db.changesCount == 1)
        }
    }

    static func service(_ database: DatabaseManager, _ root: URL) -> LibraryBackupService {
        LibraryBackupService(databaseManager: database, appDataURL: root, trash: { url in
            let trash = root.appendingPathComponent("TestTrash")
            try FileManager.default.createDirectory(at: trash, withIntermediateDirectories: true)
            try FileManager.default.moveItem(at: url, to: trash.appendingPathComponent(url.lastPathComponent))
        })
    }

    func reopen() -> LibraryBackupService { Self.service(database, root) }
}
