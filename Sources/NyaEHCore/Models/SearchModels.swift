// 本文件定义 SearchModels 领域模型，是数据库、服务层和 SwiftUI 视图之间传递业务状态的结构。

import Foundation

enum SearchMode: String, CaseIterable, Identifiable, Codable, Hashable, Sendable {
    case broad
    case exact

    var id: String { rawValue }
}

enum BookSearchScope: String, CaseIterable, Identifiable, Codable, Hashable, Sendable {
    case all
    case marked
    case continueReading
    case unread
    case completed
    case metadataPending
    case broken
    case missing
    case hidden

    var id: String { rawValue }

    var titleKey: L10nKey {
        switch self {
        case .all: .searchScopeAll
        case .marked: .searchScopeMarked
        case .continueReading: .searchScopeContinueReading
        case .unread: .searchScopeUnread
        case .completed: .searchScopeCompleted
        case .metadataPending: .searchScopeMetadataPending
        case .broken: .searchScopeBroken
        case .missing: .searchScopeMissing
        case .hidden: .searchScopeHidden
        }
    }

    var systemImage: String {
        switch self {
        case .all: "books.vertical"
        case .marked: "heart.fill"
        case .continueReading: "book.pages"
        case .unread: "circle"
        case .completed: "checkmark.circle.fill"
        case .metadataPending: "questionmark.circle"
        case .broken: "xmark.octagon"
        case .missing: "exclamationmark.triangle"
        case .hidden: "eye.slash"
        }
    }
}

enum SearchResultLayout: String, CaseIterable, Identifiable, Codable, Sendable {
    case card
    case row
    case expandedRow

    var id: String { rawValue }

    var titleKey: L10nKey {
        switch self {
        case .card: .advancedSearchCards
        case .row: .advancedSearchRows
        case .expandedRow: .advancedSearchExpanded
        }
    }

    var systemImage: String {
        switch self {
        case .card: "square.grid.3x3"
        case .row: "list.bullet"
        case .expandedRow: "list.bullet.rectangle"
        }
    }
}

enum SearchResultSortKey: String, CaseIterable, Identifiable, Codable, Sendable {
    case posted
    case added
    case title
    case rating
    case pages
    case marked

    var id: String { rawValue }

    var titleKey: L10nKey {
        switch self {
        case .posted:
            return .advancedSearchSortPosted
        case .added:
            return .recentlyAdded
        case .title:
            return .advancedSearchSortTitle
        case .rating:
            return .rating
        case .pages:
            return .pages
        case .marked:
            return .marked
        }
    }

    var systemImage: String {
        switch self {
        case .posted: "calendar"
        case .added: "clock"
        case .title: "textformat"
        case .rating: "star"
        case .pages: "doc.on.doc"
        case .marked: "heart.fill"
        }
    }
}

enum SearchTagState: String, Sendable {
    case selected
    case excluded
    case unselected
}

struct LibrarySearchRequest: Equatable, Sendable {
    var rawQuery: String
    var isRegexEnabled: Bool
    var mode: SearchMode
    var selectedTags: [SearchTagConstraint]
    var excludedTags: [SearchTagConstraint]
    var isTagTranslationEnabled: Bool
    var scope: BookSearchScope
    var page: Int
    var pageSize: Int
    var sortKey: SearchResultSortKey
    var sortDirection: SortDirection
    var showsIndividualBooks: Bool

    init(
        rawQuery: String = "",
        isRegexEnabled: Bool = false,
        mode: SearchMode = .exact,
        selectedTags: [SearchTagConstraint] = [],
        excludedTags: [SearchTagConstraint] = [],
        isTagTranslationEnabled: Bool = false,
        scope: BookSearchScope = .all,
        page: Int = 1,
        pageSize: Int = 30,
        sortKey: SearchResultSortKey = .posted,
        sortDirection: SortDirection = .descending,
        showsIndividualBooks: Bool = false
    ) {
        self.rawQuery = rawQuery
        self.isRegexEnabled = isRegexEnabled
        self.mode = mode
        self.selectedTags = selectedTags
        self.excludedTags = excludedTags
        self.isTagTranslationEnabled = isTagTranslationEnabled
        self.scope = scope
        self.page = max(page, 1)
        self.pageSize = max(pageSize, 1)
        self.sortKey = sortKey
        self.sortDirection = sortDirection
        self.showsIndividualBooks = showsIndividualBooks
    }
}

