// 本文件定义 BookMetadataEditDraft 领域模型，是数据库、服务层和 SwiftUI 视图之间传递业务状态的结构。

import Foundation

struct BookMetadataEditDraft: Equatable, Sendable {
    var title: String
    var titleJpn: String
    var category: String
    var languageSelection: BookMetadataLanguageOption
    var customLanguageCode: String
    var pagesText: String
    var isTranslated: Bool
    var isFullColor: Bool
    var censorship: String
    var hasExtraneousAds: Bool
    var tagGroups: [BookMetadataTagGroup]

    init(book: LibraryBook) {
        title = book.title
        titleJpn = book.titleJpn ?? ""
        if let category = book.category,
           BookMetadataCategoryOption.allCases.contains(where: { $0.rawValue == category }) {
            self.category = category
        } else {
            self.category = BookMetadataCategoryOption.unknown.rawValue
        }
        let language = book.languageCode.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if let knownLanguage = BookMetadataLanguageOption(languageCode: language) {
            languageSelection = knownLanguage
            customLanguageCode = ""
        } else {
            languageSelection = .other
            customLanguageCode = language
        }
        pagesText = book.pages.map(String.init) ?? ""
        isTranslated = book.isTranslated
        isFullColor = book.isFullColor
        censorship = book.censorship
        hasExtraneousAds = book.hasExtraneousAds
        tagGroups = Self.groups(from: TagParser.parseJSON(book.tags))
    }

    func validatedMetadata(for book: LibraryBook) throws -> BookManualMetadataUpdate {
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTitle.isEmpty else {
            throw BookMetadataEditError.emptyTitle
        }

        let pages = try Self.validatedPages(from: pagesText)
        let resolvedLanguageCode = languageSelection.resolvedLanguageCode(customLanguageCode: customLanguageCode)
        let tags = Self.normalizedTags(
            tagGroups: tagGroups,
            languageCode: resolvedLanguageCode,
            isTranslated: isTranslated,
            isFullColor: isFullColor,
            censorship: censorship,
            hasExtraneousAds: hasExtraneousAds
        )

        let tagsJSONData = try JSONEncoder().encode(tags)
        guard let tagsJSON = String(data: tagsJSONData, encoding: .utf8) else {
            throw BookMetadataEditError.invalidTags
        }

        return BookManualMetadataUpdate(
            title: trimmedTitle,
            titleJpn: titleJpn.nilIfBlank,
            category: category.nilIfBlank,
            languageCode: resolvedLanguageCode.nilIfBlank ?? "unknown",
            pages: pages,
            isTranslated: isTranslated,
            isFullColor: isFullColor,
            censorship: censorship.nilIfBlank ?? "unknown",
            hasExtraneousAds: hasExtraneousAds,
            tagsJSON: tagsJSON
        )
    }

    static let editableNamespaces: [String] = [
        "artist",
        "group",
        "parody",
        "character",
        "female",
        "male",
        "mixed",
        "location",
        "other"
    ]

    private static func groups(from tags: [Tag]) -> [BookMetadataTagGroup] {
        let grouped = Dictionary(grouping: tags) { tag in
            editableNamespaces.contains(tag.namespace) ? tag.namespace : "other"
        }

        return editableNamespaces.map { namespace in
            let values = grouped[namespace, default: []]
                .map(\.name)
                .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
            return BookMetadataTagGroup(namespace: namespace, valuesText: values.joined(separator: "\n"))
        }
    }

