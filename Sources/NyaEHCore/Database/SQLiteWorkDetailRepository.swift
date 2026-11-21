// 本文件为作品详情页批量读取作品、角色、成员书籍和展示素材，减少视图层临时拼查询。

import Foundation
import GRDB

final class SQLiteWorkDetailRepository: WorkDetailRepository {
    private let dbQueue: any DatabaseWriter

    init(dbQueue: any DatabaseWriter) {
        self.dbQueue = dbQueue
    }

    private struct ClaimContext {
        var claims: [LibraryBook.DatabaseID: [WorkCharacterPair: WorkCharacterClaim]]
        var indexed: Set<WorkCharacterPair>
    }

    private enum ClaimBooks {
        case withTag(Tag.DatabaseID)
        case single(LibraryBook.DatabaseID)

        var sql: String {
            switch self {
            case .withTag: "SELECT book_id FROM book_tags WHERE tag_id = ?"
            case .single: "SELECT ?"
            }
        }

        var arguments: StatementArguments {
            switch self {
            case .withTag(let id), .single(let id): [id]
            }
        }
    }

    private static func claimContext(db: Database, books: ClaimBooks) throws -> ClaimContext {
        let tagRows = try Row.fetchAll(db, sql: """
            SELECT book_tags.book_id, tags.id AS tag_id, tags.namespace, tags.name
            FROM book_tags
            JOIN tags ON tags.id = book_tags.tag_id
            WHERE book_tags.book_id IN (\(books.sql))
              AND tags.namespace IN ('parody', 'character')
            """, arguments: books.arguments)
        var works: [LibraryBook.DatabaseID: Set<Tag.DatabaseID>] = [:]
        var characters: [LibraryBook.DatabaseID: Set<Tag.DatabaseID>] = [:]
        var names: [Tag.DatabaseID: String] = [:]
        for row in tagRows {
            let bookID: LibraryBook.DatabaseID = row["book_id"]
            let candidateID: Tag.DatabaseID = row["tag_id"]
            let namespace: String = row["namespace"]
            names[candidateID] = row["name"]
            if namespace == "character" {
                characters[bookID, default: []].insert(candidateID)
            } else {
                let name: String = row["name"]
                if !["origin", "original"].contains(name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()) {
                    works[bookID, default: []].insert(candidateID)
                }
            }
        }
        let relevantCharacters = Set(characters.values.flatMap { $0 })
        guard !relevantCharacters.isEmpty else { return ClaimContext(claims: [:], indexed: []) }
        let relevantCharacterSQL = """
            SELECT DISTINCT book_tags.tag_id
            FROM book_tags
            JOIN tags ON tags.id = book_tags.tag_id
            WHERE tags.namespace = 'character'
              AND book_tags.book_id IN (\(books.sql))
            """
        let indexedRows = try Row.fetchAll(db, sql: """
            SELECT DISTINCT parody_tag_id, character_tag_id
            FROM book_work_character_links
            WHERE character_tag_id IN (\(relevantCharacterSQL))
            """, arguments: books.arguments)
        let indexed = Set(indexedRows.map { row in
            WorkCharacterPair(workID: row["parody_tag_id"], characterID: row["character_tag_id"])
        })
        let decisionRows = try Row.fetchAll(db, sql: """
            SELECT parody_tag_id, character_tag_id, decision
            FROM work_character_decisions
            WHERE character_tag_id IN (\(relevantCharacterSQL))
            """, arguments: books.arguments)
        var confirmed: Set<WorkCharacterPair> = []
        var excluded: Set<WorkCharacterPair> = []
        for row in decisionRows {
            let pair = WorkCharacterPair(workID: row["parody_tag_id"], characterID: row["character_tag_id"])
            let decision: String = row["decision"]
            if decision == "confirmed" { confirmed.insert(pair) } else { excluded.insert(pair) }
        }
        let suppressionRows = try Row.fetchAll(db, sql: """
            SELECT book_id, parody_tag_id, character_tag_id
            FROM book_work_character_suppressions
            WHERE book_id IN (\(books.sql))
            """, arguments: books.arguments)
        var suppressed: [LibraryBook.DatabaseID: Set<WorkCharacterPair>] = [:]
        for row in suppressionRows {
            let bookID: LibraryBook.DatabaseID = row["book_id"]
            suppressed[bookID, default: []].insert(WorkCharacterPair(
                workID: row["parody_tag_id"], characterID: row["character_tag_id"]
            ))
        }
        var claims: [LibraryBook.DatabaseID: [WorkCharacterPair: WorkCharacterClaim]] = [:]
        for (bookID, bookWorks) in works {
            let resolved = WorkCharacterClaimResolver.resolve(
                works: bookWorks,
                characters: characters[bookID] ?? [],
                confirmed: confirmed,
                excluded: excluded,
                indexed: indexed,
                suppressed: suppressed[bookID] ?? []
            )
            claims[bookID] = resolved.mapValues { claim in
                var claim = claim
                claim.evidenceLabels = claim.evidence.map { pair in
                    "\(names[pair.workID] ?? "?") → \(names[pair.characterID] ?? "?")"
                }
                return claim
            }
        }
        return ClaimContext(claims: claims, indexed: indexed)
    }