struct LibrarySearchResponse: Equatable, Sendable {
    var items: [LibrarySearchHit]
    var totalCount: Int
    var parsedQuery: ParsedSearchQuery
}

enum LibrarySearchEntityKey: Hashable, Sendable {
    case collection(BookCollection.ID)
    case versionGroup(BookVersionGroup.ID)
    case book(LibraryBook.ID)

    init(book: LibraryBook, showsIndividualBooks: Bool = false) {
        if showsIndividualBooks {
            self = .book(book.id)
        } else if let collectionID = book.collectionID {
            self = .collection(String(collectionID))
        } else if let versionGroupID = book.versionGroupID {
            self = .versionGroup(String(versionGroupID))
        } else {
            self = .book(book.id)
        }
    }

    var stableID: String {
        switch self {
        case .collection(let id): "collection.\(id)"
        case .versionGroup(let id): "version.\(id)"
        case .book(let id): "book.\(id)"
        }
    }
}

struct LibrarySearchHit: Equatable, Sendable {
    var entityKey: LibrarySearchEntityKey
    var representativeBook: LibraryBook
    var matchedBookIDs: Set<LibraryBook.ID>
    var similarityDistance: Double? = nil

    var databaseID: LibraryBook.DatabaseID? { representativeBook.databaseID }
    var title: String { representativeBook.title }
    var isUserHidden: Bool { representativeBook.isUserHidden }
}

struct SearchDisplayItem: Identifiable, Equatable, Sendable {
    var item: LibraryDisplayItem
    var matchedBookIDs: Set<LibraryBook.ID>
    var otherVersionMatchedBookIDs: Set<LibraryBook.ID>
    var similarityDistance: Double? = nil

    var id: String { item.id }

    var books: [LibraryBook] { item.books }
    var representativeBook: LibraryBook? { item.representativeBook }
    var matchesOtherVersion: Bool { !otherVersionMatchedBookIDs.isEmpty }

    func hasMatch(for bookID: LibraryBook.ID?) -> Bool {
        guard let bookID else { return false }
        return matchedBookIDs.contains(bookID) || otherVersionMatchedBookIDs.contains(bookID)
    }
}

struct SearchFacetCacheKey: Hashable, Sendable {
    var rawQuery: String
    var isRegexEnabled: Bool
    var mode: SearchMode
    var selectedTags: [SearchTagConstraint]
    var excludedTags: [SearchTagConstraint]
    var isTagTranslationEnabled: Bool
    var scope: BookSearchScope
    var tagRevision: Int
    var showsIndividualBooks: Bool

    init(request: LibrarySearchRequest, tagRevision: Int) {
        rawQuery = request.rawQuery
        isRegexEnabled = request.isRegexEnabled
        mode = request.mode
        selectedTags = request.selectedTags
        excludedTags = request.excludedTags
        isTagTranslationEnabled = request.isTagTranslationEnabled
        scope = request.scope
        self.tagRevision = tagRevision
        showsIndividualBooks = request.showsIndividualBooks
    }
}

struct SearchResultSelectionState: Equatable, Sendable {
    private(set) var selectedBookIDs: Set<LibraryBook.ID> = []

    mutating func appendSelection(_ item: LibraryDisplayItem) {
        let ids = Set(item.books.map(\.id))
        guard !ids.isEmpty else { return }
        selectedBookIDs.formUnion(ids)
    }

    mutating func toggleSelection(_ item: LibraryDisplayItem) {
        let ids = Set(item.books.map(\.id))
        guard !ids.isEmpty else { return }
        if ids.isSubset(of: selectedBookIDs) {
            selectedBookIDs.subtract(ids)
        } else {
            selectedBookIDs.formUnion(ids)
        }
    }

    mutating func clear() {
        selectedBookIDs.removeAll()
    }

    mutating func retainAvailableBookIDs(_ availableBookIDs: Set<LibraryBook.ID>) {
        selectedBookIDs.formIntersection(availableBookIDs)
    }

    func isSelected(_ item: LibraryDisplayItem) -> Bool {
        let ids = Set(item.books.map(\.id))
        return !ids.isEmpty && ids.isSubset(of: selectedBookIDs)
    }
}

enum SearchPrimaryActivationPolicy {
    static func opensCollectionPopover(for item: LibraryDisplayItem, layout: SearchResultLayout) -> Bool {
        guard layout == .card, case .collection = item else { return false }
        return true
    }

}

enum SearchPreviewTarget: Hashable, Sendable {
    case book(LibraryBook.ID)
    case collection(BookCollection.ID)

