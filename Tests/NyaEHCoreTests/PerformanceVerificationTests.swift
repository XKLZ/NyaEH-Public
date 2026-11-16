import Foundation
import GRDB
import Testing
@testable import NyaEHCore

@Suite("Performance verification")
struct PerformanceVerificationTests {
    @Test("synthetic library performance")
    func syntheticLibraryPerformance() throws {
        guard ProcessInfo.processInfo.environment["NYAEH_RUN_PERFORMANCE_TESTS"] == "1" else {
            return
        }

        for count in [5_000, 10_000, 30_000] {
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("NyaEH-Performance-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: directory) }
            let database = try DatabaseManager(path: directory.appendingPathComponent("NyaEH.sqlite").path)
            try populate(database: database, count: count)
            let repository = SQLiteLibrarySearchRepository(dbQueue: database.dbQueue)
            let request = LibrarySearchRequest(page: 1, pageSize: 30)

            let searchStart = Date()
            let response = try repository.search(request)
            let searchElapsed = Date().timeIntervalSince(searchStart)

            let pageStart = Date()
            _ = try repository.search(LibrarySearchRequest(page: max(count / 30, 1), pageSize: 30))
            let pageElapsed = Date().timeIntervalSince(pageStart)

            let facetStart = Date()
            let facets = try repository.tagFacets(request, knownTotalCount: response.totalCount)
            let facetElapsed = Date().timeIntervalSince(facetStart)

            print(
                "NyaEH performance books=\(count) firstPage=\(searchElapsed)s "
                + "deepPage=\(pageElapsed)s facets=\(facetElapsed)s"
            )
            #expect(response.totalCount == count)
            #expect(response.items.count == 30)
            #expect(facets.first?.availableCount == count)
            if count == 30_000 {
                #expect(searchElapsed <= 0.4)
                #expect(pageElapsed <= 0.25)
                #expect(facetElapsed <= 1.2)
            }
        }
    }

    private func populate(database: DatabaseManager, count: Int) throws {
        try database.dbQueue.write { db in
            let bookInsert = try db.makeStatement(sql: """
                INSERT INTO library_books (
                    title, hash, filepath, type, status, date, tags,
                    hidden_book, is_user_hidden, exist, created_at, updated_at
                ) VALUES (?, ?, ?, 'archive', 'correct', ?, '["female:performance"]', 0, 0, 1, ?, ?)
                """)
            let now = Timestamp.nowMilliseconds()
            for index in 0..<count {
                try bookInsert.execute(arguments: [
                    "Book \(String(format: "%06d", index))",
                    "hash-\(index)",
                    "/synthetic/\(index).cbz",
                    now - Int64(index),
                    now - Int64(index),
                    now
                ])
            }
            try db.execute(
                sql: """
                    INSERT INTO tags(namespace, name, raw_value, created_at, updated_at)
                    VALUES ('female', 'performance', 'female:performance', ?, ?)
                    """,
                arguments: [now, now]
            )
            let tagID = db.lastInsertedRowID
            try db.execute(sql: """
                INSERT INTO book_tags(book_id, tag_id)
                SELECT id, ? FROM library_books
                """, arguments: [tagID])
        }
    }
}
