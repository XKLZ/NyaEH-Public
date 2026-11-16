// 本文件实现合集、版本组和版本标签写入路径，组织功能的事务一致性集中在这里。

import Foundation
import GRDB

final class SQLiteCollectionRepository: CollectionRepository, CollectionRecommendationMutationRepository {
    private let dbQueue: any DatabaseWriter

    init(dbQueue: any DatabaseWriter) {
        self.dbQueue = dbQueue
    }

    func fetchAll() throws -> [BookCollection] {
        try dbQueue.read { db in
            try Row.fetchAll(
                db,
                sql: "SELECT id, name, created_at, updated_at FROM book_collections ORDER BY name COLLATE NOCASE ASC"
            ).map(Self.collection(from:))
        }
    }

    func fetch(id: BookCollection.DatabaseID) throws -> BookCollection? {
        try dbQueue.read { db in
            try Row.fetchOne(
                db,
                sql: "SELECT id, name, created_at, updated_at FROM book_collections WHERE id = ?",
                arguments: [id]
            ).map(Self.collection(from:))
        }
    }

    func insert(_ collection: BookCollection) throws -> BookCollection {
        try dbQueue.write { db in
            var saved = collection
            let now = Timestamp.nowMilliseconds()
            saved.createdAt = collection.createdAt
            saved.updatedAt = now
            try db.execute(
                sql: "INSERT INTO book_collections (name, created_at, updated_at) VALUES (?, ?, ?)",
                arguments: [saved.name, saved.createdAt, saved.updatedAt]
            )
            saved.databaseID = db.lastInsertedRowID
            return saved
        }
    }

    func update(_ collection: BookCollection) throws -> BookCollection {
        guard let id = collection.databaseID else {
            throw NyaEHError.bookHasNoID
        }

        return try dbQueue.write { db in
            var updated = collection
            updated.updatedAt = Timestamp.nowMilliseconds()
            try db.execute(
                sql: "UPDATE book_collections SET name = ?, created_at = ?, updated_at = ? WHERE id = ?",
                arguments: [updated.name, updated.createdAt, updated.updatedAt, id]
            )
            return updated
        }
    }

    func delete(id: BookCollection.DatabaseID) throws {
        try dbQueue.write { db in
            try db.execute(sql: "DELETE FROM book_collections WHERE id = ?", arguments: [id])
        }
    }

    func deleteAndDissolve(id: BookCollection.DatabaseID) throws {
        try dbQueue.write { db in
            let groupIDs = try Int64.fetchAll(db, sql: """
                SELECT DISTINCT version_group_id FROM library_books WHERE collection_id = ? AND version_group_id IS NOT NULL
                """, arguments: [id])
            let now = Timestamp.nowMilliseconds()
            try db.execute(
                sql: """
                    UPDATE library_books
                    SET collection_id = NULL, collection_order = NULL,
                        hidden_book = CASE WHEN version_group_id IS NOT NULL AND is_primary_version = 0 THEN 1 ELSE 0 END,
                        updated_at = ?
                    WHERE collection_id = ?
                    """,
                arguments: [now, id]
            )
            for groupID in groupIDs {
                let members = try SeriesMembership.members(db, groupID: groupID)
                if Set(members.compactMap(\.collectionID)).count == 1 {
                    try SeriesMembership.reconcile(db, members: members)
                }
            }
            try db.execute(sql: "DELETE FROM book_collections WHERE id = ?", arguments: [id])
        }
    }

    func addBookAndVersions(bookID: LibraryBook.DatabaseID, to collectionID: BookCollection.DatabaseID) throws {
        try dbQueue.write { db in
            guard try Int64.fetchOne(db, sql: "SELECT id FROM book_collections WHERE id = ?", arguments: [collectionID]) != nil else {
                throw LibraryDeletionError.bookUnavailable
            }
            let members = try SeriesMembership.members(db, bookID: bookID)
            try SeriesMembership.assign(db, members: members, to: collectionID)
        }
    }

