// 本文件持久化版本组推荐批次、候选成员和状态，接受前不直接修改 library_books。

import Foundation
import GRDB

final class SQLiteVersionRecommendationRepository: VersionRecommendationRepository {
    private let dbQueue: any DatabaseWriter

    init(dbQueue: any DatabaseWriter) {
        self.dbQueue = dbQueue
    }

    func fetchPending(
        kind: VersionRecommendationKind,
        targetVersionGroupID: BookVersionGroup.DatabaseID?
    ) throws -> [VersionRecommendation] {
        try dbQueue.write { db in
            try LibraryConsistency.invalidateRecommendations(db)
            let targetClause: String
            var arguments: StatementArguments = [
                VersionRecommendationStatus.pending.rawValue,
                kind.rawValue
            ]
            if let targetVersionGroupID {
                targetClause = "target_version_group_id = ?"
                arguments += [targetVersionGroupID]
            } else {
                targetClause = "target_version_group_id IS NULL"
            }

            let rows = try Row.fetchAll(
                db,
                sql: """
                    SELECT id, batch_id, kind, target_version_group_id, score,
                           reasons, fingerprint, status, created_at, updated_at
                    FROM version_recommendations
                    WHERE status = ? AND kind = ? AND \(targetClause)
                    ORDER BY score DESC, updated_at DESC, id DESC
                    """,
                arguments: arguments
            )
            return rows.map(Self.recommendation(from:))
        }
    }

    func fetchPendingAddToGroupCounts() throws -> [BookVersionGroup.DatabaseID: Int] {
        try dbQueue.write { db in
            try LibraryConsistency.invalidateRecommendations(db)
            let rows = try Row.fetchAll(
                db,
                sql: """
                    SELECT target_version_group_id, COUNT(*) AS recommendation_count
                    FROM version_recommendations
                    WHERE status = ?
                      AND kind = ?
                      AND target_version_group_id IS NOT NULL
                    GROUP BY target_version_group_id
                    """,
                arguments: [
                    VersionRecommendationStatus.pending.rawValue,
                    VersionRecommendationKind.addToGroup.rawValue
                ]
            )
            return Dictionary(uniqueKeysWithValues: rows.compactMap { row in
                guard let groupID: Int64 = row["target_version_group_id"] else {
                    return nil
                }
                let count: Int = row["recommendation_count"]
                return (groupID, count)
            })
        }
    }

