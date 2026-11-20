import Foundation
import GRDB
import Testing
@testable import NyaEHCore

@Suite("Deletion consistency")
struct LibraryDeletionTests {
    private struct Context {
        let db: DatabaseQueue
        let books: SQLiteLibraryBookRepository
        let versions: SQLiteVersionRecommendationRepository
        let collections: SQLiteCollectionRecommendationRepository
        init() throws {
            db = try DatabaseQueue()
            try DatabaseMigrator.nyaeh.migrate(db)
            books = SQLiteLibraryBookRepository(dbQueue: db)
            versions = SQLiteVersionRecommendationRepository(dbQueue: db)
            collections = SQLiteCollectionRecommendationRepository(dbQueue: db)
        }
        func book(_ name: String) throws -> LibraryBook {
            try books.insert(LibraryBook(title: name, hash: "same-hash", filepath: "/nonexistent-nyaeh-tests/\(UUID())/\(name).cbz", type: .archive, fileCount: 2, bundleSize: 10, mtime: 1, status: .correct, date: 1))
        }
        func service(trash: any LibrarySourceTrashing = TestTrash()) -> BookLibraryService {
            BookLibraryService(bookRepository: books, metadataRepository: SQLiteGalleryMetadataRepository(dbQueue: db), sourceTrash: trash)
        }
    }

    @Test("Deleting one of two members removes both create recommendations, including incremental no-op")
    func twoToOne() throws {
        let c = try Context()
        let a = try c.book("Same comic"), b = try c.book("Same comic")
        let ids = [a.databaseID!, b.databaseID!]
        try c.versions.replacePending(with: [.init(kind: .createGroup, bookIDs: ids, score: 99, reasons: [], fingerprint: "create:\(ids.map(String.init).joined(separator: "."))")])
        try c.collections.replacePending(with: [.init(kind: .createCollection, bookIDs: ids, score: 99, reasons: [], fingerprint: "collection-create:\(ids.map(String.init).joined(separator: "."))")])
        try c.books.delete(id: a.databaseID!)
        #expect(try c.versions.fetchPending(kind: .createGroup, targetVersionGroupID: nil).isEmpty)
        #expect(try c.collections.fetchPending(kind: .createCollection, targetCollectionID: nil).isEmpty)
        #expect(try c.versions.pendingCount(involving: [b.databaseID!]) == 0)
        _ = try VersionRecommendationService(bookRepository: c.books, recommendationRepository: c.versions).updateRecommendationsIncrementally()
        #expect(try c.versions.fetchPending(kind: .createGroup, targetVersionGroupID: nil).isEmpty)
        #expect(try c.db.read { try Row.fetchAll($0, sql: "PRAGMA foreign_key_check") }.isEmpty)
    }

    @Test("Deleted primary is replaced, singleton dissolves, collection order and user state survive")
    func normalizeMemberships() throws {
        let c = try Context()
        let a = try c.book("a"), b = try c.book("b"), d = try c.book("c")
        try c.db.write { db in
            try db.execute(sql: "INSERT INTO book_version_groups(id, created_at, updated_at) VALUES(1, 1, 1)")
            try db.execute(sql: "INSERT INTO book_collections(id, name, created_at, updated_at) VALUES(1, 'Series', 1, 1)")
            try db.execute(sql: "UPDATE library_books SET version_group_id = 1, collection_id = 1, collection_order = 7, is_primary_version = (id = ?), hidden_book = 1, mark = 1, is_user_hidden = 1", arguments: [a.databaseID])
        }
        try c.books.delete(id: a.databaseID!)
        let newPrimary = try #require(try c.books.fetch(id: b.databaseID!))
        #expect(newPrimary.isPrimaryVersion)
        #expect(newPrimary.collectionOrder == 7)
        #expect(newPrimary.mark && newPrimary.isUserHidden)
        try c.books.delete(id: b.databaseID!)
        let only = try #require(try c.books.fetch(id: d.databaseID!))
        #expect(only.versionGroupID == nil && only.isPrimaryVersion)
        #expect(only.collectionID == 1 && only.collectionOrder == 7 && only.hiddenBook)
        try c.books.delete(id: d.databaseID!)
        #expect(try c.db.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM book_collections") } == 0)
    }

