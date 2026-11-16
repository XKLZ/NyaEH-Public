// 本文件管理独立于主业务库的 SemanticTitleVectors.sqlite 可重建缓存。

import CSQLiteVec
import Foundation
import GRDB

final class SQLiteSemanticTitleVectorRepository: SemanticTitleVectorRepository, @unchecked Sendable {
    private let dbQueue: DatabaseQueue

    init(path: String) throws {
        var configuration = Configuration()
        configuration.busyMode = .timeout(5)
        configuration.prepareDatabase { db in
            try db.execute(sql: "PRAGMA foreign_keys = ON")
            try db.execute(sql: "PRAGMA journal_mode = WAL")
            guard let connection = db.sqliteConnection,
                  nyaeh_sqlite_vec_init(connection) == 0 else {
                throw NyaEHError.semanticTitleStorageUnavailable
            }
        }
        dbQueue = try DatabaseQueue(path: path, configuration: configuration)
        try migrate()
    }

    static func appDefault() throws -> SQLiteSemanticTitleVectorRepository {
        let url = try AppDataDirectory.rootURL().appendingPathComponent("SemanticTitleVectors.sqlite")
        return try SQLiteSemanticTitleVectorRepository(path: url.path)
    }

    func activeGenerationID() throws -> Int64? {
        try dbQueue.read { db in
            try Int64.fetchOne(
                db,
                sql: "SELECT CAST(value AS INTEGER) FROM semantic_title_state WHERE key = 'active_generation_id'"
            )
        }
    }

    func activeProfile() throws -> SemanticEmbeddingProfile? {
        try dbQueue.read { db in
            guard let generationID = try activeGenerationID(db) else {
                return nil
            }
            return try profile(generationID: generationID, db: db)
        }
    }

    func activeEntries(bookID: LibraryBook.DatabaseID) throws -> [SemanticTitleVectorEntry] {
        try dbQueue.read { db in
            guard let generationID = try activeGenerationID(db) else {
                return []
            }
            return try Row.fetchAll(
                db,
                sql: """
                    SELECT id, generation_id, book_id, source_kind, source_hash,
                           language_code, feature_data, failure_message
                    FROM semantic_title_entries
                    WHERE generation_id = ? AND book_id = ?
                    ORDER BY source_kind
                    """,
                arguments: [generationID, bookID]
            ).compactMap(Self.entry)
        }
    }

    func beginGeneration(profile: SemanticEmbeddingProfile) throws -> Int64 {
        try dbQueue.write { db in
            try ensureVectorTable(db, dimension: profile.dimension)
            try db.execute(
                sql: """
                    INSERT INTO semantic_title_generations (
                        model_identifier, revision, dimension, maximum_sequence_length,
                        preprocessing_version, pooling_version, status, created_at
                    ) VALUES (?, ?, ?, ?, ?, ?, 'building', ?)
                    """,
                arguments: [
                    profile.modelIdentifier,
                    profile.revision,
                    profile.dimension,
                    profile.maximumSequenceLength,
                    profile.preprocessingVersion,
                    profile.poolingVersion,
                    Timestamp.nowMilliseconds()
                ]
            )
            return db.lastInsertedRowID
        }
    }

    func upsertVector(_ vector: SemanticTitleVector, generationID: Int64) throws {
        try dbQueue.write { db in
            guard try profile(generationID: generationID, db: db) == vector.profile else {
                throw NyaEHError.semanticTitleSchemaMismatch
            }
            try ensureVectorTable(db, dimension: vector.profile.dimension)
            let entryID = try upsertEntry(
                input: vector.input,
                generationID: generationID,
                featureData: vector.featureData,
                failureMessage: nil,
                db: db
            )
            try db.execute(sql: "DELETE FROM semantic_title_embeddings WHERE rowid = ?", arguments: [entryID])
            try db.execute(
                sql: """
                    INSERT INTO semantic_title_embeddings(
                        rowid, embedding, book_id, generation_id, source_kind
                    ) VALUES (?, vec_f32(?), ?, ?, ?)
                    """,
                arguments: [
                    entryID,
                    vector.featureData,
                    vector.input.bookID,
                    generationID,
                    vector.input.sourceKind.rawValue
                ]
            )
        }
    }