    init(item: LibraryDisplayItem) {
        switch item {
        case .book(let book): self = .book(book.id)
        case .collection(let collection): self = .collection(collection.id)
        }
    }

    func resolve(in items: [LibraryDisplayItem], expandedCollections: Set<BookCollection.ID>) -> LibraryDisplayItem? {
        for item in items {
            if SearchPreviewTarget(item: item) == self { return item }
            if case .book(let id) = self, case .collection(let collection) = item,
               expandedCollections.contains(collection.id),
               let book = collection.books.first(where: { $0.id == id }) {
                return .book(book)
            }
        }
        return nil
    }
}

struct SavedBookSearch: Identifiable, Codable, Equatable, Sendable {
    var id: UUID
    var name: String
    var query: String
    var scope: BookSearchScope
    var mode: SearchMode
    var isRegexEnabled: Bool
    var sortKey: SearchResultSortKey
    var sortDirection: SortDirection
    var layout: SearchResultLayout
    var createdAt: Int64

    init(
        id: UUID = UUID(),
        name: String,
        query: String,
        scope: BookSearchScope,
        mode: SearchMode,
        isRegexEnabled: Bool = false,
        sortKey: SearchResultSortKey,
        sortDirection: SortDirection,
        layout: SearchResultLayout,
        createdAt: Int64 = Timestamp.nowMilliseconds()
    ) {
        self.id = id
        self.name = name
        self.query = query
        self.scope = scope
        self.mode = mode
        self.isRegexEnabled = isRegexEnabled
        self.sortKey = sortKey
        self.sortDirection = sortDirection
        self.layout = layout
        self.createdAt = createdAt
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, query, scope, mode, isRegexEnabled, sortKey, sortDirection, layout, createdAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        query = try container.decode(String.self, forKey: .query)
        scope = try container.decode(BookSearchScope.self, forKey: .scope)
        mode = try container.decode(SearchMode.self, forKey: .mode)
        isRegexEnabled = try container.decodeIfPresent(Bool.self, forKey: .isRegexEnabled) ?? false
        sortKey = try container.decode(SearchResultSortKey.self, forKey: .sortKey)
        sortDirection = try container.decode(SortDirection.self, forKey: .sortDirection)
        layout = try container.decode(SearchResultLayout.self, forKey: .layout)
        createdAt = try container.decode(Int64.self, forKey: .createdAt)
    }
}

struct SearchTagConstraint: Identifiable, Hashable, Sendable {
    var namespace: String?
    var name: String
    var isExact: Bool
    var isRegex: Bool

    var id: String {
        "\(namespace ?? "*"):\(name):\(isExact):\(isRegex)"
    }

    var matchID: String {
        "\(namespace ?? "*"):\(name)"
    }

    init(namespace: String?, name: String, isExact: Bool = false, isRegex: Bool = false) {
        self.namespace = namespace?.lowercased()
        self.name = name.lowercased()
        self.isExact = isExact
        self.isRegex = isRegex
    }
}

struct ParsedSearchQuery: Equatable, Sendable {
    var titleTerms: [SearchTitleTerm] = []
    var requiredTags: [SearchTagConstraint] = []
    var excludedTags: [SearchTagConstraint] = []
    var optionalTags: [SearchTagConstraint] = []
    var tokenHighlights: [SearchTokenHighlight] = []
    var warnings: [String] = []

    var hasTagTerms: Bool {
        !requiredTags.isEmpty || !excludedTags.isEmpty || !optionalTags.isEmpty
    }
}

struct SearchTitleTerm: Hashable, Sendable {
    enum Scope: Hashable, Sendable {
        case any
        case title
        case file
    }

    var text: String
    var isExcluded: Bool
    var scope: Scope

    init(text: String, isExcluded: Bool, scope: Scope = .any) {
        self.text = text
        self.isExcluded = isExcluded
        self.scope = scope
    }
}

struct SearchTokenHighlight: Identifiable, Equatable, Sendable {
    var id = UUID()
    var range: Range<String.Index>
    var displayText: String
    var state: SearchTagState
}

struct SearchTagFacet: Identifiable, Equatable, Sendable {
    var tag: TagDisplaySummary
    var state: SearchTagState
    var availableCount: Int
    var intro: String?
    var isEnabled: Bool = true

    var id: Tag.DatabaseID { tag.id }
}

struct SearchTagSuggestion: Identifiable, Equatable, Sendable {
    var tag: TagDisplaySummary
    var intro: String?

    var id: Tag.DatabaseID { tag.id }

