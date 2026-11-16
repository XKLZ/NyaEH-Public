// 本文件定义书库筛选条件，是侧边栏分类和列表派生数据之间的轻量协议。

import Foundation

enum LibraryFilter: String, CaseIterable, Identifiable, Sendable {
    case all
    case marked
    case correct
    case unscanned
    case broken
    case missing

    var id: String { rawValue }

    static var childFilters: [LibraryFilter] {
        [.correct, .unscanned, .broken, .missing]
    }

    var titleKey: L10nKey {
        switch self {
        case .all:
            return .allBooks
        case .marked:
            return .marked
        case .correct:
            return .correct
        case .unscanned:
            return .unscanned
        case .broken:
            return .broken
        case .missing:
            return .missingFiles
        }
    }

    var systemImage: String {
        switch self {
        case .all:
            "books.vertical"
        case .marked:
            "star"
        case .correct:
            "checkmark.circle"
        case .unscanned:
            "questionmark.circle"
        case .broken:
            "xmark.octagon"
        case .missing:
            "exclamationmark.triangle"
        }
    }
}