    @Test("Trash failure preserves book, memberships and recommendations")
    func failedTrash() throws {
        let c = try Context()
        let a = try c.book("a"), b = try c.book("b")
        try c.versions.replacePending(with: [.init(kind: .createGroup, bookIDs: [a.databaseID!, b.databaseID!], score: 99, reasons: [], fingerprint: "test")])
        #expect(throws: Error.self) { try c.service(trash: TestTrash(fail: true)).deleteBookAndSourceFile(a) }
        #expect(try c.books.fetch(id: a.databaseID!) != nil)
        #expect(try c.versions.fetchPending(kind: .createGroup, targetVersionGroupID: nil).count == 1)
        #expect(try c.books.deletionOperation(bookID: a.databaseID!)?.stage == "needsAttention")
    }

    @Test("Committed source phase can recover without touching a replacement source")
    func recoverAfterDatabaseFailure() throws {
        let c = try Context()
        let a = try c.book("a")
        _ = try c.books.prepareDeletion(bookID: a.databaseID!, identity: "old")
        try c.books.updateDeletion(bookID: a.databaseID!, stage: "sourceHandled", error: nil)
        try c.db.write { db in
            try db.execute(sql: "CREATE TRIGGER fail_delete BEFORE DELETE ON library_books BEGIN SELECT RAISE(ABORT, 'forced'); END")
        }
        #expect(throws: Error.self) { try c.service(trash: TestTrash(fail: true)).deleteBookAndSourceFile(a) }
        #expect(try c.books.fetch(id: a.databaseID!) != nil)
        #expect(try c.books.deletionOperation(bookID: a.databaseID!)?.stage == "sourceHandled")
        try c.db.write { try $0.execute(sql: "DROP TRIGGER fail_delete") }
        // This trash implementation throws if asked to touch a source; recovery must only commit SQLite.
        try c.service(trash: TestTrash(fail: true)).recoverLibraryDeletions()
        #expect(try c.books.fetch(id: a.databaseID!) == nil)
        #expect(try c.books.deletionOperations().isEmpty)
    }

    @Test("Uncertain moves are not retried on launch and changed sources are never trashed")
    func uncertainAndChanged() throws {
        let c = try Context()
        let a = try c.book("a")
        _ = try c.books.prepareDeletion(bookID: a.databaseID!, identity: "original")
        try c.books.updateDeletion(bookID: a.databaseID!, stage: "moving", error: nil)
        try c.service(trash: TestTrash(fail: true)).recoverLibraryDeletions()
        #expect(try c.books.fetch(id: a.databaseID!) != nil)
        #expect(throws: Error.self) { try c.service().deleteBookAndSourceFile(a) }
        #expect(try c.books.fetch(id: a.databaseID!) != nil)
    }

    @Test("Missing source deletes record; inaccessible source does not")
    func sourceErrors() throws {
        let c = try Context()
        let a = try c.book("missing"), b = try c.book("denied")
        try c.service(trash: TestTrash(missing: true)).deleteBookAndSourceFile(a)
        #expect(try c.books.fetch(id: a.databaseID!) == nil)
        #expect(throws: Error.self) { try c.service(trash: TestTrash(denied: true)).deleteBookAndSourceFile(b) }
        #expect(try c.books.fetch(id: b.databaseID!) != nil)
    }

    @Test("Deletion keeps original batch total, records deleted count, and completes an empty batch")
    func batchDeletion() throws {
        let c = try Context()
        let a = try c.book("a"), b = try c.book("b")
        let pipeline = SQLiteImportPipelineRepository(dbQueue: c.db)
        // Correct manually fetched metadata enters version analysis through reconciliation after unscanned creation.
        try c.db.write { db in
            try db.execute(sql: "INSERT INTO import_pipeline_batches(id, status, stage, total_count, created_at, updated_at) VALUES(1, 'waitingForReview', 'versionReview', 2, 1, 1)")
            for book in [a,b] {
                try db.execute(sql: "INSERT INTO import_pipeline_items(batch_id, book_id, source_hash, stage, created_at, updated_at) VALUES(1, ?, 'same-hash', 'versionReviewPending', 1, 1)", arguments: [book.databaseID])
            }
        }
        try c.books.delete(id: a.databaseID!)
        let batch = try #require(try pipeline.fetchActiveBatch())
        #expect(batch.totalCount == 2 && batch.deletedCount == 1 && batch.reviewCount == 0)
        try c.books.delete(id: b.databaseID!)
        #expect(try pipeline.fetchActiveBatch() == nil)
        #expect(try c.db.read { try Int.fetchOne($0, sql: "SELECT deleted_count FROM import_pipeline_batches WHERE id = 1") } == 2)
    }