    func fetchMemberBookIDs(recommendationID: VersionRecommendation.DatabaseID) throws -> [LibraryBook.DatabaseID] {
        try dbQueue.read { db in
            try Int64.fetchAll(
                db,
                sql: """
                    SELECT book_id
                    FROM version_recommendation_members
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
            var arguments: StatementArguments = [VersionRecommendationStatus.pending.rawValue]
            arguments += StatementArguments(ids)
            return try Int.fetchOne(
                db,
                sql: """
                    SELECT COUNT(DISTINCT version_recommendations.id)
                    FROM version_recommendations
                    JOIN version_recommendation_members
                      ON version_recommendation_members.recommendation_id = version_recommendations.id
                    WHERE version_recommendations.status = ?
                      AND version_recommendation_members.book_id IN (\(placeholders))
                    """,
                arguments: arguments
            ) ?? 0
        }
    }

    func resetDismissed(involving bookID: LibraryBook.DatabaseID) throws {
        try dbQueue.write { db in
            try db.execute(
                sql: """
                    UPDATE version_recommendations
                    SET status = ?, updated_at = ?
                    WHERE status = ? AND id IN (
                        SELECT recommendation_id FROM version_recommendation_members WHERE book_id = ?
                    )
                    """,
                arguments: [
                    VersionRecommendationStatus.stale.rawValue,
                    Timestamp.nowMilliseconds(),
                    VersionRecommendationStatus.dismissed.rawValue,
                    bookID
                ]
            )
        }
    }

    func replacePending(with candidates: [VersionRecommendationCandidate]) throws {
        try dbQueue.write { db in
            try Task.checkCancellation()
            let now = Timestamp.nowMilliseconds()
            let batchID = try insertBatch(now: now, db: db)

            try db.execute(
                sql: """
                    UPDATE version_recommendations
                    SET status = ?, updated_at = ?
                    WHERE status = ?
                    """,
                arguments: [
                    VersionRecommendationStatus.stale.rawValue,
                    now,
                    VersionRecommendationStatus.pending.rawValue
                ]
            )

            for candidate in candidates {
                try upsert(candidate, batchID: batchID, now: now, db: db)
            }
        }
    }

    func mergePendingIncremental(
        with candidates: [VersionRecommendationCandidate],
        affectedBookIDs: Set<LibraryBook.DatabaseID>,
        affectedVersionGroupIDs: Set<BookVersionGroup.DatabaseID>
    ) throws {
        try dbQueue.write { db in
            try Task.checkCancellation()
            let now = Timestamp.nowMilliseconds()
            let batchID = try insertBatch(now: now, db: db)
            try stalePending(
                affectedBookIDs: affectedBookIDs,
                affectedVersionGroupIDs: affectedVersionGroupIDs,
                now: now,
                db: db
            )
            for candidate in candidates {
                try upsert(candidate, batchID: batchID, now: now, db: db)
            }
        }
    }

    func updateStatus(
        recommendationID: VersionRecommendation.DatabaseID,
        status: VersionRecommendationStatus
    ) throws {
        try dbQueue.write { db in
            try db.execute(
                sql: "UPDATE version_recommendations SET status = ?, updated_at = ? WHERE id = ?",
                arguments: [status.rawValue, Timestamp.nowMilliseconds(), recommendationID]
            )
        }
    }

    func latestRefreshCompletedAt() throws -> Int64? {
        try dbQueue.write { db in
            try LibraryConsistency.invalidateRecommendations(db)
            return try Int64.fetchOne(
                db,
                sql: "SELECT completed_at FROM version_recommendation_batches ORDER BY completed_at DESC, id DESC LIMIT 1"
            )
        }
    }

    private func replaceMembers(
        _ bookIDs: [LibraryBook.DatabaseID],
        recommendationID: VersionRecommendation.DatabaseID,
        db: Database
    ) throws {
        try db.execute(
            sql: "DELETE FROM version_recommendation_members WHERE recommendation_id = ?",
            arguments: [recommendationID]
        )
        for (index, bookID) in bookIDs.enumerated() {
            try db.execute(
                sql: """
                    INSERT INTO version_recommendation_members (recommendation_id, book_id, position)
                    VALUES (?, ?, ?)
                    """,
                arguments: [recommendationID, bookID, index]
            )
        }
    }

    private func insertBatch(now: Int64, db: Database) throws -> Int64 {
        try db.execute(
            sql: "INSERT INTO version_recommendation_batches (created_at, completed_at) VALUES (?, ?)",
            arguments: [now, now]
        )
        return db.lastInsertedRowID
    }

    private func stalePending(
        affectedBookIDs: Set<LibraryBook.DatabaseID>,
        affectedVersionGroupIDs: Set<BookVersionGroup.DatabaseID>,
        now: Int64,
        db: Database
    ) throws {
        if !affectedBookIDs.isEmpty {
            let ids = affectedBookIDs.sorted()
            let placeholders = Array(repeating: "?", count: ids.count).joined(separator: ",")
            var arguments: StatementArguments = [
                VersionRecommendationStatus.stale.rawValue,
                now,
                VersionRecommendationStatus.pending.rawValue
            ]
            arguments += StatementArguments(ids)
            try db.execute(
                sql: """
                    UPDATE version_recommendations
                    SET status = ?, updated_at = ?
                    WHERE status = ?
                      AND id IN (
                        SELECT recommendation_id
                        FROM version_recommendation_members
                        WHERE book_id IN (\(placeholders))
                      )
                    """,
                arguments: arguments
            )
        }

        if !affectedVersionGroupIDs.isEmpty {
            let ids = affectedVersionGroupIDs.sorted()
            let placeholders = Array(repeating: "?", count: ids.count).joined(separator: ",")
            var arguments: StatementArguments = [
                VersionRecommendationStatus.stale.rawValue,
                now,
                VersionRecommendationStatus.pending.rawValue,
                VersionRecommendationKind.addToGroup.rawValue
            ]
            arguments += StatementArguments(ids)
            try db.execute(
                sql: """
                    UPDATE version_recommendations
                    SET status = ?, updated_at = ?
                    WHERE status = ?
                      AND kind = ?
                      AND target_version_group_id IN (\(placeholders))
                    """,
                arguments: arguments
            )
        }
    }

    private func upsert(
        _ candidate: VersionRecommendationCandidate,
        batchID: Int64,
        now: Int64,
        db: Database
    ) throws {
        try Task.checkCancellation()
        guard try LibraryConsistency.recommendationIsValid(db, collection: false, kind: candidate.kind.rawValue, target: candidate.targetVersionGroupID, bookIDs: candidate.bookIDs, fingerprint: candidate.fingerprint) else { return }
        if let existing = try Row.fetchOne(
            db,
            sql: "SELECT id, status, created_at FROM version_recommendations WHERE fingerprint = ?",
            arguments: [candidate.fingerprint]
        ) {
            let existingStatus = VersionRecommendationStatus(rawValue: existing["status"]) ?? .stale
            guard existingStatus != .dismissed, existingStatus != .accepted else {
                return
            }

            let recommendationID: Int64 = existing["id"]
            try db.execute(
                sql: """
                    UPDATE version_recommendations
                    SET batch_id = ?,
                        kind = ?,
                        target_version_group_id = ?,
                        score = ?,
                        reasons = ?,
                        status = ?,
                        updated_at = ?
                    WHERE id = ?
                    """,
                arguments: [
                    batchID,
                    candidate.kind.rawValue,
                    candidate.targetVersionGroupID,
                    candidate.score,
                    Self.reasonsJSON(candidate.reasons),
                    VersionRecommendationStatus.pending.rawValue,
                    now,
                    recommendationID
                ]
            )
            try replaceMembers(candidate.bookIDs, recommendationID: recommendationID, db: db)
        } else {
            try db.execute(
                sql: """
                    INSERT INTO version_recommendations (
                        batch_id, kind, target_version_group_id, score,
                        reasons, fingerprint, status, created_at, updated_at
                    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                arguments: [
                    batchID,
                    candidate.kind.rawValue,
                    candidate.targetVersionGroupID,
                    candidate.score,
                    Self.reasonsJSON(candidate.reasons),
                    candidate.fingerprint,
                    VersionRecommendationStatus.pending.rawValue,
                    now,
                    now
                ]
            )
            try replaceMembers(candidate.bookIDs, recommendationID: db.lastInsertedRowID, db: db)
        }
    }

    private static func recommendation(from row: Row) -> VersionRecommendation {
        VersionRecommendation(
            databaseID: row["id"],
            batchID: row["batch_id"],
            kind: VersionRecommendationKind(rawValue: row["kind"]) ?? .createGroup,
            targetVersionGroupID: row["target_version_group_id"],
            score: row["score"],
            reasons: reasons(from: row["reasons"]),
            fingerprint: row["fingerprint"],
            status: VersionRecommendationStatus(rawValue: row["status"]) ?? .stale,
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
