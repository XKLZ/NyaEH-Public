// 本文件持久化合集推荐批次、成员和状态，确保接受/忽略推荐可以跨启动保留。

import Foundation
import GRDB

final class SQLiteCollectionRecommendationRepository: CollectionRecommendationRepository {
    private let dbQueue: any DatabaseWriter

    init(dbQueue: any DatabaseWriter) {
        self.dbQueue = dbQueue
    }

    func fetchPending(
        kind: CollectionRecommendationKind,
        targetCollectionID: BookCollection.DatabaseID?
    ) throws -> [CollectionRecommendation] {
        try dbQueue.write { db in
            try LibraryConsistency.invalidateRecommendations(db)
            let targetClause: String
            var arguments: StatementArguments = [
                CollectionRecommendationStatus.pending.rawValue,
                kind.rawValue
            ]
            if let targetCollectionID {
                targetClause = "target_collection_id = ?"
                arguments += [targetCollectionID]
            } else {
                targetClause = "target_collection_id IS NULL"
            }

            let rows = try Row.fetchAll(
                db,
                sql: """
                    SELECT id, batch_id, kind, target_collection_id, score,
                           reasons, fingerprint, status, created_at, updated_at
                    FROM collection_recommendations
                    WHERE status = ? AND kind = ? AND \(targetClause)
                    ORDER BY score DESC, updated_at DESC, id DESC
                    """,
                arguments: arguments
            )
            return rows.map(Self.recommendation(from:))
        }
    }

    func fetchPendingAddToCollectionCounts() throws -> [BookCollection.DatabaseID: Int] {
        try dbQueue.write { db in
            try LibraryConsistency.invalidateRecommendations(db)
            let rows = try Row.fetchAll(
                db,
                sql: """
                    SELECT target_collection_id, COUNT(*) AS recommendation_count
                    FROM collection_recommendations
                    WHERE status = ?
                      AND kind = ?
                      AND target_collection_id IS NOT NULL
                    GROUP BY target_collection_id
                    """,
                arguments: [
                    CollectionRecommendationStatus.pending.rawValue,
                    CollectionRecommendationKind.addToCollection.rawValue
                ]
            )
            return Dictionary(uniqueKeysWithValues: rows.compactMap { row in
                guard let collectionID: Int64 = row["target_collection_id"] else {
                    return nil
                }
                let count: Int = row["recommendation_count"]
                return (collectionID, count)
            })
        }
    }

    func fetchMemberBookIDs(recommendationID: CollectionRecommendation.DatabaseID) throws -> [LibraryBook.DatabaseID] {
        try dbQueue.read { db in
            try Int64.fetchAll(
                db,
                sql: """
                    SELECT book_id
                    FROM collection_recommendation_members
                    WHERE recommendation_id = ?
                    ORDER BY position ASC
                    """,
                arguments: [recommendationID]
            )
        }
    }

    func pendingCount(involving bookIDs: Set<LibraryBook.DatabaseID>) throws -> Int {
        guard !bookIDs.isEmpty else { return 0 }
        return try dbQueue.write { db in
            try LibraryConsistency.invalidateRecommendations(db)
            let ids = bookIDs.sorted()
            let placeholders = Array(repeating: "?", count: ids.count).joined(separator: ",")
            var arguments: StatementArguments = [CollectionRecommendationStatus.pending.rawValue]
            arguments += StatementArguments(ids)
            return try Int.fetchOne(
                db,
                sql: """
                    SELECT COUNT(DISTINCT collection_recommendations.id)
                    FROM collection_recommendations
                    JOIN collection_recommendation_members
                      ON collection_recommendation_members.recommendation_id = collection_recommendations.id
                    WHERE collection_recommendations.status = ?
                      AND collection_recommendation_members.book_id IN (\(placeholders))
                    """,
                arguments: arguments
            ) ?? 0
        }
    }

    func resetDismissed(involving bookID: LibraryBook.DatabaseID) throws {
        try dbQueue.write { db in
            try db.execute(
                sql: """
                    UPDATE collection_recommendations
                    SET status = ?, updated_at = ?
                    WHERE status = ? AND id IN (
                        SELECT recommendation_id FROM collection_recommendation_members WHERE book_id = ?
                    )
                    """,
                arguments: [
                    CollectionRecommendationStatus.stale.rawValue,
                    Timestamp.nowMilliseconds(),
                    CollectionRecommendationStatus.dismissed.rawValue,
                    bookID
                ]
            )
        }
    }

