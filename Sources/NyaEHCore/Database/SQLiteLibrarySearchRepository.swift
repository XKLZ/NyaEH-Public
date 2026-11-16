// 本文件实现 SQL-backed 强搜索，把标题查询、标签集合和 facet 统计尽量推到 SQLite。

import Foundation
import GRDB

final class SQLiteLibrarySearchRepository: LibrarySearchRepository {
    private let dbQueue: any DatabaseWriter

    init(dbQueue: any DatabaseWriter) {
        self.dbQueue = dbQueue
    }

    func search(_ request: LibrarySearchRequest) throws -> LibrarySearchResponse {
        let parsed = combinedParsedQuery(for: request)
        try validateRegexIfNeeded(request: request, parsed: parsed)

        return try dbQueue.read { db in
            db.add(function: Self.regexpFunction)
            guard request.isRegexEnabled else {
                // 普通标题/标签搜索优先走 SQL，避免把大书库整表拉回 Swift 再过滤。
                return try searchBooksWithSQL(db: db, request: request, parsed: parsed)
            }

            // Regex 以固定批次扫描 SQL 已缩小的候选集，只保留当前页对象，避免一次把全库和全部 tag 拉入内存。
            return try searchBooksWithRegexFallback(db: db, request: request, parsed: parsed)
        }
    }

    func tagFacets(_ request: LibrarySearchRequest, knownTotalCount: Int? = nil) throws -> [SearchTagFacet] {
        let parsed = combinedParsedQuery(for: request)
        try validateRegexIfNeeded(request: request, parsed: parsed)

        return try dbQueue.read { db in
            db.add(function: Self.regexpFunction)
            guard request.isRegexEnabled else {
                // 精确模式 facet 数量会随当前查询动态收窄，SQL 统计能显著减少大标签库的 UI 卡顿。
                return try tagFacetsWithSQL(
                    db: db,
                    request: request,
                    parsed: parsed,
                    knownTotalCount: knownTotalCount
                )
            }

            let data = try loadSearchData(db: db, request: request, parsed: parsed)
            let selectedIDs = Set(parsed.requiredTags.map(\.matchID))
            let excludedIDs = Set(parsed.excludedTags.map(\.matchID))
            let summaries = try loadTagSummaries(db: db, isTagTranslationEnabled: request.isTagTranslationEnabled)

            return summaries.compactMap { summary in
                let candidate = SearchTagConstraint(
                    namespace: summary.namespace,
                    name: summary.name,
                    isExact: true
                )
                let state: SearchTagState
                if selectedIDs.contains(candidate.matchID) {
                    state = .selected
                } else if excludedIDs.contains(candidate.matchID) {
                    state = .excluded
                } else {
                    state = .unselected
                }

                let count: Int
                switch request.mode {
                case .broad:
                    count = countEntitiesContaining(candidate, data: data, parsed: parsed, request: request)
                case .exact:
                    var refined = parsed
                    if state == .unselected {
                        refined.requiredTags.append(candidate)
                    }
                    count = entityCount(
                        filterBooks(data.books, tagIndex: data.tagIndex, parsed: refined, mode: .exact),
                        request: request
                    )
                }

                return SearchTagFacet(
                    tag: TagDisplaySummary(
                        id: summary.id,
                        namespace: summary.namespace,
                        name: summary.name,
                        rawValue: summary.rawValue,
                        displayName: summary.displayName,
                        isFollowed: summary.isFollowed,
                        count: summary.count
                    ),
                    state: state,
                    availableCount: count,
                    intro: summary.intro,
                    isEnabled: state != .unselected || request.mode != .exact || count > 0
                )
            }
        }
    }