    func removeBookAndVersions(bookID: LibraryBook.DatabaseID, from collectionID: BookCollection.DatabaseID) throws {
        try dbQueue.write { db in
            let members = try SeriesMembership.members(db, bookID: bookID)
            let assigned = members.filter { $0.collectionID == collectionID }
            guard !assigned.isEmpty else { return }
            let remaining = members.filter { $0.collectionID != collectionID }
            if remaining.contains(where: { $0.collectionID != nil }) {
                try SeriesMembership.write(db, members: assigned, collectionID: nil, order: nil)
                if Set(remaining.compactMap(\.collectionID)).count == 1 {
                    try SeriesMembership.reconcile(db, members: SeriesMembership.members(db, bookID: bookID))
                }
            } else {
                try SeriesMembership.write(db, members: members, collectionID: nil, order: nil)
            }
        }
    }

    func acceptCreateCollectionRecommendation(
        recommendationID: CollectionRecommendation.DatabaseID,
        bookIDs: [LibraryBook.DatabaseID],
        orderedPrimaryBookIDs: [LibraryBook.DatabaseID],
        name: String
    ) throws -> BookCollection {
        try dbQueue.write { db in
            try LibraryConsistency.validateAcceptance(db, collection: true, id: recommendationID, bookIDs: bookIDs, target: nil)
            let now = Timestamp.nowMilliseconds()
            try db.execute(
                sql: "INSERT INTO book_collections (name, created_at, updated_at) VALUES (?, ?, ?)",
                arguments: [name, now, now]
            )
            let collectionID = db.lastInsertedRowID
            try addBooks(bookIDs, to: collectionID, startingAt: 0, db: db)
            try SeriesMembership.replaceOrder(db, bookIDs: orderedPrimaryBookIDs, collectionID: collectionID)
            try staleConflictingCollectionRecommendations(
                excluding: recommendationID,
                bookIDs: bookIDs,
                targetCollectionID: collectionID,
                updatedAt: now,
                db: db
            )
            try db.execute(
                sql: "UPDATE collection_recommendations SET status = ?, updated_at = ? WHERE id = ?",
                arguments: [CollectionRecommendationStatus.accepted.rawValue, now, recommendationID]
            )
            return BookCollection(databaseID: collectionID, name: name, createdAt: now, updatedAt: now)
        }
    }

    func acceptAddToCollectionRecommendation(
        recommendationID: CollectionRecommendation.DatabaseID,
        bookIDs: [LibraryBook.DatabaseID],
        orderedPrimaryBookIDs: [LibraryBook.DatabaseID],
        collectionID: BookCollection.DatabaseID,
        insertAtStart: Bool
    ) throws {
        try dbQueue.write { db in
            try LibraryConsistency.validateAcceptance(db, collection: true, id: recommendationID, bookIDs: bookIDs, target: collectionID)
            let now = Timestamp.nowMilliseconds()
            let firstOrder: Int
            if insertAtStart {
                let groups = try Int64.fetchAll(db, sql: """
                    SELECT DISTINCT version_group_id FROM library_books WHERE collection_id = ? AND version_group_id IS NOT NULL
                    """, arguments: [collectionID])
                for groupID in groups {
                    try SeriesMembership.reconcile(db, members: SeriesMembership.members(db, groupID: groupID))
                }
                let memberCount = try Int.fetchOne(db, sql: """
                    SELECT COUNT(*) FROM collection_recommendation_members WHERE recommendation_id = ?
                    """, arguments: [recommendationID]) ?? 0
                try db.execute(
                    sql: """
                        UPDATE library_books
                        SET collection_order = COALESCE(collection_order, 0) + ?, updated_at = ?
                        WHERE collection_id = ?
                        """,
                    arguments: [memberCount, now, collectionID]
                )
                firstOrder = 0
            } else {
                firstOrder = try SeriesMembership.nextOrder(db, collectionID: collectionID)
            }
            try addBooks(bookIDs, to: collectionID, startingAt: firstOrder, db: db)
            try SeriesMembership.replaceOrder(db, bookIDs: orderedPrimaryBookIDs, collectionID: collectionID)
            try staleConflictingCollectionRecommendations(
                excluding: recommendationID,
                bookIDs: bookIDs,
                targetCollectionID: collectionID,
                updatedAt: now,
                db: db
            )
            try db.execute(
                sql: "UPDATE collection_recommendations SET status = ?, updated_at = ? WHERE id = ?",
                arguments: [CollectionRecommendationStatus.accepted.rawValue, now, recommendationID]
            )
        }
    }