    func replacePending(with candidates: [CollectionRecommendationCandidate]) throws {
        try dbQueue.write { db in
            try Task.checkCancellation()
            let now = Timestamp.nowMilliseconds()
            let batchID = try insertBatch(now: now, db: db)

            try db.execute(
                sql: """
                    UPDATE collection_recommendations
                    SET status = ?, updated_at = ?
                    WHERE status = ?
                    """,
                arguments: [
                    CollectionRecommendationStatus.stale.rawValue,
                    now,
                    CollectionRecommendationStatus.pending.rawValue
                ]
            )

            for candidate in candidates {
                try upsert(candidate, batchID: batchID, now: now, db: db)
            }
        }
    }

    func mergePendingIncremental(
        with candidates: [CollectionRecommendationCandidate],
        affectedBookIDs: Set<LibraryBook.DatabaseID>,
        affectedCollectionIDs: Set<BookCollection.DatabaseID>
    ) throws {
        try dbQueue.write { db in
            try Task.checkCancellation()
            let now = Timestamp.nowMilliseconds()
            let batchID = try insertBatch(now: now, db: db)
            try stalePending(
                affectedBookIDs: affectedBookIDs,
                affectedCollectionIDs: affectedCollectionIDs,
                now: now,
                db: db
            )
            for candidate in candidates {
                try upsert(candidate, batchID: batchID, now: now, db: db)
            }
        }
    }

    func updateStatus(
        recommendationID: CollectionRecommendation.DatabaseID,
        status: CollectionRecommendationStatus
    ) throws {
        try dbQueue.write { db in
            try db.execute(
                sql: "UPDATE collection_recommendations SET status = ?, updated_at = ? WHERE id = ?",
                arguments: [status.rawValue, Timestamp.nowMilliseconds(), recommendationID]
            )
        }
    }

