// Shared transaction rules for deletion, migration, recommendation validation and maintenance.
import Foundation
import GRDB

enum LibraryConsistency {
    static func recommendationIsValid(
        _ db: Database, collection: Bool, kind: String, target: Int64?, bookIDs: [Int64], fingerprint: String
    ) throws -> Bool {
        let ids = Set(bookIDs)
        guard ids.count == bookIDs.count, !ids.isEmpty else { return false }
        let creating = kind == (collection ? "create_collection" : "create_group")
        guard creating || kind == (collection ? "add_to_collection" : "add_to_group") else { return false }
        if creating {
            guard target == nil, ids.count >= 2 else { return false }
        } else {
            guard let target,
                  try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM \(collection ? "book_collections" : "book_version_groups") WHERE id = ?)", arguments: [target]) == true else { return false }
        }
        for id in ids {
            guard let row = try Row.fetchOne(db, sql: "SELECT exist, collection_id, version_group_id, is_primary_version FROM library_books WHERE id = ?", arguments: [id]),
                  row["exist"] as Bool else { return false }
            let membership: Int64? = row[collection ? "collection_id" : "version_group_id"]
            guard membership == nil else { return false }
            if collection {
                guard row["is_primary_version"] as Bool else { return false }
                if let groupID: Int64 = row["version_group_id"],
                   try Bool.fetchOne(db, sql: """
                       SELECT EXISTS(SELECT 1 FROM library_books WHERE version_group_id = ? AND collection_id IS NOT NULL)
                       """, arguments: [groupID]) == true { return false }
            }
        }
        // Released fingerprints encode the original members. Preserve opaque legacy/test fingerprints.
        let prefix = collection ? (creating ? "collection-create:" : "collection-add:") : (creating ? "create:" : "add:")
        if fingerprint.hasPrefix(prefix) {
            let suffix = String(fingerprint.dropFirst(prefix.count))
            if creating {
                let encoded = suffix.split(separator: ".").compactMap { Int64($0) }
                guard encoded.count == ids.count, Set(encoded) == ids else { return false }
            } else {
                guard suffix == String(target!) + ":" + ids.sorted().map(String.init).joined(separator: ".") else { return false }
            }
        }
        return true
    }

    static func invalidRecommendationIDs(_ db: Database, collection: Bool) throws -> [Int64] {
        let table = collection ? "collection" : "version"
        let target = collection ? "target_collection_id" : "target_version_group_id"
        return try Row.fetchAll(db, sql: "SELECT id, kind, \(target), fingerprint FROM \(table)_recommendations WHERE status = 'pending'").compactMap { row in
            let id: Int64 = row["id"]
            let members = try Int64.fetchAll(db, sql: "SELECT book_id FROM \(table)_recommendation_members WHERE recommendation_id = ?", arguments: [id])
            return try recommendationIsValid(db, collection: collection, kind: row["kind"], target: row[target], bookIDs: members, fingerprint: row["fingerprint"]) ? nil : id
        }
    }

    @discardableResult
    static func invalidateRecommendations(_ db: Database) throws -> Int {
        var count = 0
        for collection in [false, true] {
            let table = collection ? "collection" : "version"
            for id in try invalidRecommendationIDs(db, collection: collection) {
                try db.execute(sql: "UPDATE \(table)_recommendations SET status = 'stale', updated_at = ? WHERE id = ?", arguments: [Timestamp.nowMilliseconds(), id])
                count += 1
            }
        }
        return count
    }

    static func validateAcceptance(_ db: Database, collection: Bool, id: Int64, bookIDs: [Int64], target: Int64? = nil) throws {
        let table = collection ? "collection" : "version"
        let targetColumn = collection ? "target_collection_id" : "target_version_group_id"
        guard let row = try Row.fetchOne(db, sql: "SELECT * FROM \(table)_recommendations WHERE id = ? AND status = 'pending'", arguments: [id]) else { throw LibraryDeletionError.staleRecommendation }
        let members = try Int64.fetchAll(db, sql: "SELECT book_id FROM \(table)_recommendation_members WHERE recommendation_id = ?", arguments: [id])
        var allowed = Set(members)
        if collection {
            for member in members {
                let secondaryIDs = try Int64.fetchAll(db, sql: "SELECT id FROM library_books WHERE version_group_id = (SELECT version_group_id FROM library_books WHERE id = ?)", arguments: [member])
                allowed.formUnion(secondaryIDs)
            }
        }
        guard allowed == Set(bookIDs), (row[targetColumn] as Int64?) == target,
              try recommendationIsValid(db, collection: collection, kind: row["kind"], target: target, bookIDs: members, fingerprint: row["fingerprint"]) else { throw LibraryDeletionError.staleRecommendation }
    }

    static func normalizeGroup(_ db: Database, id: Int64) throws {
        let rows = try Row.fetchAll(db, sql: "SELECT id, is_primary_version FROM library_books WHERE version_group_id = ? ORDER BY is_primary_version DESC, date DESC, id ASC", arguments: [id])
        if rows.count < 2 {
            for row in rows {
                let bookID: Int64 = row["id"]
                try db.execute(sql: "UPDATE library_books SET version_group_id = NULL, is_primary_version = 1, version_label = NULL, hidden_book = (collection_id IS NOT NULL), updated_at = ? WHERE id = ?", arguments: [Timestamp.nowMilliseconds(), bookID])
                try db.execute(sql: "DELETE FROM book_version_labels WHERE book_id = ?", arguments: [bookID])
            }
            try db.execute(sql: "DELETE FROM book_version_groups WHERE id = ?", arguments: [id])
        } else if let primary: Int64 = rows.first?["id"] {
            try db.execute(sql: """
                UPDATE library_books SET is_primary_version = (id = ?),
                    hidden_book = (collection_id IS NOT NULL OR id <> ?), updated_at = ?
                WHERE version_group_id = ? AND (is_primary_version <> (id = ?) OR hidden_book <> (collection_id IS NOT NULL OR id <> ?))
                """, arguments: [primary, primary, Timestamp.nowMilliseconds(), id, primary, primary])
        }
    }

    static func reconcileBatches(_ db: Database, backfillDeletedCounts: Bool = false) throws {
        for row in try Row.fetchAll(db, sql: "SELECT * FROM import_pipeline_batches") {
            let id: Int64 = row["id"]
            let count = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM import_pipeline_items WHERE batch_id = ?", arguments: [id]) ?? 0
            let total: Int = row["total_count"]
            if backfillDeletedCounts {
                try db.execute(sql: "UPDATE import_pipeline_batches SET deleted_count = MAX(deleted_count, ?) WHERE id = ?", arguments: [max(0, total - count), id])
            }
            guard (row["status"] as String) != "completed" else { continue }
            let stage: String = row["stage"]
            let table = stage == "collectionReview" ? "collection" : "version"
            let reviews = try Int.fetchOne(db, sql: """
                SELECT COUNT(DISTINCT r.id) FROM \(table)_recommendations r
                JOIN \(table)_recommendation_members m ON m.recommendation_id = r.id
                JOIN import_pipeline_items i ON m.book_id = CASE WHEN ? = 'collectionReview'
                    THEN COALESCE((SELECT p.id FROM library_books b JOIN library_books p ON p.version_group_id = b.version_group_id AND p.is_primary_version = 1 WHERE b.id = i.book_id), i.book_id)
                    ELSE i.book_id END
                WHERE i.batch_id = ? AND r.status = 'pending'
                """, arguments: [stage, id]) ?? 0
            try db.execute(sql: """
                UPDATE import_pipeline_batches SET
                    ready_count = (SELECT COUNT(*) FROM import_pipeline_items WHERE batch_id = ? AND stage IN ('versionAnalysisPending','versionReviewPending','collectionAnalysisPending','collectionReviewPending','completed')),
                    deferred_count = (SELECT COUNT(*) FROM import_pipeline_items WHERE batch_id = ? AND stage IN ('metadataDeferred','sourceNeedsAttention')),
                    review_count = ?, failed_count = (SELECT COUNT(*) FROM import_pipeline_items WHERE batch_id = ? AND stage = 'sourceNeedsAttention')
                WHERE id = ?
                """, arguments: [id, id, ["versionReview", "collectionReview"].contains(stage) ? reviews : 0, id, id])
            if count == 0 {
                try db.execute(sql: "UPDATE import_pipeline_batches SET status = 'completed', stage = 'completed', review_count = 0, completed_at = ?, updated_at = ? WHERE id = ?", arguments: [Timestamp.nowMilliseconds(), Timestamp.nowMilliseconds(), id])
            }
        }
    }

    static func deleteBook(_ db: Database, id: Int64) throws {
        guard let book = try Row.fetchOne(db, sql: "SELECT * FROM library_books WHERE id = ?", arguments: [id]) else { return }
        let groupID: Int64? = book["version_group_id"]
        let collectionID: Int64? = book["collection_id"]
        for (table, target) in [("version", "target_version_group_id"), ("collection", "target_collection_id")] {
            try db.execute(sql: """
                UPDATE \(table)_recommendations SET status = 'stale', updated_at = ?
                WHERE status = 'pending' AND (id IN (SELECT recommendation_id FROM \(table)_recommendation_members WHERE book_id = ?) OR \(target) = ?)
                """, arguments: [Timestamp.nowMilliseconds(), id, table == "version" ? groupID : collectionID])
        }
        try db.execute(sql: "UPDATE import_pipeline_batches SET deleted_count = deleted_count + 1 WHERE id IN (SELECT batch_id FROM import_pipeline_items WHERE book_id = ?)", arguments: [id])
        try db.execute(sql: "DELETE FROM library_books WHERE id = ?", arguments: [id])
        if let groupID { try normalizeGroup(db, id: groupID) }
        if let collectionID {
            try db.execute(sql: "DELETE FROM book_collections WHERE id = ? AND NOT EXISTS(SELECT 1 FROM library_books WHERE collection_id = ?)", arguments: [collectionID, collectionID])
        }
        let hash: String = book["hash"]
        try db.execute(sql: "DELETE FROM gallery_metadata WHERE hash = ? AND NOT EXISTS(SELECT 1 FROM library_books WHERE hash = ?)", arguments: [hash, hash])
        // Empty records have no remaining decisions to preserve.
        for table in ["version", "collection"] {
            try db.execute(sql: "DELETE FROM \(table)_recommendations WHERE NOT EXISTS(SELECT 1 FROM \(table)_recommendation_members WHERE recommendation_id = \(table)_recommendations.id)")
        }
        try invalidateRecommendations(db)
        try reconcileBatches(db)
    }

    static func repair(_ db: Database, backfillDeletedCounts: Bool = false) throws {
        try db.execute(sql: """
            UPDATE library_books SET collection_id = NULL, collection_order = NULL WHERE collection_id IS NOT NULL AND NOT EXISTS(SELECT 1 FROM book_collections WHERE id = collection_id);
            DELETE FROM book_version_labels WHERE book_id IN (SELECT id FROM library_books WHERE version_group_id IS NOT NULL AND NOT EXISTS(SELECT 1 FROM book_version_groups WHERE id = version_group_id));
            UPDATE library_books SET version_group_id = NULL, is_primary_version = 1, version_label = NULL WHERE version_group_id IS NOT NULL AND NOT EXISTS(SELECT 1 FROM book_version_groups WHERE id = version_group_id);
            """)
        for id in try Int64.fetchAll(db, sql: "SELECT id FROM book_version_groups") { try normalizeGroup(db, id: id) }
        try db.execute(sql: """
            DELETE FROM book_collections WHERE NOT EXISTS(SELECT 1 FROM library_books WHERE collection_id = book_collections.id);
            UPDATE library_books SET is_primary_version = 1 WHERE version_group_id IS NULL AND is_primary_version <> 1;
            UPDATE library_books SET hidden_book = (collection_id IS NOT NULL OR (version_group_id IS NOT NULL AND is_primary_version = 0))
            WHERE hidden_book <> (collection_id IS NOT NULL OR (version_group_id IS NOT NULL AND is_primary_version = 0));
            """)
        try invalidateRecommendations(db)
        try reconcileBatches(db, backfillDeletedCounts: backfillDeletedCounts)
    }
}
