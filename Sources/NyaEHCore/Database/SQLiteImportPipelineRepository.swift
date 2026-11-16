// 本文件使用 SQLite 保存导入批次边界和逐书阶段，使流水线可跨启动恢复。

import Foundation
import GRDB

final class SQLiteImportPipelineRepository: ImportPipelineRepository {
    private let dbQueue: any DatabaseWriter

    init(dbQueue: any DatabaseWriter) {
        self.dbQueue = dbQueue
    }

    func recoverInterruptedWork() throws {
        try dbQueue.write { db in
            let now = Timestamp.nowMilliseconds()
            try db.execute(
                sql: """
                    UPDATE import_pipeline_items
                    SET stage = ?, updated_at = ?
                    WHERE stage = ?
                    """,
                arguments: [
                    ImportPipelineItemStage.metadataPending.rawValue,
                    now,
                    ImportPipelineItemStage.metadataRunning.rawValue
                ]
            )
            try db.execute(
                sql: """
                    UPDATE import_pipeline_batches
                    SET status = ?, updated_at = ?
                    WHERE status = ? AND stage IN (?, ?)
                    """,
                arguments: [
                    ImportPipelineBatchStatus.paused.rawValue,
                    now,
                    ImportPipelineBatchStatus.running.rawValue,
                    ImportPipelineBatchStage.versionAnalysis.rawValue,
                    ImportPipelineBatchStage.collectionAnalysis.rawValue
                ]
            )
        }
    }

    func reconcile(books: [LibraryBook]) throws {
        try dbQueue.write { db in
            let now = Timestamp.nowMilliseconds()
            for book in books {
                guard let bookID = book.databaseID else { continue }
                let existing = try Row.fetchOne(
                    db,
                    sql: """
                        SELECT item.id, item.batch_id, item.source_hash, item.stage,
                               batch.status AS batch_status
                        FROM import_pipeline_items AS item
                        LEFT JOIN import_pipeline_batches AS batch ON batch.id = item.batch_id
                        WHERE item.book_id = ?
                        """,
                    arguments: [bookID]
                )

                if book.status == .unscanned, book.exist {
                    if let existing {
                        let sourceHash: String = existing["source_hash"]
                        let stage = ImportPipelineItemStage(rawValue: existing["stage"]) ?? .metadataPending
                        let batchID: Int64? = existing["batch_id"]
                        let batchStatusRaw: String? = existing["batch_status"]
                        let belongsToActiveBatch = batchID != nil
                            && batchStatusRaw != ImportPipelineBatchStatus.completed.rawValue
                        if sourceHash != book.hash, belongsToActiveBatch {
                            try db.execute(
                                sql: """
                                    UPDATE import_pipeline_items
                                    SET stage = ?, last_error_kind = ?, last_error_message = ?, updated_at = ?
                                    WHERE book_id = ?
                                    """,
                                arguments: [
                                    ImportPipelineItemStage.sourceNeedsAttention.rawValue,
                                    "sourceChangedDuringBatch",
                                    "The source archive changed after this batch was created. Rescan it in the next batch.",
                                    now,
                                    bookID
                                ]
                            )
                        } else if sourceHash != book.hash
                            || !stage.isIncomplete
                            || (stage == .sourceNeedsAttention && !belongsToActiveBatch) {
                            let requiresGroupingConfirmation = sourceHash != book.hash
                                && (book.collectionID != nil || book.versionGroupID != nil)
                            try db.execute(
                                sql: """
                                    UPDATE import_pipeline_items
                                    SET batch_id = NULL,
                                        source_hash = ?, source_mtime = ?, stage = ?, metadata_source = NULL,
                                        attempt_count = 0, last_error_kind = ?, last_error_message = ?,
                                        retry_after = NULL, completed_at = NULL, updated_at = ?
                                    WHERE book_id = ?
                                    """,
                                arguments: [
                                    book.hash,
                                    book.mtime,
                                    requiresGroupingConfirmation
                                        ? ImportPipelineItemStage.metadataDeferred.rawValue
                                        : ImportPipelineItemStage.metadataPending.rawValue,
                                    requiresGroupingConfirmation ? "groupingNeedsConfirmation" : nil,
                                    requiresGroupingConfirmation
                                        ? "The archive content changed. Confirm that its existing collection and version memberships should be retained before retrying."
                                        : nil,
                                    now,
                                    bookID
                                ]
                            )
                        }
                    } else {
                        try db.execute(
                            sql: """
                                INSERT INTO import_pipeline_items (
                                    batch_id, book_id, source_hash, source_mtime, stage,
                                    attempt_count, created_at, updated_at
                                ) VALUES (NULL, ?, ?, ?, ?, 0, ?, ?)
                                """,
                            arguments: [
                                bookID,
                                book.hash,
                                book.mtime,
                                ImportPipelineItemStage.metadataPending.rawValue,
                                now,
                                now
                            ]
                        )
                    }
                } else if let existing {
                    let stage = ImportPipelineItemStage(rawValue: existing["stage"]) ?? .metadataPending
                    let batchID: Int64? = existing["batch_id"]
                    let batchStatusRaw: String? = existing["batch_status"]
                    let belongsToActiveBatch = batchID != nil
                        && batchStatusRaw != ImportPipelineBatchStatus.completed.rawValue
                    if book.status == .broken || !book.exist || book.status == .missing {
                        guard stage.isIncomplete else { continue }
                        try db.execute(
                            sql: """
                                UPDATE import_pipeline_items
                                SET stage = ?, last_error_kind = ?, last_error_message = ?, updated_at = ?
                                WHERE book_id = ?
                                """,
                            arguments: [
                                ImportPipelineItemStage.sourceNeedsAttention.rawValue,
                                "sourceUnavailable",
                                "The source archive is missing or broken.",
                                now,
                                bookID
                            ]
                        )
                    } else if book.status == .correct
                        && (stage == .metadataPending
                            || (!belongsToActiveBatch && (stage == .metadataDeferred || stage == .sourceNeedsAttention))) {
                        let nextBatchID = belongsToActiveBatch && stage == .metadataPending ? batchID : nil
                        try db.execute(
                            sql: """
                                UPDATE import_pipeline_items
                                SET batch_id = ?, stage = ?, metadata_source = ?, last_error_kind = NULL,
                                    last_error_message = NULL, retry_after = NULL, updated_at = ?
                                WHERE book_id = ?
                                """,
                            arguments: [
                                nextBatchID,
                                ImportPipelineItemStage.versionAnalysisPending.rawValue,
                                ImportMetadataSource.manual.rawValue,
                                now,
                                bookID
                            ]
                        )
                    }
                }
            }
        }
    }

