// 本文件定义 HomeInsightChart 领域模型，是数据库、服务层和 SwiftUI 视图之间传递业务状态的结构。

import Foundation

enum HomeInsightChartKind: String, CaseIterable, Identifiable, Sendable {
    case works
    case characters
    case authors
    case groups
    case tags
    case languages

    var id: String { rawValue }

    var namespaces: [String] {
        switch self {
        case .works:
            return ["parody"]
        case .characters:
            return ["character"]
        case .authors:
            return ["artist"]
        case .groups:
            return ["group"]
        case .tags:
            return ["female", "male", "mixed", "location", "other"]
        case .languages:
            return ["language"]
        }
    }

    var titleKey: L10nKey {
        switch self {
        case .works:
            return .homeInsightWorks
        case .characters:
            return .homeInsightCharacters
        case .authors:
            return .homeInsightAuthors
        case .groups:
            return .homeInsightGroups
        case .tags:
            return .homeInsightTags
        case .languages:
            return .homeInsightLanguages
        }
    }

    var systemImage: String {
        switch self {
        case .works:
            return "sparkles.rectangle.stack"
        case .characters:
            return "person.crop.square"
        case .authors:
            return "person.2"
        case .groups:
            return "person.3"
        case .tags:
            return "tag"
        case .languages:
            return "character.book.closed"
        }
    }
}

struct HomeInsightCharts: Equatable, Sendable {
    var works: [TagDisplaySummary] = []
    var characters: [TagDisplaySummary] = []
    var authors: [TagDisplaySummary] = []
    var groups: [TagDisplaySummary] = []
    var tags: [TagDisplaySummary] = []
    var languages: [TagDisplaySummary] = []

    static let empty = HomeInsightCharts()

    subscript(kind: HomeInsightChartKind) -> [TagDisplaySummary] {
        get {
            switch kind {
            case .works:
                return works
            case .characters:
                return characters
            case .authors:
                return authors
            case .groups:
                return groups
            case .tags:
                return tags
            case .languages:
                return languages
            }
        }
        set {
            switch kind {
            case .works:
                works = newValue
            case .characters:
                characters = newValue
            case .authors:
                authors = newValue
            case .groups:
                groups = newValue
            case .tags:
                tags = newValue
            case .languages:
                languages = newValue
            }
        }
    }
}

enum HomeInsightChartScale {
    static func sqrtFraction(count: Int, maxCount: Int) -> Double {
        guard count > 0, maxCount > 0 else {
            return 0
        }
        let linear = min(max(Double(count) / Double(maxCount), 0), 1)
        return sqrt(linear)
    }
}