    var insertionText: String {
        let namespace = SearchNamespace.canonicalAlias(for: tag.namespace) ?? tag.namespace
        if tag.name.contains(" ") {
            return "\(namespace):\"\(tag.name)\""
        }
        return "\(namespace):\(tag.name)"
    }

    var exactInsertionText: String {
        "\(insertionText)$"
    }
}

struct SearchTagSuggestionRequest: Equatable, Sendable {
    var query: String
    var namespace: String?
    var excludedRawValue: String?
    var isTagTranslationEnabled: Bool

    init(
        query: String,
        namespace: String? = nil,
        excludedRawValue: String? = nil,
        isTagTranslationEnabled: Bool
    ) {
        self.query = query
        self.namespace = namespace
        self.excludedRawValue = excludedRawValue
        self.isTagTranslationEnabled = isTagTranslationEnabled
    }
}

struct SearchSuggestionQuery: Equatable, Sendable {
    var text: String
    var namespace: String?
    var excludedRawValue: String?
}

enum SearchQueryTextEditor {
    static func tokenText(for tag: TagDisplaySummary, state: SearchTagState) -> String {
        let namespace = SearchNamespace.canonicalAlias(for: tag.namespace) ?? tag.namespace
        let name = tag.name.contains(" ") ? "\"\(tag.name)\"" : tag.name
        let prefix = state == .excluded ? "-" : ""
        return "\(prefix)\(namespace):\(name)$"
    }

    static func replacingActiveToken(
        in query: String,
        activeRange: NSRange?,
        with replacement: String
    ) -> String {
        let normalizedReplacement = replacement.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedReplacement.isEmpty else {
            return query
        }

        if let activeRange,
           let range = Range(activeRange, in: query) {
            return query.replacingCharacters(in: range, with: normalizedReplacement)
                .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }

        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return normalizedReplacement
        }
        return "\(query) \(normalizedReplacement)"
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func cyclingHighlightedToken(
        _ highlight: SearchTokenHighlight,
        in query: String
    ) -> String {
        let range = highlight.range

        var updated = query
        switch highlight.state {
        case .selected:
            let token = String(query[range])
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .trimmingPrefix("-")
                .trimmingPrefix("~")
            updated.replaceSubrange(range, with: "-\(token)")
        case .excluded, .unselected:
            updated.removeSubrange(range)
        }

        return normalizedQuerySpacing(updated)
    }

    static func activeTokenRange(in query: String, selectedRange: NSRange) -> NSRange? {
        guard !query.isEmpty else {
            return nil
        }

        var tokens: [(range: Range<String.Index>, nsRange: NSRange)] = []
        var index = query.startIndex

        while index < query.endIndex {
            while index < query.endIndex, isTokenSeparator(query[index]) {
                index = query.index(after: index)
            }
            guard index < query.endIndex else { break }

            let start = index
            var inQuote = false
            while index < query.endIndex {
                let character = query[index]
                if character == "\"" {
                    inQuote.toggle()
                } else if !inQuote, isTokenSeparator(character) {
                    break
                }
                index = query.index(after: index)
            }

            let range = start..<index
            let nsRange = NSRange(range, in: query)
            tokens.append((range, nsRange))
        }

        guard !tokens.isEmpty else {
            return nil
        }

        let cursor = selectedRange.location
        if let token = tokens.first(where: { token in
            cursor >= token.nsRange.location && cursor <= token.nsRange.location + token.nsRange.length
        }) {
            return token.nsRange
        }

        return tokens.last(where: { $0.nsRange.location < cursor })?.nsRange
    }

    static func suggestionQuery(in query: String, activeRange: NSRange?) -> SearchSuggestionQuery? {
        guard let activeRange,
              let range = Range(activeRange, in: query) else {
            return nil
        }

        let rawToken = String(query[range]).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !rawToken.isEmpty else {
            return nil
        }

        var token = rawToken
        if token.hasPrefix("-") || token.hasPrefix("~") {
            token.removeFirst()
        }

        if token.lowercased().hasPrefix("weak:") {
            token.removeFirst("weak:".count)
        }

        if exactTagConstraint(from: token) != nil {
            return nil
        }

        if let colonIndex = token.firstIndex(of: ":") {
            let namespaceText = String(token[..<colonIndex])
            let namespace = SearchNamespace.canonical(namespaceText)
            let tail = String(token[token.index(after: colonIndex)...])
            let normalized = normalizedSuggestionText(tail)
            guard !normalized.isEmpty else {
                return nil
            }
            return SearchSuggestionQuery(text: normalized, namespace: namespace, excludedRawValue: nil)
        }

        let normalized = normalizedSuggestionText(token)
        guard !normalized.isEmpty else {
            return nil
        }
        return SearchSuggestionQuery(text: normalized, namespace: nil, excludedRawValue: nil)
    }

