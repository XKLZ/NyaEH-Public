// 本文件维护作品-角色索引缓存，把 parody 和 character 标签关系物化给作品详情页使用。

import Foundation
import GRDB

final class SQLiteWorkCharacterRepository: WorkCharacterRepository {
    private let dbQueue: any DatabaseWriter
    private static let stateID: Int64 = 1

    init(dbQueue: any DatabaseWriter) {
        self.dbQueue = dbQueue
    }

    func rebuildIndex() throws -> WorkCharacterIndexUpdateResult {
        try dbQueue.write { db in
            try db.execute(sql: "DELETE FROM book_work_character_links")
            let processedBooks = try eligibleBookCount(db: db, since: nil)
            try insertLinks(db: db, since: nil)
            let linkCount = try currentLinkCount(db: db)
            try updateState(db: db, fullRebuild: true)
            return WorkCharacterIndexUpdateResult(
                processedBooks: processedBooks,
                linkCount: linkCount,
                didChange: true
            )
        }
    }

    func updateIndexIncrementally() throws -> WorkCharacterIndexUpdateResult {
        try dbQueue.write { db in
            guard let lastIndexedAt = try lastIndexedBookUpdatedAt(db: db) else {
                try db.execute(sql: "DELETE FROM book_work_character_links")
                let processedBooks = try eligibleBookCount(db: db, since: nil)
                try insertLinks(db: db, since: nil)
                let linkCount = try currentLinkCount(db: db)
                try updateState(db: db, fullRebuild: true)
                return WorkCharacterIndexUpdateResult(
                    processedBooks: processedBooks,
                    linkCount: linkCount,
                    didChange: true
                )
            }

            let changedBookIDs = try Int64.fetchAll(
                db,
                sql: "SELECT id FROM library_books WHERE updated_at > ?",
                arguments: [lastIndexedAt]
            )
            guard !changedBookIDs.isEmpty else {
                return .noChanges
            }

            try deleteLinks(db: db, bookIDs: changedBookIDs)
            try insertLinks(db: db, since: lastIndexedAt)
            let linkCount = try currentLinkCount(db: db)
            try updateState(db: db, fullRebuild: false)
            return WorkCharacterIndexUpdateResult(
                processedBooks: changedBookIDs.count,
                linkCount: linkCount,
                didChange: true
            )
        }
    }

    func hasIncrementalChanges() throws -> Bool {
        try dbQueue.read { db in
            guard let lastIndexedAt = try lastIndexedBookUpdatedAt(db: db) else {
                return true
            }
            let latestBookUpdatedAt = try Int64.fetchOne(
                db,
                sql: "SELECT MAX(updated_at) FROM library_books"
            ) ?? 0
            return latestBookUpdatedAt > lastIndexedAt
        }
    }

    func fetchWorks(languageCode: String?) throws -> [WorkCharacterWorkSummary] {
        try dbQueue.read { db in
            try Self.fetchWorkRows(db: db, languageCode: languageCode).map { row in
                WorkCharacterWorkSummary(
                    tag: Self.displaySummary(row: row),
                    characterCount: row["character_count"],
                    bookCount: row["book_count"]
                )
            }
        }
    }