    private func searchBooksWithSQL(
        db: Database,
        request: LibrarySearchRequest,
        parsed: ParsedSearchQuery
    ) throws -> LibrarySearchResponse {
        var arguments = StatementArguments()
        var clauses = bookClauses(parsed: parsed, mode: request.mode, bookAlias: "library_books", arguments: &arguments)
        clauses.append(contentsOf: scopeClauses(request.scope, bookAlias: "library_books", arguments: &arguments))
        if request.showsIndividualBooks {
            let condition = clauses.isEmpty ? "" : " WHERE " + clauses.joined(separator: " AND ")
            let totalCount = try countEntitiesWithSQL(db: db, request: request, parsed: parsed)
            arguments += [request.pageSize, (request.page - 1) * request.pageSize]
            let books = try Row.fetchAll(
                db,
                sql: "SELECT * FROM library_books" + condition + " ORDER BY \(searchOrderSQL(request)) LIMIT ? OFFSET ?",
                arguments: arguments
            ).map(SQLiteLibraryBookRepository.book(from:))
            let hits = books.map {
                LibrarySearchHit(entityKey: .book($0.id), representativeBook: $0, matchedBookIDs: [$0.id])
            }
            return LibrarySearchResponse(items: hits, totalCount: totalCount, parsedQuery: parsed)
        }
        let totalCount = try countEntitiesWithSQL(db: db, request: request, parsed: parsed)
        let entityKind = entityKindSQL(bookAlias: "library_books")
        let entityID = entityIDSQL(bookAlias: "library_books")
        var sql = """
            WITH ranked_matches AS (
                SELECT library_books.*,
                       (\(entityKind)) AS search_entity_kind,
                       (\(entityID)) AS search_entity_id,
                       ROW_NUMBER() OVER (
                           PARTITION BY (\(entityKind)), (\(entityID))
                           ORDER BY \(searchOrderSQL(request))
                       ) AS search_entity_rank
                FROM library_books
            """
        if !clauses.isEmpty {
            sql += "\nWHERE " + clauses.joined(separator: " AND ")
        }
        sql += """

            )
            SELECT id, title, cover_path, hash, filepath, type, file_count,
                   bundle_size, mtime, cover_hash, status, date, rating, tags,
                   title_jpn, pages, posted, filesize, category, url,
                   collection_id, collection_order, version_group_id,
                   is_primary_version, version_label,
                   language_code, is_translated, is_full_color, censorship,
                   has_extraneous_ads, mark,
                   hidden_book, is_user_hidden, read_count, last_read_at, exist, created_at, updated_at,
                   search_entity_kind, search_entity_id
            FROM ranked_matches
            WHERE search_entity_rank = 1
            ORDER BY \(searchOrderSQL(request)), search_entity_kind ASC, search_entity_id ASC
            LIMIT ? OFFSET ?
            """
        arguments += [request.pageSize, (request.page - 1) * request.pageSize]

        let representatives = try Row.fetchAll(db, sql: sql, arguments: arguments)
            .map(SQLiteLibraryBookRepository.book(from:))
        let pageEntityKeys = representatives.map { LibrarySearchEntityKey(book: $0) }
        let matchedIDs = try loadMatchedBookIDsByEntity(
            db: db,
            request: request,
            parsed: parsed,
            entityKeys: pageEntityKeys
        )
        let hits = representatives.map { book in
            let entityKey = LibrarySearchEntityKey(book: book)
            return LibrarySearchHit(
                entityKey: entityKey,
                representativeBook: book,
                matchedBookIDs: matchedIDs[entityKey] ?? [book.id]
            )
        }
        return LibrarySearchResponse(items: hits, totalCount: totalCount, parsedQuery: parsed)
    }

    private func searchBooksWithRegexFallback(
        db: Database,
        request: LibrarySearchRequest,
        parsed: ParsedSearchQuery
    ) throws -> LibrarySearchResponse {
        let batchSize = 512
        let resultOffset = (request.page - 1) * request.pageSize
        var candidateOffset = 0
        var entityCount = 0
        var seenEntityKeys: Set<LibrarySearchEntityKey> = []
        var pageEntityKeys: [LibrarySearchEntityKey] = []
        var pageRepresentatives: [LibrarySearchEntityKey: LibraryBook] = [:]
        var pageMatchedBookIDs: [LibrarySearchEntityKey: Set<LibraryBook.ID>] = [:]

        while true {
            var arguments = StatementArguments()
            var clauses: [String] = []
            for term in parsed.titleTerms where !term.text.isEmpty {
                let predicate = regexTitlePredicate(for: term, arguments: &arguments)
                clauses.append(term.isExcluded ? "NOT \(predicate)" : predicate)
            }
            clauses.append(contentsOf: regexSQLNarrowingClauses(
                parsed: parsed,
                mode: request.mode,
                arguments: &arguments
            ))
            clauses.append(contentsOf: scopeClauses(
                request.scope,
                bookAlias: "library_books",
                arguments: &arguments
            ))

            var sql = """
                SELECT id, title, cover_path, hash, filepath, type, file_count,
                       bundle_size, mtime, cover_hash, status, date, rating, tags,
                       title_jpn, pages, posted, filesize, category, url,
                       collection_id, collection_order, version_group_id,
                       is_primary_version, version_label,
                       language_code, is_translated, is_full_color, censorship,
                       has_extraneous_ads, mark,
                       hidden_book, is_user_hidden, read_count, last_read_at, exist, created_at, updated_at
                FROM library_books
                """
            if !clauses.isEmpty { sql += "\nWHERE " + clauses.joined(separator: " AND ") }
            sql += "\nORDER BY \(searchOrderSQL(request)) LIMIT ? OFFSET ?"
            arguments += [batchSize, candidateOffset]

            let candidates = try Row.fetchAll(db, sql: sql, arguments: arguments)
                .map(SQLiteLibraryBookRepository.book(from:))
            guard !candidates.isEmpty else { break }

            let tagIndex = parsed.hasTagTerms
                ? try loadBookTagIndex(db: db, bookIDs: candidates.compactMap(\.databaseID))
                : [:]
            for book in candidates where filterBooks(
                [book],
                tagIndex: tagIndex,
                parsed: parsed,
                mode: request.mode
            ).isEmpty == false {
                let entityKey = LibrarySearchEntityKey(book: book, showsIndividualBooks: request.showsIndividualBooks)
                if request.showsIndividualBooks || seenEntityKeys.insert(entityKey).inserted {
                    if entityCount >= resultOffset && pageEntityKeys.count < request.pageSize {
                        pageEntityKeys.append(entityKey)
                        pageRepresentatives[entityKey] = book
                    }
                    entityCount += 1
                }
                if pageRepresentatives[entityKey] != nil {
                    pageMatchedBookIDs[entityKey, default: []].insert(book.id)
                }
            }
            candidateOffset += candidates.count
            if candidates.count < batchSize { break }
        }

        let hits = pageEntityKeys.compactMap { entityKey -> LibrarySearchHit? in
            guard let representative = pageRepresentatives[entityKey] else { return nil }
            return LibrarySearchHit(
                entityKey: entityKey,
                representativeBook: representative,
                matchedBookIDs: pageMatchedBookIDs[entityKey] ?? [representative.id]
            )
        }
        return LibrarySearchResponse(items: hits, totalCount: entityCount, parsedQuery: parsed)
    }