    func markFailure(
        input: SemanticTitleInput,
        profile: SemanticEmbeddingProfile,
        generationID: Int64,
        message: String
    ) throws {
        try dbQueue.write { db in
            guard try self.profile(generationID: generationID, db: db) == profile else {
                throw NyaEHError.semanticTitleSchemaMismatch
            }
            let entryID = try upsertEntry(
                input: input,
                generationID: generationID,
                featureData: nil,
                failureMessage: message,
                db: db
            )
            if try db.tableExists("semantic_title_embeddings") {
                try db.execute(sql: "DELETE FROM semantic_title_embeddings WHERE rowid = ?", arguments: [entryID])
            }
        }
    }

    func activateGeneration(_ generationID: Int64) throws {
        try dbQueue.write { db in
            guard try profile(generationID: generationID, db: db) != nil else {
                throw NyaEHError.semanticTitleSchemaMismatch
            }
            try db.execute(
                sql: "UPDATE semantic_title_generations SET status = 'ready', completed_at = ? WHERE id = ?",
                arguments: [Timestamp.nowMilliseconds(), generationID]
            )
            try db.execute(
                sql: """
                    INSERT INTO semantic_title_state(key, value)
                    VALUES ('active_generation_id', ?)
                    ON CONFLICT(key) DO UPDATE SET value = excluded.value
                """,
                arguments: [String(generationID)]
            )
            let retiredGenerationIDs = try Int64.fetchAll(
                db,
                sql: "SELECT id FROM semantic_title_generations WHERE id <> ?",
                arguments: [generationID]
            )
            for retiredGenerationID in retiredGenerationIDs {
                try deleteGeneration(retiredGenerationID, db: db)
            }
        }
    }

    func discardGeneration(_ generationID: Int64) throws {
        try dbQueue.write { db in
            try deleteGeneration(generationID, db: db)
        }
    }

    func deleteEntries(bookID: LibraryBook.DatabaseID, generationID: Int64) throws {
        try dbQueue.write { db in
            let entryIDs = try Int64.fetchAll(
                db,
                sql: "SELECT id FROM semantic_title_entries WHERE generation_id = ? AND book_id = ?",
                arguments: [generationID, bookID]
            )
            try deleteEmbeddings(entryIDs: entryIDs, db: db)
            try db.execute(
                sql: "DELETE FROM semantic_title_entries WHERE generation_id = ? AND book_id = ?",
                arguments: [generationID, bookID]
            )
        }
    }

    func indexedBookIDs() throws -> Set<LibraryBook.DatabaseID> {
        try dbQueue.read { db in
            guard let generationID = try activeGenerationID(db) else {
                return []
            }
            return Set(try Int64.fetchAll(
                db,
                sql: """
                    SELECT DISTINCT book_id
                    FROM semantic_title_entries
                    WHERE generation_id = ? AND feature_data IS NOT NULL
                    """,
                arguments: [generationID]
            ))
        }
    }

    func nearestNeighbors(
        bookID: LibraryBook.DatabaseID,
        among candidateBookIDs: Set<LibraryBook.DatabaseID>,
        limit: Int
    ) throws -> [SemanticTitleVectorNeighbor] {
        let candidates = candidateBookIDs.subtracting([bookID]).sorted()
        guard limit > 0, !candidates.isEmpty else {
            return []
        }
        return try dbQueue.read { db in
            guard try db.tableExists("semantic_title_embeddings"),
                  let generationID = try activeGenerationID(db) else {
                return []
            }
            let queryVectors = try Data.fetchAll(
                db,
                sql: """
                    SELECT feature_data FROM semantic_title_entries
                    WHERE generation_id = ? AND book_id = ? AND feature_data IS NOT NULL
                    """,
                arguments: [generationID, bookID]
            )
            guard !queryVectors.isEmpty else {
                return []
            }
            let placeholders = Array(repeating: "?", count: candidates.count).joined(separator: ",")
            var bestByBookID: [LibraryBook.DatabaseID: Double] = [:]
            for vector in queryVectors {
                var arguments: [DatabaseValueConvertible] = [vector, generationID]
                arguments.append(contentsOf: candidates)
                arguments.append(max(limit * 4, limit))
                let rows = try Row.fetchAll(
                    db,
                    sql: """
                        SELECT book_id, distance
                        FROM semantic_title_embeddings
                        WHERE embedding MATCH vec_f32(?)
                          AND generation_id = ?
                          AND book_id IN (\(placeholders))
                        ORDER BY distance
                        LIMIT ?
                        """,
                    arguments: StatementArguments(arguments)
                )
                for row in rows {
                    let neighborID: Int64 = row["book_id"]
                    let l2: Double = row["distance"]
                    let squared = l2 * l2
                    bestByBookID[neighborID] = min(bestByBookID[neighborID] ?? squared, squared)
                }
            }
            let neighbors = bestByBookID.map { entry in
                SemanticTitleVectorNeighbor(bookID: entry.key, distance: entry.value)
            }
            let sorted = neighbors.sorted { lhs, rhs in
                if lhs.distance == rhs.distance {
                    return lhs.bookID < rhs.bookID
                }
                return lhs.distance < rhs.distance
            }
            return Array(sorted.prefix(limit))
        }
    }

