// Pure whole-library projections are built away from MainActor after organization edits.

import Foundation

actor OrganizationProjectionWorker {
    func filterCandidates(_ books: [LibraryBook], query: String) -> [LibraryBook] {
        guard !Task.isCancelled else { return [] }
        return OrganizationDerivedSnapshot.filterCandidates(books, query: query)
    }

    func build(
        books: [LibraryBook],
        readingStates: [LibraryBook.DatabaseID: BookReadingState],
        collections: [BookCollection],
        searchText: String,
        filter: LibraryFilter
    ) -> OrganizationDerivedSnapshot? {
        guard !Task.isCancelled else { return nil }
        let snapshot = OrganizationDerivedSnapshot.build(
            books: books,
            readingStates: readingStates,
            collections: collections,
            searchText: searchText,
            filter: filter
        )
        return Task.isCancelled ? nil : snapshot
    }
}

struct OrganizationDerivedSnapshot: Sendable {
    let collectionCandidates: [LibraryBook]
    let versionCandidates: [LibraryBook]
    let recommendedBooks: [LibraryBook]
    let markedPreviewBooks: [LibraryBook]
    let favoriteManagementBooks: [LibraryBook]
    let continueReadingBooks: [LibraryBook]
    let recentlyViewedBooks: [LibraryBook]
    let recentlyAddedBooks: [LibraryBook]
    let searchedBooks: [LibraryBook]
    let displayItems: [LibraryDisplayItem]
    let filteredDisplayItems: [LibraryDisplayItem]
    let filteredBooks: [LibraryBook]