    private func regexSQLNarrowingClauses(
        parsed: ParsedSearchQuery,
        mode: SearchMode,
        arguments: inout StatementArguments
    ) -> [String] {
        var clauses = parsed.excludedTags
            .filter { !$0.isRegex }
            .map { "NOT \(tagExistsSQL($0, bookAlias: "library_books", arguments: &arguments))" }
        if mode == .exact {
            clauses += parsed.requiredTags
                .filter { !$0.isRegex }
                .map { tagExistsSQL($0, bookAlias: "library_books", arguments: &arguments) }
        }
        return clauses
    }

    private func tagFacetsWithSQL(
        db: Database,
        request: LibrarySearchRequest,
        parsed: ParsedSearchQuery,
        knownTotalCount: Int?
    ) throws -> [SearchTagFacet] {
        let selectedIDs = Set(parsed.requiredTags.map(\.matchID))
        let excludedIDs = Set(parsed.excludedTags.map(\.matchID))
        let currentResultCount = try knownTotalCount
            ?? countEntitiesWithSQL(db: db, request: request, parsed: parsed)
        var arguments = StatementArguments()
        var availableClauses: [String]

        switch request.mode {
        case .broad:
            availableClauses = facetAvailableClausesForBroad(parsed: parsed, arguments: &arguments)
        case .exact:
            availableClauses = facetAvailableClausesForExact(parsed: parsed, arguments: &arguments)
        }
        availableClauses.append(contentsOf: scopeClauses(request.scope, bookAlias: "library_books", arguments: &arguments))

        var sql = """
            SELECT tags.id,
                   tags.namespace,
                   tags.name,
                   tags.raw_value,
                   total_counts.count AS count,
                   COALESCE(available_counts.available_count, 0) AS available_count,
                   tag_translations.translated_name,
                   tag_translations.intro,
                   followed_tags.tag_id IS NOT NULL AS is_followed
            FROM tags
            JOIN (
                SELECT tag_id, COUNT(book_id) AS count
                FROM book_tags
                GROUP BY tag_id
            ) AS total_counts ON total_counts.tag_id = tags.id
            LEFT JOIN (
                SELECT candidate_tags.tag_id,
                       COUNT(DISTINCT \(request.showsIndividualBooks ? "library_books.id" : entityTextKeySQL(bookAlias: "library_books"))) AS available_count
                FROM book_tags AS candidate_tags
                JOIN library_books ON library_books.id = candidate_tags.book_id
            """
        if !availableClauses.isEmpty {
            sql += "\nWHERE " + availableClauses.joined(separator: " AND ")
        }
        sql += """

                GROUP BY candidate_tags.tag_id
            ) AS available_counts ON available_counts.tag_id = tags.id
            LEFT JOIN tag_translations
                ON tag_translations.tag_id = tags.id
               AND tag_translations.language_code = ?
            LEFT JOIN followed_tags ON followed_tags.tag_id = tags.id
            ORDER BY tags.namespace COLLATE NOCASE ASC, is_followed DESC, count DESC, tags.name COLLATE NOCASE ASC
            """
        arguments += [EhTagTranslationCache.languageCode]

        let rows = try Row.fetchAll(db, sql: sql, arguments: arguments)
        return rows.map { row in
            let summary = searchTagSummary(row: row, isTagTranslationEnabled: request.isTagTranslationEnabled)
            let candidate = SearchTagConstraint(
                namespace: summary.namespace,
                name: summary.name,
                isExact: true
            )
            let state: SearchTagState
            if selectedIDs.contains(candidate.matchID) {
                state = .selected
            } else if excludedIDs.contains(candidate.matchID) {
                state = .excluded
            } else {
                state = .unselected
            }

            let availableCount: Int
            if request.mode == .exact, state == .excluded {
                availableCount = currentResultCount
            } else {
                availableCount = row["available_count"]
            }

            return SearchTagFacet(
                tag: TagDisplaySummary(
                    id: summary.id,
                    namespace: summary.namespace,
                    name: summary.name,
                    rawValue: summary.rawValue,
                    displayName: summary.displayName,
                    isFollowed: summary.isFollowed,
                    count: summary.count
                ),
                state: state,
                availableCount: availableCount,
                intro: summary.intro,
                isEnabled: state != .unselected || request.mode != .exact || availableCount > 0
            )
        }
    }

    func tagSuggestions(_ request: SearchTagSuggestionRequest) throws -> [SearchTagSuggestion] {
        let trimmed = request.query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return []
        }

