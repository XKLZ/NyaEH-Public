// 本文件定义每本书阅读进度的持久化边界。

import Foundation

protocol BookReadingStateRepository {
    func fetch(bookID: LibraryBook.DatabaseID) throws -> BookReadingState?
    func fetchAll() throws -> [BookReadingState]
    func save(_ state: BookReadingState) throws -> BookReadingState
    func reset(bookID: LibraryBook.DatabaseID) throws
}
