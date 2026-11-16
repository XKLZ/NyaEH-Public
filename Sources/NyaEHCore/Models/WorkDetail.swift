// 本文件定义 WorkDetail 领域模型，是数据库、服务层和 SwiftUI 视图之间传递业务状态的结构。

import Foundation

struct WorkDetail: Equatable, Sendable {
    var work: TagDisplaySummary
    var sections: [WorkCharacterBookSection]
    var hasCharacterIndexRelations: Bool = true

    var totalBookCount: Int {
        Set(sections.flatMap { section in
            section.books.map(\.id)
        }).count
    }

    var characterCount: Int {
        sections.filter { $0.character != nil }.count
    }
}

struct WorkCharacterBookSection: Identifiable, Equatable, Sendable {
    var character: TagDisplaySummary?
    var books: [LibraryBook]
    var claimsByBookID: [LibraryBook.DatabaseID: WorkCharacterClaim] = [:]

    var id: String {
        character.map { "character.\($0.id)" } ?? "character.untagged"
    }

    var bookCount: Int {
        books.count
    }
}

struct CharacterDetail: Equatable, Sendable {
    var character: TagDisplaySummary
    var sections: [CharacterWorkBookSection]

    var totalBookCount: Int {
        Set(sections.flatMap { section in
            section.books.map(\.id)
        }).count
    }

    var workCount: Int {
        sections.filter { $0.work != nil }.count
    }

    var backgroundTag: TagDisplaySummary? {
        if let path = character.visualProfile?.backgroundAssetPath, !path.isEmpty {
            return character
        }
        return sections.compactMap(\.work).first {
            TagOpenDestinationResolver.destination(for: $0) == .workDetail
                && !($0.visualProfile?.backgroundAssetPath ?? "").isEmpty
        }
    }
}

struct CharacterWorkBookSection: Identifiable, Equatable, Sendable {
    var work: TagDisplaySummary?
    var books: [LibraryBook]
    var claimsByBookID: [LibraryBook.DatabaseID: WorkCharacterClaim] = [:]

    var id: String {
        work.map { "work.\($0.id)" } ?? "work.untagged"
    }

    var bookCount: Int {
        books.count
    }
}
