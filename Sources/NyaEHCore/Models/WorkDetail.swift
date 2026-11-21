// 本文件定义 WorkDetail 领域模型，是数据库、服务层和 SwiftUI 视图之间传递业务状态的结构。

import Foundation

struct WorkDetail: Equatable, Sendable {
    var work: TagDisplaySummary
    var hasCharacterIndexRelations: Bool
    private var primaryVersions: [BookVersionGroup.DatabaseID: LibraryBook]
    private var overview: Overview

    var sections: [WorkCharacterBookSection] {
        get { overview.sections }
        set { overview = Overview(sections: newValue, primaryVersions: primaryVersions) }
    }

    init(work: TagDisplaySummary, sections: [WorkCharacterBookSection], hasCharacterIndexRelations: Bool = true,
         primaryVersions: [BookVersionGroup.DatabaseID: LibraryBook] = [:]) {
        self.work = work
        self.hasCharacterIndexRelations = hasCharacterIndexRelations
        self.primaryVersions = primaryVersions
        overview = Overview(sections: sections, primaryVersions: primaryVersions)
    }

    var totalBookCount: Int { overview.totalBookCount }
    var characterCount: Int { overview.characters.count }
    var characters: [TagDisplaySummary] { overview.characters }
    var unclassifiedBooks: [LibraryBook] { overview.unclassifiedIndex.map { overview.sections[$0].books } ?? [] }

    func section(for characterID: Tag.DatabaseID) -> WorkCharacterBookSection? {
        overview.characterIndices[characterID].map { overview.sections[$0] }
    }

    /// Reproject only topics containing a changed edition or one of its version groups.
    mutating func updateVersions(_ changes: [LibraryBook.ID: LibraryBook]) -> Bool {
        guard changes.values.contains(where: { book in
            overview.bookIDs.contains(book.id) || book.versionGroupID.map(overview.groupIDs.contains) == true
        }) else { return false }

        var updatedSections = sections
        for i in updatedSections.indices {
            for j in updatedSections[i].books.indices {
                if let updated = changes[updatedSections[i].books[j].id] {
                    updatedSections[i].books[j] = updated
                }
            }
        }
        let groups = Set(updatedSections.flatMap { $0.books.compactMap(\.versionGroupID) })
        primaryVersions = primaryVersions.filter { groups.contains($0.key) && changes[$0.value.id] == nil }
        for book in changes.values where book.isPrimaryVersion {
            if let group = book.versionGroupID, groups.contains(group) { primaryVersions[group] = book }
        }
        sections = updatedSections
        return true
    }

    private struct Overview: Equatable, Sendable {
        var sections: [WorkCharacterBookSection]
        let totalBookCount: Int
        var bookIDs: Set<LibraryBook.ID>
        var groupIDs: Set<BookVersionGroup.DatabaseID> = []
        var characters: [TagDisplaySummary] = []
        var characterIndices: [Tag.DatabaseID: Int] = [:]
        var unclassifiedIndex: Int?

        init(sections: [WorkCharacterBookSection], primaryVersions: [BookVersionGroup.DatabaseID: LibraryBook]) {
            self.sections = sections
            bookIDs = Set(primaryVersions.values.map(\.id))
            var primaries = primaryVersions
            for section in sections {
                for book in section.books {
                    bookIDs.insert(book.id)
                    if let group = book.versionGroupID {
                        groupIDs.insert(group)
                        if book.isPrimaryVersion { primaries[group] = book }
                    }
                }
            }
            var logicalIDs: Set<WorkTopicBookSlot.ID> = []
            for (i, section) in sections.enumerated() {
                if let character = section.character {
                    let slots = WorkTopicBookSlot.fold(section.books, claims: section.claimsByBookID, primaries: primaries)
                    self.sections[i].slots = slots
                    guard !slots.isEmpty else { continue }
                    characters.append(character)
                    characterIndices[character.id] = i
                    logicalIDs.formUnion(slots.lazy.map(\.id))
                } else {
                    unclassifiedIndex = i
                    logicalIDs.formUnion(section.books.lazy.map(WorkTopicBookSlot.ID.init))
                }
            }
            totalBookCount = logicalIDs.count
        }
    }
}

struct WorkTopicBookSlot: Identifiable, Equatable, Sendable {
    enum ID: Hashable, Sendable {
        case versionGroup(BookVersionGroup.DatabaseID)
        case book(LibraryBook.ID)

        init(_ book: LibraryBook) {
            self = book.versionGroupID.map(Self.versionGroup) ?? .book(book.id)
        }
    }

    let id: ID
    let book: LibraryBook
    let claim: WorkCharacterClaim?

    fileprivate static func fold(_ books: [LibraryBook], claims: [LibraryBook.DatabaseID: WorkCharacterClaim],
                                primaries: [BookVersionGroup.DatabaseID: LibraryBook]) -> [Self] {
        let matches = Dictionary(grouping: books, by: ID.init)
        var seen: Set<ID> = []
        var slots: [Self] = []
        for book in books {
            let id = ID(book)
            guard seen.insert(id).inserted, let editions = matches[id] else { continue }
            let primary = book.versionGroupID.flatMap { primaries[$0] }
            guard let representative = primary.flatMap({ $0.isUserHidden ? nil : $0 })
                    ?? editions.first(where: { !$0.isUserHidden }) else { continue }
            let evidence = editions.compactMap { edition in edition.databaseID.flatMap { claims[$0] } }
            slots.append(Self(id: id, book: representative, claim: evidence.first { $0.source != .automatic } ?? evidence.first))
        }
        return slots
    }
}

struct WorkCharacterBookSection: Identifiable, Equatable, Sendable {
    var character: TagDisplaySummary?
    // Original, individually classified editions. These remain the source for claims and the unclassified list.
    var books: [LibraryBook]
    var claimsByBookID: [LibraryBook.DatabaseID: WorkCharacterClaim] = [:]
    fileprivate(set) var slots: [WorkTopicBookSlot] = []

    var id: String {
        character.map { "character.\($0.id)" } ?? "character.untagged"
    }

    var bookCount: Int { character == nil ? books.count : slots.count }
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
