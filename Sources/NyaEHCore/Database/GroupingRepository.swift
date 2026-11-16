// 本文件定义 GroupingRepository 数据访问协议，隔离服务层和具体 SQLite 实现。

import Foundation

protocol CollectionRepository {
    func fetchAll() throws -> [BookCollection]
    func fetch(id: BookCollection.DatabaseID) throws -> BookCollection?
    func insert(_ collection: BookCollection) throws -> BookCollection
    func update(_ collection: BookCollection) throws -> BookCollection
    func delete(id: BookCollection.DatabaseID) throws
    func deleteAndDissolve(id: BookCollection.DatabaseID) throws
    func addBookAndVersions(bookID: LibraryBook.DatabaseID, to collectionID: BookCollection.DatabaseID) throws
    func removeBookAndVersions(bookID: LibraryBook.DatabaseID, from collectionID: BookCollection.DatabaseID) throws
}

protocol CollectionRecommendationMutationRepository {
    func acceptCreateCollectionRecommendation(
        recommendationID: CollectionRecommendation.DatabaseID,
        bookIDs: [LibraryBook.DatabaseID],
        orderedPrimaryBookIDs: [LibraryBook.DatabaseID],
        name: String
    ) throws -> BookCollection
    func acceptAddToCollectionRecommendation(
        recommendationID: CollectionRecommendation.DatabaseID,
        bookIDs: [LibraryBook.DatabaseID],
        orderedPrimaryBookIDs: [LibraryBook.DatabaseID],
        collectionID: BookCollection.DatabaseID,
        insertAtStart: Bool
    ) throws
}

protocol VersionGroupRepository {
    func fetchAll() throws -> [BookVersionGroup]
    func fetch(id: BookVersionGroup.DatabaseID) throws -> BookVersionGroup?
    func insert(_ group: BookVersionGroup) throws -> BookVersionGroup
    func delete(id: BookVersionGroup.DatabaseID) throws
}

protocol VersionGroupMutationRepository {
    func createVersionGroup(bookIDs: [LibraryBook.DatabaseID]) throws -> BookVersionGroup
    func acceptCreateVersionGroupRecommendation(
        recommendationID: VersionRecommendation.DatabaseID,
        bookIDs: [LibraryBook.DatabaseID],
        automaticLabels: [LibraryBook.DatabaseID: [String]]
    ) throws -> BookVersionGroup
    func acceptAddToVersionGroupRecommendation(
        recommendationID: VersionRecommendation.DatabaseID,
        bookID: LibraryBook.DatabaseID,
        groupID: BookVersionGroup.DatabaseID,
        automaticLabels: [String]
    ) throws
    func deleteVersionGroup(id: BookVersionGroup.DatabaseID) throws
    func addBook(bookID: LibraryBook.DatabaseID, to groupID: BookVersionGroup.DatabaseID, isPrimary: Bool) throws
    func addBooks(bookIDs: [LibraryBook.DatabaseID], to groupID: BookVersionGroup.DatabaseID) throws
    func removeBook(bookID: LibraryBook.DatabaseID) throws
    func setPrimary(bookID: LibraryBook.DatabaseID) throws
    func setLabels(_ labels: [String], bookID: LibraryBook.DatabaseID) throws
    func repairVersionGroupMarkedState() throws -> VersionGroupMarkedRepairResult
}

struct VersionGroupMarkedRepairResult: Equatable, Sendable {
    var checkedVersionGroups: Int
    var repairedVersionGroups: Int
    var updatedBooks: Int
}

protocol VersionLabelSuggestionRepository {
    func fetchAll() throws -> [VersionLabelSuggestion]
    @discardableResult
    func upsert(label: String) throws -> VersionLabelSuggestion?
}

protocol BookVersionLabelRepository {
    func fetchLabels(bookID: LibraryBook.DatabaseID) throws -> [String]
    func replaceLabels(_ labels: [String], bookID: LibraryBook.DatabaseID) throws
}