    func fetchCharacters(
        parodyTagID: Tag.DatabaseID,
        languageCode: String?
    ) throws -> [WorkCharacterCharacterSummary] {
        try dbQueue.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: Self.characterSQL(includesTranslations: languageCode != nil),
                arguments: Self.characterArguments(parodyTagID: parodyTagID, languageCode: languageCode)
            )
            return rows.map { row in
                WorkCharacterCharacterSummary(
                    tag: Self.displaySummary(row: row),
                    bookCount: row["book_count"]
                )
            }
        }
    }

    private func insertLinks(db: Database, since lastIndexedAt: Int64?) throws {
        let now = Timestamp.nowMilliseconds()
        var arguments = StatementArguments()
        var staleFilter = ""
        if let lastIndexedAt {
            staleFilter = "WHERE library_books.updated_at > ?"
            arguments += [lastIndexedAt]
        }
        arguments += [now, now]

        try db.execute(
            sql: """
                WITH stale_books AS (
                    SELECT library_books.id
                    FROM library_books
                    \(staleFilter)
                ),
                parody_books AS (
                    SELECT book_tags.book_id,
                           MIN(tags.id) AS parody_tag_id,
                           COUNT(DISTINCT tags.id) AS parody_count,
                           MIN(tags.name) AS parody_name
                    FROM book_tags
                    JOIN tags ON tags.id = book_tags.tag_id
                    JOIN stale_books ON stale_books.id = book_tags.book_id
                    WHERE tags.namespace = 'parody'
                    GROUP BY book_tags.book_id
                )
                INSERT OR IGNORE INTO book_work_character_links (
                    book_id,
                    parody_tag_id,
                    character_tag_id,
                    created_at,
                    updated_at
                )
                SELECT DISTINCT
                    character_tags.book_id,
                    parody_books.parody_tag_id,
                    character_tags.tag_id,
                    ?,
                    ?
                FROM parody_books
                JOIN book_tags AS character_tags
                  ON character_tags.book_id = parody_books.book_id
                JOIN tags AS characters
                  ON characters.id = character_tags.tag_id
                 AND characters.namespace = 'character'
                WHERE parody_books.parody_count = 1
                  AND LOWER(TRIM(parody_books.parody_name)) <> 'origin'
                """,
            arguments: arguments
        )
    }

    private func deleteLinks(db: Database, bookIDs: [LibraryBook.DatabaseID]) throws {
        guard !bookIDs.isEmpty else {
            return
        }
        let placeholders = Array(repeating: "?", count: bookIDs.count).joined(separator: ",")
        try db.execute(
            sql: "DELETE FROM book_work_character_links WHERE book_id IN (\(placeholders))",
            arguments: StatementArguments(bookIDs)
        )
    }

    private func updateState(db: Database, fullRebuild: Bool) throws {
        let now = Timestamp.nowMilliseconds()
        let latestBookUpdatedAt = try Int64.fetchOne(
            db,
            sql: "SELECT MAX(updated_at) FROM library_books"
        ) ?? 0
        try db.execute(
            sql: """
                INSERT INTO work_character_index_state (
                    id,
                    last_indexed_book_updated_at,
                    last_full_rebuild_at,
                    updated_at
                )
                VALUES (?, ?, ?, ?)
                ON CONFLICT(id) DO UPDATE SET
                    last_indexed_book_updated_at = excluded.last_indexed_book_updated_at,
                    last_full_rebuild_at = CASE
                        WHEN ? THEN excluded.last_full_rebuild_at
                        ELSE work_character_index_state.last_full_rebuild_at
                    END,
                    updated_at = excluded.updated_at
                """,
            arguments: [
                Self.stateID,
                latestBookUpdatedAt,
                fullRebuild ? now : nil,
                now,
                fullRebuild ? 1 : 0
            ]
        )
    }

    private func lastIndexedBookUpdatedAt(db: Database) throws -> Int64? {
        try Int64.fetchOne(
            db,
            sql: "SELECT last_indexed_book_updated_at FROM work_character_index_state WHERE id = ?",
            arguments: [Self.stateID]
        )
    }

    private func eligibleBookCount(db: Database, since lastIndexedAt: Int64?) throws -> Int {
        var sql = "SELECT COUNT(*) FROM library_books"
        var arguments = StatementArguments()
        if let lastIndexedAt {
            sql += " WHERE updated_at > ?"
            arguments += [lastIndexedAt]
        }
        return try Int.fetchOne(db, sql: sql, arguments: arguments) ?? 0
    }

    private func currentLinkCount(db: Database) throws -> Int {
        try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM book_work_character_links") ?? 0
    }

    private static func fetchWorkRows(db: Database, languageCode: String?) throws -> [Row] {
        try Row.fetchAll(
            db,
            sql: workSQL(includesTranslations: languageCode != nil),
            arguments: workArguments(languageCode: languageCode)
        )
    }

    private static func displaySummary(row: Row) -> TagDisplaySummary {
        let linksJSON: String? = row["links"]
        let linksData = linksJSON?.data(using: .utf8) ?? Data()
        let links = (try? JSONDecoder().decode([String].self, from: linksData)) ?? []
        return TagDisplaySummary(
            id: row["id"],
            namespace: row["namespace"],
            name: row["name"],
            rawValue: row["raw_value"],
            displayName: row["translated_name"] ?? row["name"],
            translationIntro: row["intro"],
            translationLinks: links,
            isFollowed: (row["is_followed"] as Int) != 0,
            count: row["tag_count"]
        )
    }

    private static func workSQL(includesTranslations: Bool) -> String {
        summarySQL(
            includesTranslations: includesTranslations,
            extraColumns: """
                   COUNT(DISTINCT book_work_character_links.character_tag_id) AS character_count,
                   COUNT(DISTINCT book_work_character_links.book_id) AS book_count
            """,
            joinSQL: """
            JOIN book_work_character_links
              ON book_work_character_links.parody_tag_id = tags.id
            """,
            whereSQL: "WHERE tags.namespace = 'parody'",
            orderSQL: "character_count DESC, book_count DESC, tags.name COLLATE NOCASE ASC"
        )
    }

    private static func characterSQL(includesTranslations: Bool) -> String {
        summarySQL(
            includesTranslations: includesTranslations,
            extraColumns: """
                   0 AS character_count,
                   COUNT(DISTINCT book_work_character_links.book_id) AS book_count
            """,
            joinSQL: """
            JOIN book_work_character_links
              ON book_work_character_links.character_tag_id = tags.id
            """,
            whereSQL: "WHERE tags.namespace = 'character' AND book_work_character_links.parody_tag_id = ?",
            orderSQL: "book_count DESC, tags.name COLLATE NOCASE ASC"
        )
    }

    private static func summarySQL(
        includesTranslations: Bool,
        extraColumns: String,
        joinSQL: String,
        whereSQL: String,
        orderSQL: String
    ) -> String {
        let translationColumns = includesTranslations
            ? """
              tag_translations.translated_name,
              tag_translations.intro,
              tag_translations.links,
              """
            : """
              NULL AS translated_name,
              NULL AS intro,
              NULL AS links,
              """
        let translationJoin = includesTranslations
            ? """
            LEFT JOIN tag_translations
              ON tag_translations.tag_id = tags.id
             AND tag_translations.language_code = ?
            """
            : ""

        return """
            SELECT tags.id,
                   tags.namespace,
                   tags.name,
                   tags.raw_value,
                   \(translationColumns)
                   followed_tags.tag_id IS NOT NULL AS is_followed,
                   total_counts.tag_count,
                   \(extraColumns)
            FROM tags
            \(joinSQL)
            JOIN (
                SELECT tag_id, COUNT(book_id) AS tag_count
                FROM book_tags
                GROUP BY tag_id
            ) AS total_counts ON total_counts.tag_id = tags.id
            \(translationJoin)
            LEFT JOIN followed_tags ON followed_tags.tag_id = tags.id
            \(whereSQL)
            GROUP BY tags.id
            ORDER BY \(orderSQL)
            """
    }

    private static func workArguments(languageCode: String?) -> StatementArguments {
        var arguments = StatementArguments()
        if let languageCode {
            arguments += [languageCode]
        }
        return arguments
    }

    private static func characterArguments(
        parodyTagID: Tag.DatabaseID,
        languageCode: String?
    ) -> StatementArguments {
        var arguments = StatementArguments()
        if let languageCode {
            arguments += [languageCode]
        }
        arguments += [parodyTagID]
        return arguments
    }
}