    static func settingTag(
        _ tag: TagDisplaySummary,
        to state: SearchTagState,
        in query: String
    ) -> String {
        let parsed = SearchQueryParser.parse(query)
        let rangesToRemove = parsed.tokenHighlights.compactMap { highlight -> Range<String.Index>? in
            guard tagMatchesHighlight(tag, highlight: highlight, query: query) else {
                return nil
            }
            return highlight.range
        }

        var updated = query
        for range in rangesToRemove.sorted(by: { $0.lowerBound > $1.lowerBound }) {
            updated.removeSubrange(range)
        }

        updated = updated
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard state != .unselected else {
            return updated
        }

        let token = tokenText(for: tag, state: state)
        guard !updated.isEmpty else {
            return token
        }
        return "\(updated) \(token)"
    }

    private static func tagMatchesHighlight(
        _ tag: TagDisplaySummary,
        highlight: SearchTokenHighlight,
        query: String
    ) -> Bool {
        let token = String(query[highlight.range])
        let parsed = SearchQueryParser.parse(token)
        let constraints = parsed.requiredTags + parsed.excludedTags + parsed.optionalTags
        return constraints.contains {
            $0.namespace == tag.namespace && $0.name == tag.name
        }
    }

    private static func exactTagConstraint(from token: String) -> SearchTagConstraint? {
        guard let colonIndex = token.firstIndex(of: ":") else {
            return nil
        }

        let namespaceText = String(token[..<colonIndex])
        guard let namespace = SearchNamespace.canonical(namespaceText) else {
            return nil
        }

        let tail = String(token[token.index(after: colonIndex)...])
        guard tail.hasSuffix("$") || (tail.hasPrefix("\"") && tail.hasSuffix("\"")) else {
            return nil
        }

        var name = tail
        if name.hasSuffix("$") {
            name.removeLast()
        }
        name = normalizedSuggestionText(name)
        guard !name.isEmpty else {
            return nil
        }
        return SearchTagConstraint(namespace: namespace, name: name, isExact: true)
    }

    private static func normalizedSuggestionText(_ text: String) -> String {
        var value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.count >= 2, value.first == "\"", value.last == "\"" {
            value.removeFirst()
            value.removeLast()
        }
        return value
            .replacingOccurrences(of: "_", with: " ")
            .trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
    }

    private static func normalizedQuerySpacing(_ query: String) -> String {
        query
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func isTokenSeparator(_ character: Character) -> Bool {
        character.isWhitespace || character == ","
    }
}

private extension String {
    func trimmingPrefix(_ prefix: Character) -> String {
        var value = self
        if value.first == prefix {
            value.removeFirst()
        }
        return value
    }
}

enum SearchNamespace {
    static let aliases: [String: String] = [
        "f": "female",
        "female": "female",
        "m": "male",
        "male": "male",
        "a": "artist",
        "artist": "artist",
        "c": "character",
        "char": "character",
        "character": "character",
        "p": "parody",
        "series": "parody",
        "parody": "parody",
        "g": "group",
        "circle": "group",
        "group": "group",
        "l": "language",
        "lang": "language",
        "language": "language",
        "o": "other",
        "other": "other",
        "x": "mixed",
        "mixed": "mixed",
        "loc": "location",
        "location": "location",
        "cos": "cosplayer",
        "cosplayer": "cosplayer",
        "r": "reclass",
        "reclass": "reclass"
    ]

    static let facetNamespaces = [
        "female",
        "male",
        "mixed",
        "artist",
        "group",
        "parody",
        "character",
        "cosplayer",
        "language",
        "location",
        "other",
        "reclass"
    ]

    static func canonical(_ namespace: String) -> String? {
        aliases[namespace.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()]
    }

    static func canonicalAlias(for namespace: String) -> String? {
        switch namespace {
        case "female": return "f"
        case "male": return "m"
        case "artist": return "a"
        case "character": return "c"
        case "parody": return "p"
        case "group": return "g"
        case "language": return "l"
        case "other": return "o"
        case "mixed": return "x"
        case "location": return "loc"
        case "cosplayer": return "cos"
        case "reclass": return "r"
        default: return nil
        }
    }
}