    static func filterCandidates(_ books: [LibraryBook], query: String) -> [LibraryBook] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return books }
        return books.filter { book in
            book.title.localizedCaseInsensitiveContains(trimmed)
                || (book.titleJpn?.localizedCaseInsensitiveContains(trimmed) ?? false)
                || book.filepath.localizedCaseInsensitiveContains(trimmed)
                || book.hash.localizedCaseInsensitiveContains(trimmed)
                || (book.url?.localizedCaseInsensitiveContains(trimmed) ?? false)
        }
    }

    static func build(
        books: [LibraryBook],
        readingStates: [LibraryBook.DatabaseID: BookReadingState],
        collections: [BookCollection],
        searchText: String,
        filter: LibraryFilter
    ) -> Self {
        let primaryBooks = books.filter { $0.versionGroupID == nil || $0.isPrimaryVersion }
        let candidateSort: (LibraryBook, LibraryBook) -> Bool = { lhs, rhs in
            BookTitleFormatter.displayTitle(for: lhs, mode: .originalTitle)
                .localizedCaseInsensitiveCompare(BookTitleFormatter.displayTitle(for: rhs, mode: .originalTitle)) == .orderedAscending
        }
        let favoriteSort: (LibraryBook, LibraryBook) -> Bool = { lhs, rhs in
            if lhs.date == rhs.date { return lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending }
            return lhs.date > rhs.date
        }
        let today = Calendar.current.dateComponents([.year, .month, .day], from: Date())
        let dateKey = "\(today.year ?? 0)-\(today.month ?? 0)-\(today.day ?? 0)"
        func recommendationScore(_ book: LibraryBook) -> UInt64 {
            let source = "\(dateKey)|\(book.id)|\(book.hash)|\(book.filepath)"
            return source.utf8.reduce(UInt64(14_695_981_039_346_656_037)) { hash, byte in
                (hash ^ UInt64(byte)) &* 1_099_511_628_211
            }
        }
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let searchedBooks = books.filter { book in
            query.isEmpty || book.title.localizedCaseInsensitiveContains(query)
                || book.filepath.localizedCaseInsensitiveContains(query)
                || book.hash.localizedCaseInsensitiveContains(query)
                || (book.titleJpn?.localizedCaseInsensitiveContains(query) ?? false)
                || (book.url?.localizedCaseInsensitiveContains(query) ?? false)
        }
        let searchedIDs = Set(searchedBooks.map(\.id))
        let groupedBooks = Dictionary(grouping: books.compactMap { book -> (Int64, LibraryBook)? in
            book.collectionID.map { ($0, book) }
        }, by: \.0)
        let collectionItems: [LibraryDisplayItem] = collections.compactMap { collection in
            guard let id = collection.databaseID else { return nil }
            let members = (groupedBooks[id] ?? []).map(\.1)
                .filter { $0.isPrimaryVersion && searchedIDs.contains($0.id) }
                .sorted { lhs, rhs in
                    let left = lhs.collectionOrder ?? Int.max
                    let right = rhs.collectionOrder ?? Int.max
                    return left == right
                        ? lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
                        : left < right
                }
            guard !members.isEmpty else { return nil }
            return .collection(BookCollectionDisplayItem(collection: collection, books: members))
        }
        let displayItems = (collectionItems + searchedBooks.filter { !$0.hiddenBook }.map(LibraryDisplayItem.book))
            .sorted { lhs, rhs in
                let left = lhs.representativeBook?.date ?? 0
                let right = rhs.representativeBook?.date ?? 0
                if left != right { return left > right }
                let leftTitle: String = switch lhs { case .book(let book): book.title; case .collection(let item): item.collection.name }
                let rightTitle: String = switch rhs { case .book(let book): book.title; case .collection(let item): item.collection.name }
                return leftTitle.localizedCaseInsensitiveCompare(rightTitle) == .orderedAscending
            }
        func matches(_ book: LibraryBook) -> Bool {
            switch filter {
            case .all: true
            case .marked: book.mark
            case .correct: book.status == .correct
            case .unscanned: book.status == .unscanned
            case .broken: book.status == .broken
            case .missing: book.status == .missing || !book.exist
            }
        }
        return Self(
            collectionCandidates: primaryBooks.filter { $0.collectionID == nil }.sorted(by: candidateSort),
            versionCandidates: books.filter { $0.versionGroupID == nil }.sorted(by: candidateSort),
            recommendedBooks: Array(primaryBooks.sorted { recommendationScore($0) < recommendationScore($1) }.prefix(10)),
            markedPreviewBooks: Array(primaryBooks.filter(\.mark).prefix(10)),
            favoriteManagementBooks: primaryBooks.filter(\.mark).sorted(by: favoriteSort),
            continueReadingBooks: Array(primaryBooks.filter { book in
                guard let id = book.databaseID, let state = readingStates[id] else { return false }
                return state.currentPageIndex > 0 && !state.isCompleted && !book.isUserHidden
            }.sorted { lhs, rhs in
                let left = lhs.databaseID.flatMap { readingStates[$0]?.updatedAt } ?? 0
                let right = rhs.databaseID.flatMap { readingStates[$0]?.updatedAt } ?? 0
                return left == right ? lhs.id < rhs.id : left > right
            }.prefix(10)),
            recentlyViewedBooks: Array(books.filter { !$0.hiddenBook && $0.lastReadAt != nil }.sorted { lhs, rhs in
                let left = lhs.lastReadAt ?? 0
                let right = rhs.lastReadAt ?? 0
                return left == right ? lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending : left > right
            }.prefix(10)),
            recentlyAddedBooks: Array(books.sorted { lhs, rhs in
                return lhs.createdAt == rhs.createdAt
                    ? lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
                    : lhs.createdAt > rhs.createdAt
            }.prefix(10)),
            searchedBooks: searchedBooks,
            displayItems: displayItems,
            filteredDisplayItems: displayItems.filter { item in
                switch item {
                case .book(let book): matches(book)
                case .collection(let collection): collection.books.contains(where: matches)
                }
            },
            filteredBooks: searchedBooks.filter { !$0.hiddenBook && matches($0) }
        )
    }
}
