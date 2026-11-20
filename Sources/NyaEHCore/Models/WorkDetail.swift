// 本文件定义 WorkDetail 领域模型，是数据库、服务层和 SwiftUI 视图之间传递业务状态的结构。

import Foundation

struct WorkDetail: Equatable, Sendable {
    var work: TagDisplaySummary
    var sections: [WorkCharacterBookSection] {
        didSet { overview = Overview(sections: sections) }
    }
    var hasCharacterIndexRelations: Bool
    private var overview: Overview

    init(work: TagDisplaySummary, sections: [WorkCharacterBookSection], hasCharacterIndexRelations: Bool = true) {
        self.work = work
        self.sections = sections
        self.hasCharacterIndexRelations = hasCharacterIndexRelations
        overview = Overview(sections: sections)
    }

    var totalBookCount: Int { overview.totalBookCount }
    var characterCount: Int { overview.characters.count }
    var characters: [TagDisplaySummary] { overview.characters }
    var unclassifiedBooks: [LibraryBook] { overview.unclassifiedIndex.map { sections[$0].books } ?? [] }

    func section(for characterID: Tag.DatabaseID) -> WorkCharacterBookSection? {
        overview.characterIndices[characterID].map { sections[$0] }
    }

    private struct Overview: Equatable, Sendable {
        let totalBookCount: Int
        var characters: [TagDisplaySummary] = []
        var characterIndices: [Tag.DatabaseID: Int] = [:]
        var unclassifiedIndex: Int?

        init(sections: [WorkCharacterBookSection]) {
            var bookIDs: Set<LibraryBook.ID> = []
            for (i, section) in sections.enumerated() {
                bookIDs.formUnion(section.books.lazy.map(\.id))
                if let character = section.character {
                    characters.append(character)
                    characterIndices[character.id] = i
                } else {
                    unclassifiedIndex = i
                }
            }
            totalBookCount = bookIDs.count
        }
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