    func storedVectorCount() throws -> Int {
        try countActive(whereClause: "feature_data IS NOT NULL")
    }

    func storedFailureCount() throws -> Int {
        try countActive(whereClause: "failure_message IS NOT NULL")
    }

    func pruneOrphanedVectors(existingBookIDs: Set<LibraryBook.DatabaseID>) throws -> Int {
        try dbQueue.write { db in
            let stored = Set(try Int64.fetchAll(db, sql: "SELECT DISTINCT book_id FROM semantic_title_entries"))
            let orphaned = stored.subtracting(existingBookIDs)
            guard !orphaned.isEmpty else {
                return 0
            }
            let placeholders = Array(repeating: "?", count: orphaned.count).joined(separator: ",")
            let ids = orphaned.sorted()
            let entryIDs = try Int64.fetchAll(
                db,
                sql: "SELECT id FROM semantic_title_entries WHERE book_id IN (\(placeholders))",
                arguments: StatementArguments(ids)
            )
            try deleteEmbeddings(entryIDs: entryIDs, db: db)
            try db.execute(
                sql: "DELETE FROM semantic_title_entries WHERE book_id IN (\(placeholders))",
                arguments: StatementArguments(ids)
            )
            return orphaned.count
        }
    }

    func clear() throws {
        try dbQueue.write { db in
            try db.execute(sql: "DROP TABLE IF EXISTS semantic_title_embeddings")
            try db.execute(sql: "DELETE FROM semantic_title_entries")
            try db.execute(sql: "DELETE FROM semantic_title_generations")
            try db.execute(sql: "DELETE FROM semantic_title_state")
        }
    }

