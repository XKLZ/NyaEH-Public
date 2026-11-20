import Foundation
import GRDB
import Testing
@testable import NyaEHCore

@Suite("Version group series membership")
struct SeriesMembershipTests {
    @Test("group creation inherits the existing series slot in either input order", arguments: [true, false])
    func creationInheritsSeries(unassignedFirst: Bool) throws {
        let fixture = try makeFixture()
        defer { fixture.remove() }
        let series = try fixture.series("Series")
        let original = try fixture.book("original", series: series, order: 2)
        let translation = try fixture.book("translation")
        let ids = unassignedFirst ? [translation, original] : [original, translation]
        let group = try fixture.groups.createVersionGroup(bookIDs: ids)
        let groupID = try #require(group.databaseID)
        let versions = try fixture.books.fetchByVersionGroupID(groupID)
        #expect(versions.count == 2)
        #expect(versions.allSatisfy { $0.collectionID == series && $0.collectionOrder == 2 && $0.hiddenBook })
        #expect(versions.first(where: \.isPrimaryVersion)?.databaseID == ids.first)
    }

    @Test("adding either version preserves its existing slot and switching the primary keeps it")
    func repeatedAdditionAndPrimarySwitch() throws {
        let fixture = try makeFixture()
        defer { fixture.remove() }
        let series = try fixture.series("Series")
        let original = try fixture.book("original")
        let translation = try fixture.book("translation")
        _ = try fixture.book("later", series: series, order: 4)
        _ = try fixture.groups.createVersionGroup(bookIDs: [translation, original])
        try fixture.setSeries(series, order: 2, bookID: original)

        try fixture.collections.addBookAndVersions(bookID: original, to: series)
        let committed = try fixture.books.fetchByCollectionID(series)
        try fixture.collections.addBookAndVersions(bookID: translation, to: series)
        #expect(try fixture.books.fetchByCollectionID(series) == committed)
        try fixture.groups.setPrimary(bookID: original)
        #expect(try fixture.books.fetch(id: original)?.isPrimaryVersion == true)
        #expect(try fixture.books.fetch(id: translation)?.collectionOrder == 2)
        #expect(try fixture.books.fetch(id: original)?.collectionOrder == 2)
    }

