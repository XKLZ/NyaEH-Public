// 本文件实现标签、书籍标签关系、翻译和关注标签的 SQLite 持久化。

import Foundation
import GRDB

final class SQLiteTagRepository: TagRepository {
    private let dbQueue: any DatabaseWriter

    init(dbQueue: any DatabaseWriter) {
        self.dbQueue = dbQueue
    }

    func rebuildTags(forBookID bookID: LibraryBook.DatabaseID, tagsJSON: String) throws {
        let tags = TagParser.parseJSON(tagsJSON)
        let derived = TagParser.derivedState(from: tags)

        try dbQueue.write { db in
            try db.execute(sql: "DELETE FROM book_tags WHERE book_id = ?", arguments: [bookID])

            for tag in tags {
                let tagID = try upsert(tag: tag, in: db)
                try db.execute(
                    sql: """
                        INSERT OR IGNORE INTO book_tags (book_id, tag_id)
                        VALUES (?, ?)
                        """,
                    arguments: [bookID, tagID]
                )
            }

            try db.execute(
                sql: """
                    UPDATE library_books
                    SET language_code = ?,
                        is_translated = ?,
                        is_full_color = ?,
                        censorship = ?,
                        has_extraneous_ads = ?,
                        updated_at = ?
                    WHERE id = ?
                    """,
                arguments: [
                    derived.languageCode,
                    derived.isTranslated ? 1 : 0,
                    derived.isFullColor ? 1 : 0,
                    derived.censorship,
                    derived.hasExtraneousAds ? 1 : 0,
                    Timestamp.nowMilliseconds(),
                    bookID
                ]
            )
        }
    }

    func rebuildAllTags(from books: [LibraryBook]) throws {
        let indexedBooks = books.compactMap { book -> (LibraryBook.DatabaseID, String)? in
            guard let id = book.databaseID else {
                return nil
            }
            return (id, book.tags)
        }

        try dbQueue.write { db in
            try db.execute(sql: "DELETE FROM book_tags")

            for (bookID, tagsJSON) in indexedBooks {
                let tags = TagParser.parseJSON(tagsJSON)
                let derived = TagParser.derivedState(from: tags)

                for tag in tags {
                    let tagID = try upsert(tag: tag, in: db)
                    try db.execute(
                        sql: """
                            INSERT OR IGNORE INTO book_tags (book_id, tag_id)
                            VALUES (?, ?)
                            """,
                        arguments: [bookID, tagID]
                    )
                }

                try db.execute(
                    sql: """
                        UPDATE library_books
                        SET language_code = ?,
                            is_translated = ?,
                            is_full_color = ?,
                            censorship = ?,
                            has_extraneous_ads = ?,
                            updated_at = ?
                        WHERE id = ?
                        """,
                    arguments: [
                        derived.languageCode,
                        derived.isTranslated ? 1 : 0,
                        derived.isFullColor ? 1 : 0,
                        derived.censorship,
                        derived.hasExtraneousAds ? 1 : 0,
                        Timestamp.nowMilliseconds(),
                        bookID
                    ]
                )
            }
        }
    }