    func fetchWorkCharacterCandidates(parodyTagID: Tag.DatabaseID, languageCode: String?) throws -> [WorkCharacterCandidate] {
        try dbQueue.read { db in
            let context = try Self.claimContext(db: db, books: .withTag(parodyTagID))
            let rows = try Row.fetchAll(db, sql: """
                SELECT characters.id,
                       decisions.decision
                FROM tags AS characters
                LEFT JOIN work_character_decisions AS decisions
                  ON decisions.parody_tag_id = ?
                 AND decisions.character_tag_id = characters.id
                WHERE characters.namespace = 'character'
                  AND characters.id IN (
                    SELECT character_tags.tag_id
                    FROM book_tags AS work_tags
                    JOIN book_tags AS character_tags ON character_tags.book_id = work_tags.book_id
                    WHERE work_tags.tag_id = ?
                    UNION
                    SELECT character_tag_id FROM work_character_decisions WHERE parody_tag_id = ?
                  )
                ORDER BY characters.name COLLATE NOCASE
                """, arguments: [parodyTagID, parodyTagID, parodyTagID])
            return try rows.compactMap { row -> WorkCharacterCandidate? in
                let characterID: Tag.DatabaseID = row["id"]
                guard let character = try fetchTagSummary(
                    db: db, tagID: characterID, expectedNamespace: "character", languageCode: languageCode
                ) else { return nil }
                let rawDecision: String? = row["decision"]
                let pair = WorkCharacterPair(workID: parodyTagID, characterID: characterID)
                return WorkCharacterCandidate(
                    character: character,
                    decision: rawDecision.flatMap(WorkCharacterManualDecision.init(rawValue:)),
                    hasIndexedEvidence: context.indexed.contains(pair),
                    automaticBookCount: context.claims.values.reduce(0) { count, claims in
                        count + (claims[pair]?.source == .automatic ? 1 : 0)
                    }
                )
            }
        }
    }