    @Test("Valid single add and unrelated dismissed decisions survive deletion")
    func validAddSurvives() throws {
        let c = try Context()
        let a = try c.book("a"), b = try c.book("b"), candidate = try c.book("candidate"), unrelated = try c.book("unrelated")
        try c.db.write { db in
            try db.execute(sql: "INSERT INTO book_version_groups(id, created_at, updated_at) VALUES(1, 1, 1)")
            try db.execute(sql: "UPDATE library_books SET version_group_id = 1, is_primary_version = (id = ?) WHERE id IN (?, ?)", arguments: [a.databaseID, a.databaseID, b.databaseID])
        }
        try c.versions.replacePending(with: [.init(kind: .addToGroup, targetVersionGroupID: 1, bookIDs: [candidate.databaseID!], score: 99, reasons: [], fingerprint: "add:1:\(candidate.databaseID!)")])
        try c.books.delete(id: unrelated.databaseID!)
        #expect(try c.versions.fetchPending(kind: .addToGroup, targetVersionGroupID: 1).count == 1)
        let row = try #require(try c.versions.fetchPending(kind: .addToGroup, targetVersionGroupID: 1).first)
        try c.versions.updateStatus(recommendationID: row.databaseID!, status: .dismissed)
        try c.db.write { try LibraryConsistency.repair($0) }
        #expect(try c.db.read { try String.fetchOne($0, sql: "SELECT status FROM version_recommendations WHERE id = ?", arguments: [row.databaseID]) } == "dismissed")
    }

    @Test("Deletion cancels an in-flight metadata request before removing the book")
    @MainActor
    func storeCancelsMetadata() async throws {
        let c = try Context()
        var a = try c.book("metadata")
        a.hash = String(repeating: "a", count: 40)
        a = try c.books.update(a)
        let client = DeletionHTTPClient()
        let store = CatalogStore(service: BookLibraryService(
            bookRepository: c.books,
            metadataRepository: SQLiteGalleryMetadataRepository(dbQueue: c.db),
            metadataFetchService: GalleryMetadataFetchService(httpClient: client),
            sourceTrash: TestTrash()
        ))
        store.refresh()
        store.selectedBookID = a.id
        let request = Task { await store.fetchMetadataForSelectedBook(configuration: .init(), localizer: .init(language: .en)) }
        for _ in 0..<1000 {
            if await client.started { break }
            try await Task.sleep(for: .milliseconds(1))
        }
        #expect(await client.started)
        await store.deleteBookAndSourceFile(a)
        await request.value
        #expect(await client.cancelled)
        #expect(try c.books.fetch(id: a.databaseID!) == nil)
        #expect(store.books.isEmpty && !store.isDeletingBook && store.loadError == nil)
        store.saveReadingProgress(for: a, currentPageIndex: 1, totalPages: 2)
        #expect(store.readingStates.isEmpty)
    }

    @Test("Deletion reloads SQL search snapshots and clears removed entities")
    @MainActor
    func deletionReloadsSearch() async throws {
        let c = try Context()
        let a = try c.book("Search-delete"), b = try c.book("Search-keep")
        let store = CatalogStore(service: BookLibraryService(
            bookRepository: c.books,
            metadataRepository: SQLiteGalleryMetadataRepository(dbQueue: c.db),
            searchRepository: SQLiteLibrarySearchRepository(dbQueue: c.db),
            sourceTrash: TestTrash()
        ))
        store.refresh()
        store.submitAdvancedSearch(isTagTranslationEnabled: true)
        for _ in 0..<1000 where store.isAdvancedSearchLoading {
            try await Task.sleep(for: .milliseconds(1))
        }
        #expect(store.advancedSearchTotalCount == 2)
        await store.deleteBookAndSourceFile(a)
        for _ in 0..<1000 where store.isAdvancedSearchLoading {
            try await Task.sleep(for: .milliseconds(1))
        }
        #expect(store.advancedSearchError == nil)
        #expect(store.advancedSearchTotalCount == 1)
        #expect(store.advancedSearchResults.map(\.id) == [b.id])
        await store.deleteBookAndSourceFile(b)
        for _ in 0..<1000 where store.isAdvancedSearchLoading {
            try await Task.sleep(for: .milliseconds(1))
        }
        #expect(store.advancedSearchTotalCount == 0)
        #expect(store.advancedSearchDisplayItems.isEmpty)
    }