    func indexedBookTagCount() throws -> Int {
        try dbQueue.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM book_tags") ?? 0
        }
    }

    func summaries(namespace: String? = nil) throws -> [TagSummary] {
        try summaries(namespace: namespace, languageCode: nil)
    }

    func summaries(namespace: String? = nil, languageCode: String?) throws -> [TagSummary] {
        try dbQueue.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: Self.summarySQL(namespace: namespace != nil, includesTranslations: languageCode != nil),
                arguments: Self.summaryArguments(namespace: namespace, languageCode: languageCode)
            )
            let decoder = JSONDecoder()

            return rows.map { row in
                let linksJSON: String? = row["links"]
                let linksData = linksJSON?.data(using: .utf8) ?? Data()
                let links = (try? decoder.decode([String].self, from: linksData)) ?? []
                return TagSummary(
                    id: row["id"],
                    namespace: row["namespace"],
                    name: row["name"],
                    rawValue: row["raw_value"],
                    translatedName: row["translated_name"],
                    translationIntro: row["intro"],
                    translationLinks: links,
                    isFollowed: (row["is_followed"] as Int) != 0,
                    count: row["count"]
                )
            }
        }
    }

    func topSummaries(
        namespaces: [String],
        limit: Int,
        languageCode: String?
    ) throws -> [TagSummary] {
        let normalizedNamespaces = Array(
            Set(
                namespaces
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
                    .filter { !$0.isEmpty }
            )
        ).sorted()
        guard !normalizedNamespaces.isEmpty, limit > 0 else {
            return []
        }

        return try dbQueue.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: Self.topSummarySQL(namespaceCount: normalizedNamespaces.count, includesTranslations: languageCode != nil),
                arguments: Self.topSummaryArguments(
                    namespaces: normalizedNamespaces,
                    limit: limit,
                    languageCode: languageCode
                )
            )
            let decoder = JSONDecoder()

            return rows.map { row in
                let linksJSON: String? = row["links"]
                let linksData = linksJSON?.data(using: .utf8) ?? Data()
                let links = (try? decoder.decode([String].self, from: linksData)) ?? []
                return TagSummary(
                    id: row["id"],
                    namespace: row["namespace"],
                    name: row["name"],
                    rawValue: row["raw_value"],
                    translatedName: row["translated_name"],
                    translationIntro: row["intro"],
                    translationLinks: links,
                    isFollowed: (row["is_followed"] as Int) != 0,
                    count: row["count"]
                )
            }
        }
    }

    func tags(forBookID bookID: LibraryBook.DatabaseID) throws -> [Tag] {
        try dbQueue.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                    SELECT tags.id, tags.namespace, tags.name, tags.raw_value, tags.created_at, tags.updated_at
                    FROM tags
                    JOIN book_tags ON book_tags.tag_id = tags.id
                    WHERE book_tags.book_id = ?
                    ORDER BY tags.namespace COLLATE NOCASE ASC, tags.name COLLATE NOCASE ASC
                    """,
                arguments: [bookID]
            )

            return rows.map { row in
                Tag(
                    id: row["id"],
                    namespace: row["namespace"],
                    name: row["name"],
                    rawValue: row["raw_value"],
                    createdAt: row["created_at"],
                    updatedAt: row["updated_at"]
                )
            }
        }
    }

    func bookIDs(namespace: String, name: String) throws -> [LibraryBook.DatabaseID] {
        try dbQueue.read { db in
            try Int64.fetchAll(
                db,
                sql: """
                    SELECT book_tags.book_id
                    FROM book_tags
                    JOIN tags ON tags.id = book_tags.tag_id
                    WHERE tags.namespace = ? AND tags.name = ?
                    ORDER BY book_tags.book_id ASC
                    """,
                arguments: [namespace.lowercased(), name.lowercased()]
            )
        }
    }

    func followedTagIDs() throws -> Set<Tag.DatabaseID> {
        try dbQueue.read { db in
            Set(try Int64.fetchAll(db, sql: "SELECT tag_id FROM followed_tags"))
        }
    }

    func setFollowed(tagID: Tag.DatabaseID, isFollowed: Bool) throws {
        try dbQueue.write { db in
            if isFollowed {
                let now = Timestamp.nowMilliseconds()
                try db.execute(
                    sql: """
                        INSERT INTO followed_tags (tag_id, created_at, updated_at)
                        VALUES (?, ?, ?)
                        ON CONFLICT(tag_id) DO UPDATE SET
                            updated_at = excluded.updated_at
                        """,
                    arguments: [tagID, now, now]
                )
            } else {
                try db.execute(
                    sql: "DELETE FROM followed_tags WHERE tag_id = ?",
                    arguments: [tagID]
                )
            }
        }
    }

    func upsertTranslation(tagID: Tag.DatabaseID, languageCode: String, translatedName: String) throws {
        try dbQueue.write { db in
            try db.execute(
                sql: """
                    INSERT INTO tag_translations (
                        tag_id, language_code, translated_name, updated_at
                    )
                    VALUES (?, ?, ?, ?)
                    ON CONFLICT(tag_id, language_code) DO UPDATE SET
                        translated_name = excluded.translated_name,
                        updated_at = excluded.updated_at
                    """,
                arguments: [tagID, languageCode, translatedName, Timestamp.nowMilliseconds()]
            )
        }
    }

    func fetchAllTags() throws -> [Tag] {
        try dbQueue.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                    SELECT id, namespace, name, raw_value, created_at, updated_at
                    FROM tags
                    ORDER BY namespace COLLATE NOCASE ASC, name COLLATE NOCASE ASC
                    """
            )

            return rows.map { row in
                Tag(
                    id: row["id"],
                    namespace: row["namespace"],
                    name: row["name"],
                    rawValue: row["raw_value"],
                    createdAt: row["created_at"],
                    updatedAt: row["updated_at"]
                )
            }
        }
    }

    func materializeTranslations(
        _ translations: [ExternalTagTranslation],
        languageCode: String,
        source: String,
        sourceRevision: String
    ) throws -> Int {
        let translationIndex = Dictionary(
            translations.map { (Self.translationKey(namespace: $0.namespace, name: $0.name), $0) },
            uniquingKeysWith: { first, _ in first }
        )
        let encoder = JSONEncoder()
        let now = Timestamp.nowMilliseconds()

        return try dbQueue.write { db in
            let tags = try Row.fetchAll(
                db,
                sql: "SELECT id, namespace, name FROM tags"
            )
            var count = 0

            for row in tags {
                let namespace: String = row["namespace"]
                let name: String = row["name"]
                guard let translation = translationIndex[Self.translationKey(namespace: namespace, name: name)] else {
                    continue
                }

                let linksData = try encoder.encode(translation.links)
                let linksJSON = String(data: linksData, encoding: .utf8) ?? "[]"

                try db.execute(
                    sql: """
                        INSERT INTO tag_translations (
                            tag_id,
                            language_code,
                            translated_name,
                            intro,
                            links,
                            source,
                            source_revision,
                            updated_at
                        )
                        VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                        ON CONFLICT(tag_id, language_code) DO UPDATE SET
                            translated_name = excluded.translated_name,
                            intro = excluded.intro,
                            links = excluded.links,
                            source = excluded.source,
                            source_revision = excluded.source_revision,
                            updated_at = excluded.updated_at
                        """,
                    arguments: [
                        row["id"] as Int64,
                        languageCode,
                        translation.translatedName,
                        translation.intro,
                        linksJSON,
                        source,
                        sourceRevision,
                        now
                    ]
                )
                count += 1
            }

            return count
        }
    }

    func translation(for tag: Tag, languageCode: String) throws -> TagResolvedTranslation? {
        guard let tagID = tag.id else {
            return nil
        }

        return try dbQueue.read { db -> TagResolvedTranslation? in
            let row = try Row.fetchOne(
                db,
                sql: """
                    SELECT translated_name, intro, links, source, source_revision
                    FROM tag_translations
                    WHERE tag_id = ? AND language_code = ?
                    """,
                arguments: [tagID, languageCode]
            )
            guard let row else {
                return nil
            }

            let linksJSON: String = row["links"]
            let linksData = linksJSON.data(using: .utf8) ?? Data()
            let links = (try? JSONDecoder().decode([String].self, from: linksData)) ?? []
            return TagResolvedTranslation(
                translatedName: row["translated_name"],
                intro: row["intro"],
                links: links,
                source: row["source"],
                sourceRevision: row["source_revision"]
            )
        }
    }

    private func upsert(tag: Tag, in db: Database) throws -> Tag.DatabaseID {
        let now = Timestamp.nowMilliseconds()
        try db.execute(
            sql: """
                INSERT INTO tags (namespace, name, raw_value, created_at, updated_at)
                VALUES (?, ?, ?, ?, ?)
                ON CONFLICT(raw_value) DO UPDATE SET
                    namespace = excluded.namespace,
                    name = excluded.name,
                    updated_at = excluded.updated_at
                """,
            arguments: [tag.namespace, tag.name, tag.rawValue, now, now]
        )

        guard let tagID = try Int64.fetchOne(
            db,
            sql: "SELECT id FROM tags WHERE raw_value = ?",
            arguments: [tag.rawValue]
        ) else {
            throw NyaEHError.databaseInvariantViolation("Tag upsert did not return a row for \(tag.rawValue).")
        }
        return tagID
    }

    private static func translationKey(namespace: String, name: String) -> String {
        "\(namespace.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()):\(name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())"
    }

    private static func summarySQL(namespace: Bool, includesTranslations: Bool) -> String {
        let translationColumns = includesTranslations
            ? """
              tag_translations.translated_name AS translated_name,
              tag_translations.intro AS intro,
              tag_translations.links AS links,
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
        let namespaceFilter = namespace ? "\nWHERE tags.namespace = ?" : ""
        let ordering = namespace
            ? "count DESC, tags.name COLLATE NOCASE ASC"
            : "tags.namespace COLLATE NOCASE ASC, count DESC, tags.name COLLATE NOCASE ASC"

        return """
            SELECT tags.id,
                   tags.namespace,
                   tags.name,
                   tags.raw_value,
                   \(translationColumns)
                   followed_tags.tag_id IS NOT NULL AS is_followed,
                   COUNT(book_tags.book_id) AS count
            FROM tags
            JOIN book_tags ON book_tags.tag_id = tags.id\(translationJoin)
            LEFT JOIN followed_tags ON followed_tags.tag_id = tags.id
            \(namespaceFilter)
            GROUP BY tags.id
            ORDER BY \(ordering)
            """
    }

    private static func summaryArguments(namespace: String?, languageCode: String?) -> StatementArguments {
        var arguments = StatementArguments()
        if let languageCode {
            arguments += [languageCode]
        }
        if let namespace {
            arguments += [namespace]
        }
        return arguments
    }

    private static func topSummarySQL(namespaceCount: Int, includesTranslations: Bool) -> String {
        let translationColumns = includesTranslations
            ? """
              tag_translations.translated_name AS translated_name,
              tag_translations.intro AS intro,
              tag_translations.links AS links,
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
        let namespacePlaceholders = Array(repeating: "?", count: namespaceCount).joined(separator: ", ")

        return """
            SELECT tags.id,
                   tags.namespace,
                   tags.name,
                   tags.raw_value,
                   \(translationColumns)
                   followed_tags.tag_id IS NOT NULL AS is_followed,
                   COUNT(book_tags.book_id) AS count
            FROM tags
            JOIN book_tags ON book_tags.tag_id = tags.id\(translationJoin)
            LEFT JOIN followed_tags ON followed_tags.tag_id = tags.id
            WHERE tags.namespace IN (\(namespacePlaceholders))
            GROUP BY tags.id
            ORDER BY count DESC, tags.name COLLATE NOCASE ASC
            LIMIT ?
            """
    }

    private static func topSummaryArguments(
        namespaces: [String],
        limit: Int,
        languageCode: String?
    ) -> StatementArguments {
        var arguments = StatementArguments()
        if let languageCode {
            arguments += [languageCode]
        }
        arguments += StatementArguments(namespaces)
        arguments += [limit]
        return arguments
    }
}
