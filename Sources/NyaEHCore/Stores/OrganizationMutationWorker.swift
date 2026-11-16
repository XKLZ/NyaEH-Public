// Organization writes run on this actor's executor. UI state stays on CatalogStore's MainActor.

import Foundation

enum OrganizationMutation: Sendable {
    case createCollection(String)
    case renameCollection(BookCollection, String)
    case deleteCollection(BookCollection)
    case addToCollection([LibraryBook], BookCollection)
    case removeFromCollection(LibraryBook, BookCollection)
    case removeFromCollectionBatch([LibraryBook], BookCollection)
    case reorderCollection([LibraryBook], BookCollection)
    case acceptCreateCollection(CollectionRecommendationDisplayItem, String)
    case acceptAddToCollection(CollectionRecommendationDisplayItem, LibraryBook, BookCollection)
    case dismissCollection(CollectionRecommendationDisplayItem)
    case createVersionGroup([LibraryBook])
    case addToVersionGroup([LibraryBook], BookVersionGroup)
    case removeFromVersionGroup(LibraryBook)
    case deleteVersionGroup(BookVersionGroup)
    case setPrimaryVersion(LibraryBook)
    case setVersionLabels([String], LibraryBook)
    case acceptCreateVersionGroup(VersionRecommendationDisplayItem)
    case acceptAddToVersionGroup(VersionRecommendationDisplayItem, LibraryBook, BookVersionGroup)
    case dismissVersion(VersionRecommendationDisplayItem)

    var bookIDs: Set<LibraryBook.DatabaseID> {
        let books: [LibraryBook]
        switch self {
        case .addToCollection(let members, _), .removeFromCollectionBatch(let members, _),
             .reorderCollection(let members, _),
             .createVersionGroup(let members), .addToVersionGroup(let members, _):
            books = members
        case .removeFromCollection(let book, _), .removeFromVersionGroup(let book),
             .setPrimaryVersion(let book), .setVersionLabels(_, let book):
            books = [book]
        case .acceptCreateCollection(let item, _): books = item.books
        case .acceptAddToCollection(let item, let book, _): books = item.books + [book]
        case .acceptCreateVersionGroup(let item): books = item.books
        case .acceptAddToVersionGroup(let item, let book, _): books = item.books + [book]
        default: books = []
        }
        return Set(books.compactMap(\.databaseID))
    }

    var collectionIDs: Set<BookCollection.DatabaseID> {
        switch self {
        case .renameCollection(let collection, _), .deleteCollection(let collection),
             .addToCollection(_, let collection), .removeFromCollection(_, let collection),
             .removeFromCollectionBatch(_, let collection),
             .reorderCollection(_, let collection), .acceptAddToCollection(_, _, let collection):
            return Set([collection.databaseID].compactMap { $0 })
        default: return []
        }
    }

    var versionGroupIDs: Set<BookVersionGroup.DatabaseID> {
        switch self {
        case .addToVersionGroup(_, let group), .deleteVersionGroup(let group),
             .acceptAddToVersionGroup(_, _, let group):
            return Set([group.databaseID].compactMap { $0 })
        default: return []
        }
    }

    var expandsCollectionMembers: Bool {
        switch self {
        case .deleteCollection, .reorderCollection, .acceptAddToCollection:
            return true
        default:
            return false
        }
    }

    var expandsVersionMembers: Bool {
        switch self {
        case .addToCollection, .removeFromCollection, .removeFromCollectionBatch, .acceptCreateCollection,
             .acceptAddToCollection, .createVersionGroup, .addToVersionGroup,
             .removeFromVersionGroup, .deleteVersionGroup, .setPrimaryVersion,
             .acceptCreateVersionGroup, .acceptAddToVersionGroup:
            return true
        default:
            return false
        }
    }

    var changesCollectionList: Bool {
        switch self {
        case .createCollection, .renameCollection, .deleteCollection, .acceptCreateCollection:
            return true
        default:
            return false
        }
    }

    var changesVersionGroupList: Bool {
        switch self {
        case .createVersionGroup, .addToVersionGroup, .removeFromVersionGroup,
             .deleteVersionGroup, .acceptCreateVersionGroup, .acceptAddToVersionGroup:
            return true
        default:
            return false
        }
    }
}