    private static func validatedPages(from text: String) throws -> Int? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return nil
        }
        guard let pages = Int(trimmed), pages > 0 else {
            throw BookMetadataEditError.invalidPages
        }
        return pages
    }

    private static func normalizedTags(
        tagGroups: [BookMetadataTagGroup],
        languageCode: String,
        isTranslated: Bool,
        isFullColor: Bool,
        censorship: String,
        hasExtraneousAds: Bool
    ) -> [String] {
        var rawValues: [String] = []
        var seen = Set<String>()

        func append(namespace: String, name: String) {
            let namespace = namespace.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let name = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard !namespace.isEmpty, !name.isEmpty else {
                return
            }
            let rawValue = "\(namespace):\(name)"
            guard seen.insert(rawValue).inserted else {
                return
            }
            rawValues.append(rawValue)
        }

        for group in tagGroups {
            let namespace = editableNamespaces.contains(group.namespace) ? group.namespace : "other"
            for line in group.valuesText.components(separatedBy: .newlines) {
                let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else {
                    continue
                }
                if trimmed.contains(":") {
                    let parts = trimmed.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
                    if parts.count == 2 {
                        append(namespace: String(parts[0]), name: String(parts[1]))
                    }
                } else {
                    append(namespace: namespace, name: trimmed)
                }
            }
        }

        let normalizedLanguage = languageCode.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if !normalizedLanguage.isEmpty, normalizedLanguage != "unknown" {
            append(namespace: "language", name: normalizedLanguage)
        }
        if isTranslated {
            append(namespace: "language", name: "translated")
        }
        if isFullColor {
            append(namespace: "other", name: "full color")
        }

        switch censorship.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "uncensored", "full censored", "mosaic censorship":
            append(namespace: "other", name: censorship)
        default:
            break
        }

        if hasExtraneousAds {
            append(namespace: "other", name: "extraneous ads")
        }

        return rawValues
    }
}

struct BookMetadataTagGroup: Identifiable, Equatable, Sendable {
    var namespace: String
    var valuesText: String

    var id: String { namespace }
}

struct BookManualMetadataUpdate: Equatable, Sendable {
    var title: String
    var titleJpn: String?
    var category: String?
    var languageCode: String
    var pages: Int?
    var isTranslated: Bool
    var isFullColor: Bool
    var censorship: String
    var hasExtraneousAds: Bool
    var tagsJSON: String
}

enum BookMetadataLanguageOption: String, CaseIterable, Identifiable, Sendable {
    case chinese
    case english
    case japanese
    case korean
    case unknown
    case other

    var id: String { rawValue }

    init?(languageCode: String) {
        switch languageCode {
        case "chinese":
            self = .chinese
        case "english":
            self = .english
        case "japanese":
            self = .japanese
        case "korean":
            self = .korean
        case "", "unknown":
            self = .unknown
        default:
            return nil
        }
    }

    var title: String {
        switch self {
        case .chinese:
            return "中文"
        case .english:
            return "英文"
        case .japanese:
            return "日文"
        case .korean:
            return "韩文"
        case .unknown:
            return "未知"
        case .other:
            return "其他"
        }
    }

    func resolvedLanguageCode(customLanguageCode: String) -> String {
        switch self {
        case .chinese:
            return "chinese"
        case .english:
            return "english"
        case .japanese:
            return "japanese"
        case .korean:
            return "korean"
        case .unknown:
            return "unknown"
        case .other:
            let trimmed = customLanguageCode.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            return trimmed.isEmpty ? "other" : trimmed
        }
    }
}

enum BookMetadataCategoryOption: String, CaseIterable, Identifiable, Sendable {
    case doujinshi = "Doujinshi"
    case manga = "Manga"
    case artistCG = "Artist CG"
    case gameCG = "Game CG"
    case western = "Western"
    case nonH = "Non-H"
    case imageSet = "Image Set"
    case cosplay = "Cosplay"
    case asianPorn = "Asian Porn"
    case misc = "Misc"
    case unknown = "Unknown"

    var id: String { rawValue }
}

enum BookMetadataEditError: LocalizedError, Equatable {
    case emptyTitle
    case invalidPages
    case invalidTags
    case invalidGalleryURL

    var errorDescription: String? {
        switch self {
        case .emptyTitle:
            return "Title cannot be empty."
        case .invalidPages:
            return "Pages must be a positive integer or blank."
        case .invalidTags:
            return "Tags could not be encoded."
        case .invalidGalleryURL:
            return "Enter a valid E-Hentai or ExHentai gallery URL."
        }
    }
}

private extension String {
    var nilIfBlank: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