    func addCharacterTag(to bookID: LibraryBook.DatabaseID, pair: WorkCharacterPair) throws -> WorkCharacterTagAddition {
        try dbQueue.write { db in
            try Task.checkCancellation()
            try Self.validate(pair: pair, db: db)
            var book = try SQLiteLibraryBookRepository.writableBook(bookID, in: db)
            let belongsToWork = try Bool.fetchOne(db, sql: """
                SELECT EXISTS(SELECT 1 FROM book_tags WHERE book_id = ? AND tag_id = ?)
                """, arguments: [bookID, pair.workID])
            guard belongsToWork == true else { throw LibraryDeletionError.bookUnavailable }
            guard let rawValue = try String.fetchOne(db, sql: "SELECT raw_value FROM tags WHERE id = ?", arguments: [pair.characterID]) else {
                throw NyaEHError.databaseInvariantViolation("Character tag no longer exists.")
            }

            // Keep unrelated raw strings (including tags unknown to the metadata editor) verbatim.
            var rawTags = try JSONDecoder().decode([String].self, from: Data(book.tags.utf8))
            let needsRawTag = !TagParser.parseJSON(book.tags).contains { $0.rawValue == rawValue }
            if needsRawTag {
                rawTags.append(rawValue)
                book.tags = String(decoding: try JSONEncoder().encode(rawTags), as: UTF8.self)
                book.updatedAt = Timestamp.nowMilliseconds()
                try db.execute(sql: "UPDATE library_books SET tags = ?, updated_at = ? WHERE id = ?",
                               arguments: [book.tags, book.updatedAt, bookID])
            }
            try db.execute(sql: "INSERT OR IGNORE INTO book_tags (book_id, tag_id) VALUES (?, ?)",
                           arguments: [bookID, pair.characterID])
            let addedToIndex = db.changesCount > 0
            try SQLiteWorkCharacterRepository.insertMissingLinks(for: bookID, db: db)
            let addedEvidence = db.changesCount > 0
            let context = try Self.claimContext(db: db, books: .single(bookID))
            return WorkCharacterTagAddition(book: book, didChange: needsRawTag || addedToIndex || addedEvidence,
                                            isClassified: context.claims[bookID]?[pair] != nil)
        }
    }

    func setWorkCharacterDecision(_ decision: WorkCharacterManualDecision?, pair: WorkCharacterPair) throws {
        try dbQueue.write { db in
            try Self.validate(pair: pair, db: db)
            if let decision {
                try db.execute(sql: """
                    INSERT INTO work_character_decisions (parody_tag_id, character_tag_id, decision, updated_at)
                    VALUES (?, ?, ?, ?)
                    ON CONFLICT(parody_tag_id, character_tag_id) DO UPDATE SET
                        decision = excluded.decision, updated_at = excluded.updated_at
                    """, arguments: [pair.workID, pair.characterID, decision.rawValue, Timestamp.nowMilliseconds()])
            } else {
                try db.execute(sql: "DELETE FROM work_character_decisions WHERE parody_tag_id = ? AND character_tag_id = ?",
                               arguments: [pair.workID, pair.characterID])
            }
        }
    }