    func createBatchFromPendingItems() throws -> ImportPipelineBatch? {
        try dbQueue.write { db in
            if let row = try Row.fetchOne(
                db,
                sql: """
                    SELECT id, status, stage, pause_reason, deleted_count, total_count, ready_count,
                           deferred_count, review_count, failed_count, created_at,
                           started_at, completed_at, updated_at
                    FROM import_pipeline_batches
                    WHERE status <> ?
                    ORDER BY id DESC LIMIT 1
                    """,
                arguments: [ImportPipelineBatchStatus.completed.rawValue]
            ) {
                return Self.batch(from: row)
            }

            let itemIDs = try Int64.fetchAll(
                db,
                sql: """
                    SELECT id FROM import_pipeline_items
                    WHERE batch_id IS NULL AND stage IN (?, ?)
                    ORDER BY created_at ASC, id ASC
                    """,
                arguments: [
                    ImportPipelineItemStage.metadataPending.rawValue,
                    ImportPipelineItemStage.versionAnalysisPending.rawValue
                ]
            )
            guard !itemIDs.isEmpty else { return nil }

            let now = Timestamp.nowMilliseconds()
            try db.execute(
                sql: """
                    INSERT INTO import_pipeline_batches (
                        status, stage, total_count, ready_count, deferred_count,
                        review_count, failed_count, created_at, started_at, updated_at
                    ) VALUES (?, ?, ?, 0, 0, 0, 0, ?, ?, ?)
                    """,
                arguments: [
                    ImportPipelineBatchStatus.running.rawValue,
                    ImportPipelineBatchStage.metadata.rawValue,
                    itemIDs.count,
                    now,
                    now,
                    now
                ]
            )
            let batchID = db.lastInsertedRowID
            let placeholders = Array(repeating: "?", count: itemIDs.count).joined(separator: ",")
            var arguments: StatementArguments = [batchID, now]
            arguments += StatementArguments(itemIDs)
            try db.execute(
                sql: "UPDATE import_pipeline_items SET batch_id = ?, updated_at = ? WHERE id IN (\(placeholders))",
                arguments: arguments
            )
            return ImportPipelineBatch(
                id: batchID,
                status: .running,
                stage: .metadata,
                pauseReason: nil,
                totalCount: itemIDs.count,
                readyCount: 0,
                deferredCount: 0,
                reviewCount: 0,
                failedCount: 0,
                createdAt: now,
                startedAt: now,
                completedAt: nil,
                updatedAt: now
            )
        }
    }

