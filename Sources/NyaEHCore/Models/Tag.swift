// 本文件定义 Tag 领域模型，是数据库、服务层和 SwiftUI 视图之间传递业务状态的结构。

import Foundation

struct Tag: Identifiable, Equatable, Sendable {
    typealias DatabaseID = Int64

    var id: DatabaseID?
    var namespace: String
    var name: String
    var rawValue: String
    var createdAt: Int64
    var updatedAt: Int64

    init(
        id: DatabaseID? = nil,
        namespace: String,
        name: String,
        rawValue: String,
        createdAt: Int64 = Timestamp.nowMilliseconds(),
        updatedAt: Int64 = Timestamp.nowMilliseconds()
    ) {
        self.id = id
        self.namespace = namespace
        self.name = name
        self.rawValue = rawValue
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

struct TagSummary: Equatable, Sendable {
    var id: Tag.DatabaseID
    var namespace: String
    var name: String
    var rawValue: String
    var translatedName: String?
    var translationIntro: String?
    var translationLinks: [String]
    var isFollowed: Bool
    var count: Int

    init(
        id: Tag.DatabaseID,
        namespace: String,
        name: String,
        rawValue: String,
        translatedName: String? = nil,
        translationIntro: String? = nil,
        translationLinks: [String] = [],
        isFollowed: Bool = false,
        count: Int
    ) {
        self.id = id
        self.namespace = namespace
        self.name = name
        self.rawValue = rawValue
        self.translatedName = translatedName
        self.translationIntro = translationIntro
        self.translationLinks = translationLinks
        self.isFollowed = isFollowed
        self.count = count
    }
}

struct TagDisplaySummary: Identifiable, Equatable, Sendable {
    var id: Tag.DatabaseID
    var namespace: String
    var name: String
    var rawValue: String
    var displayName: String
    var displayText: String
    var displayImageURL: URL?
    var displayImageAltText: String?
    var translationIntro: String? = nil
    var translationLinks: [String] = []
    var isFollowed: Bool
    var count: Int
    var visualProfile: TagVisualProfile?

    init(
        id: Tag.DatabaseID,
        namespace: String,
        name: String,
        rawValue: String,
        displayName: String,
        translationIntro: String? = nil,
        translationLinks: [String] = [],
        isFollowed: Bool = false,
        count: Int,
        visualProfile: TagVisualProfile? = nil
    ) {
        let parsedDisplayName = TagDisplayName(markdown: displayName)
        self.id = id
        self.namespace = namespace
        self.name = name
        self.rawValue = rawValue
        self.displayName = displayName
        self.displayText = parsedDisplayName.text
        self.displayImageURL = parsedDisplayName.imageURL
        self.displayImageAltText = parsedDisplayName.imageAltText
        self.translationIntro = translationIntro
        self.translationLinks = translationLinks
        self.isFollowed = isFollowed
        self.count = count
        self.visualProfile = visualProfile
    }
}

enum TagHoverExplanationDelay {
    static let defaultMilliseconds = 600

    static func shouldShow(
        elapsedMilliseconds: Int,
        delayMilliseconds: Int = defaultMilliseconds,
        isHovering: Bool,
        hasIntro: Bool
    ) -> Bool {
        isHovering && hasIntro && elapsedMilliseconds >= max(delayMilliseconds, 0)
    }
}

struct BookDetailTagGroups: Equatable, Sendable {
    var creatorGroups: [BookDetailTagGroup]
    var workGroups: [BookDetailTagGroup]
    var otherGroups: [BookDetailTagGroup]

    var creatorTags: [TagDisplaySummary] {
        creatorGroups.flatMap(\.tags)
    }

    var workTags: [TagDisplaySummary] {
        workGroups.flatMap(\.tags)
    }

    var otherTags: [TagDisplaySummary] {
        otherGroups.flatMap(\.tags)
    }
}

struct BookDetailTagGroup: Identifiable, Equatable, Sendable {
    var namespace: String
    var tags: [TagDisplaySummary]

    var id: String { namespace }
}

enum BookDetailTagOrganizer {
    static let creatorNamespaces: Set<String> = ["artist", "group"]
    static let workNamespaces: Set<String> = ["parody", "character"]
    static let hiddenNamespaces: Set<String> = ["language"]
    static let hiddenRawValues: Set<String> = [
        "language:translated",
        "other:full color",
        "other:uncensored",
        "other:full censored",
        "other:mosaic censorship",
        "other:extraneous ads"
    ]

    static func groups(from tags: [TagDisplaySummary]) -> BookDetailTagGroups {
        var creatorTags: [String: [TagDisplaySummary]] = [:]
        var workTags: [String: [TagDisplaySummary]] = [:]
        var otherTags: [String: [TagDisplaySummary]] = [:]

        for tag in tags {
            let namespace = tag.namespace.lowercased()
            let rawValue = tag.rawValue.lowercased()

            if creatorNamespaces.contains(namespace) {
                creatorTags[namespace, default: []].append(tag)
            } else if workNamespaces.contains(namespace) {
                workTags[namespace, default: []].append(tag)
            } else if hiddenNamespaces.contains(namespace) || hiddenRawValues.contains(rawValue) {
                continue
            } else {
                otherTags[namespace, default: []].append(tag)
            }
        }

        return BookDetailTagGroups(
            creatorGroups: groupedTags(creatorTags, preferredOrder: ["artist", "group"]),
            workGroups: groupedTags(workTags, preferredOrder: ["parody", "character"]),
            otherGroups: groupedTags(
                otherTags,
                preferredOrder: ["female", "male", "mixed", "group", "location", "other"]
            )
        )
    }

    static func allGroups(from tags: [TagDisplaySummary]) -> [BookDetailTagGroup] {
        groupedTags(
            Dictionary(grouping: tags, by: { $0.namespace.lowercased() }),
            preferredOrder: ["artist", "group", "parody", "character", "female", "male", "mixed",
                             "language", "cosplayer", "location", "reclass", "other"]
        )
    }

    private static func groupedTags(
        _ tagsByNamespace: [String: [TagDisplaySummary]],
        preferredOrder: [String]
    ) -> [BookDetailTagGroup] {
        let orderedNamespaces = preferredOrder.filter { tagsByNamespace[$0]?.isEmpty == false }
            + tagsByNamespace.keys
            .filter { !preferredOrder.contains($0) }
            .sorted()

        return orderedNamespaces.compactMap { namespace in
            guard let tags = tagsByNamespace[namespace], !tags.isEmpty else {
                return nil
            }
            return BookDetailTagGroup(namespace: namespace, tags: sortedTags(tags))
        }
    }

    private static func sortedTags(_ tags: [TagDisplaySummary]) -> [TagDisplaySummary] {
        tags.sorted { lhs, rhs in
            if lhs.isFollowed != rhs.isFollowed {
                return lhs.isFollowed
            }
            return lhs.displayText.localizedCaseInsensitiveCompare(rhs.displayText) == .orderedAscending
        }
    }
}

struct TagDisplayName: Equatable, Sendable {
    var rawValue: String
    var text: String
    var imageURL: URL?
    var imageAltText: String?

    init(markdown: String) {
        rawValue = markdown

        var firstImageURL: URL?
        var firstImageAltText: String?
        var cleaned = markdown
        let pattern = #"!\[([^\]]*)\]\(([^)\s]+)\)"#

        if let regex = try? NSRegularExpression(pattern: pattern) {
            let range = NSRange(markdown.startIndex..<markdown.endIndex, in: markdown)
            let matches = regex.matches(in: markdown, range: range)

            for match in matches {
                if firstImageURL == nil,
                   let urlRange = Range(match.range(at: 2), in: markdown) {
                    let urlString = String(markdown[urlRange])
                    if let url = URL(string: urlString),
                       let scheme = url.scheme?.lowercased(),
                       scheme == "http" || scheme == "https" {
                        firstImageURL = url
                        if let altRange = Range(match.range(at: 1), in: markdown) {
                            firstImageAltText = String(markdown[altRange])
                        }
                    }
                }
            }

            for match in matches.reversed() {
                if let matchRange = Range(match.range, in: cleaned) {
                    cleaned.removeSubrange(matchRange)
                }
            }
        }

        let normalizedText = cleaned
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        text = normalizedText.isEmpty ? markdown : normalizedText
        imageURL = firstImageURL
        imageAltText = firstImageAltText
    }
}

enum TagCategory: String, CaseIterable, Identifiable, Sendable {
    case creator
    case work
    case tags

    var id: String { rawValue }

    var tabs: [TagCategoryTab] {
        switch self {
        case .creator:
            return [.artist, .group]
        case .work:
            return [.parody, .character]
        case .tags:
            return []
        }
    }

    var defaultTab: TagCategoryTab? {
        tabs.first
    }

    var namespaces: [String] {
        switch self {
        case .creator, .work:
            return tabs.map(\.namespace)
        case .tags:
            return TagNamespaceGroup.allCases.map(\.namespace)
        }
    }

    var titleKey: L10nKey {
        switch self {
        case .creator:
            return .tagCategoryCreator
        case .work:
            return .tagCategoryWork
        case .tags:
            return .tagCategoryTags
        }
    }

    var systemImage: String {
        switch self {
        case .creator:
            return "paintpalette"
        case .work:
            return "sparkles.rectangle.stack"
        case .tags:
            return "tag"
        }
    }
}

enum TagCategoryTab: String, CaseIterable, Identifiable, Sendable {
    case artist
    case group
    case parody
    case character

    var id: String { rawValue }

    var namespace: String { rawValue }

    var titleKey: L10nKey {
        switch self {
        case .artist:
            return .tagNamespaceArtist
        case .group:
            return .tagNamespaceGroup
        case .parody:
            return .tagNamespaceParody
        case .character:
            return .tagNamespaceCharacter
        }
    }
}

enum TagNamespaceGroup: String, CaseIterable, Identifiable, Sendable {
    case female
    case male
    case mixed
    case location
    case other

    var id: String { rawValue }

    var namespace: String { rawValue }

    var titleKey: L10nKey {
        switch self {
        case .female:
            return .tagNamespaceFemale
        case .male:
            return .tagNamespaceMale
        case .mixed:
            return .tagNamespaceMixed
        case .location:
            return .tagNamespaceLocation
        case .other:
            return .tagNamespaceOther
        }
    }
}

enum TagNamespaceDisplayMode: String, CaseIterable, Identifiable, Sendable {
    case grouped
    case flat

    var id: String { rawValue }

    var titleKey: L10nKey {
        switch self {
        case .grouped:
            return .tagDisplayGrouped
        case .flat:
            return .tagDisplayFlat
        }
    }
}

enum TagSortStrategy: String, CaseIterable, Identifiable, Sendable {
    case alphabetical
    case count

    var id: String { rawValue }

    var titleKey: L10nKey {
        switch self {
        case .alphabetical:
            return .tagSortAlphabetical
        case .count:
            return .tagSortCount
        }
    }
}

enum SortDirection: String, CaseIterable, Identifiable, Codable, Sendable {
    case ascending
    case descending

    var id: String { rawValue }

    var titleKey: L10nKey {
        switch self {
        case .ascending:
            return .sortAscending
        case .descending:
            return .sortDescending
        }
    }
}

enum TagSummarySorter {
    static func sorted(
        _ summaries: [TagDisplaySummary],
        strategy: TagSortStrategy,
        direction: SortDirection
    ) -> [TagDisplaySummary] {
        summaries.sorted { lhs, rhs in
            if lhs.isFollowed != rhs.isFollowed {
                return lhs.isFollowed
            }

            let result: ComparisonResult
            switch strategy {
            case .alphabetical:
                result = lhs.displayText.localizedCaseInsensitiveCompare(rhs.displayText)
            case .count:
                if lhs.count == rhs.count {
                    result = lhs.displayText.localizedCaseInsensitiveCompare(rhs.displayText)
                } else {
                    result = lhs.count < rhs.count ? .orderedAscending : .orderedDescending
                }
            }

            switch direction {
            case .ascending:
                return result == .orderedAscending
            case .descending:
                return result == .orderedDescending
            }
        }
    }
}

struct TagResolvedTranslation: Equatable, Sendable {
    var translatedName: String
    var intro: String?
    var links: [String]
    var source: String
    var sourceRevision: String?
}

struct ExternalTagTranslation: Equatable, Sendable {
    var namespace: String
    var name: String
    var translatedName: String
    var intro: String?
    var links: [String]
}

struct TagTranslationUpdateResult: Equatable, Sendable {
    var revision: String
    var downloaded: Bool
    var files: Int
    var parsedTranslations: Int
    var materializedTranslations: Int
}

struct TagDerivedState: Equatable, Sendable {
    var languageCode = "unknown"
    var isTranslated = false
    var isFullColor = false
    var censorship = "unknown"
    var hasExtraneousAds = false
}

enum TagParser {
    static func parseJSON(_ tagsJSON: String) -> [Tag] {
        guard let data = tagsJSON.data(using: .utf8),
              let rawTags = try? JSONDecoder().decode([String].self, from: data) else {
            return []
        }

        var seen = Set<String>()
        return rawTags.compactMap { rawTag in
            let rawValue = rawTag.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !rawValue.isEmpty else {
                return nil
            }

            let normalizedRawValue = rawValue.lowercased()
            guard seen.insert(normalizedRawValue).inserted else {
                return nil
            }

            let parts = rawValue.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
            let namespace: String
            let name: String

            if parts.count == 2 {
                namespace = String(parts[0]).trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                name = String(parts[1]).trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            } else {
                namespace = "other"
                name = rawValue.lowercased()
            }

            guard !namespace.isEmpty, !name.isEmpty else {
                return nil
            }

            return Tag(namespace: namespace, name: name, rawValue: "\(namespace):\(name)")
        }
    }

    static func derivedState(from tags: [Tag]) -> TagDerivedState {
        var state = TagDerivedState()

        for tag in tags where tag.namespace == "language" {
            if tag.name == "translated" {
                state.isTranslated = true
            } else if state.languageCode == "unknown" {
                state.languageCode = tag.name
            }
        }

        let otherNames = Set(tags.filter { $0.namespace == "other" }.map(\.name))
        state.isFullColor = otherNames.contains("full color")
        state.hasExtraneousAds = otherNames.contains("extraneous ads")

        if otherNames.contains("uncensored") {
            state.censorship = "uncensored"
        } else if otherNames.contains("full censored") {
            state.censorship = "full censored"
        } else if otherNames.contains("mosaic censorship") {
            state.censorship = "mosaic censorship"
        }

        return state
    }
}
