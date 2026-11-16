// 本文件管理可重建的 CoverVectors.sqlite 缓存，封面向量不写入主业务库。

import CSQLiteVec
import Foundation
import GRDB

final class SQLiteCoverVectorRepository: CoverVectorRepository {
    private let dbQueue: DatabaseQueue

    init(path: String) throws {
        var configuration = Configuration()
        configuration.busyMode = .timeout(5)
        configuration.prepareDatabase { db in
            try db.execute(sql: "PRAGMA foreign_keys = ON")
            try db.execute(sql: "PRAGMA journal_mode = WAL")
            guard let connection = db.sqliteConnection else {
                throw NyaEHError.coverVectorStorageUnavailable
            }
            // sqlite-vec 只加载在封面向量缓存库中；主库不依赖这个扩展，删除缓存后可完整重建。
            let code = nyaeh_sqlite_vec_init(connection)
            guard code == 0 else {
                throw NyaEHError.coverVectorStorageUnavailable
            }
        }
        dbQueue = try DatabaseQueue(path: path, configuration: configuration)
        try migrate()
    }

    static func appDefault() throws -> SQLiteCoverVectorRepository {
        let appDirectory = try AppDataDirectory.rootURL()
        let databaseURL = appDirectory.appendingPathComponent("CoverVectors.sqlite")
        return try SQLiteCoverVectorRepository(path: databaseURL.path)
    }

    func fetchEntry(bookID: LibraryBook.DatabaseID) throws -> CoverVectorEntry? {
        try dbQueue.read { db in
            try Row.fetchOne(
                db,
                sql: """
                    SELECT book_id, cover_hash, vision_revision, element_type,
                           element_count, feature_data, failure_message, created_at, updated_at
                    FROM cover_vector_entries
                    WHERE book_id = ?
                    """,
                arguments: [bookID]
            ).map(Self.entry(from:))
        }
    }

    func upsertVector(_ vector: CoverFeatureVector) throws {
        try dbQueue.write { db in
            try ensureVectorTable(db, elementCount: vector.elementCount)
            let now = Timestamp.nowMilliseconds()
            // rowid 与 library_books.id 对齐，便于近邻结果直接映射回书籍；跨库一致性按 best effort 维护。
            try db.execute(
                sql: "DELETE FROM cover_vector_embeddings WHERE rowid = ?",
                arguments: [vector.bookID]
            )
            try db.execute(
                sql: """
                    INSERT INTO cover_vector_entries (
                        book_id, cover_hash, vision_revision, element_type, element_count,
                        feature_data, failure_message, created_at, updated_at
                    ) VALUES (?, ?, ?, ?, ?, ?, NULL, ?, ?)
                    ON CONFLICT(book_id) DO UPDATE SET
                        cover_hash = excluded.cover_hash,
                        vision_revision = excluded.vision_revision,
                        element_type = excluded.element_type,
                        element_count = excluded.element_count,
                        feature_data = excluded.feature_data,
                        failure_message = NULL,
                        updated_at = excluded.updated_at
                    """,
                arguments: [
                    vector.bookID,
                    vector.coverHash,
                    vector.visionRevision,
                    vector.elementType,
                    vector.elementCount,
                    vector.featureData,
                    now,
                    now
                ]
            )
            try db.execute(
                sql: """
                    INSERT INTO cover_vector_embeddings(rowid, embedding)
                    VALUES (?, vec_f32(?))
                    """,
                arguments: [vector.bookID, vector.featureData]
            )
        }
    }

    func markFailure(bookID: LibraryBook.DatabaseID, coverHash: String?, message: String) throws {
        try dbQueue.write { db in
            let now = Timestamp.nowMilliseconds()
            try db.execute(
                sql: """
                    INSERT INTO cover_vector_entries (
                        book_id, cover_hash, vision_revision, element_type, element_count,
                        feature_data, failure_message, created_at, updated_at
                    ) VALUES (?, ?, NULL, NULL, NULL, NULL, ?, ?, ?)
                    ON CONFLICT(book_id) DO UPDATE SET
                        cover_hash = excluded.cover_hash,
                        vision_revision = NULL,
                        element_type = NULL,
                        element_count = NULL,
                        feature_data = NULL,
                        failure_message = excluded.failure_message,
                        updated_at = excluded.updated_at
                    """,
                arguments: [bookID, coverHash, message, now, now]
            )
            if try db.tableExists("cover_vector_embeddings") {
                try db.execute(
                    sql: "DELETE FROM cover_vector_embeddings WHERE rowid = ?",
                    arguments: [bookID]
                )
            }
        }
    }

    func deleteVector(bookID: LibraryBook.DatabaseID) throws {
        try dbQueue.write { db in
            try db.execute(sql: "DELETE FROM cover_vector_entries WHERE book_id = ?", arguments: [bookID])
            if try db.tableExists("cover_vector_embeddings") {
                try db.execute(sql: "DELETE FROM cover_vector_embeddings WHERE rowid = ?", arguments: [bookID])
            }
        }
    }

    func pruneOrphanedVectors(existingBookIDs: Set<LibraryBook.DatabaseID>) throws -> Int {
        try dbQueue.write { db in
            let storedBookIDs = Set(try Int64.fetchAll(db, sql: "SELECT book_id FROM cover_vector_entries"))
            let orphanedBookIDs = storedBookIDs.subtracting(existingBookIDs)
            guard !orphanedBookIDs.isEmpty else {
                return 0
            }

            let placeholders = Array(repeating: "?", count: orphanedBookIDs.count).joined(separator: ",")
            let sortedBookIDs = orphanedBookIDs.sorted()
            try db.execute(
                sql: "DELETE FROM cover_vector_entries WHERE book_id IN (\(placeholders))",
                arguments: StatementArguments(sortedBookIDs)
            )
            if try db.tableExists("cover_vector_embeddings") {
                try db.execute(
                    sql: "DELETE FROM cover_vector_embeddings WHERE rowid IN (\(placeholders))",
                    arguments: StatementArguments(sortedBookIDs)
                )
            }
            return orphanedBookIDs.count
        }
    }