    @Test("conflicting series roll back group creation and batch addition")
    func conflictRollsBack() throws {
        let fixture = try makeFixture()
        defer { fixture.remove() }
        let first = try fixture.series("First")
        let second = try fixture.series("Second")
        let a = try fixture.book("a", series: first, order: 1)
        let b = try fixture.book("b", series: second, order: 2)
        let c = try fixture.book("c")
        #expect(throws: NyaEHError.self) { try fixture.groups.createVersionGroup(bookIDs: [a, b]) }
        #expect(try fixture.groups.fetchAll().isEmpty)
        let group = try fixture.groups.createVersionGroup(bookIDs: [a])
        let groupID = try #require(group.databaseID)
        #expect(throws: NyaEHError.self) { try fixture.groups.addBooks(bookIDs: [c, b], to: groupID) }
        #expect(try fixture.books.fetchByVersionGroupID(groupID).map(\.databaseID) == [a])
        #expect(try fixture.books.fetch(id: c)?.collectionID == nil)

        try fixture.groups.addBook(bookID: c, to: groupID, isPrimary: false)
        try fixture.setSeries(second, order: 8, bookID: c)
        #expect(try fixture.backups.healthCheck().issues.contains { !$0.repairable
            && $0.detail.contains("First") && $0.detail.contains("Second")
        })
        _ = try fixture.backups.repairDerivedData(books: [], tagRepository: nil, labelRepository: nil)
        #expect(try fixture.books.fetch(id: a)?.collectionID == first)
        #expect(try fixture.books.fetch(id: c)?.collectionID == second)
        try fixture.collections.addBookAndVersions(bookID: a, to: second)
        #expect(try fixture.books.fetch(id: a)?.collectionOrder == 8)
        #expect(try fixture.books.fetch(id: c)?.collectionOrder == 8)
    }

    @Test("v22 backs up and repairs known series, restoring a v21 backup reruns repair")
    func migrationBacksUpAndRepairs() throws {
        let fixture = try makeFixture()
        defer { fixture.remove() }
        let series = try fixture.series("Series")
        let original = try fixture.book("original")
        let translation = try fixture.book("translation")
        _ = try fixture.book("later", series: series, order: 4)
        _ = try fixture.groups.createVersionGroup(bookIDs: [translation, original])
        try fixture.setSeries(series, order: 2, bookID: original)

        let primary = try fixture.book("primary")
        let secondary = try fixture.book("secondary")
        _ = try fixture.groups.createVersionGroup(bookIDs: [primary, secondary])
        try fixture.setSeries(series, order: 6, bookID: primary)
        try fixture.setSeries(series, order: 7, bookID: secondary)

        let missingOrderIDs = try (0..<2).map { index in
            let first = try fixture.book("missing-order-\(index)-first")
            let second = try fixture.book("missing-order-\(index)-second")
            _ = try fixture.groups.createVersionGroup(bookIDs: [first, second])
            try fixture.setSeries(series, order: nil, bookID: first)
            return [first, second]
        }

        try fixture.database.dbQueue.write { db in
            try db.execute(sql: """
                INSERT INTO collection_recommendations (id, kind, target_collection_id, score, fingerprint, status, created_at, updated_at)
                VALUES (1, 'add_to_collection', ?, 90, ?, 'pending', 1, 1)
                """, arguments: [series, "collection-add:\(series):\(translation)"])
            try db.execute(sql: "INSERT INTO collection_recommendation_members VALUES (1, ?, 0)", arguments: [translation])
            try db.execute(sql: "DELETE FROM grdb_migrations WHERE identifier = 'v22_version_series_membership'")
        }
        #expect(LibraryBackupService.currentSchemaVersion == 22)
        let upgraded = try DatabaseManager(path: fixture.database.path)
        let books = SQLiteLibraryBookRepository(dbQueue: upgraded.dbQueue)
        #expect(try books.fetch(id: translation)?.collectionOrder == 2)
        #expect(try books.fetch(id: secondary)?.collectionOrder == 6)
        for (index, ids) in missingOrderIDs.enumerated() {
            for id in ids {
                #expect(try books.fetch(id: id)?.collectionOrder == 7 + index)
            }
        }
        #expect(try upgraded.dbQueue.read { db in
            try String.fetchOne(db, sql: "SELECT status FROM collection_recommendations WHERE id = 1")
        } == "stale")

        let backups = try FileManager.default.contentsOfDirectory(
            at: fixture.root.appendingPathComponent("Backups"), includingPropertiesForKeys: nil
        )
        let preMigration = try #require(backups.first { $0.lastPathComponent.hasPrefix("preMigration-") })
        #expect(try fixture.backups.validate(packageURL: preMigration).schemaVersion == 21)
        let oldDatabase = try DatabaseQueue(path: preMigration.appendingPathComponent("NyaEH.sqlite").path)
        #expect(try SQLiteLibraryBookRepository(dbQueue: oldDatabase).fetch(id: translation)?.collectionID == nil)
        let expected = try books.fetchByCollectionID(series).map(\.collectionOrder)
        _ = try fixture.backups.restore(from: preMigration)
        #expect(try books.fetchByCollectionID(series).map(\.collectionOrder) == expected)
        let beforeRepair = try books.fetchByCollectionID(series)
        _ = try fixture.backups.repairDerivedData(books: [], tagRepository: nil, labelRepository: nil)
        #expect(try books.fetchByCollectionID(series) == beforeRepair)
    }

    @Test("stale scan and metadata snapshots preserve committed series and primary")
    func staleSnapshotsPreserveOrganization() throws {
        let fixture = try makeFixture()
        defer { fixture.remove() }
        let series = try fixture.series("Series")
        let first = try fixture.book("first")
        let second = try fixture.book("second")
        var staleMetadata = try #require(try fixture.books.fetch(id: first))
        var staleScan = try #require(try fixture.books.fetch(id: second))
        let group = try fixture.groups.createVersionGroup(bookIDs: [first, second])
        try fixture.collections.addBookAndVersions(bookID: second, to: series)
        try fixture.groups.setPrimary(bookID: second)

        staleMetadata.title = "Fresh title"
        _ = try fixture.books.updateMetadata(staleMetadata)
        staleScan.coverPath = "fresh-cover.png"
        _ = try fixture.books.applyScanChanges(inserts: [], updates: [staleScan],
                                              seenFilepaths: [staleMetadata.filepath, staleScan.filepath])
        #expect(try fixture.books.fetch(id: first)?.title == "Fresh title")
        #expect(try fixture.books.fetch(id: second)?.coverPath == "fresh-cover.png")
        let members = try fixture.books.fetchByVersionGroupID(try #require(group.databaseID))
        #expect(members.count == 2)
        #expect(members.allSatisfy { $0.collectionID == series && $0.collectionOrder == 0 && $0.hiddenBook })
        #expect(members.first(where: \.isPrimaryVersion)?.databaseID == second)
    }

    private func makeFixture() throws -> Fixture {
        let root = TestRunResources.directory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let database = try DatabaseManager(path: root.appendingPathComponent("NyaEH.sqlite").path)
        return Fixture(root: root, database: database)
    }

    private struct Fixture {
        let root: URL
        let database: DatabaseManager

        var books: SQLiteLibraryBookRepository { .init(dbQueue: database.dbQueue) }
        var collections: SQLiteCollectionRepository { .init(dbQueue: database.dbQueue) }
        var groups: SQLiteVersionGroupRepository { .init(dbQueue: database.dbQueue) }
        var backups: LibraryBackupService { .init(databaseManager: database, appDataURL: root) }

        func series(_ name: String) throws -> Int64 {
            try #require(collections.insert(BookCollection(name: name)).databaseID)
        }

        func book(_ title: String, series: Int64? = nil, order: Int? = nil) throws -> Int64 {
            try #require(books.insert(LibraryBook(title: title, hash: title, filepath: root.appendingPathComponent(title + ".cbz").path,
                                                 type: .archive, status: .correct, date: 0, collectionID: series,
                                                 collectionOrder: order, hiddenBook: series != nil)).databaseID)
        }

        func setSeries(_ series: Int64, order: Int?, bookID: Int64) throws {
            try database.dbQueue.write { db in
                try db.execute(sql: "UPDATE library_books SET collection_id = ?, collection_order = ?, hidden_book = 1 WHERE id = ?",
                               arguments: [series, order, bookID])
            }
        }

        func remove() {
            try? FileManager.default.removeItem(at: root)
        }
    }
}