        return try dbQueue.read { db in
            let lowered = trimmed.lowercased()
            return try loadTagSummaries(db: db, isTagTranslationEnabled: request.isTagTranslationEnabled)
                .filter { summary in
                    if let namespace = request.namespace, summary.namespace != namespace {
                        return false
                    }
                    if request.excludedRawValue == summary.rawValue {
                        return false
                    }
                    return suggestionRank(summary: summary, query: lowered) != nil
                }
                .sorted { lhs, rhs in
                    let leftRank = suggestionRank(summary: lhs, query: lowered) ?? Int.max
                    let rightRank = suggestionRank(summary: rhs, query: lowered) ?? Int.max
                    if leftRank != rightRank {
                        return leftRank < rightRank
                    }
                    if lhs.isFollowed != rhs.isFollowed {
                        return lhs.isFollowed
                    }
                    if lhs.count != rhs.count {
                        return lhs.count > rhs.count
                    }
                    return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
                }
                .prefix(12)
                .map { summary in
                    SearchTagSuggestion(
                        tag: TagDisplaySummary(
                            id: summary.id,
                            namespace: summary.namespace,
                            name: summary.name,
                            rawValue: summary.rawValue,
                            displayName: summary.displayName,
                            isFollowed: summary.isFollowed,
                            count: summary.count
                        ),
                        intro: summary.intro
                    )
                }
        }
    }

    private func suggestionRank(summary: SearchTagSummaryRow, query: String) -> Int? {
        if summary.name.hasPrefix(query) || summary.rawValue.hasPrefix(query) {
            return 0
        }
        if summary.translationName?.localizedCaseInsensitiveContains(query) == true
            || summary.displayName.localizedCaseInsensitiveContains(query) {
            return 1
        }
        if summary.name.localizedCaseInsensitiveContains(query)
            || summary.rawValue.localizedCaseInsensitiveContains(query) {
            return 2
        }
        return nil
    }

    private static let regexpFunction = DatabaseFunction("regexp", argumentCount: 2, pure: true) { values in
        guard let pattern = String.fromDatabaseValue(values[0]),
              let string = String.fromDatabaseValue(values[1]) else {
            return false
        }

        let regex = try NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
        let range = NSRange(string.startIndex..<string.endIndex, in: string)
        return regex.firstMatch(in: string, range: range) != nil
    }

    private func combinedParsedQuery(for request: LibrarySearchRequest) -> ParsedSearchQuery {
        var parsed = SearchQueryParser.parse(request.rawQuery)
        parsed.requiredTags.append(contentsOf: request.selectedTags)
        parsed.excludedTags.append(contentsOf: request.excludedTags)
        parsed.requiredTags = unique(parsed.requiredTags)
        parsed.excludedTags = unique(parsed.excludedTags)
        parsed.optionalTags = unique(parsed.optionalTags)
        if request.isRegexEnabled {
            parsed.requiredTags = parsed.requiredTags.map(regexConstraint)
            parsed.excludedTags = parsed.excludedTags.map(regexConstraint)
            parsed.optionalTags = parsed.optionalTags.map(regexConstraint)
        }
        return parsed
    }

    private func regexConstraint(_ constraint: SearchTagConstraint) -> SearchTagConstraint {
        SearchTagConstraint(
            namespace: constraint.namespace,
            name: constraint.name,
            isExact: constraint.isExact,
            isRegex: true
        )
    }

    private func unique(_ constraints: [SearchTagConstraint]) -> [SearchTagConstraint] {
        var seen = Set<String>()
        return constraints.filter { seen.insert($0.id).inserted }
    }

    private func validateRegexIfNeeded(request: LibrarySearchRequest, parsed: ParsedSearchQuery) throws {
        guard request.isRegexEnabled else {
            return
        }

        for term in parsed.titleTerms where !term.text.isEmpty {
            _ = try NSRegularExpression(pattern: term.text, options: [.caseInsensitive])
        }
        for constraint in parsed.requiredTags + parsed.excludedTags + parsed.optionalTags where constraint.isRegex {
            _ = try NSRegularExpression(pattern: constraint.name, options: [.caseInsensitive])
        }
    }

    private func countEntitiesWithSQL(
        db: Database,
        request: LibrarySearchRequest,
        parsed: ParsedSearchQuery
    ) throws -> Int {
        var arguments = StatementArguments()
        var clauses = bookClauses(parsed: parsed, mode: request.mode, bookAlias: "library_books", arguments: &arguments)
        clauses.append(contentsOf: scopeClauses(request.scope, bookAlias: "library_books", arguments: &arguments))
        if request.showsIndividualBooks {
            let condition = clauses.isEmpty ? "" : " WHERE " + clauses.joined(separator: " AND ")
            return try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM library_books" + condition, arguments: arguments) ?? 0
        }
        var sql = """
            SELECT COUNT(*)
            FROM (
                SELECT 1
                FROM library_books
            """
        if !clauses.isEmpty {
            sql += "\nWHERE " + clauses.joined(separator: " AND ")
        }
        sql += """

                GROUP BY \(entityKindSQL(bookAlias: "library_books")),
                         \(entityIDSQL(bookAlias: "library_books"))
            ) AS matching_entities
            """
        return try Int.fetchOne(db, sql: sql, arguments: arguments) ?? 0
    }

    private func scopeClauses(
        _ scope: BookSearchScope,
        bookAlias: String,
        arguments: inout StatementArguments
    ) -> [String] {
        let visible = "\(bookAlias).is_user_hidden = 0"
        switch scope {
        case .all:
            return [visible]
        case .marked:
            return [visible, "\(bookAlias).mark = 1"]
        case .continueReading:
            return [
                visible,
                """
                EXISTS (
                    SELECT 1 FROM book_reading_state
                    WHERE book_reading_state.book_id = \(bookAlias).id
                      AND book_reading_state.current_page_index > 0
                      AND book_reading_state.completed_at IS NULL
                )
                """
            ]
        case .unread:
            return [
                visible,
                """
                NOT EXISTS (
                    SELECT 1 FROM book_reading_state
                    WHERE book_reading_state.book_id = \(bookAlias).id
                      AND (book_reading_state.current_page_index > 0 OR book_reading_state.completed_at IS NOT NULL)
                )
                """
            ]
        case .completed:
            return [
                visible,
                """
                EXISTS (
                    SELECT 1 FROM book_reading_state
                    WHERE book_reading_state.book_id = \(bookAlias).id
                      AND book_reading_state.completed_at IS NOT NULL
                )
                """
            ]
        case .metadataPending:
            arguments += [BookStatus.unscanned.rawValue]
            return [visible, "\(bookAlias).status = ?"]
        case .broken:
            arguments += [BookStatus.broken.rawValue]
            return [visible, "\(bookAlias).status = ?"]
        case .missing:
            arguments += [BookStatus.missing.rawValue]
            return [visible, "(\(bookAlias).status = ? OR \(bookAlias).exist = 0)"]
        case .hidden:
            return ["\(bookAlias).is_user_hidden = 1"]
        }
    }

    private func loadMatchedBookIDsByEntity(
        db: Database,
        request: LibrarySearchRequest,
        parsed: ParsedSearchQuery,
        entityKeys: [LibrarySearchEntityKey]
    ) throws -> [LibrarySearchEntityKey: Set<LibraryBook.ID>] {
        guard !entityKeys.isEmpty else { return [:] }

        var arguments = StatementArguments()
        var clauses = bookClauses(
            parsed: parsed,
            mode: request.mode,
            bookAlias: "library_books",
            arguments: &arguments
        )
        clauses.append(contentsOf: scopeClauses(
            request.scope,
            bookAlias: "library_books",
            arguments: &arguments
        ))

        var entityClauses: [String] = []
        for key in entityKeys {
            switch key {
            case .collection(let id):
                entityClauses.append("library_books.collection_id = ?")
                arguments += [Int64(id)]
            case .versionGroup(let id):
                entityClauses.append("(library_books.collection_id IS NULL AND library_books.version_group_id = ?)")
                arguments += [Int64(id)]
            case .book(let id):
                entityClauses.append("(library_books.collection_id IS NULL AND library_books.version_group_id IS NULL AND library_books.id = ?)")
                arguments += [Int64(id)]
            }
        }
        clauses.append("(" + entityClauses.joined(separator: " OR ") + ")")

        let rows = try Row.fetchAll(
            db,
            sql: """
                SELECT id, collection_id, version_group_id
                FROM library_books
                WHERE \(clauses.joined(separator: " AND "))
                """,
            arguments: arguments
        )
        var result: [LibrarySearchEntityKey: Set<LibraryBook.ID>] = [:]
        for row in rows {
            let id: Int64 = row["id"]
            let collectionID: Int64? = row["collection_id"]
            let versionGroupID: Int64? = row["version_group_id"]
            let key: LibrarySearchEntityKey
            if let collectionID {
                key = .collection(String(collectionID))
            } else if let versionGroupID {
                key = .versionGroup(String(versionGroupID))
            } else {
                key = .book(String(id))
            }
            result[key, default: []].insert(String(id))
        }
        return result
    }

    private func entityKindSQL(bookAlias: String) -> String {
        "CASE WHEN \(bookAlias).collection_id IS NOT NULL THEN 0 WHEN \(bookAlias).version_group_id IS NOT NULL THEN 1 ELSE 2 END"
    }

    private func entityIDSQL(bookAlias: String) -> String {
        "COALESCE(\(bookAlias).collection_id, \(bookAlias).version_group_id, \(bookAlias).id)"
    }

    private func entityTextKeySQL(bookAlias: String) -> String {
        "(CAST(\(entityKindSQL(bookAlias: bookAlias)) AS TEXT) || ':' || CAST(\(entityIDSQL(bookAlias: bookAlias)) AS TEXT))"
    }

    private func searchOrderSQL(_ request: LibrarySearchRequest) -> String {
        let direction = request.sortDirection == .ascending ? "ASC" : "DESC"
        let primary: String
        switch request.sortKey {
        case .posted:
            primary = "COALESCE(posted, date) \(direction)"
        case .added:
            primary = "created_at \(direction)"
        case .title:
            primary = "title COLLATE NOCASE \(direction)"
        case .rating:
            primary = "COALESCE(rating, 0) \(direction)"
        case .pages:
            primary = "COALESCE(pages, file_count, 0) \(direction)"
        case .marked:
            primary = "mark \(direction)"
        }
        return "\(primary), title COLLATE NOCASE ASC, id ASC"
    }

    private func searchSort(_ lhs: LibraryBook, _ rhs: LibraryBook, request: LibrarySearchRequest) -> Bool {
        let ascending = request.sortDirection == .ascending
        func compare<T: Comparable>(_ left: T, _ right: T) -> Bool? {
            guard left != right else { return nil }
            return ascending ? left < right : left > right
        }
        let result: Bool?
        switch request.sortKey {
        case .posted:
            result = compare(lhs.posted ?? lhs.date, rhs.posted ?? rhs.date)
        case .added:
            result = compare(lhs.createdAt, rhs.createdAt)
        case .title:
            let comparison = lhs.title.localizedCaseInsensitiveCompare(rhs.title)
            result = comparison == .orderedSame ? nil : (ascending ? comparison == .orderedAscending : comparison == .orderedDescending)
        case .rating:
            result = compare(lhs.rating ?? 0, rhs.rating ?? 0)
        case .pages:
            result = compare(lhs.pages ?? lhs.fileCount ?? 0, rhs.pages ?? rhs.fileCount ?? 0)
        case .marked:
            result = compare(lhs.mark ? 1 : 0, rhs.mark ? 1 : 0)
        }
        if let result { return result }
        let title = lhs.title.localizedCaseInsensitiveCompare(rhs.title)
        return title == .orderedSame ? lhs.id < rhs.id : title == .orderedAscending
    }

    private func bookClauses(
        parsed: ParsedSearchQuery,
        mode: SearchMode,
        bookAlias: String,
        arguments: inout StatementArguments
    ) -> [String] {
        var clauses = titleClauses(parsed.titleTerms, bookAlias: bookAlias, arguments: &arguments)

        for constraint in parsed.excludedTags {
            clauses.append("NOT \(tagExistsSQL(constraint, bookAlias: bookAlias, arguments: &arguments))")
        }

        if !parsed.optionalTags.isEmpty {
            let optionalClauses = parsed.optionalTags.map {
                tagExistsSQL($0, bookAlias: bookAlias, arguments: &arguments)
            }
            clauses.append("(" + optionalClauses.joined(separator: " OR ") + ")")
        }

        if !parsed.requiredTags.isEmpty {
            switch mode {
            case .broad:
                let requiredClauses = parsed.requiredTags.map {
                    tagExistsSQL($0, bookAlias: bookAlias, arguments: &arguments)
                }
                clauses.append("(" + requiredClauses.joined(separator: " OR ") + ")")
            case .exact:
                for constraint in parsed.requiredTags {
                    clauses.append(tagExistsSQL(constraint, bookAlias: bookAlias, arguments: &arguments))
                }
            }
        }

        return clauses
    }

    private func facetAvailableClausesForBroad(
        parsed: ParsedSearchQuery,
        arguments: inout StatementArguments
    ) -> [String] {
        var clauses = titleClauses(parsed.titleTerms, bookAlias: "library_books", arguments: &arguments)
        for constraint in parsed.excludedTags {
            clauses.append("NOT \(tagExistsSQL(constraint, bookAlias: "library_books", arguments: &arguments))")
        }
        return clauses
    }

    private func facetAvailableClausesForExact(
        parsed: ParsedSearchQuery,
        arguments: inout StatementArguments
    ) -> [String] {
        var clauses = titleClauses(parsed.titleTerms, bookAlias: "library_books", arguments: &arguments)
        for constraint in parsed.excludedTags {
            clauses.append("NOT \(tagExistsSQL(constraint, bookAlias: "library_books", arguments: &arguments))")
        }
        if !parsed.optionalTags.isEmpty {
            let optionalClauses = parsed.optionalTags.map {
                tagExistsSQL($0, bookAlias: "library_books", arguments: &arguments)
            }
            clauses.append("(" + optionalClauses.joined(separator: " OR ") + ")")
        }
        for constraint in parsed.requiredTags {
            clauses.append(tagExistsSQL(constraint, bookAlias: "library_books", arguments: &arguments))
        }
        return clauses
    }

    private func titleClauses(
        _ terms: [SearchTitleTerm],
        bookAlias: String,
        arguments: inout StatementArguments
    ) -> [String] {
        terms.compactMap { term in
            guard !term.text.isEmpty else {
                return nil
            }
            let pattern = "%\(escapedLike(term.text))%"
            let predicate: String
            switch term.scope {
            case .any:
                predicate = """
                    (\(bookAlias).title LIKE ? ESCAPE '\\' COLLATE NOCASE
                     OR COALESCE(\(bookAlias).title_jpn, '') LIKE ? ESCAPE '\\' COLLATE NOCASE
                     OR \(bookAlias).filepath LIKE ? ESCAPE '\\' COLLATE NOCASE)
                    """
                arguments += [pattern, pattern, pattern]
            case .title:
                predicate = """
                    (\(bookAlias).title LIKE ? ESCAPE '\\' COLLATE NOCASE
                     OR COALESCE(\(bookAlias).title_jpn, '') LIKE ? ESCAPE '\\' COLLATE NOCASE)
                    """
                arguments += [pattern, pattern]
            case .file:
                predicate = "\(bookAlias).filepath LIKE ? ESCAPE '\\' COLLATE NOCASE"
                arguments += [pattern]
            }
            return term.isExcluded ? "NOT \(predicate)" : predicate
        }
    }

    private func regexTitlePredicate(for term: SearchTitleTerm, arguments: inout StatementArguments) -> String {
        switch term.scope {
        case .any:
            arguments += [term.text, term.text, term.text]
            return "(title REGEXP ? OR COALESCE(title_jpn, '') REGEXP ? OR filepath REGEXP ?)"
        case .title:
            arguments += [term.text, term.text]
            return "(title REGEXP ? OR COALESCE(title_jpn, '') REGEXP ?)"
        case .file:
            arguments += [term.text]
            return "filepath REGEXP ?"
        }
    }

    private func likeTitlePredicate(for term: SearchTitleTerm, arguments: inout StatementArguments) -> String {
        let pattern = "%\(escapedLike(term.text))%"
        switch term.scope {
        case .any:
            arguments += [pattern, pattern, pattern]
            return "(title LIKE ? ESCAPE '\\' COLLATE NOCASE OR COALESCE(title_jpn, '') LIKE ? ESCAPE '\\' COLLATE NOCASE OR filepath LIKE ? ESCAPE '\\' COLLATE NOCASE)"
        case .title:
            arguments += [pattern, pattern]
            return "(title LIKE ? ESCAPE '\\' COLLATE NOCASE OR COALESCE(title_jpn, '') LIKE ? ESCAPE '\\' COLLATE NOCASE)"
        case .file:
            arguments += [pattern]
            return "filepath LIKE ? ESCAPE '\\' COLLATE NOCASE"
        }
    }

    private func tagExistsSQL(
        _ constraint: SearchTagConstraint,
        bookAlias: String,
        arguments: inout StatementArguments
    ) -> String {
        var tagClauses: [String] = []
        if let namespace = constraint.namespace {
            tagClauses.append("tags.namespace = ? COLLATE NOCASE")
            arguments += [namespace]
        }

        if constraint.isExact {
            tagClauses.append("tags.name = ? COLLATE NOCASE")
            arguments += [constraint.name]
        } else {
            tagClauses.append("""
                (tags.name = ? COLLATE NOCASE
                 OR tags.name LIKE ? ESCAPE '\\' COLLATE NOCASE
                 OR tags.name LIKE ? ESCAPE '\\' COLLATE NOCASE)
                """)
            let escapedName = escapedLike(constraint.name)
            arguments += [constraint.name, "\(escapedName)%", "% \(escapedName)%"]
        }

        return """
            EXISTS (
                SELECT 1
                FROM book_tags
                JOIN tags ON tags.id = book_tags.tag_id
                WHERE book_tags.book_id = \(bookAlias).id
                  AND \(tagClauses.joined(separator: " AND "))
            )
            """
    }

    private func loadSearchData(
        db: Database,
        request: LibrarySearchRequest,
        parsed: ParsedSearchQuery
    ) throws -> SearchData {
        var sql = """
            SELECT id, title, cover_path, hash, filepath, type, file_count,
                   bundle_size, mtime, cover_hash, status, date, rating, tags,
                   title_jpn, pages, posted, filesize, category, url,
                   collection_id, collection_order, version_group_id,
                   is_primary_version, version_label,
                   language_code, is_translated, is_full_color, censorship,
                   has_extraneous_ads, mark,
                   hidden_book, is_user_hidden, read_count, last_read_at, exist, created_at, updated_at
            FROM library_books
            """
        var clauses: [String] = []
        var arguments: StatementArguments = []

        for term in parsed.titleTerms {
            guard !term.text.isEmpty else { continue }
            let predicate: String
            if request.isRegexEnabled {
                predicate = regexTitlePredicate(for: term, arguments: &arguments)
            } else {
                predicate = likeTitlePredicate(for: term, arguments: &arguments)
            }
            clauses.append(term.isExcluded ? "NOT \(predicate)" : predicate)
        }
        clauses.append(contentsOf: scopeClauses(request.scope, bookAlias: "library_books", arguments: &arguments))

        if !clauses.isEmpty {
            sql += "\nWHERE " + clauses.joined(separator: " AND ")
        }
        sql += "\nORDER BY date DESC, title COLLATE NOCASE ASC"

        let books = try Row.fetchAll(db, sql: sql, arguments: arguments).map(SQLiteLibraryBookRepository.book(from:))
        let bookIDs = books.compactMap(\.databaseID)
        let tagIndex = try loadBookTagIndex(db: db, bookIDs: bookIDs)
        return SearchData(books: books, tagIndex: tagIndex)
    }

    private func loadBookTagIndex(
        db: Database,
        bookIDs: [LibraryBook.DatabaseID]
    ) throws -> [LibraryBook.DatabaseID: [SearchIndexedTag]] {
        guard !bookIDs.isEmpty else {
            return [:]
        }

        var index: [LibraryBook.DatabaseID: [SearchIndexedTag]] = [:]
        for batch in stride(from: 0, to: bookIDs.count, by: 512) {
            let ids = Array(bookIDs[batch..<min(batch + 512, bookIDs.count)])
            let placeholders = Array(repeating: "?", count: ids.count).joined(separator: ",")
            let rows = try Row.fetchAll(
                db,
                sql: """
                    SELECT book_tags.book_id, tags.id, tags.namespace, tags.name, tags.raw_value
                    FROM book_tags
                    JOIN tags ON tags.id = book_tags.tag_id
                    WHERE book_tags.book_id IN (\(placeholders))
                    """,
                arguments: StatementArguments(ids)
            )
            for row in rows {
                let bookID: LibraryBook.DatabaseID = row["book_id"]
                index[bookID, default: []].append(
                    SearchIndexedTag(
                        id: row["id"],
                        namespace: row["namespace"],
                        name: row["name"],
                        rawValue: row["raw_value"]
                    )
                )
            }
        }
        return index
    }

    private func filterBooks(
        _ books: [LibraryBook],
        tagIndex: [LibraryBook.DatabaseID: [SearchIndexedTag]],
        parsed: ParsedSearchQuery,
        mode: SearchMode
    ) -> [LibraryBook] {
        books.filter { book in
            guard let bookID = book.databaseID else {
                return false
            }
            let tags = tagIndex[bookID] ?? []
            if parsed.excludedTags.contains(where: { matchesAny($0, tags: tags) }) {
                return false
            }

            if !parsed.optionalTags.isEmpty,
               !parsed.optionalTags.contains(where: { matchesAny($0, tags: tags) }) {
                return false
            }

            guard !parsed.requiredTags.isEmpty else {
                return true
            }

            switch mode {
            case .broad:
                return parsed.requiredTags.contains { matchesAny($0, tags: tags) }
            case .exact:
                return parsed.requiredTags.allSatisfy { matchesAny($0, tags: tags) }
            }
        }
    }

    private func countEntitiesContaining(
        _ constraint: SearchTagConstraint,
        data: SearchData,
        parsed: ParsedSearchQuery,
        request: LibrarySearchRequest
    ) -> Int {
        var refined = parsed
        refined.requiredTags = []
        refined.optionalTags = []
        refined.excludedTags = parsed.excludedTags
        let matchingBooks = filterBooks(data.books, tagIndex: data.tagIndex, parsed: refined, mode: .broad)
            .filter { book in
                guard let bookID = book.databaseID else { return false }
                return matchesAny(constraint, tags: data.tagIndex[bookID] ?? [])
            }
        return entityCount(matchingBooks, request: request)
    }

    private func entityCount(_ books: [LibraryBook], request: LibrarySearchRequest) -> Int {
        if request.showsIndividualBooks { return books.count }
        return Set(books.map { LibrarySearchEntityKey(book: $0) }).count
    }

    private func matchesAny(_ constraint: SearchTagConstraint, tags: [SearchIndexedTag]) -> Bool {
        tags.contains { tag in
            if let namespace = constraint.namespace, namespace != tag.namespace {
                return false
            }

            if constraint.isRegex {
                return (try? NSRegularExpression(pattern: constraint.name, options: [.caseInsensitive]))
                    .map { regex in
                        regex.firstMatch(
                            in: tag.name,
                            range: NSRange(tag.name.startIndex..<tag.name.endIndex, in: tag.name)
                        ) != nil
                    } ?? false
            }

            if constraint.isExact {
                return tag.name == constraint.name
            }
            return tag.name == constraint.name
                || tag.name.hasPrefix(constraint.name)
                || tag.name.split(separator: " ").contains { $0.hasPrefix(constraint.name) }
        }
    }

    private func loadTagSummaries(db: Database, isTagTranslationEnabled: Bool) throws -> [SearchTagSummaryRow] {
        let rows = try Row.fetchAll(
            db,
            sql: """
                SELECT tags.id,
                       tags.namespace,
                       tags.name,
                       tags.raw_value,
                       COUNT(book_tags.book_id) AS count,
                       tag_translations.translated_name,
                       tag_translations.intro,
                       followed_tags.tag_id IS NOT NULL AS is_followed
                FROM tags
                JOIN book_tags ON book_tags.tag_id = tags.id
                LEFT JOIN tag_translations
                    ON tag_translations.tag_id = tags.id
                   AND tag_translations.language_code = ?
                LEFT JOIN followed_tags ON followed_tags.tag_id = tags.id
                GROUP BY tags.id
                ORDER BY tags.namespace COLLATE NOCASE ASC, is_followed DESC, count DESC, tags.name COLLATE NOCASE ASC
                """,
            arguments: [EhTagTranslationCache.languageCode]
        )

        return rows.map { searchTagSummary(row: $0, isTagTranslationEnabled: isTagTranslationEnabled) }
    }

    private func searchTagSummary(row: Row, isTagTranslationEnabled: Bool) -> SearchTagSummaryRow {
        let name: String = row["name"]
        let translatedName: String? = row["translated_name"]
        return SearchTagSummaryRow(
            id: row["id"],
            namespace: row["namespace"],
            name: name,
            rawValue: row["raw_value"],
            displayName: isTagTranslationEnabled ? (translatedName ?? name) : name,
            translationName: translatedName,
            intro: row["intro"],
            isFollowed: (row["is_followed"] as Int) != 0,
            count: row["count"]
        )
    }

    private func escapedLike(_ text: String) -> String {
        text
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "%", with: "\\%")
            .replacingOccurrences(of: "_", with: "\\_")
    }
}

private struct SearchData {
    var books: [LibraryBook]
    var tagIndex: [LibraryBook.DatabaseID: [SearchIndexedTag]]
}

private struct SearchIndexedTag {
    var id: Tag.DatabaseID
    var namespace: String
    var name: String
    var rawValue: String
}

private struct SearchTagSummaryRow {
    var id: Tag.DatabaseID
    var namespace: String
    var name: String
    var rawValue: String
    var displayName: String
    var translationName: String?
    var intro: String?
    var isFollowed: Bool
    var count: Int
}
