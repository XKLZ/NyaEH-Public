// 本文件定义 LibraryGrouping 领域模型，是数据库、服务层和 SwiftUI 视图之间传递业务状态的结构。

import Foundation

struct BookCollection: Identifiable, Codable, Equatable, Sendable {
    typealias DatabaseID = Int64

    var databaseID: DatabaseID?
    var name: String
    var createdAt: Int64
    var updatedAt: Int64

    var id: String {
        databaseID.map(String.init) ?? name
    }

    init(
        databaseID: DatabaseID? = nil,
        name: String,
        createdAt: Int64 = Timestamp.nowMilliseconds(),
        updatedAt: Int64 = Timestamp.nowMilliseconds()
    ) {
        self.databaseID = databaseID
        self.name = name
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

struct BookVersionGroup: Identifiable, Codable, Equatable, Sendable {
    typealias DatabaseID = Int64

    var databaseID: DatabaseID?
    var createdAt: Int64
    var updatedAt: Int64

    var id: String {
        databaseID.map(String.init) ?? "\(createdAt)"
    }

    init(
        databaseID: DatabaseID? = nil,
        createdAt: Int64 = Timestamp.nowMilliseconds(),
        updatedAt: Int64 = Timestamp.nowMilliseconds()
    ) {
        self.databaseID = databaseID
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

struct VersionLabelSuggestion: Identifiable, Codable, Equatable, Sendable {
    typealias DatabaseID = Int64

    var databaseID: DatabaseID?
    var label: String
    var usageCount: Int
    var lastUsedAt: Int64
    var createdAt: Int64
    var updatedAt: Int64

    var id: String {
        databaseID.map(String.init) ?? label
    }

    init(
        databaseID: DatabaseID? = nil,
        label: String,
        usageCount: Int = 0,
        lastUsedAt: Int64 = Timestamp.nowMilliseconds(),
        createdAt: Int64 = Timestamp.nowMilliseconds(),
        updatedAt: Int64 = Timestamp.nowMilliseconds()
    ) {
        self.databaseID = databaseID
        self.label = label
        self.usageCount = usageCount
        self.lastUsedAt = lastUsedAt
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

struct BookVersionLabel: Identifiable, Codable, Equatable, Sendable {
    typealias DatabaseID = Int64

    var bookID: LibraryBook.DatabaseID
    var label: String
    var position: Int
    var createdAt: Int64
    var updatedAt: Int64

    var id: String {
        "\(bookID):\(position):\(label)"
    }

    init(
        bookID: LibraryBook.DatabaseID,
        label: String,
        position: Int,
        createdAt: Int64 = Timestamp.nowMilliseconds(),
        updatedAt: Int64 = Timestamp.nowMilliseconds()
    ) {
        self.bookID = bookID
        self.label = label
        self.position = position
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

enum VersionLabelPreset {
    static let original = "原始"
    static let translated = "翻译"
    static let fullColor = "彩色"
    static let uncensored = "无修"
    static let special = "特别"

    static let all = [original, translated, fullColor, uncensored, special]
}

enum VersionLabelFormatter {
    static let separator = " / "

    static func normalizedLabels(_ labels: [String]) -> [String] {
        var seen = Set<String>()
        return labels.compactMap { label in
            let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                return nil
            }
            let key = trimmed.lowercased()
            guard seen.insert(key).inserted else {
                return nil
            }
            return trimmed
        }
    }

    static func displayText(for labels: [String]) -> String? {
        let normalized = normalizedLabels(labels)
        return normalized.isEmpty ? nil : normalized.joined(separator: separator)
    }

    static func labels(from displayText: String?) -> [String] {
        guard let displayText else {
            return []
        }
        return normalizedLabels(displayText.components(separatedBy: separator))
    }
}

struct BookCollectionDisplayItem: Identifiable, Equatable, Sendable {
    var collection: BookCollection
    var books: [LibraryBook]

    var id: String { collection.id }

    var representativeBook: LibraryBook? {
        books.first
    }
}

enum LibraryDisplayItem: Identifiable, Equatable, Sendable {
    case book(LibraryBook)
    case collection(BookCollectionDisplayItem)

    var id: String {
        switch self {
        case .book(let book):
            return "book.\(book.id)"
        case .collection(let item):
            return "collection.\(item.id)"
        }
    }

    var representativeBook: LibraryBook? {
        switch self {
        case .book(let book):
            return book
        case .collection(let item):
            return item.representativeBook
        }
    }

    var books: [LibraryBook] {
        switch self {
        case .book(let book): [book]
        case .collection(let item): item.books
        }
    }
}