    func clear() throws {
        try dbQueue.write { db in
            try db.execute(sql: "DROP TABLE IF EXISTS cover_vector_embeddings")
            try db.execute(sql: "DELETE FROM cover_vector_entries")
            try db.execute(sql: "DELETE FROM cover_vector_state")
        }
    }

    func storedVectorCount() throws -> Int {
        try dbQueue.read { db in
            try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM cover_vector_entries WHERE feature_data IS NOT NULL"
            ) ?? 0
        }
    }

    func storedFailureCount() throws -> Int {
        try dbQueue.read { db in
            try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM cover_vector_entries WHERE failure_message IS NOT NULL"
            ) ?? 0
        }
    }

    func indexedBookIDs() throws -> Set<LibraryBook.DatabaseID> {
        try dbQueue.read { db in
            Set(try Int64.fetchAll(
                db,
                sql: "SELECT book_id FROM cover_vector_entries WHERE feature_data IS NOT NULL"
            ))
        }
    }

    func nearestNeighbors(bookID: LibraryBook.DatabaseID, limit: Int) throws -> [CoverVectorNeighbor] {
        guard limit > 0 else {
            return []
        }
        return try dbQueue.read { db in
            guard try db.tableExists("cover_vector_embeddings"),
                  let data = try Data.fetchOne(
                    db,
                    sql: "SELECT feature_data FROM cover_vector_entries WHERE book_id = ? AND feature_data IS NOT NULL",
                    arguments: [bookID]
                  ) else {
                return []
            }
            return try Row.fetchAll(
                db,
                sql: """
                    SELECT rowid, distance
                    FROM cover_vector_embeddings
                    WHERE embedding MATCH vec_f32(?)
                    ORDER BY distance
                    LIMIT ?
                    """,
                arguments: [data, limit + 1]
            )
            .compactMap { row in
                let neighborID: Int64 = row["rowid"]
                guard neighborID != bookID else {
                    return nil
                }
                let l2Distance: Double = row["distance"]
                return CoverVectorNeighbor(
                    bookID: neighborID,
                    distance: l2Distance * l2Distance
                )
            }
            .prefix(limit)
            .map { $0 }
        }
    }

    func nearestNeighbors(query: CoverFeatureQuery, limit: Int) throws -> [CoverVectorNeighbor] {
        guard limit > 0 else {
            return []
        }
        return try dbQueue.read { db in
            guard try db.tableExists("cover_vector_embeddings") else {
                return []
            }
            let storedElementCount = try Int.fetchOne(
                db,
                sql: "SELECT CAST(value AS INTEGER) FROM cover_vector_state WHERE key = 'element_count'"
            )
            guard storedElementCount == query.elementCount,
                  query.featureData.count == query.elementCount * MemoryLayout<Float>.size else {
                throw NyaEHError.coverVectorSchemaMismatch
            }

            return try Row.fetchAll(
                db,
                sql: """
                    SELECT rowid, distance
                    FROM cover_vector_embeddings
                    WHERE embedding MATCH vec_f32(?)
                    ORDER BY distance
                    LIMIT ?
                    """,
                arguments: [query.featureData, limit]
            ).map { row in
                let l2Distance: Double = row["distance"]
                return CoverVectorNeighbor(
                    bookID: row["rowid"],
                    distance: l2Distance * l2Distance
                )
            }
        }
    }

    private func migrate() throws {
        try dbQueue.write { db in
            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS cover_vector_entries (
                    book_id INTEGER PRIMARY KEY,
                    cover_hash TEXT,
                    vision_revision INTEGER,
                    element_type INTEGER,
                    element_count INTEGER,
                    feature_data BLOB,
                    failure_message TEXT,
                    created_at INTEGER NOT NULL,
                    updated_at INTEGER NOT NULL
                );

                CREATE TABLE IF NOT EXISTS cover_vector_state (
                    key TEXT PRIMARY KEY,
                    value TEXT NOT NULL
                );
                """)
        }
    }

    private func ensureVectorTable(_ db: Database, elementCount: Int) throws {
        if try db.tableExists("cover_vector_embeddings") {
            let existing = try Int.fetchOne(
                db,
                sql: "SELECT CAST(value AS INTEGER) FROM cover_vector_state WHERE key = 'element_count'"
            )
            guard existing == elementCount else {
                throw NyaEHError.coverVectorSchemaMismatch
            }
            return
        }

        try db.execute(sql: "CREATE VIRTUAL TABLE cover_vector_embeddings USING vec0(embedding float[\(elementCount)])")
        try db.execute(
            sql: """
                INSERT INTO cover_vector_state(key, value)
                VALUES ('element_count', ?)
                ON CONFLICT(key) DO UPDATE SET value = excluded.value
                """,
            arguments: ["\(elementCount)"]
        )
    }

    private static func entry(from row: Row) -> CoverVectorEntry {
        CoverVectorEntry(
            bookID: row["book_id"],
            coverHash: row["cover_hash"],
            visionRevision: row["vision_revision"],
            elementType: row["element_type"],
            elementCount: row["element_count"],
            featureData: row["feature_data"],
            failureMessage: row["failure_message"],
            createdAt: row["created_at"],
            updatedAt: row["updated_at"]
        )
    }
}