    func fetchActiveBatch() throws -> ImportPipelineBatch? {
        try dbQueue.read { db in
            try Row.fetchOne(
                db,
                sql: """
                    SELECT id, status, stage, pause_reason, deleted_count, total_count, ready_count,
                           deferred_count, review_count, failed_count, created_at,
                           started_at, completed_at, updated_at
                    FROM import_pipeline_batches
                    WHERE status <> ?
                    ORDER BY id DESC LIMIT 1
                    """,
                arguments: [ImportPipelineBatchStatus.completed.rawValue]
            ).map(Self.batch(from:))
        }
    }

    func fetchItems(batchID: ImportPipelineBatch.ID) throws -> [ImportPipelineItem] {
        try dbQueue.read { db in
            try Row.fetchAll(
                db,
                sql: "SELECT * FROM import_pipeline_items WHERE batch_id = ? ORDER BY created_at ASC, id ASC",
                arguments: [batchID]
            ).map(Self.item(from:))
        }
    }

    func fetchAllItems() throws -> [ImportPipelineItem] {
        try dbQueue.read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM import_pipeline_items ORDER BY updated_at DESC, id DESC")
                .map(Self.item(from:))
        }
    }

    func fetchItem(bookID: LibraryBook.DatabaseID) throws -> ImportPipelineItem? {
        try dbQueue.read { db in
            try Row.fetchOne(
                db,
                sql: "SELECT * FROM import_pipeline_items WHERE book_id = ?",
                arguments: [bookID]
            ).map(Self.item(from:))
        }
    }

    func updateBatch(_ batch: ImportPipelineBatch) throws {
        try dbQueue.write { db in
            try db.execute(
                sql: """
                    UPDATE import_pipeline_batches
                    SET status = ?, stage = ?, pause_reason = ?, total_count = ?, ready_count = ?,
                        deferred_count = ?, review_count = ?, failed_count = ?, started_at = ?,
                        completed_at = ?, updated_at = ?
                    WHERE id = ?
                    """,
                arguments: [
                    batch.status.rawValue,
                    batch.stage.rawValue,
                    batch.pauseReason,
                    batch.totalCount,
                    batch.readyCount,
                    batch.deferredCount,
                    batch.reviewCount,
                    batch.failedCount,
                    batch.startedAt,
                    batch.completedAt,
                    Timestamp.nowMilliseconds(),
                    batch.id
                ]
            )
        }
    }

    func updateItem(_ item: ImportPipelineItem) throws {
        try dbQueue.write { db in
            try db.execute(
                sql: """
                    UPDATE import_pipeline_items
                    SET batch_id = ?, source_hash = ?, source_mtime = ?, stage = ?, metadata_source = ?,
                        preferred_gallery_url = ?, attempt_count = ?, last_error_kind = ?,
                        last_error_message = ?, retry_after = ?, completed_at = ?, updated_at = ?
                    WHERE id = ?
                    """,
                arguments: [
                    item.batchID,
                    item.sourceHash,
                    item.sourceMtime,
                    item.stage.rawValue,
                    item.metadataSource?.rawValue,
                    item.preferredGalleryURL,
                    item.attemptCount,
                    item.lastErrorKind,
                    item.lastErrorMessage,
                    item.retryAfter,
                    item.completedAt,
                    Timestamp.nowMilliseconds(),
                    item.id
                ]
            )
        }
    }

    private static func batch(from row: Row) -> ImportPipelineBatch {
        ImportPipelineBatch(
            id: row["id"],
            status: ImportPipelineBatchStatus(rawValue: row["status"]) ?? .paused,
            stage: ImportPipelineBatchStage(rawValue: row["stage"]) ?? .metadata,
            pauseReason: row["pause_reason"],
            deletedCount: row["deleted_count"],
            totalCount: row["total_count"],
            readyCount: row["ready_count"],
            deferredCount: row["deferred_count"],
            reviewCount: row["review_count"],
            failedCount: row["failed_count"],
            createdAt: row["created_at"],
            startedAt: row["started_at"],
            completedAt: row["completed_at"],
            updatedAt: row["updated_at"]
        )
    }

    private static func item(from row: Row) -> ImportPipelineItem {
        let metadataSourceRaw: String? = row["metadata_source"]
        return ImportPipelineItem(
            id: row["id"],
            batchID: row["batch_id"],
            bookID: row["book_id"],
            sourceHash: row["source_hash"],
            sourceMtime: row["source_mtime"],
            stage: ImportPipelineItemStage(rawValue: row["stage"]) ?? .metadataPending,
            metadataSource: metadataSourceRaw.flatMap(ImportMetadataSource.init(rawValue:)),
            preferredGalleryURL: row["preferred_gallery_url"],
            attemptCount: row["attempt_count"],
            lastErrorKind: row["last_error_kind"],
            lastErrorMessage: row["last_error_message"],
            retryAfter: row["retry_after"],
            createdAt: row["created_at"],
            updatedAt: row["updated_at"],
            completedAt: row["completed_at"]
        )
    }
}
