import Foundation
import GRDB
import Testing
@testable import NyaEHCore

struct LegacyNamingTests {
    @Test("database promotion includes committed WAL pages and keeps the last active database")
    func promotesWALSnapshot() throws {
        try withDirectory { root in
            let old = root.appendingPathComponent(LegacyNaming.databaseFilename)
            let database = try DatabaseManager(path: old.path)
            let books = SQLiteLibraryBookRepository(dbQueue: database.dbQueue)
            let book = try books.insert(LibraryBook(title: "WAL fixture", hash: "fixture", filepath: "/fixture.cbz", type: .archive, status: .correct, date: 0))
            let wal = URL(fileURLWithPath: old.path + "-wal")
            #expect(try Data(contentsOf: wal).count > 32)

            let current = try DatabaseManager.activeDatabaseURL(in: root)
            #expect(current.lastPathComponent == LibraryBackupService.databaseFilename)
            let copied = try DatabaseManager(path: current.path)
            let copiedBooks = SQLiteLibraryBookRepository(dbQueue: copied.dbQueue)
            #expect(try copiedBooks.fetch(id: #require(book.databaseID))?.title == "WAL fixture")
            try database.dbQueue.write { db in
                try db.execute(sql: "UPDATE library_books SET title = 'Previous database changed'")
            }
            #expect(try DatabaseManager.activeDatabaseURL(in: root) == current)
            #expect(try copiedBooks.fetch(id: #require(book.databaseID))?.title == "WAL fixture")
            #expect(FileManager.default.fileExists(atPath: old.path))
        }
    }

    @Test("invalid legacy data does not create a new database and a subsequent start can retry")
    func rejectsInvalidDatabase() throws {
        try withDirectory { root in
            let old = root.appendingPathComponent(LegacyNaming.databaseFilename)
            let current = root.appendingPathComponent(LibraryBackupService.databaseFilename)
            try Data("not a database".utf8).write(to: old)
            #expect(throws: (any Error).self) { try DatabaseManager.activeDatabaseURL(in: root) }
            #expect(!FileManager.default.fileExists(atPath: current.path))
            #expect(try Data(contentsOf: old) == Data("not a database".utf8))
            try FileManager.default.removeItem(at: old)
            let recovered = try DatabaseManager(path: old.path)
            #expect(try DatabaseManager.activeDatabaseURL(in: root) == current)
            #expect(try recovered.integrityCheck() == ["ok"])
        }
    }

    @Test("a previous backup filename is accepted for validation and restore")
    func restoresPreviousBackup() throws {
        try withDirectory { root in
            let database = try DatabaseManager(path: root.appendingPathComponent(LibraryBackupService.databaseFilename).path)
            let books = SQLiteLibraryBookRepository(dbQueue: database.dbQueue)
            let book = try books.insert(LibraryBook(title: "Archived fixture", hash: "fixture", filepath: "/fixture.cbz", type: .archive, status: .correct, date: 0))
            let backup = LibraryBackupService(databaseManager: database, appDataURL: root)
            let package = root.appendingPathComponent("fixture.nyaehbackup")
            _ = try backup.export(to: package)
            try FileManager.default.moveItem(
                at: package.appendingPathComponent(LibraryBackupService.databaseFilename),
                to: package.appendingPathComponent(LegacyNaming.databaseFilename)
            )
            try database.dbQueue.write { db in
                try db.execute(sql: "UPDATE library_books SET title = 'Current title'")
            }
            _ = try backup.restore(from: package)
            #expect(try books.fetch(id: #require(book.databaseID))?.title == "Archived fixture")
        }
    }

    @MainActor
    @Test("preferences migrate in their own domain without replacing new settings or importing old secrets")
    func migratesPreferencesAndBookmark() throws {
        try withDirectory { root in
            let domain = "dev.gazelee.NyaEH.naming-tests.\(UUID().uuidString)"
            let defaults = try #require(UserDefaults(suiteName: domain))
            defer { defaults.removePersistentDomain(forName: domain) }
            let bookmark = try LibraryBookmarkService.bookmarkData(for: root)
            defaults.set(bookmark, forKey: "TreeC.libraryRootBookmarkData")
            defaults.set(1.75, forKey: "TreeC.reader.display.zoom")
            defaults.set(1.25, forKey: "NyaEH.reader.display.zoom")
            defaults.set("unused-secret", forKey: "TreeC.exhentai.igneous")
            let store = FileCredentialStore(appDataRoot: root)
            try store.set("old-token", forKey: "TreeC.github.updateToken")
            let prefs = AppPreferences(userDefaults: defaults, credentialStore: store, preferencesDomain: domain)
            #expect(prefs.readerDisplayPreferences.zoom == 1.25)
            #expect(prefs.exhentaiIgneous.isEmpty)
            let relaunched = AppPreferences(userDefaults: defaults, credentialStore: store, preferencesDomain: domain)
            #expect(try relaunched.resolvedLibraryRootURL()?.resolvingSymlinksInPath() == root.resolvingSymlinksInPath())
            prefs.exhentaiIgneous = "new-cookie"
            #expect(try store.string(forKey: "TreeC.github.updateToken") == "old-token")
            #expect(try store.string(forKey: "NyaEH.exhentai.igneous") == "new-cookie")
        }
    }

    private func withDirectory(_ body: (URL) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        try body(directory)
    }
}
