import AppKit
import Foundation
import GRDB
import Testing
@testable import NyaEHCore

@Suite("Advanced search")
struct AdvancedSearchTests {
    @Test("parser handles EH namespace aliases and operators")
    func parserHandlesEHSyntax() {
        let parsed = SearchQueryParser.parse(#"title:"comic aun" filename:"scan archive" f:tomgirl -m:muscle ~tag:"school uniform"$ p:love_live* weak:a:sample"#)

        #expect(parsed.titleTerms == [
            SearchTitleTerm(text: "comic aun", isExcluded: false, scope: .title),
            SearchTitleTerm(text: "scan archive", isExcluded: false, scope: .file)
        ])
        #expect(parsed.requiredTags.contains(SearchTagConstraint(namespace: "female", name: "tomgirl")))
        #expect(parsed.requiredTags.contains(SearchTagConstraint(namespace: "parody", name: "love live")))
        #expect(parsed.requiredTags.contains(SearchTagConstraint(namespace: "artist", name: "sample")))
        #expect(parsed.excludedTags == [SearchTagConstraint(namespace: "male", name: "muscle")])
        #expect(parsed.optionalTags == [SearchTagConstraint(namespace: nil, name: "school uniform", isExact: true)])
    }

    @Test("SQLite search supports title regex and tag include exclude")
    func sqliteSearchSupportsRegexAndTags() throws {
        let context = try makeContext()
        let first = try insertBook(
            context,
            title: "Comic AUN 2024",
            filepath: "/tmp/a.cbz",
            tags: #"["female:tomgirl","parody:love live"]"#
        )
        let second = try insertBook(
            context,
            title: "Comic AUN 2025",
            filepath: "/tmp/b.cbz",
            tags: #"["female:tomgirl","male:muscle"]"#
        )
        _ = try insertBook(
            context,
            title: "Other Work",
            filepath: "/tmp/c.cbz",
            tags: #"["female:school uniform"]"#
        )

        let response = try context.search.search(
            LibrarySearchRequest(
                rawQuery: #"Comic\s+AUN\s+\d+ f:tomgirl -m:muscle"#,
                isRegexEnabled: true,
                mode: .exact
            )
        )

        #expect(response.items.map(\.databaseID) == [first.databaseID])
        #expect(!response.items.contains { $0.databaseID == second.databaseID })

        let tagRegex = try context.search.search(
            LibrarySearchRequest(rawQuery: #"f:tom.*"#, isRegexEnabled: true, mode: .exact)
        )
        #expect(Set(tagRegex.items.compactMap(\.databaseID)) == Set([first.databaseID, second.databaseID]))
    }

    @Test("SQLite search supports filename terms")
    func sqliteSearchSupportsFilenameTerms() throws {
        let context = try makeContext()
        let filenameOnly = try insertBook(
            context,
            title: "Imported Gallery",
            filepath: "/tmp/library/Circle Alpha Special.cbz",
            tags: #"["female:tomgirl"]"#
        )
        let titleOnly = try insertBook(
            context,
            title: "Circle Alpha",
            filepath: "/tmp/library/random.cbz",
            tags: #"["female:tomgirl"]"#
        )
        _ = try insertBook(
            context,
            title: "Other",
            filepath: "/tmp/library/other.cbz",
            tags: #"["female:tomgirl"]"#
        )

        let plain = try context.search.search(
            LibrarySearchRequest(rawQuery: #"Alpha"#, mode: .exact)
        )
        #expect(Set(plain.items.compactMap(\.databaseID)) == Set([filenameOnly.databaseID, titleOnly.databaseID]))

        let fileOnly = try context.search.search(
            LibrarySearchRequest(rawQuery: #"filename:"Circle Alpha""#, mode: .exact)
        )
        #expect(fileOnly.items.map(\.databaseID) == [filenameOnly.databaseID])

        let excluded = try context.search.search(
            LibrarySearchRequest(rawQuery: #"f:tomgirl -file:random"#, mode: .exact)
        )
        #expect(!excluded.items.contains { $0.databaseID == titleOnly.databaseID })
        #expect(excluded.items.contains { $0.databaseID == filenameOnly.databaseID })
    }

    @Test("SQLite search distinguishes broad union from exact intersection")
    func sqliteSearchModes() throws {
        let context = try makeContext()
        let first = try insertBook(
            context,
            title: "First",
            filepath: "/tmp/first.cbz",
            tags: #"["female:tomgirl","parody:love live"]"#
        )
        let second = try insertBook(
            context,
            title: "Second",
            filepath: "/tmp/second.cbz",
            tags: #"["female:tomgirl"]"#
        )
        _ = try insertBook(
            context,
            title: "Third",
            filepath: "/tmp/third.cbz",
            tags: #"["parody:love live"]"#
        )

        let broad = try context.search.search(
            LibrarySearchRequest(rawQuery: "f:tomgirl p:love_live", mode: .broad)
        )
        let exact = try context.search.search(
            LibrarySearchRequest(rawQuery: "f:tomgirl p:love_live", mode: .exact)
        )

        #expect(Set(broad.items.compactMap(\.databaseID)).contains(first.databaseID))
        #expect(Set(broad.items.compactMap(\.databaseID)).contains(second.databaseID))
        #expect(exact.items.map(\.databaseID) == [first.databaseID])
    }

    @Test("search folds matching collection members into one entity")
    func searchFoldsCollectionMembersIntoOneEntity() throws {
        let context = try makeContext()
        let first = try insertBook(
            context,
            title: "Series Needle One",
            filepath: "/tmp/series-one.cbz",
            tags: #"["female:shared"]"#
        )
        let second = try insertBook(
            context,
            title: "Series Needle Two",
            filepath: "/tmp/series-two.cbz",
            tags: #"["female:shared"]"#
        )
        let service = makeService(context)
        let collection = try service.createCollection(name: "Needle Series")
        try service.addBook(first, to: collection)
        try service.addBook(second, to: collection)

        let response = try context.search.search(.init(rawQuery: "Series Needle", pageSize: 1))
        let hit = try #require(response.items.first)

        #expect(response.totalCount == 1)
        #expect(response.items.count == 1)
        #expect(hit.entityKey == .collection(collection.id))
        #expect(hit.matchedBookIDs == Set([first.id, second.id]))

        let sharedFacet = try #require(
            try context.search.tagFacets(.init(rawQuery: "Series Needle"))
                .first { $0.tag.rawValue == "female:shared" }
        )
        #expect(sharedFacet.tag.count == 2)
        #expect(sharedFacet.availableCount == 1)
    }

    @Test("regex and pagination deduplicate collection entities")
    func regexAndPaginationDeduplicateCollectionEntities() throws {
        let context = try makeContext()
        let first = try insertBook(
            context,
            title: "Series 01",
            filepath: "/tmp/regex-series-one.cbz",
            tags: "[]",
            posted: 300
        )
        let second = try insertBook(
            context,
            title: "Series 02",
            filepath: "/tmp/regex-series-two.cbz",
            tags: "[]",
            posted: 200
        )
        _ = try insertBook(
            context,
            title: "Standalone",
            filepath: "/tmp/regex-standalone.cbz",
            tags: "[]",
            posted: 100
        )
        let service = makeService(context)
        let collection = try service.createCollection(name: "Series")
        try service.addBook(first, to: collection)
        try service.addBook(second, to: collection)

        let regex = try context.search.search(.init(
            rawQuery: #"Series\s+\d+"#,
            isRegexEnabled: true,
            pageSize: 1
        ))
        #expect(regex.totalCount == 1)
        #expect(regex.items.first?.entityKey == .collection(collection.id))
        #expect(regex.items.first?.matchedBookIDs == Set([first.id, second.id]))

        let firstPage = try context.search.search(.init(page: 1, pageSize: 1))
        let secondPage = try context.search.search(.init(page: 2, pageSize: 1))
        #expect(firstPage.totalCount == 2)
        #expect(secondPage.totalCount == 2)
        #expect(firstPage.items.first?.entityKey != secondPage.items.first?.entityKey)
    }

    @Test("entity scopes keep user hiding separate from structural membership")
    func entityScopesSeparateUserAndStructuralHiding() throws {
        let context = try makeContext()
        let visible = try insertBook(
            context,
            title: "Scoped Needle Visible",
            filepath: "/tmp/scoped-visible.cbz",
            tags: "[]",
            mark: true
        )
        let hidden = try insertBook(
            context,
            title: "Scoped Needle Hidden",
            filepath: "/tmp/scoped-hidden.cbz",
            tags: "[]",
            isUserHidden: true
        )
        let service = makeService(context)
        let collection = try service.createCollection(name: "Scoped Series")
        try service.addBook(visible, to: collection)
        try service.addBook(hidden, to: collection)

        let all = try context.search.search(.init(rawQuery: "Scoped Needle"))
        #expect(all.totalCount == 1)
        #expect(all.items.first?.entityKey == .collection(collection.id))
        #expect(all.items.first?.matchedBookIDs == [visible.id])

        let marked = try context.search.search(.init(rawQuery: "Scoped Needle", scope: .marked))
        #expect(marked.totalCount == 1)
        #expect(marked.items.first?.matchedBookIDs == [visible.id])

        let hiddenOnly = try context.search.search(.init(rawQuery: "Scoped Needle", scope: .hidden))
        #expect(hiddenOnly.totalCount == 1)
        #expect(hiddenOnly.items.first?.entityKey == .collection(collection.id))
        #expect(hiddenOnly.items.first?.matchedBookIDs == [hidden.id])
    }

    @MainActor
    @Test("store returns a full collection and maps another version match to the primary")
    func storeBuildsEntityDisplayContext() async throws {
        let context = try makeContext()
        let first = try insertBook(
            context,
            title: "Collection Match",
            filepath: "/tmp/store-collection-one.cbz",
            tags: "[]"
        )
        let second = try insertBook(
            context,
            title: "Collection Companion",
            filepath: "/tmp/store-collection-two.cbz",
            tags: "[]"
        )
        let service = makeService(context)
        let collection = try service.createCollection(name: "Store Series")
        try service.addBook(first, to: collection)
        try service.addBook(second, to: collection)

        let primary = try insertBook(
            context,
            title: "Primary Edition",
            filepath: "/tmp/store-primary.cbz",
            tags: "[]"
        )
        let alternate = try insertBook(
            context,
            title: "Alternate Needle Edition",
            filepath: "/tmp/store-alternate.cbz",
            tags: "[]"
        )
        let group = try context.versionGroups.createVersionGroup(bookIDs: [
            try #require(primary.databaseID),
            try #require(alternate.databaseID)
        ])

        let store = CatalogStore(service: service)
        store.refresh()

        store.advancedSearchText = "Collection Match"
        store.submitAdvancedSearch(isTagTranslationEnabled: false)
        await waitForAdvancedSearch(store)
        let collectionDisplay = try #require(store.advancedSearchDisplayItems.first)
        guard case .collection(let item) = collectionDisplay.item else {
            Issue.record("Expected a collection display item")
            return
        }
        #expect(item.collection.id == collection.id)
        #expect(item.books.map(\.id) == [first.id, second.id])
        #expect(collectionDisplay.matchedBookIDs == [first.id])

        store.advancedSearchText = "Alternate Needle"
        store.submitAdvancedSearch(isTagTranslationEnabled: false)
        await waitForAdvancedSearch(store)
        let versionDisplay = try #require(store.advancedSearchDisplayItems.first)
        #expect(store.advancedSearchHits.first?.entityKey == .versionGroup(group.id))
        #expect(versionDisplay.representativeBook?.id == primary.id)
        #expect(versionDisplay.matchesOtherVersion)
    }

    @Test("suggestions match translated tag names")
    func suggestionsMatchTranslations() throws {
        let context = try makeContext()
        let book = try insertBook(
            context,
            title: "Uniform",
            filepath: "/tmp/uniform.cbz",
            tags: #"["female:school uniform"]"#
        )
        let bookID = try #require(book.databaseID)
        let tag = try #require(try context.tags.tags(forBookID: bookID).first)
        try context.tags.upsertTranslation(
            tagID: try #require(tag.id),
            languageCode: EhTagTranslationCache.languageCode,
            translatedName: "校服"
        )

        let suggestions = try context.search.tagSuggestions(
            SearchTagSuggestionRequest(query: "校", isTagTranslationEnabled: true)
        )

        #expect(suggestions.map(\.insertionText).contains(#"f:"school uniform""#))
        #expect(suggestions.first?.tag.displayName == "校服")
    }

    @Test("followed tags are marked and prioritized in facets and suggestions")
    func followedTagsAreMarkedAndPrioritized() throws {
        let context = try makeContext()
        _ = try insertBook(
            context,
            title: "Uniform",
            filepath: "/tmp/uniform.cbz",
            tags: #"["female:school uniform"]"#
        )
        _ = try insertBook(
            context,
            title: "Swimsuit",
            filepath: "/tmp/swimsuit.cbz",
            tags: #"["female:school swimsuit"]"#
        )
        _ = try insertBook(
            context,
            title: "Extra Uniform",
            filepath: "/tmp/extra-uniform.cbz",
            tags: #"["female:school uniform"]"#
        )
        let swimsuit = try #require(try context.tags.fetchAllTags().first { $0.rawValue == "female:school swimsuit" })
        try context.tags.setFollowed(tagID: try #require(swimsuit.id), isFollowed: true)

        let facets = try context.search.tagFacets(LibrarySearchRequest())
            .filter { $0.tag.namespace == "female" }
        let suggestions = try context.search.tagSuggestions(
            SearchTagSuggestionRequest(query: "school", isTagTranslationEnabled: false)
        )

        #expect(facets.first?.tag.rawValue == "female:school swimsuit")
        #expect(facets.first?.tag.isFollowed == true)
        #expect(suggestions.first?.tag.rawValue == "female:school swimsuit")
        #expect(suggestions.first?.tag.isFollowed == true)
    }

    @Test("search query text edits facet tokens and active suggestions")
    func searchQueryTextEditsFacetTokensAndSuggestions() {
        let tag = TagDisplaySummary(
            id: 1,
            namespace: "female",
            name: "magical girl",
            rawValue: "female:magical girl",
            displayName: "魔法少女",
            count: 3
        )
        let suggestion = SearchTagSuggestion(tag: tag, intro: nil)

        let selected = SearchQueryTextEditor.settingTag(tag, to: .selected, in: "comic")
        #expect(selected == #"comic f:"magical girl"$"#)
        let selectedFromEmpty = SearchQueryTextEditor.settingTag(tag, to: .selected, in: "")
        #expect(selectedFromEmpty == #"f:"magical girl"$"#)

        let groupTag = TagDisplaySummary(
            id: 3,
            namespace: "group",
            name: "circle a",
            rawValue: "group:circle a",
            displayName: "Circle A",
            count: 2
        )
        let languageTag = TagDisplaySummary(
            id: 4,
            namespace: "language",
            name: "chinese",
            rawValue: "language:chinese",
            displayName: "Chinese",
            count: 4
        )
        #expect(SearchQueryTextEditor.settingTag(groupTag, to: .selected, in: "") == #"g:"circle a"$"#)
        #expect(SearchQueryTextEditor.settingTag(languageTag, to: .selected, in: "") == "l:chinese$")

        let excluded = SearchQueryTextEditor.settingTag(tag, to: .excluded, in: selected)
        #expect(excluded == #"comic -f:"magical girl"$"#)

        let cleared = SearchQueryTextEditor.settingTag(tag, to: .unselected, in: excluded)
        #expect(cleared == "comic")

        let replaced = SearchQueryTextEditor.replacingActiveToken(
            in: "魔法",
            activeRange: NSRange(location: 0, length: 2),
            with: suggestion.exactInsertionText
        )
        #expect(replaced == #"f:"magical girl"$"#)

        let selectedHighlight = SearchQueryParser.parse(replaced).tokenHighlights[0]
        let cycledToExcluded = SearchQueryTextEditor.cyclingHighlightedToken(selectedHighlight, in: replaced)
        #expect(cycledToExcluded == #"-f:"magical girl"$"#)

        let excludedHighlight = SearchQueryParser.parse(cycledToExcluded).tokenHighlights[0]
        let cycledToCleared = SearchQueryTextEditor.cyclingHighlightedToken(excludedHighlight, in: cycledToExcluded)
        #expect(cycledToCleared == "")

        let query = #"title f:"magical girl" -c:"cure finale""#
        for location in 8...22 {
            #expect(
                SearchQueryTextEditor.activeTokenRange(
                    in: query,
                    selectedRange: NSRange(location: location, length: 0)
                ) == NSRange(location: 6, length: 16)
            )
        }

        let finale = SearchTagSuggestion(
            tag: TagDisplaySummary(
                id: 2,
                namespace: "character",
                name: "cure finale",
                rawValue: "character:cure finale",
                displayName: "cure finale",
                count: 1
            ),
            intro: nil
        )
        let replacedMiddle = SearchQueryTextEditor.replacingActiveToken(
            in: query,
            activeRange: SearchQueryTextEditor.activeTokenRange(
                in: query,
                selectedRange: NSRange(location: 28, length: 0)
            ),
            with: finale.exactInsertionText
        )
        #expect(replacedMiddle == #"title f:"magical girl" c:"cure finale"$"#)
        #expect(
            SearchQueryTextEditor.suggestionQuery(
                in: #"f:"magical girl""#,
                activeRange: NSRange(location: 0, length: 16)
            ) == nil
        )
    }

    @Test("suggestion selection follows keyboard movement and changing results")
    func suggestionSelectionNavigation() {
        var selection = SearchSuggestionSelection()
        let ids: [Int64] = [11, 22, 33]

        selection.move(.next, among: ids)
        #expect(selection.selectedID == 11)
        selection.move(.next, among: ids)
        #expect(selection.selectedID == 22)
        selection.move(.next, among: ids)
        selection.move(.next, among: ids)
        #expect(selection.selectedID == 11)
        selection.move(.previous, among: ids)
        #expect(selection.selectedID == 33)
        selection.reconcile(with: [11, 22])
        #expect(selection.selectedID == nil)
        selection.move(.previous, among: [11, 22])
        #expect(selection.selectedID == 22)
        selection.clear()
        #expect(selection.selectedID == nil)
    }

    @MainActor
    @Test("selecting a suggestion changes the draft without submitting a search")
    func selectingSuggestionOnlyChangesDraft() throws {
        let context = try makeContext()
        let service = BookLibraryService(
            bookRepository: context.books,
            metadataRepository: context.metadata,
            tagRepository: context.tags,
            searchRepository: context.search
        )
        let store = CatalogStore(service: service)
        let suggestion = SearchTagSuggestion(
            tag: TagDisplaySummary(
                id: 5,
                namespace: "female",
                name: "magical girl",
                rawValue: "female:magical girl",
                displayName: "魔法少女",
                count: 1
            ),
            intro: nil
        )
        store.advancedSearchText = "comic magic"
        store.advancedSearchActiveTokenRange = NSRange(location: 6, length: 5)
        store.advancedSearchSuggestions = [suggestion]

        store.insertAdvancedSearchSuggestion(
            suggestion,
            activeRange: store.advancedSearchActiveTokenRange
        )

        #expect(store.advancedSearchText == #"comic f:"magical girl"$"#)
        #expect(store.advancedSearchSuggestions.isEmpty)
        #expect(store.advancedSearchActiveTokenRange?.location == (store.advancedSearchText as NSString).length)
        #expect(!store.isAdvancedSearchLoading)
        #expect(store.advancedSearchResults.isEmpty)
    }

    @Test("suggestions respect complete tokens and namespaces")
    func suggestionsRespectCompleteTokensAndNamespaces() throws {
        let context = try makeContext()
        _ = try insertBook(
            context,
            title: "Magical",
            filepath: "/tmp/magical.cbz",
            tags: #"["female:magical girl","male:magical boy","character:cure finale"]"#
        )

        let namespaced = try context.search.tagSuggestions(
            SearchTagSuggestionRequest(query: "mag", namespace: "female", isTagTranslationEnabled: false)
        )
        #expect(namespaced.map(\.tag.rawValue) == ["female:magical girl"])

        let complete = try context.search.tagSuggestions(
            SearchTagSuggestionRequest(
                query: "magical girl",
                namespace: "female",
                excludedRawValue: "female:magical girl",
                isTagTranslationEnabled: false
            )
        )
        #expect(complete.isEmpty)
    }

    @Test("exact mode keeps unavailable facets visible")
    func exactModeKeepsUnavailableFacetsVisible() throws {
        let context = try makeContext()
        _ = try insertBook(
            context,
            title: "First",
            filepath: "/tmp/first.cbz",
            tags: #"["female:tomgirl","parody:love live"]"#
        )
        _ = try insertBook(
            context,
            title: "Second",
            filepath: "/tmp/second.cbz",
            tags: #"["female:school uniform"]"#
        )

        let facets = try context.search.tagFacets(
            LibrarySearchRequest(rawQuery: "p:love_live", mode: .exact)
        )
        let unavailable = try #require(facets.first { $0.tag.rawValue == "female:school uniform" })

        #expect(unavailable.availableCount == 0)
        #expect(!unavailable.isEnabled)
    }

    @MainActor
    @Test("store refreshes search state and facet counts")
    func storeRefreshesSearchState() async throws {
        let context = try makeContext()
        _ = try insertBook(
            context,
            title: "First",
            filepath: "/tmp/first.cbz",
            tags: #"["female:tomgirl","parody:love live"]"#
        )
        _ = try insertBook(
            context,
            title: "Second",
            filepath: "/tmp/second.cbz",
            tags: #"["female:tomgirl"]"#
        )
        let service = BookLibraryService(
            bookRepository: context.books,
            metadataRepository: context.metadata,
            tagRepository: context.tags,
            searchRepository: context.search
        )
        let store = CatalogStore(service: service)
        store.advancedSearchText = "f:tomgirl"
        store.advancedSearchMode = .exact

        store.submitAdvancedSearch(isTagTranslationEnabled: false)
        await waitForAdvancedSearch(store)

        #expect(store.advancedSearchResults.count == 2)
        #expect(store.advancedSearchDisplayItems.count == 2)
        #expect(store.advancedSearchFacetsByNamespace["parody"]?.contains { $0.tag.rawValue == "parody:love live" && $0.availableCount == 1 } == true)
        #expect(store.advancedSearchTagFacets.contains { $0.tag.rawValue == "parody:love live" && $0.availableCount == 1 })
        #expect(store.advancedSearchError == nil)
    }

    @MainActor
    @Test("editing a later search page keeps committed results while suggestions refresh")
    func editingSearchTextDoesNotExecuteSearch() async throws {
        let context = try makeContext()
        _ = try insertBook(
            context,
            title: "Magical",
            filepath: "/tmp/magical.cbz",
            tags: #"["female:magical girl"]"#
        )
        _ = try insertBook(
            context,
            title: "Other",
            filepath: "/tmp/other.cbz",
            tags: #"["female:schoolgirl"]"#
        )
        let service = BookLibraryService(
            bookRepository: context.books,
            metadataRepository: context.metadata,
            tagRepository: context.tags,
            searchRepository: context.search
        )
        let store = CatalogStore(service: service)
        store.advancedSearchPageSize = 1
        store.advancedSearchPage = 2
        store.submitAdvancedSearch(isTagTranslationEnabled: false)
        await waitForAdvancedSearch(store)
        let committedResults = store.advancedSearchResults
        #expect(committedResults.count == 1)

        for query in ["f:ma", "f:magi", "f:magical"] {
            store.advancedSearchText = query
            store.advancedSearchActiveTokenRange = NSRange(location: 0, length: (query as NSString).length)
            store.updateAdvancedSearchDraft()
            store.refreshAdvancedSearchSuggestionsAsync(isTagTranslationEnabled: false)
        }
        for _ in 0..<100 where store.advancedSearchSuggestions.isEmpty {
            try? await Task.sleep(for: .milliseconds(10))
        }

        #expect(store.advancedSearchResults == committedResults)
        #expect(store.advancedSearchPage == 2)
        #expect(!store.isAdvancedSearchLoading)
        #expect(!store.advancedSearchParsedQuery.tokenHighlights.isEmpty)
        #expect(store.advancedSearchSuggestions.contains { $0.tag.rawValue == "female:magical girl" })

        store.advancedSearchPage = 1
        store.submitAdvancedSearch(isTagTranslationEnabled: false)
        await waitForAdvancedSearch(store)

        #expect(store.advancedSearchResults.map(\.title) == ["Magical"])
    }

    @MainActor
    @Test("store searches books matching selected tag")
    func storeSearchesBooksMatchingSelectedTag() async throws {
        let context = try makeContext()
        _ = try insertBook(
            context,
            title: "Magical",
            filepath: "/tmp/magical.cbz",
            tags: #"["female:magical girl"]"#
        )
        _ = try insertBook(
            context,
            title: "Other",
            filepath: "/tmp/other.cbz",
            tags: #"["female:schoolgirl"]"#
        )
        let service = BookLibraryService(
            bookRepository: context.books,
            metadataRepository: context.metadata,
            tagRepository: context.tags,
            searchRepository: context.search
        )
        let store = CatalogStore(service: service)
        store.advancedSearchText = "old query"
        store.advancedSearchMode = .broad
        store.advancedSearchSuggestions = [
            SearchTagSuggestion(
                tag: TagDisplaySummary(
                    id: 99,
                    namespace: "female",
                    name: "old",
                    rawValue: "female:old",
                    displayName: "old",
                    count: 1
                ),
                intro: nil
            )
        ]
        store.advancedSearchActiveTokenRange = NSRange(location: 0, length: 3)

        store.searchBooks(
            matching: TagDisplaySummary(
                id: 1,
                namespace: "female",
                name: "magical girl",
                rawValue: "female:magical girl",
                displayName: "魔法少女",
                count: 1
            ),
            isTagTranslationEnabled: false
        )
        await waitForAdvancedSearch(store)

        #expect(store.advancedSearchText == #"f:"magical girl"$"#)
        #expect(store.advancedSearchMode == .exact)
        #expect(store.advancedSearchActiveTokenRange == nil)
        #expect(store.advancedSearchSuggestions.isEmpty)
        #expect(store.advancedSearchResults.map(\.title) == ["Magical"])
        #expect(store.advancedSearchError == nil)
    }

    @MainActor
    @Test("recent additions opens the complete edition search in descending import order")
    func searchRecentlyAddedBooks() async throws {
        let context = try makeContext()
        let older = try context.books.insert(LibraryBook(title: "A", hash: "a", filepath: "/a.cbz", createdAt: 100))
        let newer = try context.books.insert(LibraryBook(title: "Z", hash: "z", filepath: "/z.cbz", createdAt: 500))
        _ = try context.versionGroups.createVersionGroup(bookIDs: [
            try #require(older.databaseID), try #require(newer.databaseID)
        ])
        let store = CatalogStore(service: makeService(context))
        store.advancedSearchText = "stale"
        store.advancedSearchMode = .broad
        store.advancedSearchScope = .marked
        store.advancedSearchPage = 7
        store.advancedSearchSortKey = .title
        store.advancedSearchSortDirection = .ascending
        store.isAdvancedSearchRegexEnabled = true
        store.isCoverImageSearchActive = true
        store.advancedSearchActiveTokenRange = NSRange(location: 0, length: 5)

        store.searchRecentlyAddedBooks(isTagTranslationEnabled: false)
        await waitForAdvancedSearch(store)

        #expect(store.advancedSearchPage == 1)
        #expect(store.advancedSearchText.isEmpty)
        #expect(store.advancedSearchMode == .exact)
        #expect(store.advancedSearchScope == .all)
        #expect(store.advancedSearchSortKey == .added)
        #expect(store.advancedSearchSortDirection == .descending)
        #expect(store.advancedSearchShowsIndividualBooks)
        #expect(!store.isAdvancedSearchRegexEnabled)
        #expect(!store.isCoverImageSearchActive)
        #expect(store.advancedSearchActiveTokenRange == nil)
        #expect(store.advancedSearchResults.map(\.id) == [newer.id, older.id])
    }

    @MainActor
    @Test("store locally sorts advanced search results")
    func storeLocallySortsAdvancedSearchResults() async throws {
        let context = try makeContext()
        _ = try insertBook(
            context,
            title: "Gamma",
            filepath: "/tmp/gamma.cbz",
            tags: #"["female:shared"]"#,
            rating: 2,
            pages: 10,
            posted: 300,
            mark: false
        )
        _ = try insertBook(
            context,
            title: "Alpha",
            filepath: "/tmp/alpha.cbz",
            tags: #"["female:shared"]"#,
            rating: 5,
            pages: 30,
            posted: 100,
            mark: true
        )
        _ = try insertBook(
            context,
            title: "Beta",
            filepath: "/tmp/beta.cbz",
            tags: #"["female:shared"]"#,
            rating: 1,
            pages: 20,
            posted: 200,
            mark: false
        )
        let service = BookLibraryService(
            bookRepository: context.books,
            metadataRepository: context.metadata,
            tagRepository: context.tags,
            searchRepository: context.search
        )
        let store = CatalogStore(service: service)
        store.advancedSearchText = "f:shared"
        store.submitAdvancedSearch(isTagTranslationEnabled: false)
        await waitForAdvancedSearch(store)

        #expect(store.advancedSearchResults.map(\.title) == ["Gamma", "Beta", "Alpha"])
        let facetsBeforeSort = store.advancedSearchTagFacets

        store.advancedSearchSortKey = .title
        store.advancedSearchSortDirection = .ascending
        store.resortAdvancedSearchResults()
        #expect(store.advancedSearchResults.map(\.title) == ["Alpha", "Beta", "Gamma"])
        #expect(store.advancedSearchTagFacets == facetsBeforeSort)
        #expect(!store.isAdvancedSearchLoading)

        store.advancedSearchSortKey = .rating
        store.advancedSearchSortDirection = .descending
        store.resortAdvancedSearchResults()
        #expect(store.advancedSearchResults.map(\.title) == ["Alpha", "Gamma", "Beta"])

        store.advancedSearchSortKey = .pages
        store.advancedSearchSortDirection = .ascending
        store.resortAdvancedSearchResults()
        #expect(store.advancedSearchResults.map(\.title) == ["Gamma", "Beta", "Alpha"])

        store.advancedSearchSortKey = .marked
        store.advancedSearchSortDirection = .descending
        store.resortAdvancedSearchResults()
        #expect(store.advancedSearchResults.map(\.title) == ["Alpha", "Beta", "Gamma"])
    }

    @Test("facet counts stay exact on larger libraries")
    func facetCountsStayExactOnLargerLibraries() throws {
        let context = try makeContext()
        for index in 0..<2_000 {
            var tags = [
                "female:shared",
                "parody:series \(index % 20)",
                "character:hero \(index % 40)"
            ]
            if index % 2 == 0 {
                tags.append("male:even")
            }
            if index % 5 == 0 {
                tags.append("female:rare")
            }
            let tagJSON = try String(
                data: JSONEncoder().encode(tags),
                encoding: .utf8
            ) ?? "[]"
            _ = try insertBook(
                context,
                title: "Book \(index)",
                filepath: "/tmp/large-\(index).cbz",
                tags: tagJSON
            )
        }

        let facets = try context.search.tagFacets(
            LibrarySearchRequest(rawQuery: "f:shared p:\"series 1\"$", mode: .exact)
        )
        let matchingCharacter = try #require(facets.first { $0.tag.rawValue == "character:hero 1" })
        let nonMatchingCharacter = try #require(facets.first { $0.tag.rawValue == "character:hero 2" })
        let rare = try #require(facets.first { $0.tag.rawValue == "female:rare" })

        #expect(matchingCharacter.availableCount == 50)
        #expect(matchingCharacter.isEnabled)
        #expect(nonMatchingCharacter.availableCount == 0)
        #expect(!nonMatchingCharacter.isEnabled)
        #expect(rare.availableCount == 0)
        #expect(!rare.isEnabled)
    }

    @Test("empty search shows visible books and scopes compose with text")
    func emptySearchAndScopes() throws {
        let context = try makeContext()
        let visible = try insertBook(context, title: "Needle Visible", filepath: "/tmp/scope-visible.cbz", tags: "[]")
        _ = try insertBook(context, title: "Needle Hidden", filepath: "/tmp/scope-hidden.cbz", tags: "[]", isUserHidden: true)
        let favorite = try insertBook(context, title: "Needle Favorite", filepath: "/tmp/scope-favorite.cbz", tags: "[]", mark: true)
        _ = try insertBook(context, title: "Other Favorite", filepath: "/tmp/scope-other.cbz", tags: "[]", mark: true)

        let all = try context.search.search(.init(rawQuery: ""))
        #expect(all.totalCount == 3)
        #expect(all.items.contains { $0.databaseID == visible.databaseID })
        #expect(!all.items.contains { $0.isUserHidden })

        let hidden = try context.search.search(.init(rawQuery: "Needle", scope: .hidden))
        #expect(hidden.totalCount == 1)
        #expect(hidden.items.allSatisfy { $0.isUserHidden })

        let marked = try context.search.search(.init(rawQuery: "Needle", scope: .marked))
        #expect(marked.items.map(\.databaseID) == [favorite.databaseID])

        // A zero-result range must not affect later queries in the same repository.
        for (scope, count) in [
            (BookSearchScope.all, 3), (.marked, 2), (.missing, 0),
            (.unread, 3), (.hidden, 1), (.all, 3)
        ] {
            let response = try context.search.search(.init(rawQuery: "", scope: scope))
            #expect(response.totalCount == count)
        }
    }

    @Test("SQL pagination returns stable disjoint pages and total count")
    func sqlPaginationIsStable() throws {
        let context = try makeContext()
        for index in 0..<5 {
            _ = try insertBook(
                context,
                title: "Same Title",
                filepath: "/tmp/page-\(index).cbz",
                tags: "[]"
            )
        }

        let first = try context.search.search(.init(
            rawQuery: "",
            page: 1,
            pageSize: 2,
            sortKey: .title,
            sortDirection: .ascending
        ))
        let second = try context.search.search(.init(
            rawQuery: "",
            page: 2,
            pageSize: 2,
            sortKey: .title,
            sortDirection: .ascending
        ))

        #expect(first.totalCount == 5)
        #expect(second.totalCount == 5)
        #expect(first.items.count == 2)
        #expect(second.items.count == 2)
        #expect(Set(first.items.compactMap(\.databaseID)).isDisjoint(with: Set(second.items.compactMap(\.databaseID))))
    }

    @Test("secondary selection appends books")
    func secondarySelectionOnlyAppends() {
        let first = selectionBook(id: 1, title: "First")
        let second = selectionBook(id: 2, title: "Second")
        var state = SearchResultSelectionState()

        state.appendSelection(.book(first))
        #expect(state.selectedBookIDs == [first.id])

        state.appendSelection(.book(first))
        #expect(state.selectedBookIDs == [first.id])

        state.appendSelection(.book(second))
        #expect(state.selectedBookIDs == [first.id, second.id])
    }

    @Test("secondary collection selection adds every member")
    func secondaryCollectionSelectionAddsMembers() {
        let first = selectionBook(id: 1, title: "First")
        let second = selectionBook(id: 2, title: "Second")
        let collection = BookCollection(databaseID: 9, name: "Series")
        let item = LibraryDisplayItem.collection(
            BookCollectionDisplayItem(collection: collection, books: [first, second])
        )
        var state = SearchResultSelectionState()

        state.appendSelection(item)

        #expect(state.selectedBookIDs == [first.id, second.id])

    }

    @Test("individual results match and paginate by book in SQL and regex")
    func individualResultsPaginateMatchingBooks() throws {
        let context = try makeContext()
        let service = makeService(context)
        let collection = try service.createCollection(name: "Series")
        let first = try insertBook(context, title: "Needle 01", filepath: "/tmp/individual-one.cbz", tags: #"["female:shared"]"#)
        let second = try insertBook(context, title: "Needle 02", filepath: "/tmp/individual-two.cbz", tags: #"["female:shared"]"#)
        let excluded = try insertBook(context, title: "Other", filepath: "/tmp/individual-other.cbz", tags: #"["female:shared"]"#)
        for book in [first, second, excluded] {
            try service.addBook(book, to: collection)
        }

        for isRegex in [false, true] {
            let query = isRegex ? #"Needle\s+\d+"# : "Needle"
            var request = LibrarySearchRequest(
                rawQuery: query,
                isRegexEnabled: isRegex,
                pageSize: 1,
                sortKey: .title,
                sortDirection: .ascending,
                showsIndividualBooks: true
            )
            let pageOne = try context.search.search(request)
            request.page = 2
            let pageTwo = try context.search.search(request)
            #expect(pageOne.totalCount == 2)
            #expect(pageTwo.totalCount == 2)
            #expect(pageOne.items.map(\.entityKey) == [.book(first.id)])
            #expect(pageTwo.items.map(\.entityKey) == [.book(second.id)])
            #expect(pageTwo.items.first?.matchedBookIDs == [second.id])

            let facet = try #require(try context.search.tagFacets(request).first { $0.tag.rawValue == "female:shared" })
            #expect(facet.availableCount == 2)
            let individualCacheKey = SearchFacetCacheKey(request: request, tagRevision: 0)
            request.showsIndividualBooks = false
            #expect(SearchFacetCacheKey(request: request, tagRevision: 0) != individualCacheKey)
            let groupedFacet = try #require(try context.search.tagFacets(request).first { $0.tag.rawValue == "female:shared" })
            #expect(groupedFacet.availableCount == 1)
        }
    }

    @Test("matching versions remain separate in individual search and cover similarity")
    func individualSearchKeepsMatchingVersionsSeparate() throws {
        let context = try makeContext()
        let first = try insertBook(context, title: "Edition One", filepath: "/tmp/individual-primary.cbz", tags: "[]")
        let second = try insertBook(context, title: "Edition Two", filepath: "/tmp/individual-secondary.cbz", tags: "[]")
        let group = try context.versionGroups.createVersionGroup(bookIDs: [
            try #require(first.databaseID), try #require(second.databaseID)
        ])
        let result = try context.search.search(.init(rawQuery: "Edition", showsIndividualBooks: true))
        #expect(result.totalCount == 2)
        #expect(Set(result.items.map(\.entityKey)) == [.book(first.id), .book(second.id)])

        let matches = result.items.map {
            CoverImageSearchMatch(book: $0.representativeBook, distance: $0.entityKey == .book(first.id) ? 80 : 10)
        }
        let grouped = CatalogStore.coverImageSearchHits(matches, showsIndividualBooks: false)
        #expect(grouped.map(\.entityKey) == [.versionGroup(group.id)])
        #expect(grouped.first?.similarityDistance == 10)
        let individual = CatalogStore.coverImageSearchHits(matches, showsIndividualBooks: true)
        #expect(individual.map(\.entityKey) == [.book(second.id), .book(first.id)])
        #expect(individual.map(\.similarityDistance) == [10, 80])
    }

    @Test("selection buttons toggle and blank clearing resets batch selection")
    func selectionToggleAndClear() {
        let first = selectionBook(id: 1, title: "First")
        let second = selectionBook(id: 2, title: "Second")
        let firstItem = LibraryDisplayItem.book(first)
        var state = SearchResultSelectionState()

        state.toggleSelection(firstItem)
        #expect(state.selectedBookIDs == [first.id])

        state.appendSelection(.book(second))
        state.toggleSelection(.book(second))
        #expect(state.selectedBookIDs == [first.id])

        state.clear()
        #expect(state.selectedBookIDs.isEmpty)
    }

    @Test("selection is reconciled to the current result page")
    func selectionRetainsOnlyAvailableBooks() {
        let first = selectionBook(id: 1, title: "First")
        let second = selectionBook(id: 2, title: "Second")
        var state = SearchResultSelectionState()
        state.appendSelection(.book(first))
        state.appendSelection(.book(second))

        state.retainAvailableBookIDs([first.id])

        #expect(state.selectedBookIDs == [first.id])
    }

    @Test("preview resolves the current page and only the members of expanded series")
    func previewResolvesVisibleResults() {
        let first = selectionBook(id: 1, title: "First")
        let second = selectionBook(id: 2, title: "Second")
        let collection = BookCollection(databaseID: 9, name: "Series")
        let item = LibraryDisplayItem.collection(
            BookCollectionDisplayItem(collection: collection, books: [first, second])
        )
        let series = SearchPreviewTarget(item: item)
        let book = SearchPreviewTarget(item: .book(second))
        #expect(series.resolve(in: [item], expandedCollections: []) == item)
        #expect(series.resolve(in: [.book(first)], expandedCollections: [collection.id]) == nil)
        #expect(book.resolve(in: [item], expandedCollections: []) == nil)
        #expect(book.resolve(in: [item], expandedCollections: [collection.id]) == .book(second))
        #expect(book.resolve(in: [.book(second)], expandedCollections: []) == .book(second))
    }

    @Test("secondary-click policy ignores ordinary pointer and scrolling events")
    func secondaryClickPolicy() {
        #expect(SearchSecondaryClickHitPolicy.accepts(eventType: .rightMouseDown))
        #expect(SearchSecondaryClickHitPolicy.accepts(eventType: .rightMouseUp))
        #expect(SearchSecondaryClickHitPolicy.accepts(eventType: .leftMouseDown, modifierFlags: .control))
        #expect(SearchSecondaryClickHitPolicy.accepts(eventType: .leftMouseUp, modifierFlags: .control))

        #expect(!SearchSecondaryClickHitPolicy.accepts(eventType: .rightMouseDown, commandClickOnly: true))
        #expect(!SearchSecondaryClickHitPolicy.accepts(eventType: .leftMouseDown, modifierFlags: .control, commandClickOnly: true))
        #expect(SearchSecondaryClickHitPolicy.accepts(eventType: .leftMouseDown, modifierFlags: .command, commandClickOnly: true))
        #expect(!SearchSecondaryClickHitPolicy.accepts(eventType: .leftMouseDown, modifierFlags: [.control, .command], commandClickOnly: true))
        #expect(!SearchSecondaryClickHitPolicy.accepts(eventType: .leftMouseDown))
        #expect(!SearchSecondaryClickHitPolicy.accepts(eventType: .leftMouseUp))
        #expect(!SearchSecondaryClickHitPolicy.accepts(eventType: .scrollWheel))
        #expect(!SearchSecondaryClickHitPolicy.accepts(eventType: .leftMouseDragged, modifierFlags: .control))
        #expect(!SearchSecondaryClickHitPolicy.accepts(eventType: .mouseMoved))
    }

    @Test("pinned search header waits for a dynamic measurement and uses it as scroll clearance")
    func pinnedHeaderLayoutUsesDynamicMeasurement() {
        #expect(SearchPinnedHeaderLayout.normalizedMeasuredHeight(123.4) == 124)
        #expect(SearchPinnedHeaderLayout.normalizedMeasuredHeight(0) == nil)
        #expect(SearchPinnedHeaderLayout.normalizedMeasuredHeight(.infinity) == nil)

        #expect(SearchPinnedHeaderLayout.topContentClearance(isPinned: true, measuredHeight: nil) == 0)
        #expect(!SearchPinnedHeaderLayout.isResultContentReady(isPinned: true, measuredHeight: nil))

        #expect(SearchPinnedHeaderLayout.topContentClearance(isPinned: true, measuredHeight: 287) == 287)
        #expect(SearchPinnedHeaderLayout.isResultContentReady(isPinned: true, measuredHeight: 287))

        #expect(SearchPinnedHeaderLayout.topContentClearance(isPinned: false, measuredHeight: 287) == 0)
        #expect(SearchPinnedHeaderLayout.isResultContentReady(isPinned: false, measuredHeight: nil))
    }

    @Test("search suggestion popup fits the available viewport")
    func suggestionPlacementRespectsViewport() {
        let regular = SearchSuggestionPlacement.make(
            inputFrame: CGRect(x: 30, y: 40, width: 1_000, height: 44),
            containerSize: CGSize(width: 1_200, height: 700),
            footerHeight: 70,
            suggestionCount: 20
        )
        #expect(regular?.left == 30)
        #expect(regular?.top == 92)
        #expect(regular?.width == 560)
        #expect(regular?.height == 260)

        let narrow = SearchSuggestionPlacement.make(
            inputFrame: CGRect(x: 28, y: 40, width: 320, height: 44),
            containerSize: CGSize(width: 340, height: 300),
            footerHeight: 70,
            suggestionCount: 20
        )
        #expect(narrow?.left == 16)
        #expect(narrow?.width == 308)
        #expect(narrow?.height == 122)
        #expect(narrow.map { $0.top + $0.height } == 214)

        #expect(SearchSuggestionPlacement.make(
            inputFrame: CGRect(x: 28, y: 180, width: 320, height: 44),
            containerSize: CGSize(width: 340, height: 300),
            footerHeight: 70,
            suggestionCount: 20
        ) == nil)
    }

    private func selectionBook(id: Int64, title: String) -> LibraryBook {
        LibraryBook(
            databaseID: id,
            title: title,
            hash: "hash-\(id)",
            filepath: "/tmp/\(id).cbz",
            type: .archive,
            status: .correct
        )
    }

    private func insertBook(
        _ context: SearchRepositoryContext,
        title: String,
        filepath: String,
        tags: String,
        rating: Double? = nil,
        pages: Int? = nil,
        posted: Int64? = nil,
        mark: Bool = false,
        isUserHidden: Bool = false
    ) throws -> LibraryBook {
        let book = try context.books.insert(
            LibraryBook(
                title: title,
                hash: UUID().uuidString,
                filepath: filepath,
                type: .archive,
                status: .correct,
                date: 1_775_657_594_420,
                rating: rating,
                tags: tags,
                pages: pages,
                posted: posted,
                mark: mark,
                isUserHidden: isUserHidden
            )
        )
        try context.tags.rebuildTags(
            forBookID: try #require(book.databaseID),
            tagsJSON: tags
        )
        return try context.books.fetch(id: try #require(book.databaseID)) ?? book
    }

    private func makeContext() throws -> SearchRepositoryContext {
        let directory = TestRunResources.directory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let database = try DatabaseManager(path: directory.appendingPathComponent("NyaEH.sqlite").path)
        return SearchRepositoryContext(
            database: database,
            books: SQLiteLibraryBookRepository(dbQueue: database.dbQueue),
            metadata: SQLiteGalleryMetadataRepository(dbQueue: database.dbQueue),
            tags: SQLiteTagRepository(dbQueue: database.dbQueue),
            search: SQLiteLibrarySearchRepository(dbQueue: database.dbQueue),
            collections: SQLiteCollectionRepository(dbQueue: database.dbQueue),
            versionGroups: SQLiteVersionGroupRepository(dbQueue: database.dbQueue)
        )
    }

    private func makeService(_ context: SearchRepositoryContext) -> BookLibraryService {
        BookLibraryService(
            bookRepository: context.books,
            metadataRepository: context.metadata,
            tagRepository: context.tags,
            searchRepository: context.search,
            collectionRepository: context.collections,
            versionGroupRepository: context.versionGroups
        )
    }

    @MainActor
    private func waitForAdvancedSearch(_ store: CatalogStore) async {
        for _ in 0..<100 where store.isAdvancedSearchLoading {
            try? await Task.sleep(for: .milliseconds(10))
        }
    }
}

private struct SearchRepositoryContext {
    let database: DatabaseManager
    let books: SQLiteLibraryBookRepository
    let metadata: SQLiteGalleryMetadataRepository
    let tags: SQLiteTagRepository
    let search: SQLiteLibrarySearchRepository
    let collections: SQLiteCollectionRepository
    let versionGroups: SQLiteVersionGroupRepository
}
