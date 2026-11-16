// 本文件定义跨领域 Store 的最小增量变更信号，避免用全量 refresh 维持一致性。

import Foundation
import Observation

enum LibraryChange: Equatable, Sendable {
    case booksUpserted([LibraryBook])
    case booksDeleted(Set<LibraryBook.DatabaseID>)
    case readingStateChanged(bookID: LibraryBook.DatabaseID, state: BookReadingState?)
    case collectionsChanged(Set<BookCollection.DatabaseID>)
    case versionGroupsChanged(Set<BookVersionGroup.DatabaseID>)
    case tagsChanged(Set<LibraryBook.DatabaseID>)
    case fullReload(reason: String)
}

@MainActor
@Observable
final class LibraryChangeBus {
    private(set) var revision = 0
    private(set) var lastChange: LibraryChange?

    func publish(_ change: LibraryChange) {
        lastChange = change
        revision &+= 1
    }
}
