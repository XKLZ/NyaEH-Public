// 本文件定义 LibraryBookRepository 数据访问协议，隔离服务层和具体 SQLite 实现。

import Foundation

protocol LibraryBookRepository {
    func fetchAll() throws -> [LibraryBook]
    func fetch(id: LibraryBook.DatabaseID) throws -> LibraryBook?
    func fetchByHash(_ hash: String) throws -> [LibraryBook]
    func fetchByFilepath(_ filepath: String) throws -> LibraryBook?
    func fetchByCollectionID(_ collectionID: BookCollection.DatabaseID) throws -> [LibraryBook]
    func fetchByVersionGroupID(_ versionGroupID: BookVersionGroup.DatabaseID) throws -> [LibraryBook]
    func insert(_ book: LibraryBook) throws -> LibraryBook
    func update(_ book: LibraryBook) throws -> LibraryBook
    func updateMetadata(_ book: LibraryBook) throws -> LibraryBook
    func updateFromScan(_ book: LibraryBook) throws -> LibraryBook
    func setMarked(_ marked: Bool, bookID: LibraryBook.DatabaseID) throws -> LibraryBook
    func setUserHidden(_ hidden: Bool, bookID: LibraryBook.DatabaseID) throws -> LibraryBook
    func replaceCollectionOrder(
        bookIDs: [LibraryBook.DatabaseID],
        collectionID: BookCollection.DatabaseID
    ) throws -> [LibraryBook]
    func delete(id: LibraryBook.DatabaseID) throws
    func incrementReadCount(bookID: LibraryBook.DatabaseID) throws -> LibraryBook?
    func updateStatus(bookID: LibraryBook.DatabaseID, status: BookStatus, exist: Bool) throws
    func markMissingExcept(filepaths: Set<String>) throws
    func applyScanChanges(
        inserts: [LibraryBook],
        updates: [LibraryBook],
        seenFilepaths: Set<String>
    ) throws -> LibraryScanCommitResult
}

struct LibraryScanCommitResult: Equatable, Sendable {
    var inserted: Int
    var updated: Int
    var newlyMissing: Int
}

extension LibraryBookRepository {
    func updateMetadata(_ book: LibraryBook) throws -> LibraryBook { try update(book) }
    func updateFromScan(_ book: LibraryBook) throws -> LibraryBook { try update(book) }

    func setMarked(_ marked: Bool, bookID: LibraryBook.DatabaseID) throws -> LibraryBook {
        guard var book = try fetch(id: bookID) else { throw LibraryDeletionError.bookUnavailable }
        let members = try book.versionGroupID.map { try fetchByVersionGroupID($0) } ?? [book]
        for var member in members {
            member.mark = marked
            let saved = try update(member)
            if saved.databaseID == bookID { book = saved }
        }
        return book
    }

    func setUserHidden(_ hidden: Bool, bookID: LibraryBook.DatabaseID) throws -> LibraryBook {
        guard var book = try fetch(id: bookID) else { throw LibraryDeletionError.bookUnavailable }
        book.isUserHidden = hidden
        return try update(book)
    }

    func applyScanChanges(
        inserts: [LibraryBook],
        updates: [LibraryBook],
        seenFilepaths: Set<String>
    ) throws -> LibraryScanCommitResult {
        let missingBefore = try fetchAll().filter { !$0.exist || $0.status == .missing }.count
        for book in inserts { _ = try insert(book) }
        for book in updates { _ = try updateFromScan(book) }
        try markMissingExcept(filepaths: seenFilepaths)
        let missingAfter = try fetchAll().filter { !$0.exist || $0.status == .missing }.count
        return .init(inserted: inserts.count, updated: updates.count, newlyMissing: max(0, missingAfter - missingBefore))
    }
}