    @Test("Upgrade from v19 backs up the old database before repairing it")
    func migrationBackup() throws {
        let root = TestRunResources.directory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let path = root.appendingPathComponent("NyaEH.sqlite").path
        let old = try DatabaseQueue(path: path)
        try DatabaseMigrator.nyaeh.migrate(old, upTo: "v19_import_pipeline")
        try old.write { try $0.execute(sql: "INSERT INTO book_collections(id, name, created_at, updated_at) VALUES(1, 'empty', 1, 1)") }
        let upgraded = try DatabaseManager(path: path)
        #expect(try upgraded.dbQueue.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM book_collections") } == 0)
        let packages = try FileManager.default.contentsOfDirectory(at: root.appendingPathComponent("Backups"), includingPropertiesForKeys: nil)
        #expect(packages.count == 1)
        let backup = try DatabaseQueue(path: packages[0].appendingPathComponent("NyaEH.sqlite").path)
        #expect(try backup.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM book_collections") } == 1)
        _ = try DatabaseManager(path: path)
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("Backups").path).count == 1)
    }

    @Test("Cache cleanup failure does not undo deletion and can be retried independently")
    func cleanupRetry() throws {
        let c = try Context()
        var book = try c.book("cover")
        book.coverPath = "/isolated-fake-cover"
        book = try c.books.update(book)
        let failing = BookLibraryService(bookRepository: c.books,
            metadataRepository: SQLiteGalleryMetadataRepository(dbQueue: c.db),
            coverCache: DeletionCoverCache(fails: true), sourceTrash: TestTrash())
        let result = try failing.deleteBookAndSourceFile(book)
        #expect(result.cleanupWarning != nil)
        #expect(try c.books.fetch(id: book.databaseID!) == nil)
        #expect(try c.books.deletionOperation(bookID: book.databaseID!)?.stage == "cleanupPending")
        let retry = BookLibraryService(bookRepository: c.books,
            metadataRepository: SQLiteGalleryMetadataRepository(dbQueue: c.db),
            coverCache: DeletionCoverCache(fails: false), sourceTrash: TestTrash(fail: true))
        try retry.recoverLibraryDeletions()
        #expect(try c.books.deletionOperations().isEmpty)
    }

    @Test("Rejected source removal leaves the retained book writable")
    func failedMoveRetainsUsability() throws {
        let c = try Context()
        var book = try c.book("retained")
        #expect(throws: Error.self) { try c.service(trash: TestTrash(fail: true)).deleteBookAndSourceFile(book) }
        book.mark = true
        #expect(try c.books.update(book).mark)
    }

    @Test("Old recommendation and metadata snapshots cannot write a deleted book back")
    func staleSnapshots() throws {
        let c = try Context()
        let a = try c.book("a"), b = try c.book("b"), third = try c.book("third")
        let ids = [a.databaseID!, b.databaseID!, third.databaseID!]
        let candidate = VersionRecommendationCandidate(kind: .createGroup, bookIDs: ids, score: 99, reasons: [], fingerprint: "create:\(ids.map(String.init).joined(separator: "."))")
        try c.versions.replacePending(with: [candidate])
        let recommendation = try #require(try c.versions.fetchPending(kind: .createGroup, targetVersionGroupID: nil).first)
        try c.books.delete(id: a.databaseID!)
        #expect(throws: Error.self) { try c.books.update(a) }
        try c.versions.replacePending(with: [candidate])
        #expect(try c.versions.fetchPending(kind: .createGroup, targetVersionGroupID: nil).isEmpty)
        let groups = SQLiteVersionGroupRepository(dbQueue: c.db)
        #expect(throws: Error.self) { try groups.acceptCreateVersionGroupRecommendation(recommendationID: recommendation.databaseID!, bookIDs: ids, automaticLabels: [:]) }
        #expect(try groups.fetchAll().isEmpty)
    }

    @Test("Backup failure stops the migration before historical groups are modified")
    func backupFailureStopsMigration() throws {
        let root = TestRunResources.directory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let path = root.appendingPathComponent("NyaEH.sqlite").path
        let old = try DatabaseQueue(path: path)
        try DatabaseMigrator.nyaeh.migrate(old, upTo: "v19_import_pipeline")
        try old.write { try $0.execute(sql: "INSERT INTO book_collections(id, name, created_at, updated_at) VALUES(1, 'empty', 1, 1)") }
        try Data("not a directory".utf8).write(to: root.appendingPathComponent("Backups"))
        #expect(throws: Error.self) { try DatabaseManager(path: path) }
        #expect(try old.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM book_collections") } == 1)
        #expect(try old.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM grdb_migrations WHERE identifier = 'v20_deletion_consistency'") } == 0)
    }

    @Test("Migration repairs historical singleton recommendations and groups and is idempotent")
    func historicalRepair() throws {
        let db = try DatabaseQueue()
        try DatabaseMigrator.nyaeh.migrate(db, upTo: "v19_import_pipeline")
        try db.write { db in
            try db.execute(sql: "INSERT INTO book_version_groups(id, created_at, updated_at) VALUES(1, 1, 1)")
            try db.execute(sql: "INSERT INTO book_collections(id, name, created_at, updated_at) VALUES(1, 'empty', 1, 1)")
            try db.execute(sql: "INSERT INTO library_books(title, hash, filepath, type, status, date, created_at, updated_at, version_group_id, is_primary_version, hidden_book) VALUES('a', 'a', '/missing/a', 'archive', 'correct', 1, 1, 1, 1, 0, 1)")
            try db.execute(sql: "INSERT INTO version_recommendations(id, kind, score, reasons, fingerprint, status, created_at, updated_at) VALUES(1, 'create_group', 99, '[]', 'create:1.2', 'pending', 1, 1)")
            try db.execute(sql: "INSERT INTO version_recommendation_members(recommendation_id, book_id, position) VALUES(1, 1, 0)")
        }
        try DatabaseMigrator.nyaeh.migrate(db)
        let values = try db.read { db in
            (try String.fetchOne(db, sql: "SELECT status FROM version_recommendations WHERE id = 1"),
             try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM book_version_groups"),
             try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM book_collections"),
             try Int.fetchOne(db, sql: "SELECT hidden_book FROM library_books WHERE id = 1"))
        }
        #expect(values.0 == "stale")
        #expect(values.1 == 0 && values.2 == 0 && values.3 == 0)
        let invalid = try db.write { db in
            try LibraryConsistency.repair(db)
            return try LibraryConsistency.invalidateRecommendations(db)
        }
        #expect(invalid == 0)
    }
}

private struct TestTrash: LibrarySourceTrashing {
    var fail = false
    var missing = false
    var denied = false
    func identity(at url: URL) throws -> String? {
        if denied { throw CocoaError(.fileReadNoPermission) }
        return missing ? nil : "identity"
    }
    func trash(_ url: URL) throws {
        if fail { throw CocoaError(.fileWriteNoPermission) }
    }
}

private actor DeletionHTTPClient: GalleryMetadataHTTPClient {
    var started = false
    var cancelled = false
    func data(for request: URLRequest, proxySettings: NetworkProxySettings) async throws -> (Data, HTTPURLResponse) {
        started = true
        do { try await Task.sleep(for: .seconds(30)) }
        catch { cancelled = Task.isCancelled; throw error }
        throw URLError(.timedOut)
    }
}

private struct DeletionCoverCache: CoverCaching {
    var fails: Bool
    func cacheCover(originalData: Data) throws -> CachedCover? { nil }
    func cachedCoverExists(path: String?) -> Bool { true }
    func removeCachedCover(path: String?) throws { if fails { throw CocoaError(.fileWriteNoPermission) } }
}