struct OrganizationMutationResult: Sendable {
    var books: [LibraryBook]
    var affectedBookIDs: Set<LibraryBook.DatabaseID>
    var affectedCollectionIDs: Set<BookCollection.DatabaseID>
    var affectedVersionGroupIDs: Set<BookVersionGroup.DatabaseID>
    var collections: [BookCollection]?
    var versionGroups: [BookVersionGroup]?
    var labelSuggestions: [VersionLabelSuggestion]
    var createCollectionRecommendations: [CollectionRecommendationDisplayItem]
    var addToCollectionRecommendationCounts: [BookCollection.DatabaseID: Int]
    var selectedCollectionRecommendations: [CollectionRecommendationDisplayItem]
    var selectedCollectionID: BookCollection.DatabaseID?
    var createVersionRecommendations: [VersionRecommendationDisplayItem]
    var addToVersionRecommendationCounts: [BookVersionGroup.DatabaseID: Int]
    var selectedVersionRecommendations: [VersionRecommendationDisplayItem]
    var selectedVersionGroupID: BookVersionGroup.DatabaseID?
    var createdCollectionID: BookCollection.DatabaseID?
    var createdVersionGroupID: BookVersionGroup.DatabaseID?
    var failures: [String]
}

actor OrganizationMutationWorker {
    // BookLibraryService is already @unchecked Sendable. This actor serializes organization writes;
    // production repositories share GRDB's synchronized DatabasePool. Replace that escape hatch
    // when all repository protocols can express checked Sendable ownership.
    private let service: BookLibraryService
    private let beforeExecute: @Sendable () async -> Void

    init(service: BookLibraryService, beforeExecute: @escaping @Sendable () async -> Void = {}) {
        self.service = service
        self.beforeExecute = beforeExecute
    }

    func execute(
        _ mutation: OrganizationMutation,
        selectedCollectionID: BookCollection.DatabaseID?,
        selectedVersionGroupID: BookVersionGroup.DatabaseID?
    ) async throws -> OrganizationMutationResult {
        await beforeExecute()
        var affectedBookIDs = mutation.bookIDs
        var affectedCollectionIDs = mutation.collectionIDs
        var affectedVersionGroupIDs = mutation.versionGroupIDs
        try expandAffectedBooks(
            bookIDs: &affectedBookIDs,
            collectionIDs: &affectedCollectionIDs,
            versionGroupIDs: &affectedVersionGroupIDs,
            includeCollectionMembers: mutation.expandsCollectionMembers,
            includeVersionMembers: mutation.expandsVersionMembers
        )

        var createdCollectionID: BookCollection.DatabaseID?
        var createdVersionGroupID: BookVersionGroup.DatabaseID?
        var failures: [String] = []
        switch mutation {
        case .createCollection(let name):
            createdCollectionID = try service.createCollection(name: name).databaseID
        case .renameCollection(let collection, let name):
            _ = try service.renameCollection(collection, name: name)
        case .deleteCollection(let collection):
            try service.deleteCollection(collection)
        case .addToCollection(let books, let collection):
            for book in books {
                do { try service.addBook(book, to: collection) }
                catch { failures.append("\(book.title): \(error.localizedDescription)") }
            }
        case .removeFromCollection(let book, let collection):
            try service.removeBook(book, from: collection)
        case .removeFromCollectionBatch(let books, let collection):
            for book in books {
                do { try service.removeBook(book, from: collection) }
                catch { failures.append("\(book.title): \(error.localizedDescription)") }
            }
        case .reorderCollection(let books, let collection):
            _ = try service.reorderBooks(books, in: collection)
        case .acceptCreateCollection(let item, let fallbackName):
            createdCollectionID = try service.acceptCreateCollectionRecommendation(
                item.recommendation,
                books: item.books,
                fallbackName: fallbackName
            ).databaseID
        case .acceptAddToCollection(let item, let book, let collection):
            try service.acceptAddToCollectionRecommendation(item.recommendation, book: book, collection: collection)
        case .dismissCollection(let item):
            try service.dismissCollectionRecommendation(item.recommendation)
        case .createVersionGroup(let books):
            createdVersionGroupID = try service.createVersionGroup(with: books).databaseID
        case .addToVersionGroup(let books, let group):
            try service.addBooks(books, toVersionGroup: group)
        case .removeFromVersionGroup(let book):
            try service.removeBookFromVersionGroup(book)
        case .deleteVersionGroup(let group):
            try service.deleteVersionGroup(group)
        case .setPrimaryVersion(let book):
            try service.setPrimaryVersion(book)
        case .setVersionLabels(let labels, let book):
            try service.setVersionLabels(labels, for: book)
        case .acceptCreateVersionGroup(let item):
            createdVersionGroupID = try service.acceptCreateVersionGroupRecommendation(
                item.recommendation,
                books: item.books
            ).databaseID
        case .acceptAddToVersionGroup(let item, let book, let group):
            try service.acceptAddToVersionGroupRecommendation(item.recommendation, book: book, group: group)
        case .dismissVersion(let item):
            try service.dismissVersionRecommendation(item.recommendation)
        }

        return try makeSnapshot(
            mutation,
            affectedBookIDs: affectedBookIDs,
            affectedCollectionIDs: affectedCollectionIDs,
            affectedVersionGroupIDs: affectedVersionGroupIDs,
            selectedCollectionID: selectedCollectionID,
            selectedVersionGroupID: selectedVersionGroupID,
            createdCollectionID: createdCollectionID,
            createdVersionGroupID: createdVersionGroupID,
            failures: failures
        )
    }

    func snapshot(
        for mutation: OrganizationMutation,
        selectedCollectionID: BookCollection.DatabaseID?,
        selectedVersionGroupID: BookVersionGroup.DatabaseID?
    ) throws -> OrganizationMutationResult {
        try makeSnapshot(
            mutation,
            affectedBookIDs: mutation.bookIDs,
            affectedCollectionIDs: mutation.collectionIDs,
            affectedVersionGroupIDs: mutation.versionGroupIDs,
            selectedCollectionID: selectedCollectionID,
            selectedVersionGroupID: selectedVersionGroupID,
            createdCollectionID: nil,
            createdVersionGroupID: nil,
            failures: []
        )
    }

    private func makeSnapshot(
        _ mutation: OrganizationMutation,
        affectedBookIDs initialBookIDs: Set<LibraryBook.DatabaseID>,
        affectedCollectionIDs initialCollectionIDs: Set<BookCollection.DatabaseID>,
        affectedVersionGroupIDs initialVersionGroupIDs: Set<BookVersionGroup.DatabaseID>,
        selectedCollectionID: BookCollection.DatabaseID?,
        selectedVersionGroupID: BookVersionGroup.DatabaseID?,
        createdCollectionID: BookCollection.DatabaseID?,
        createdVersionGroupID: BookVersionGroup.DatabaseID?,
        failures: [String]
    ) throws -> OrganizationMutationResult {
        var affectedBookIDs = initialBookIDs
        var affectedCollectionIDs = initialCollectionIDs
        var affectedVersionGroupIDs = initialVersionGroupIDs
        if let createdCollectionID { affectedCollectionIDs.insert(createdCollectionID) }
        if let createdVersionGroupID { affectedVersionGroupIDs.insert(createdVersionGroupID) }
        try expandAffectedBooks(
            bookIDs: &affectedBookIDs,
            collectionIDs: &affectedCollectionIDs,
            versionGroupIDs: &affectedVersionGroupIDs,
            includeCollectionMembers: mutation.expandsCollectionMembers,
            includeVersionMembers: mutation.expandsVersionMembers
        )
        let updatedBooks = try affectedBookIDs.sorted().compactMap { try service.loadBook(id: $0) }
        let currentCollections = mutation.changesCollectionList ? try service.loadCollections() : nil
        let currentVersionGroups = mutation.changesVersionGroupList ? try service.loadVersionGroups() : nil
        return try OrganizationMutationResult(
            books: updatedBooks,
            affectedBookIDs: affectedBookIDs,
            affectedCollectionIDs: affectedCollectionIDs,
            affectedVersionGroupIDs: affectedVersionGroupIDs,
            collections: currentCollections,
            versionGroups: currentVersionGroups,
            labelSuggestions: service.loadVersionLabelSuggestions(),
            createCollectionRecommendations: service.loadCreateCollectionRecommendations(),
            addToCollectionRecommendationCounts: service.loadAddToCollectionRecommendationCounts(),
            selectedCollectionRecommendations: selectedCollectionID.map { try service.loadAddToCollectionRecommendations(collectionID: $0) } ?? [],
            selectedCollectionID: selectedCollectionID,
            createVersionRecommendations: service.loadCreateVersionGroupRecommendations(),
            addToVersionRecommendationCounts: service.loadAddToVersionGroupRecommendationCounts(),
            selectedVersionRecommendations: selectedVersionGroupID.map { try service.loadAddToVersionGroupRecommendations(groupID: $0) } ?? [],
            selectedVersionGroupID: selectedVersionGroupID,
            createdCollectionID: createdCollectionID,
            createdVersionGroupID: createdVersionGroupID,
            failures: failures
        )
    }

    private func expandAffectedBooks(
        bookIDs: inout Set<LibraryBook.DatabaseID>,
        collectionIDs: inout Set<BookCollection.DatabaseID>,
        versionGroupIDs: inout Set<BookVersionGroup.DatabaseID>,
        includeCollectionMembers: Bool,
        includeVersionMembers: Bool
    ) throws {
        for bookID in bookIDs {
            guard let book = try service.loadBook(id: bookID) else { continue }
            if let collectionID = book.collectionID { collectionIDs.insert(collectionID) }
            if let versionGroupID = book.versionGroupID { versionGroupIDs.insert(versionGroupID) }
        }
        if includeCollectionMembers {
            for collectionID in collectionIDs {
                bookIDs.formUnion(try service.loadBooks(collectionID: collectionID).compactMap(\.databaseID))
            }
        }
        if includeVersionMembers {
            for versionGroupID in versionGroupIDs {
                bookIDs.formUnion(try service.loadBooks(versionGroupID: versionGroupID).compactMap(\.databaseID))
            }
        }
    }
}