    private func migrate() throws {
        try dbQueue.write { db in
            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS semantic_title_generations (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    model_identifier TEXT NOT NULL,
                    revision INTEGER NOT NULL,
                    dimension INTEGER NOT NULL,
                    maximum_sequence_length INTEGER NOT NULL,
                    preprocessing_version INTEGER NOT NULL,
                    pooling_version INTEGER NOT NULL,
                    status TEXT NOT NULL,
                    created_at INTEGER NOT NULL,
                    completed_at INTEGER
                );

                CREATE TABLE IF NOT EXISTS semantic_title_entries (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    generation_id INTEGER NOT NULL,
                    book_id INTEGER NOT NULL,
                    source_kind TEXT NOT NULL,
                    source_hash TEXT NOT NULL,
                    language_code TEXT,
                    feature_data BLOB,
                    failure_message TEXT,
                    created_at INTEGER NOT NULL,
                    updated_at INTEGER NOT NULL,
                    UNIQUE(generation_id, book_id, source_kind),
                    FOREIGN KEY(generation_id) REFERENCES semantic_title_generations(id) ON DELETE CASCADE
                );

                CREATE INDEX IF NOT EXISTS idx_semantic_title_entries_generation_book
                    ON semantic_title_entries(generation_id, book_id);

                CREATE TABLE IF NOT EXISTS semantic_title_state (
                    key TEXT PRIMARY KEY,
                    value TEXT NOT NULL
                );
                """)
        }
    }

    private func ensureVectorTable(_ db: Database, dimension: Int) throws {
        if try db.tableExists("semantic_title_embeddings") {
            let storedDimension = try Int.fetchOne(
                db,
                sql: "SELECT CAST(value AS INTEGER) FROM semantic_title_state WHERE key = 'dimension'"
            )
            guard storedDimension == dimension else {
                throw NyaEHError.semanticTitleSchemaMismatch
            }
            return
        }
        try db.execute(
            sql: """
                CREATE VIRTUAL TABLE semantic_title_embeddings USING vec0(
                    embedding float[\(dimension)],
                    book_id integer,
                    generation_id integer,
                    source_kind text
                )
                """
        )
        try db.execute(
            sql: """
                INSERT INTO semantic_title_state(key, value)
                VALUES ('dimension', ?)
                ON CONFLICT(key) DO UPDATE SET value = excluded.value
                """,
            arguments: [String(dimension)]
        )
    }

    private func upsertEntry(
        input: SemanticTitleInput,
        generationID: Int64,
        featureData: Data?,
        failureMessage: String?,
        db: Database
    ) throws -> Int64 {
        let now = Timestamp.nowMilliseconds()
        try db.execute(
            sql: """
                INSERT INTO semantic_title_entries (
                    generation_id, book_id, source_kind, source_hash, language_code,
                    feature_data, failure_message, created_at, updated_at
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(generation_id, book_id, source_kind) DO UPDATE SET
                    source_hash = excluded.source_hash,
                    language_code = excluded.language_code,
                    feature_data = excluded.feature_data,
                    failure_message = excluded.failure_message,
                    updated_at = excluded.updated_at
                """,
            arguments: [
                generationID,
                input.bookID,
                input.sourceKind.rawValue,
                input.sourceHash,
                input.languageCode,
                featureData,
                failureMessage,
                now,
                now
            ]
        )
        guard let id = try Int64.fetchOne(
            db,
            sql: """
                SELECT id FROM semantic_title_entries
                WHERE generation_id = ? AND book_id = ? AND source_kind = ?
                """,
            arguments: [generationID, input.bookID, input.sourceKind.rawValue]
        ) else {
            throw NyaEHError.semanticTitleStorageUnavailable
        }
        return id
    }

    private func countActive(whereClause: String) throws -> Int {
        try dbQueue.read { db in
            guard let generationID = try activeGenerationID(db) else {
                return 0
            }
            return try Int.fetchOne(
                db,
                sql: """
                    SELECT COUNT(*) FROM semantic_title_entries
                    WHERE generation_id = ? AND \(whereClause)
                    """,
                arguments: [generationID]
            ) ?? 0
        }
    }

    private func deleteGeneration(_ generationID: Int64, db: Database) throws {
        let entryIDs = try Int64.fetchAll(
            db,
            sql: "SELECT id FROM semantic_title_entries WHERE generation_id = ?",
            arguments: [generationID]
        )
        try deleteEmbeddings(entryIDs: entryIDs, db: db)
        try db.execute(sql: "DELETE FROM semantic_title_generations WHERE id = ?", arguments: [generationID])
    }

    private func deleteEmbeddings(entryIDs: [Int64], db: Database) throws {
        guard !entryIDs.isEmpty, try db.tableExists("semantic_title_embeddings") else {
            return
        }
        let placeholders = Array(repeating: "?", count: entryIDs.count).joined(separator: ",")
        try db.execute(
            sql: "DELETE FROM semantic_title_embeddings WHERE rowid IN (\(placeholders))",
            arguments: StatementArguments(entryIDs)
        )
    }

    private func activeGenerationID(_ db: Database) throws -> Int64? {
        try Int64.fetchOne(
            db,
            sql: "SELECT CAST(value AS INTEGER) FROM semantic_title_state WHERE key = 'active_generation_id'"
        )
    }

    private func profile(generationID: Int64, db: Database) throws -> SemanticEmbeddingProfile? {
        try Row.fetchOne(
            db,
            sql: """
                SELECT model_identifier, revision, dimension, maximum_sequence_length,
                       preprocessing_version, pooling_version
                FROM semantic_title_generations WHERE id = ?
                """,
            arguments: [generationID]
        ).map {
            SemanticEmbeddingProfile(
                modelIdentifier: $0["model_identifier"],
                revision: $0["revision"],
                dimension: $0["dimension"],
                maximumSequenceLength: $0["maximum_sequence_length"],
                preprocessingVersion: $0["preprocessing_version"],
                poolingVersion: $0["pooling_version"]
            )
        }
    }

    private static func entry(_ row: Row) -> SemanticTitleVectorEntry? {
        guard let sourceKind = SemanticTitleSourceKind(rawValue: row["source_kind"]) else {
            return nil
        }
        return SemanticTitleVectorEntry(
            databaseID: row["id"],
            generationID: row["generation_id"],
            bookID: row["book_id"],
            sourceKind: sourceKind,
            sourceHash: row["source_hash"],
            languageCode: row["language_code"],
            featureData: row["feature_data"],
            failureMessage: row["failure_message"]
        )
    }
}