    private func staleConflictingCollectionRecommendations(
        excluding recommendationID: CollectionRecommendation.DatabaseID,
        bookIDs: [LibraryBook.DatabaseID],
        targetCollectionID: BookCollection.DatabaseID,
        updatedAt: Int64,
        db: Database
    ) throws {
        if !bookIDs.isEmpty {
            let placeholders = Array(repeating: "?", count: bookIDs.count).joined(separator: ",")
            var arguments: StatementArguments = [
                CollectionRecommendationStatus.stale.rawValue,
                updatedAt,
                CollectionRecommendationStatus.pending.rawValue,
                recommendationID
            ]
            arguments += StatementArguments(bookIDs)
            try db.execute(
                sql: """
                    UPDATE collection_recommendations
                    SET status = ?, updated_at = ?
                    WHERE status = ?
                      AND id != ?
                      AND id IN (
                        SELECT recommendation_id
                        FROM collection_recommendation_members
                        WHERE book_id IN (\(placeholders))
                      )
                    """,
                arguments: arguments
            )
        }

        try db.execute(
            sql: """
                UPDATE collection_recommendations
                SET status = ?, updated_at = ?
                WHERE status = ?
                  AND id != ?
                  AND kind = ?
                  AND target_collection_id = ?
                """,
            arguments: [
                CollectionRecommendationStatus.stale.rawValue,
                updatedAt,
                CollectionRecommendationStatus.pending.rawValue,
                recommendationID,
                CollectionRecommendationKind.addToCollection.rawValue,
                targetCollectionID
            ]
        )
    }

    private func addBooks(
        _ bookIDs: [LibraryBook.DatabaseID],
        to collectionID: BookCollection.DatabaseID,
        startingAt firstOrder: Int,
        db: Database
    ) throws {
        var assigned = Set<Int64>()
        var order = firstOrder
        for bookID in bookIDs where !assigned.contains(bookID) {
            let members = try SeriesMembership.members(db, bookID: bookID)
            guard try SeriesMembership.uniqueCollection(members) == nil else {
                throw LibraryDeletionError.staleRecommendation
            }
            try SeriesMembership.assign(db, members: members, to: collectionID, order: order)
            assigned.formUnion(members.map(\.id))
            order += 1
        }
    }

    private static func collection(from row: Row) -> BookCollection {
        BookCollection(
            databaseID: row["id"],
            name: row["name"],
            createdAt: row["created_at"],
            updatedAt: row["updated_at"]
        )
    }
}

final class SQLiteVersionGroupRepository: VersionGroupRepository, VersionGroupMutationRepository {
    private let dbQueue: any DatabaseWriter

    init(dbQueue: any DatabaseWriter) {
        self.dbQueue = dbQueue
    }

    func fetchAll() throws -> [BookVersionGroup] {
        try dbQueue.read { db in
            try Row.fetchAll(
                db,
                sql: "SELECT id, created_at, updated_at FROM book_version_groups ORDER BY updated_at DESC, id DESC"
            ).map(Self.group(from:))
        }
    }

    func fetch(id: BookVersionGroup.DatabaseID) throws -> BookVersionGroup? {
        try dbQueue.read { db in
            try Row.fetchOne(
                db,
                sql: "SELECT id, created_at, updated_at FROM book_version_groups WHERE id = ?",
                arguments: [id]
            ).map(Self.group(from:))
        }
    }

