// 本文件定义 WorkCharacterIndex 领域模型，是数据库、服务层和 SwiftUI 视图之间传递业务状态的结构。

import Foundation

struct WorkCharacterIndexUpdateResult: Equatable, Sendable {
    var processedBooks: Int
    var linkCount: Int
    var didChange: Bool

    static let noChanges = WorkCharacterIndexUpdateResult(
        processedBooks: 0,
        linkCount: 0,
        didChange: false
    )
}

struct WorkCharacterWorkSummary: Identifiable, Equatable, Sendable {
    var tag: TagDisplaySummary
    var characterCount: Int
    var bookCount: Int

    var id: Tag.DatabaseID {
        tag.id
    }
}

struct WorkCharacterCharacterSummary: Identifiable, Equatable, Sendable {
    var tag: TagDisplaySummary
    var bookCount: Int

    var id: Tag.DatabaseID {
        tag.id
    }
}