    func setAutomaticClaimSuppressed(_ isSuppressed: Bool, bookID: LibraryBook.DatabaseID, pair: WorkCharacterPair) throws {
        try dbQueue.write { db in
            try Self.validate(pair: pair, db: db)
            guard try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM book_tags WHERE book_id = ? AND tag_id IN (?, ?)",
                                   arguments: [bookID, pair.workID, pair.characterID]) == 2 else {
                throw NyaEHError.databaseInvariantViolation("The book must have both tags to change a claim.")
            }
            if isSuppressed {
                try db.execute(sql: """
                    INSERT OR IGNORE INTO book_work_character_suppressions
                        (book_id, parody_tag_id, character_tag_id, created_at)
                    VALUES (?, ?, ?, ?)
                    """, arguments: [bookID, pair.workID, pair.characterID, Timestamp.nowMilliseconds()])
            } else {
                try db.execute(sql: """
                    DELETE FROM book_work_character_suppressions
                    WHERE book_id = ? AND parody_tag_id = ? AND character_tag_id = ?
                    """, arguments: [bookID, pair.workID, pair.characterID])
            }
        }
    }

    private static func validate(pair: WorkCharacterPair, db: Database) throws {
        let count = try Int.fetchOne(db, sql: """
            SELECT COUNT(*) FROM tags AS works, tags AS characters
            WHERE works.id = ? AND works.namespace = 'parody'
              AND LOWER(TRIM(works.name)) NOT IN ('origin', 'original')
              AND characters.id = ? AND characters.namespace = 'character'
            """, arguments: [pair.workID, pair.characterID]) ?? 0
        guard count == 1 else {
            throw NyaEHError.databaseInvariantViolation("Work-character claim must reference a work and a character.")
        }
    }

    func fetchWorkDetail(parodyTagID: Tag.DatabaseID, languageCode: String?) throws -> WorkDetail? {
        try dbQueue.read { db in
            guard let work = try fetchTagSummary(db: db, tagID: parodyTagID, expectedNamespace: "parody", languageCode: languageCode) else {
                return nil
            }
            let context = try Self.claimContext(db: db, books: .withTag(parodyTagID))

            let rows = try Row.fetchAll(
                db,
                sql: Self.booksSQL(includesTranslations: languageCode != nil),
                arguments: Self.booksArguments(parodyTagID: parodyTagID, languageCode: languageCode)
            )

            var sections: [WorkCharacterBookSection] = []
            var sectionIndexes: [Tag.DatabaseID: Int] = [:]
            var untaggedIndex: Int?
            var visitedBooks: Set<LibraryBook.DatabaseID> = []
            var matchedBooks: Set<LibraryBook.DatabaseID> = []
            var booksInOrder: [LibraryBook] = []

            for row in rows {
                let book = SQLiteLibraryBookRepository.book(from: row)
                guard let bookID = book.databaseID else { continue }
                if visitedBooks.insert(bookID).inserted { booksInOrder.append(book) }
                let characterID: Tag.DatabaseID? = row["character_id"]

                if let characterID,
                   let claim = context.claims[bookID]?[WorkCharacterPair(workID: parodyTagID, characterID: characterID)] {
                    let index: Int
                    if let existingIndex = sectionIndexes[characterID] {
                        index = existingIndex
                    } else {
                        let character = Self.characterSummary(row: row)
                        sections.append(WorkCharacterBookSection(character: character, books: []))
                        index = sections.count - 1
                        sectionIndexes[characterID] = index
                    }
                    sections[index].books.append(book)
                    sections[index].claimsByBookID[bookID] = claim
                    matchedBooks.insert(bookID)
                }
            }

            for book in booksInOrder {
                guard let bookID = book.databaseID, !matchedBooks.contains(bookID) else { continue }
                if let untaggedIndex {
                    sections[untaggedIndex].books.append(book)
                } else {
                    sections.append(WorkCharacterBookSection(character: nil, books: [book]))
                    untaggedIndex = sections.count - 1
                }
            }

            // The global primary may carry neither the work tag nor the character tag.
            var primaryVersions: [BookVersionGroup.DatabaseID: LibraryBook] = [:]
            if booksInOrder.contains(where: { $0.versionGroupID != nil }) {
                let rows = try Row.fetchAll(db, sql: """
                    SELECT primary_book.*
                    FROM library_books primary_book
                    WHERE primary_book.is_primary_version = 1 AND primary_book.version_group_id IN (
                        SELECT matched.version_group_id FROM book_tags
                        JOIN library_books matched ON matched.id = book_tags.book_id
                        WHERE book_tags.tag_id = ? AND matched.version_group_id IS NOT NULL
                    )
                    """, arguments: [parodyTagID])
                for row in rows {
                    let book = SQLiteLibraryBookRepository.book(from: row)
                    if let group = book.versionGroupID { primaryVersions[group] = book }
                }
            }

            return WorkDetail(
                work: work,
                sections: sections,
                hasCharacterIndexRelations: try Self.characterIndexRelationCount(db: db, parodyTagID: parodyTagID) > 0,
                primaryVersions: primaryVersions
            )
        }
    }

    func fetchCharacterDetail(characterTagID: Tag.DatabaseID, languageCode: String?) throws -> CharacterDetail? {
        try dbQueue.read { db in
            guard let character = try fetchTagSummary(db: db, tagID: characterTagID, expectedNamespace: "character", languageCode: languageCode) else {
                return nil
            }
            let context = try Self.claimContext(db: db, books: .withTag(characterTagID))

            let rows = try Row.fetchAll(
                db,
                sql: Self.characterBooksSQL(includesTranslations: languageCode != nil),
                arguments: Self.characterBooksArguments(characterTagID: characterTagID, languageCode: languageCode)
            )

            var sections: [CharacterWorkBookSection] = []
            var sectionIndexes: [Tag.DatabaseID: Int] = [:]
            var ungroupedIndex: Int?
            var visitedBooks: Set<LibraryBook.DatabaseID> = []
            var matchedBooks: Set<LibraryBook.DatabaseID> = []
            var booksInOrder: [LibraryBook] = []

            for row in rows {
                let book = SQLiteLibraryBookRepository.book(from: row)
                guard let bookID = book.databaseID else { continue }
                if visitedBooks.insert(bookID).inserted { booksInOrder.append(book) }
                let workID: Tag.DatabaseID? = row["work_id"]

                if let workID,
                   let claim = context.claims[bookID]?[WorkCharacterPair(workID: workID, characterID: characterTagID)] {
                    let index: Int
                    if let existingIndex = sectionIndexes[workID] {
                        index = existingIndex
                    } else {
                        let work = Self.workSummary(row: row)
                        sections.append(CharacterWorkBookSection(work: work, books: []))
                        index = sections.count - 1
                        sectionIndexes[workID] = index
                    }
                    sections[index].books.append(book)
                    sections[index].claimsByBookID[bookID] = claim
                    matchedBooks.insert(bookID)
                }
            }

            for book in booksInOrder {
                guard let bookID = book.databaseID, !matchedBooks.contains(bookID) else { continue }
                if let ungroupedIndex {
                    sections[ungroupedIndex].books.append(book)
                } else {
                    sections.append(CharacterWorkBookSection(work: nil, books: [book]))
                    ungroupedIndex = sections.count - 1
                }
            }

            return CharacterDetail(character: character, sections: sections)
        }
    }

    private func fetchTagSummary(
        db: Database,
        tagID: Tag.DatabaseID,
        expectedNamespace: String,
        languageCode: String?
    ) throws -> TagDisplaySummary? {
        let row = try Row.fetchOne(
            db,
            sql: Self.tagSummarySQL(includesTranslations: languageCode != nil),
            arguments: Self.tagSummaryArguments(tagID: tagID, languageCode: languageCode)
        )
        guard let row,
              (row["namespace"] as String) == expectedNamespace else {
            return nil
        }
        return Self.displaySummary(row: row, prefix: "")
    }

    private static func characterSummary(row: Row) -> TagDisplaySummary {
        displaySummary(row: row, prefix: "character_")
    }

    private static func workSummary(row: Row) -> TagDisplaySummary {
        displaySummary(row: row, prefix: "work_")
    }

    private static func displaySummary(row: Row, prefix: String) -> TagDisplaySummary {
        let linksJSON: String? = row["\(prefix)links"]
        let linksData = linksJSON?.data(using: .utf8) ?? Data()
        let links = (try? JSONDecoder().decode([String].self, from: linksData)) ?? []
        let tagID: Tag.DatabaseID = row["\(prefix)id"]
        return TagDisplaySummary(
            id: tagID,
            namespace: row["\(prefix)namespace"],
            name: row["\(prefix)name"],
            rawValue: row["\(prefix)raw_value"],
            displayName: row["\(prefix)translated_name"] ?? row["\(prefix)name"],
            translationIntro: row["\(prefix)intro"],
            translationLinks: links,
            isFollowed: (row["\(prefix)is_followed"] as Int) != 0,
            count: row["\(prefix)tag_count"],
            visualProfile: visualProfile(row: row, prefix: prefix, tagID: tagID)
        )
    }

    private static func visualProfile(row: Row, prefix: String, tagID: Tag.DatabaseID) -> TagVisualProfile? {
        let createdAt: Int64? = row["\(prefix)visual_created_at"]
        guard let createdAt else {
            return nil
        }
        return TagVisualProfile(
            tagID: tagID,
            foregroundAssetPath: row["\(prefix)foreground_asset_path"],
            foregroundScale: row["\(prefix)foreground_scale"],
            foregroundOffsetX: row["\(prefix)foreground_offset_x"],
            foregroundOffsetY: row["\(prefix)foreground_offset_y"],
            backgroundAssetPath: row["\(prefix)background_asset_path"],
            backgroundScale: row["\(prefix)background_scale"],
            backgroundOffsetX: row["\(prefix)background_offset_x"],
            backgroundOffsetY: row["\(prefix)background_offset_y"],
            backgroundColorHex: row["\(prefix)background_color_hex"],
            backgroundColorSource: TagVisualBackgroundColorSource(rawValue: row["\(prefix)background_color_source"]) ?? .generated,
            createdAt: createdAt,
            updatedAt: row["\(prefix)visual_updated_at"]
        )
    }

    private static func tagSummarySQL(includesTranslations: Bool) -> String {
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

        return """
            SELECT tags.id,
                   tags.namespace,
                   tags.name,
                   tags.raw_value,
                   \(translationColumns)
                   followed_tags.tag_id IS NOT NULL AS is_followed,
                   COALESCE(total_counts.tag_count, 0) AS tag_count,
                   tag_visual_profiles.foreground_asset_path,
                   tag_visual_profiles.foreground_scale,
                   tag_visual_profiles.foreground_offset_x,
                   tag_visual_profiles.foreground_offset_y,
                   tag_visual_profiles.background_asset_path,
                   tag_visual_profiles.background_scale,
                   tag_visual_profiles.background_offset_x,
                   tag_visual_profiles.background_offset_y,
                   tag_visual_profiles.background_color_hex,
                   tag_visual_profiles.background_color_source,
                   tag_visual_profiles.created_at AS visual_created_at,
                   tag_visual_profiles.updated_at AS visual_updated_at
            FROM tags
            LEFT JOIN (
                SELECT tag_id, COUNT(book_id) AS tag_count
                FROM book_tags
                GROUP BY tag_id
            ) AS total_counts ON total_counts.tag_id = tags.id
            \(translationJoin)
            LEFT JOIN followed_tags ON followed_tags.tag_id = tags.id
            LEFT JOIN tag_visual_profiles ON tag_visual_profiles.tag_id = tags.id
            WHERE tags.id = ?
            """
    }

    private static func booksSQL(includesTranslations: Bool) -> String {
        let translationColumns = includesTranslations
            ? """
              tag_translations.translated_name AS character_translated_name,
              tag_translations.intro AS character_intro,
              tag_translations.links AS character_links,
              """
            : """
              NULL AS character_translated_name,
              NULL AS character_intro,
              NULL AS character_links,
              """
        let translationJoin = includesTranslations
            ? """
            LEFT JOIN tag_translations
              ON tag_translations.tag_id = characters.id
             AND tag_translations.language_code = ?
            """
            : ""

        return """
            WITH work_books AS (
                SELECT book_id
                FROM book_tags
                WHERE tag_id = ?
            ),
            available_characters AS (
                SELECT id FROM tags WHERE namespace = 'character'
            )
            SELECT library_books.id, library_books.title, library_books.cover_path,
                   library_books.hash, library_books.filepath, library_books.type,
                   library_books.file_count, library_books.bundle_size,
                   library_books.mtime, library_books.cover_hash,
                   library_books.status, library_books.date, library_books.rating,
                   library_books.tags, library_books.title_jpn, library_books.pages,
                   library_books.posted, library_books.filesize,
                   library_books.category, library_books.url,
                   library_books.collection_id, library_books.collection_order,
                   library_books.version_group_id, library_books.is_primary_version,
                   library_books.version_label, library_books.language_code,
                   library_books.is_translated, library_books.is_full_color,
                   library_books.censorship, library_books.has_extraneous_ads,
                   library_books.mark, library_books.hidden_book, library_books.is_user_hidden,
                   library_books.read_count, library_books.last_read_at, library_books.exist,
                   library_books.created_at, library_books.updated_at,
                   characters.id AS character_id,
                   characters.namespace AS character_namespace,
                   characters.name AS character_name,
                   characters.raw_value AS character_raw_value,
                   \(translationColumns)
                   followed_tags.tag_id IS NOT NULL AS character_is_followed,
                   COALESCE(character_counts.tag_count, 0) AS character_tag_count,
                   tag_visual_profiles.foreground_asset_path AS character_foreground_asset_path,
                   tag_visual_profiles.foreground_scale AS character_foreground_scale,
                   tag_visual_profiles.foreground_offset_x AS character_foreground_offset_x,
                   tag_visual_profiles.foreground_offset_y AS character_foreground_offset_y,
                   tag_visual_profiles.background_asset_path AS character_background_asset_path,
                   tag_visual_profiles.background_scale AS character_background_scale,
                   tag_visual_profiles.background_offset_x AS character_background_offset_x,
                   tag_visual_profiles.background_offset_y AS character_background_offset_y,
                   tag_visual_profiles.background_color_hex AS character_background_color_hex,
                   tag_visual_profiles.background_color_source AS character_background_color_source,
                   tag_visual_profiles.created_at AS character_visual_created_at,
                   tag_visual_profiles.updated_at AS character_visual_updated_at
            FROM work_books
            JOIN library_books ON library_books.id = work_books.book_id
            LEFT JOIN book_tags AS matching_characters
              ON matching_characters.book_id = library_books.id
             AND matching_characters.tag_id IN (SELECT id FROM available_characters)
            LEFT JOIN tags AS characters
              ON characters.id = matching_characters.tag_id
            \(translationJoin)
            LEFT JOIN (
                SELECT tag_id, COUNT(book_id) AS tag_count
                FROM book_tags
                GROUP BY tag_id
            ) AS character_counts ON character_counts.tag_id = characters.id
            LEFT JOIN followed_tags ON followed_tags.tag_id = characters.id
            LEFT JOIN tag_visual_profiles ON tag_visual_profiles.tag_id = characters.id
            ORDER BY character_tag_count DESC,
                     characters.name COLLATE NOCASE ASC,
                     library_books.date DESC,
                     library_books.title COLLATE NOCASE ASC,
                     library_books.id ASC
            """
    }

    private static func characterIndexRelationCount(db: Database, parodyTagID: Tag.DatabaseID) throws -> Int {
        try Int.fetchOne(
            db,
            sql: """
                SELECT COUNT(DISTINCT character_tag_id)
                FROM book_work_character_links
                WHERE parody_tag_id = ?
                """,
            arguments: [parodyTagID]
        ) ?? 0
    }

    private static func characterBooksSQL(includesTranslations: Bool) -> String {
        let translationColumns = includesTranslations
            ? """
              tag_translations.translated_name AS work_translated_name,
              tag_translations.intro AS work_intro,
              tag_translations.links AS work_links,
              """
            : """
              NULL AS work_translated_name,
              NULL AS work_intro,
              NULL AS work_links,
              """
        let translationJoin = includesTranslations
            ? """
            LEFT JOIN tag_translations
              ON tag_translations.tag_id = works.id
             AND tag_translations.language_code = ?
            """
            : ""

        return """
            WITH character_books AS (
                SELECT book_id
                FROM book_tags
                WHERE tag_id = ?
            )
            SELECT library_books.id, library_books.title, library_books.cover_path,
                   library_books.hash, library_books.filepath, library_books.type,
                   library_books.file_count, library_books.bundle_size,
                   library_books.mtime, library_books.cover_hash,
                   library_books.status, library_books.date, library_books.rating,
                   library_books.tags, library_books.title_jpn, library_books.pages,
                   library_books.posted, library_books.filesize,
                   library_books.category, library_books.url,
                   library_books.collection_id, library_books.collection_order,
                   library_books.version_group_id, library_books.is_primary_version,
                   library_books.version_label, library_books.language_code,
                   library_books.is_translated, library_books.is_full_color,
                   library_books.censorship, library_books.has_extraneous_ads,
                   library_books.mark, library_books.hidden_book, library_books.is_user_hidden,
                   library_books.read_count, library_books.last_read_at, library_books.exist,
                   library_books.created_at, library_books.updated_at,
                   works.id AS work_id,
                   works.namespace AS work_namespace,
                   works.name AS work_name,
                   works.raw_value AS work_raw_value,
                   \(translationColumns)
                   followed_tags.tag_id IS NOT NULL AS work_is_followed,
                   COALESCE(work_counts.tag_count, 0) AS work_tag_count,
                   tag_visual_profiles.foreground_asset_path AS work_foreground_asset_path,
                   tag_visual_profiles.foreground_scale AS work_foreground_scale,
                   tag_visual_profiles.foreground_offset_x AS work_foreground_offset_x,
                   tag_visual_profiles.foreground_offset_y AS work_foreground_offset_y,
                   tag_visual_profiles.background_asset_path AS work_background_asset_path,
                   tag_visual_profiles.background_scale AS work_background_scale,
                   tag_visual_profiles.background_offset_x AS work_background_offset_x,
                   tag_visual_profiles.background_offset_y AS work_background_offset_y,
                   tag_visual_profiles.background_color_hex AS work_background_color_hex,
                   tag_visual_profiles.background_color_source AS work_background_color_source,
                   tag_visual_profiles.created_at AS work_visual_created_at,
                   tag_visual_profiles.updated_at AS work_visual_updated_at
            FROM character_books
            JOIN library_books ON library_books.id = character_books.book_id
            LEFT JOIN book_tags AS matching_works
              ON matching_works.book_id = library_books.id
             AND matching_works.tag_id IN (SELECT id FROM tags WHERE namespace = 'parody' AND LOWER(TRIM(name)) NOT IN ('origin', 'original'))
            LEFT JOIN tags AS works ON works.id = matching_works.tag_id
            \(translationJoin)
            LEFT JOIN (
                SELECT tag_id, COUNT(book_id) AS tag_count
                FROM book_tags
                GROUP BY tag_id
            ) AS work_counts ON work_counts.tag_id = works.id
            LEFT JOIN followed_tags ON followed_tags.tag_id = works.id
            LEFT JOIN tag_visual_profiles ON tag_visual_profiles.tag_id = works.id
            ORDER BY works.id IS NULL ASC,
                     work_tag_count DESC,
                     works.name COLLATE NOCASE ASC,
                     library_books.date DESC,
                     library_books.title COLLATE NOCASE ASC
            """
    }

    private static func tagSummaryArguments(tagID: Tag.DatabaseID, languageCode: String?) -> StatementArguments {
        var arguments = StatementArguments()
        if let languageCode {
            arguments += [languageCode]
        }
        arguments += [tagID]
        return arguments
    }

    private static func booksArguments(parodyTagID: Tag.DatabaseID, languageCode: String?) -> StatementArguments {
        var arguments: StatementArguments = [parodyTagID]
        if let languageCode {
            arguments += [languageCode]
        }
        return arguments
    }

    private static func characterBooksArguments(characterTagID: Tag.DatabaseID, languageCode: String?) -> StatementArguments {
        var arguments: StatementArguments = [characterTagID]
        if let languageCode {
            arguments += [languageCode]
        }
        return arguments
    }
}