    func insert(_ group: BookVersionGroup) throws -> BookVersionGroup {
        try dbQueue.write { db in
            var saved = group
            let now = Timestamp.nowMilliseconds()
            saved.createdAt = group.createdAt
            saved.updatedAt = now
            try db.execute(
                sql: "INSERT INTO book_version_groups (created_at, updated_at) VALUES (?, ?)",
                arguments: [saved.createdAt, saved.updatedAt]
            )
            saved.databaseID = db.lastInsertedRowID
            return saved
        }
    }

    func delete(id: BookVersionGroup.DatabaseID) throws {
        try dbQueue.write { db in
            try db.execute(sql: "DELETE FROM book_version_groups WHERE id = ?", arguments: [id])
        }
    }

    // VersionGroupMutationRepository 的方法承担跨表事务：library_books 归组、主版本、
    // normalized labels、推荐状态和组级收藏语义必须在同一个 write 中保持一致。

    func createVersionGroup(bookIDs: [LibraryBook.DatabaseID]) throws -> BookVersionGroup {
        try dbQueue.write { db in
            try createVersionGroup(bookIDs: bookIDs, db: db)
        }
    }

    func acceptCreateVersionGroupRecommendation(
        recommendationID: VersionRecommendation.DatabaseID,
        bookIDs: [LibraryBook.DatabaseID],
        automaticLabels: [LibraryBook.DatabaseID: [String]]
    ) throws -> BookVersionGroup {
        try dbQueue.write { db in
            try LibraryConsistency.validateAcceptance(db, collection: false, id: recommendationID, bookIDs: bookIDs, target: nil)
            let group = try createVersionGroup(bookIDs: bookIDs, db: db)
            for bookID in bookIDs {
                try applyAutomaticLabelsIfNeeded(automaticLabels[bookID] ?? [], toBookID: bookID, db: db)
            }
            try markRecommendation(recommendationID, as: .accepted, db: db)
            return group
        }
    }

    func acceptAddToVersionGroupRecommendation(
        recommendationID: VersionRecommendation.DatabaseID,
        bookID: LibraryBook.DatabaseID,
        groupID: BookVersionGroup.DatabaseID,
        automaticLabels: [String]
    ) throws {
        try dbQueue.write { db in
            try LibraryConsistency.validateAcceptance(db, collection: false, id: recommendationID, bookIDs: [bookID], target: groupID)
            try addBooks([bookID], toVersionGroupID: groupID, firstIsPrimary: false, db: db)
            try applyAutomaticLabelsIfNeeded(automaticLabels, toBookID: bookID, db: db)
            try markRecommendation(recommendationID, as: .accepted, db: db)
        }
    }

    func deleteVersionGroup(id: BookVersionGroup.DatabaseID) throws {
        try dbQueue.write { db in
            let members = try SeriesMembership.members(db, groupID: id)
            if Set(members.compactMap(\.collectionID)).count <= 1 {
                try SeriesMembership.reconcile(db, members: members)
            }
            let memberIDs = try Int64.fetchAll(
                db,
                sql: "SELECT id FROM library_books WHERE version_group_id = ?",
                arguments: [id]
            )
            let now = Timestamp.nowMilliseconds()
            for memberID in memberIDs {
                try db.execute(
                    sql: """
                        UPDATE library_books
                        SET version_group_id = NULL,
                            is_primary_version = 1,
                            version_label = NULL,
                            hidden_book = CASE WHEN collection_id IS NOT NULL THEN 1 ELSE 0 END,
                            updated_at = ?
                        WHERE id = ?
                        """,
                    arguments: [now, memberID]
                )
                try db.execute(
                    sql: "DELETE FROM book_version_labels WHERE book_id = ?",
                    arguments: [memberID]
                )
            }

            try db.execute(
                sql: """
                    DELETE FROM version_recommendation_members
                    WHERE recommendation_id IN (
                        SELECT id FROM version_recommendations
                        WHERE target_version_group_id = ?
                    )
                    """,
                arguments: [id]
            )
            try db.execute(
                sql: "DELETE FROM version_recommendations WHERE target_version_group_id = ?",
                arguments: [id]
            )
            try db.execute(sql: "DELETE FROM book_version_groups WHERE id = ?", arguments: [id])
        }
    }