    func fetchDismissedCreateDecisions() throws -> [CollectionRecommendationDecisionSnapshot] {
        try dbQueue.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                    SELECT id, batch_id, kind, target_collection_id, score,
                           reasons, fingerprint, status, created_at, updated_at
                    FROM collection_recommendations
                    WHERE status = ? AND kind = ?
                    ORDER BY id ASC
                    """,
                arguments: [
                    CollectionRecommendationStatus.dismissed.rawValue,
                    CollectionRecommendationKind.createCollection.rawValue
                ]
            )
            return try rows.map { row in
                let recommendation = Self.recommendation(from: row)
                guard let recommendationID = recommendation.databaseID else {
                    return CollectionRecommendationDecisionSnapshot(
                        recommendation: recommendation,
                        bookIDs: []
                    )
                }
                let bookIDs = try Int64.fetchAll(
                    db,
                    sql: """
                        SELECT book_id
                        FROM collection_recommendation_members
                        WHERE recommendation_id = ?
                        ORDER BY position ASC
                        """,
                    arguments: [recommendationID]
                )
                return CollectionRecommendationDecisionSnapshot(
                    recommendation: recommendation,
                    bookIDs: bookIDs
                )
            }
        }
    }

    func latestRefreshCompletedAt() throws -> Int64? {
        try dbQueue.write { db in
            try LibraryConsistency.invalidateRecommendations(db)
            return try Int64.fetchOne(
                db,
                sql: "SELECT completed_at FROM collection_recommendation_batches ORDER BY completed_at DESC, id DESC LIMIT 1"
            )
        }
    }

    private func replaceMembers(
        _ bookIDs: [LibraryBook.DatabaseID],
        recommendationID: CollectionRecommendation.DatabaseID,
        db: Database
    ) throws {
        try db.execute(
            sql: "DELETE FROM collection_recommendation_members WHERE recommendation_id = ?",
            arguments: [recommendationID]
        )
        for (index, bookID) in bookIDs.enumerated() {
            try db.execute(
                sql: """
                    INSERT INTO collection_recommendation_members (recommendation_id, book_id, position)
                    VALUES (?, ?, ?)
                    """,
                arguments: [recommendationID, bookID, index]
            )
        }
    }

    private func insertBatch(now: Int64, db: Database) throws -> Int64 {
        try db.execute(
            sql: "INSERT INTO collection_recommendation_batches (created_at, completed_at) VALUES (?, ?)",
            arguments: [now, now]
        )
        return db.lastInsertedRowID
    }

    private func stalePending(
        affectedBookIDs: Set<LibraryBook.DatabaseID>,
        affectedCollectionIDs: Set<BookCollection.DatabaseID>,
        now: Int64,
        db: Database
    ) throws {
        if !affectedBookIDs.isEmpty {
            let ids = affectedBookIDs.sorted()
            let placeholders = Array(repeating: "?", count: ids.count).joined(separator: ",")
            var arguments: StatementArguments = [
                CollectionRecommendationStatus.stale.rawValue,
                now,
                CollectionRecommendationStatus.pending.rawValue
            ]
            arguments += StatementArguments(ids)
            try db.execute(
                sql: """
                    UPDATE collection_recommendations
                    SET status = ?, updated_at = ?
                    WHERE status = ?
                      AND id IN (
                        SELECT recommendation_id
                        FROM collection_recommendation_members
                        WHERE book_id IN (\(placeholders))
                      )
                    """,
                arguments: arguments
            )
        }

        if !affectedCollectionIDs.isEmpty {
            let ids = affectedCollectionIDs.sorted()
            let placeholders = Array(repeating: "?", count: ids.count).joined(separator: ",")
            var arguments: StatementArguments = [
                CollectionRecommendationStatus.stale.rawValue,
                now,
                CollectionRecommendationStatus.pending.rawValue,
                CollectionRecommendationKind.addToCollection.rawValue
            ]
            arguments += StatementArguments(ids)
            try db.execute(
                sql: """
                    UPDATE collection_recommendations
                    SET status = ?, updated_at = ?
                    WHERE status = ?
                      AND kind = ?
                      AND target_collection_id IN (\(placeholders))
                    """,
                arguments: arguments
            )
        }
    }

    private func upsert(
        _ candidate: CollectionRecommendationCandidate,
        batchID: Int64,
        now: Int64,
        db: Database
    ) throws {
        try Task.checkCancellation()
        guard try LibraryConsistency.recommendationIsValid(db, collection: true, kind: candidate.kind.rawValue, target: candidate.targetCollectionID, bookIDs: candidate.bookIDs, fingerprint: candidate.fingerprint) else { return }
        if let existing = try Row.fetchOne(
            db,
            sql: "SELECT id, status, created_at FROM collection_recommendations WHERE fingerprint = ?",
            arguments: [candidate.fingerprint]
        ) {
            let existingStatus = CollectionRecommendationStatus(rawValue: existing["status"]) ?? .stale
            guard existingStatus != .dismissed, existingStatus != .accepted else {
                return
            }

            let recommendationID: Int64 = existing["id"]
            try db.execute(
                sql: """
                    UPDATE collection_recommendations
                    SET batch_id = ?,
                        kind = ?,
                        target_collection_id = ?,
                        score = ?,
                        reasons = ?,
                        status = ?,
                        updated_at = ?
                    WHERE id = ?
                    """,
                arguments: [
                    batchID,
                    candidate.kind.rawValue,
                    candidate.targetCollectionID,
                    candidate.score,
                    Self.reasonsJSON(candidate.reasons),
                    CollectionRecommendationStatus.pending.rawValue,
                    now,
                    recommendationID
                ]
            )
            try replaceMembers(candidate.bookIDs, recommendationID: recommendationID, db: db)
        } else {
            try db.execute(
                sql: """
                    INSERT INTO collection_recommendations (
                        batch_id, kind, target_collection_id, score,
                        reasons, fingerprint, status, created_at, updated_at
                    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                arguments: [
                    batchID,
                    candidate.kind.rawValue,
                    candidate.targetCollectionID,
                    candidate.score,
                    Self.reasonsJSON(candidate.reasons),
                    candidate.fingerprint,
                    CollectionRecommendationStatus.pending.rawValue,
                    now,
                    now
                ]
            )
            try replaceMembers(candidate.bookIDs, recommendationID: db.lastInsertedRowID, db: db)
        }
    }

    private static func recommendation(from row: Row) -> CollectionRecommendation {
        CollectionRecommendation(
            databaseID: row["id"],
            batchID: row["batch_id"],
            kind: CollectionRecommendationKind(rawValue: row["kind"]) ?? .createCollection,
            targetCollectionID: row["target_collection_id"],
            score: row["score"],
            reasons: reasons(from: row["reasons"]),
            fingerprint: row["fingerprint"],
            status: CollectionRecommendationStatus(rawValue: row["status"]) ?? .stale,
            createdAt: row["created_at"],
            updatedAt: row["updated_at"]
        )
    }

    private static func reasonsJSON(_ reasons: [String]) -> String {
        guard let data = try? JSONEncoder().encode(reasons),
              let text = String(data: data, encoding: .utf8) else {
            return "[]"
        }
        return text
    }

    private static func reasons(from text: String) -> [String] {
        guard let data = text.data(using: .utf8),
              let reasons = try? JSONDecoder().decode([String].self, from: data) else {
            return []
        }
        return reasons
    }
}