    func addBook(bookID: LibraryBook.DatabaseID, to groupID: BookVersionGroup.DatabaseID, isPrimary: Bool) throws {
        try dbQueue.write { db in
            try addBooks([bookID], toVersionGroupID: groupID, firstIsPrimary: isPrimary, db: db)
        }
    }

    func addBooks(bookIDs: [LibraryBook.DatabaseID], to groupID: BookVersionGroup.DatabaseID) throws {
        try dbQueue.write { db in
            try addBooks(bookIDs, toVersionGroupID: groupID, firstIsPrimary: false, db: db)
        }
    }

    func removeBook(bookID: LibraryBook.DatabaseID) throws {
        try dbQueue.write { db in
            guard let row = try Row.fetchOne(db, sql: "SELECT version_group_id FROM library_books WHERE id = ?", arguments: [bookID]) else {
                throw LibraryDeletionError.bookUnavailable
            }
            guard let groupID: Int64 = row["version_group_id"] else { return }
            let members = try SeriesMembership.members(db, groupID: groupID)
            if Set(members.compactMap(\.collectionID)).count <= 1 {
                try SeriesMembership.reconcile(db, members: members)
            }
            let now = Timestamp.nowMilliseconds()
            try db.execute(
                sql: """
                    UPDATE library_books
                    SET version_group_id = NULL, is_primary_version = 1, version_label = NULL,
                        hidden_book = CASE WHEN collection_id IS NOT NULL THEN 1 ELSE 0 END,
                        updated_at = ?
                    WHERE id = ?
                    """,
                arguments: [now, bookID]
            )
            try db.execute(sql: "DELETE FROM book_version_labels WHERE book_id = ?", arguments: [bookID])
            try LibraryConsistency.normalizeGroup(db, id: groupID)
        }
    }

    func setPrimary(bookID: LibraryBook.DatabaseID) throws {
        try dbQueue.write { db in
            guard let row = try Row.fetchOne(db, sql: "SELECT version_group_id, is_primary_version FROM library_books WHERE id = ?", arguments: [bookID]) else {
                throw LibraryDeletionError.bookUnavailable
            }
            guard let groupID: Int64 = row["version_group_id"] else { return }
            let isAlreadyPrimary: Bool = row["is_primary_version"]
            try SeriesMembership.reconcile(db, members: SeriesMembership.members(db, groupID: groupID))
            guard !isAlreadyPrimary else { return }
            // The partial unique index checks each updated row. Demote the old primary first,
            // then promote the target in this same write transaction.
            try db.execute(
                sql: "UPDATE library_books SET is_primary_version = 0 WHERE version_group_id = ? AND is_primary_version = 1",
                arguments: [groupID]
            )
            try db.execute(
                sql: """
                    UPDATE library_books
                    SET is_primary_version = CASE WHEN id = ? THEN 1 ELSE 0 END,
                        hidden_book = CASE WHEN collection_id IS NOT NULL OR id != ? THEN 1 ELSE 0 END,
                        updated_at = ?
                    WHERE version_group_id = ?
                    """,
                arguments: [bookID, bookID, Timestamp.nowMilliseconds(), groupID]
            )
        }
    }

    func setLabels(_ labels: [String], bookID: LibraryBook.DatabaseID) throws {
        let normalized = VersionLabelFormatter.normalizedLabels(labels)
        try dbQueue.write { db in
            guard try Int64.fetchOne(db, sql: "SELECT id FROM library_books WHERE id = ?", arguments: [bookID]) != nil else {
                throw LibraryDeletionError.bookUnavailable
            }
            let now = Timestamp.nowMilliseconds()
            try db.execute(
                sql: "UPDATE library_books SET version_label = ?, updated_at = ? WHERE id = ?",
                arguments: [VersionLabelFormatter.displayText(for: normalized), now, bookID]
            )
            try db.execute(sql: "DELETE FROM book_version_labels WHERE book_id = ?", arguments: [bookID])
            for (position, label) in normalized.enumerated() {
                try db.execute(
                    sql: """
                        INSERT INTO book_version_labels (book_id, label, position, created_at, updated_at)
                        VALUES (?, ?, ?, ?, ?)
                        """,
                    arguments: [bookID, label, position, now, now]
                )
                try upsertVersionLabelSuggestion(label, db: db, now: now)
            }
        }
    }

    func repairVersionGroupMarkedState() throws -> VersionGroupMarkedRepairResult {
        try dbQueue.write { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                    SELECT version_group_id AS group_id,
                           COUNT(*) AS member_count,
                           SUM(CASE WHEN mark THEN 1 ELSE 0 END) AS marked_count
                    FROM library_books
                    WHERE version_group_id IS NOT NULL
                    GROUP BY version_group_id
                    """
            )
            var repairedVersionGroups = 0
            var updatedBooks = 0
            let now = Timestamp.nowMilliseconds()
            for row in rows {
                let groupID: Int64 = row["group_id"]
                let memberCount: Int = row["member_count"]
                let markedCount: Int = row["marked_count"]
                guard markedCount > 0, markedCount < memberCount else {
                    continue
                }
                repairedVersionGroups += 1
                updatedBooks += memberCount - markedCount
                try db.execute(
                    sql: """
                        UPDATE library_books
                        SET mark = 1,
                            updated_at = ?
                        WHERE version_group_id = ?
                          AND mark = 0
                        """,
                    arguments: [now, groupID]
                )
            }
            return VersionGroupMarkedRepairResult(
                checkedVersionGroups: rows.count,
                repairedVersionGroups: repairedVersionGroups,
                updatedBooks: updatedBooks
            )
        }
    }

    private static func group(from row: Row) -> BookVersionGroup {
        BookVersionGroup(
            databaseID: row["id"],
            createdAt: row["created_at"],
            updatedAt: row["updated_at"]
        )
    }

    private func insertVersionGroup(db: Database) throws -> BookVersionGroup {
        let now = Timestamp.nowMilliseconds()
        try db.execute(
            sql: "INSERT INTO book_version_groups (created_at, updated_at) VALUES (?, ?)",
            arguments: [now, now]
        )
        return BookVersionGroup(databaseID: db.lastInsertedRowID, createdAt: now, updatedAt: now)
    }

    private func createVersionGroup(bookIDs: [Int64], db: Database) throws -> BookVersionGroup {
        let group = try insertVersionGroup(db: db)
        guard let groupID = group.databaseID else { throw NyaEHError.groupingRepositoryUnavailable }
        try addBooks(bookIDs, toVersionGroupID: groupID, firstIsPrimary: true, db: db)
        return group
    }

    private func addBooks(_ bookIDs: [Int64], toVersionGroupID groupID: Int64, firstIsPrimary: Bool, db: Database) throws {
        guard try Int64.fetchOne(db, sql: "SELECT id FROM book_version_groups WHERE id = ?", arguments: [groupID]) != nil else {
            throw LibraryDeletionError.bookUnavailable
        }
        let existing = try SeriesMembership.members(db, groupID: groupID)
        var seen = Set(existing.map(\.id))
        let incoming = try bookIDs.filter { seen.insert($0).inserted }.map { try SeriesMembership.member(db, id: $0) }
        for source in Set(incoming.compactMap(\.groupID)).sorted() {
            try SeriesMembership.reconcile(db, members: SeriesMembership.members(db, groupID: source))
        }
        let refreshed = try incoming.map { try SeriesMembership.member(db, id: $0.id) }
        let collectionID = try SeriesMembership.uniqueCollection(existing + refreshed)
        let order = collectionID.flatMap {
            SeriesMembership.existingOrder(in: $0, members: existing)
                ?? refreshed.filter { $0.collectionID == collectionID }.compactMap(\.order).min()
        }
        if !refreshed.isEmpty && !existing.isEmpty && firstIsPrimary {
            try db.execute(sql: "UPDATE library_books SET is_primary_version = 0 WHERE version_group_id = ? AND is_primary_version = 1",
                           arguments: [groupID])
        }
        let now = Timestamp.nowMilliseconds()
        for (index, member) in refreshed.enumerated() {
            let primary = index == 0 && (existing.isEmpty || firstIsPrimary)
            try db.execute(sql: """
                UPDATE library_books SET version_group_id = ?, is_primary_version = ?, updated_at = ?
                WHERE id = ?
                """, arguments: [groupID, primary, now, member.id])
        }
        for source in Set(refreshed.compactMap(\.groupID)).sorted() {
            try LibraryConsistency.normalizeGroup(db, id: source)
        }
        let members = try SeriesMembership.members(db, groupID: groupID)
        if let collectionID {
            try SeriesMembership.assign(db, members: members, to: collectionID, order: order)
        } else {
            try SeriesMembership.write(db, members: members, collectionID: nil, order: nil)
        }
        try db.execute(sql: """
            UPDATE library_books SET mark = 1, updated_at = ?
            WHERE version_group_id = ? AND mark = 0 AND EXISTS (
                SELECT 1 FROM library_books WHERE version_group_id = ? AND mark = 1
            )
            """, arguments: [now, groupID, groupID])
    }

    private func applyAutomaticLabelsIfNeeded(
        _ labels: [String],
        toBookID bookID: LibraryBook.DatabaseID,
        db: Database
    ) throws {
        let normalized = VersionLabelFormatter.normalizedLabels(labels)
        guard !normalized.isEmpty else {
            return
        }
        let labelCount = try Int.fetchOne(
            db,
            sql: "SELECT COUNT(*) FROM book_version_labels WHERE book_id = ?",
            arguments: [bookID]
        ) ?? 0
        let cachedLabel = try String.fetchOne(
            db,
            sql: "SELECT version_label FROM library_books WHERE id = ?",
            arguments: [bookID]
        )?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard labelCount == 0, cachedLabel?.isEmpty ?? true else {
            return
        }

        let now = Timestamp.nowMilliseconds()
        try db.execute(
            sql: "UPDATE library_books SET version_label = ?, updated_at = ? WHERE id = ?",
            arguments: [VersionLabelFormatter.displayText(for: normalized), now, bookID]
        )
        for (position, label) in normalized.enumerated() {
            try db.execute(
                sql: """
                    INSERT INTO book_version_labels (
                        book_id, label, position, created_at, updated_at
                    ) VALUES (?, ?, ?, ?, ?)
                    """,
                arguments: [bookID, label, position, now, now]
            )
            try upsertVersionLabelSuggestion(label, db: db, now: now)
        }
    }

    private func upsertVersionLabelSuggestion(_ label: String, db: Database, now: Int64) throws {
        try db.execute(
            sql: """
                INSERT INTO version_label_suggestions (
                    label, usage_count, last_used_at, created_at, updated_at
                ) VALUES (?, 1, ?, ?, ?)
                ON CONFLICT(label) DO UPDATE SET
                    label = excluded.label,
                    usage_count = usage_count + 1,
                    last_used_at = excluded.last_used_at,
                    updated_at = excluded.updated_at
                """,
            arguments: [label, now, now, now]
        )
    }

    private func markRecommendation(
        _ recommendationID: VersionRecommendation.DatabaseID,
        as status: VersionRecommendationStatus,
        db: Database
    ) throws {
        try db.execute(
            sql: "UPDATE version_recommendations SET status = ?, updated_at = ? WHERE id = ?",
            arguments: [status.rawValue, Timestamp.nowMilliseconds(), recommendationID]
        )
    }
}

final class SQLiteVersionLabelSuggestionRepository: VersionLabelSuggestionRepository {
    private let dbQueue: any DatabaseWriter

    init(dbQueue: any DatabaseWriter) {
        self.dbQueue = dbQueue
    }

    func fetchAll() throws -> [VersionLabelSuggestion] {
        try dbQueue.read { db in
            try Row.fetchAll(
                db,
                sql: """
                    SELECT id, label, usage_count, last_used_at, created_at, updated_at
                    FROM version_label_suggestions
                    ORDER BY usage_count DESC, last_used_at DESC, label COLLATE NOCASE ASC
                    """
            ).map(Self.suggestion(from:))
        }
    }

    @discardableResult
    func upsert(label: String) throws -> VersionLabelSuggestion? {
        let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return nil
        }

        return try dbQueue.write { db in
            let now = Timestamp.nowMilliseconds()
            if let row = try Row.fetchOne(
                db,
                sql: """
                    SELECT id, label, usage_count, last_used_at, created_at, updated_at
                    FROM version_label_suggestions
                    WHERE label = ? COLLATE NOCASE
                    """,
                arguments: [trimmed]
            ) {
                let id: Int64 = row["id"]
                try db.execute(
                    sql: """
                        UPDATE version_label_suggestions
                        SET label = ?, usage_count = usage_count + 1, last_used_at = ?, updated_at = ?
                        WHERE id = ?
                        """,
                    arguments: [trimmed, now, now, id]
                )
                return try Row.fetchOne(
                    db,
                    sql: """
                        SELECT id, label, usage_count, last_used_at, created_at, updated_at
                        FROM version_label_suggestions
                        WHERE id = ?
                        """,
                    arguments: [id]
                ).map(Self.suggestion(from:))
            }

            try db.execute(
                sql: """
                    INSERT INTO version_label_suggestions (
                        label, usage_count, last_used_at, created_at, updated_at
                    ) VALUES (?, 1, ?, ?, ?)
                    """,
                arguments: [trimmed, now, now, now]
            )
            return VersionLabelSuggestion(
                databaseID: db.lastInsertedRowID,
                label: trimmed,
                usageCount: 1,
                lastUsedAt: now,
                createdAt: now,
                updatedAt: now
            )
        }
    }

    private static func suggestion(from row: Row) -> VersionLabelSuggestion {
        VersionLabelSuggestion(
            databaseID: row["id"],
            label: row["label"],
            usageCount: row["usage_count"],
            lastUsedAt: row["last_used_at"],
            createdAt: row["created_at"],
            updatedAt: row["updated_at"]
        )
    }
}

final class SQLiteBookVersionLabelRepository: BookVersionLabelRepository {
    private let dbQueue: any DatabaseWriter

    init(dbQueue: any DatabaseWriter) {
        self.dbQueue = dbQueue
    }

    func fetchLabels(bookID: LibraryBook.DatabaseID) throws -> [String] {
        try dbQueue.read { db in
            try String.fetchAll(
                db,
                sql: """
                    SELECT label
                    FROM book_version_labels
                    WHERE book_id = ?
                    ORDER BY position ASC, label COLLATE NOCASE ASC
                    """,
                arguments: [bookID]
            )
        }
    }

    func replaceLabels(_ labels: [String], bookID: LibraryBook.DatabaseID) throws {
        let normalized = VersionLabelFormatter.normalizedLabels(labels)
        try dbQueue.write { db in
            let now = Timestamp.nowMilliseconds()
            try db.execute(
                sql: "DELETE FROM book_version_labels WHERE book_id = ?",
                arguments: [bookID]
            )
            for (position, label) in normalized.enumerated() {
                try db.execute(
                    sql: """
                        INSERT INTO book_version_labels (
                            book_id, label, position, created_at, updated_at
                        ) VALUES (?, ?, ?, ?, ?)
                        """,
                    arguments: [bookID, label, position, now, now]
                )
            }
        }
    }
}
