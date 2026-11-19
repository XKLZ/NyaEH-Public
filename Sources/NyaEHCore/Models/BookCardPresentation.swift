import Foundation

struct BookCardFields: OptionSet, Sendable {
    let rawValue: Int

    static let language = Self(rawValue: 1 << 0)
    static let color = Self(rawValue: 1 << 1)
    static let censorship = Self(rawValue: 1 << 2)
    static let pages = Self(rawValue: 1 << 3)
    static let rating = Self(rawValue: 1 << 4)
    static let directRead = Self(rawValue: 1 << 8)
    static let readingStatus = Self(rawValue: 1 << 6)
    static let readingNumbers = Self(rawValue: 1 << 7)

    static let metadata: Self = [.language, .color, .censorship, .pages]
    static let evaluation: Self = [.rating, .directRead]
    static let reading: Self = [.readingStatus, .readingNumbers]
    static let all: Self = [.metadata, .evaluation, .reading]
}

struct BookCardMetadata: Equatable, Sendable {
    let language: String?
    let isFullColor: Bool
    let censorship: String?
    let pages: Int?
    let rating: Double?
    let url: URL?

    init(book: LibraryBook) {
        let language = book.languageCode.trimmingCharacters(in: .whitespacesAndNewlines)
        self.language = language.isEmpty || language.lowercased() == "unknown" ? nil : language
        isFullColor = book.isFullColor
        let censorship = book.censorship.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        self.censorship = ["uncensored", "mosaic censorship", "full censored"].contains(censorship) ? censorship : nil
        pages = [book.pages, book.fileCount].compactMap { $0 }.first { $0 > 0 }
        rating = book.rating.flatMap { $0.isFinite ? $0 : nil }
        if let address = book.url?.trimmingCharacters(in: .whitespacesAndNewlines),
           let candidate = URL(string: address),
           let scheme = candidate.scheme?.lowercased(), ["http", "https"].contains(scheme),
           let host = candidate.host, !host.isEmpty {
            url = candidate
        } else {
            url = nil
        }
    }
}

enum BookCardReadingStatus: Equatable, Sendable {
    case unread
    case reading(current: Int, total: Int?)
    case completed(openCount: Int)

    init(state: BookReadingState?, openCount: Int) {
        if let state, state.isCompleted {
            self = .completed(openCount: openCount)
        } else if let state, state.currentPageIndex > 0 {
            self = .reading(
                current: state.totalPages > 0 ? min(state.currentPageIndex + 1, state.totalPages) : state.currentPageIndex + 1,
                total: state.totalPages > 0 ? state.totalPages : nil
            )
        } else {
            self = .unread
        }
    }

}

enum BookCardVersionChoices {
    static func alternatives(
        to book: LibraryBook, among companions: [LibraryBook], showsUserHidden: Bool
    ) -> [LibraryBook] {
        guard let groupID = book.versionGroupID else { return [] }
        return companions.filter {
            $0.id != book.id && $0.versionGroupID == groupID && $0.isUserHidden == showsUserHidden
        }
    }
}

struct BookCardEditionStack {
    let editions: [LibraryBook]

    init(current: LibraryBook, visibleAlternatives: [LibraryBook], aggregatesVersions: Bool) {
        editions = aggregatesVersions ? [current] + visibleAlternatives : [current]
    }

    var depth: Int { min(editions.count, 3) }

    func index(for id: LibraryBook.ID?) -> Int {
        editions.firstIndex { $0.id == id } ?? 0
    }

    // Strict improvement keeps the card version, then the existing version order, on ties.
    var highestRating: LibraryBook? {
        var best: LibraryBook?
        for edition in editions {
            guard let rating = edition.rating, rating.isFinite, best?.rating.map({ rating > $0 }) ?? true else { continue }
            best = edition
        }
        return best
    }
}

struct BookCardLanguageLabel: Equatable {
    let abbreviation: String
    let fullName: String

    private static let codes = [
        "chinese": "zh", "japanese": "ja", "english": "en", "korean": "ko",
        "spanish": "es", "french": "fr", "german": "de", "italian": "it", "portuguese": "pt",
        "russian": "ru", "thai": "th", "vietnamese": "vi", "indonesian": "id", "dutch": "nl", "polish": "pl"
    ]
    private static let shortNames: [String: (hans: String, hant: String, japanese: String, korean: String)] = [
        "zh": ("中", "中", "中", "중"), "ja": ("日", "日", "日", "일"),
        "en": ("英", "英", "英", "영"), "ko": ("韩", "韓", "韓", "한"),
        "es": ("西", "西", "西", "스"), "fr": ("法", "法", "仏", "프"),
        "de": ("德", "德", "独", "독"), "it": ("意", "義", "伊", "이"),
        "pt": ("葡", "葡", "葡", "포"), "ru": ("俄", "俄", "露", "러"),
        "th": ("泰", "泰", "泰", "태"), "vi": ("越", "越", "越", "베")
    ]

    init(_ language: String, interfaceLanguage: AppLanguage, systemLocale: Locale = .current) {
        let raw = language.lowercased().replacingOccurrences(of: "_", with: "-")
        let identifier = Self.codes[raw] ?? raw
        let base = identifier.split(separator: "-").first.map(String.init) ?? identifier
        let locale = interfaceLanguage.localizationIdentifier.map(Locale.init(identifier:)) ?? systemLocale
        let resolvedLanguage = interfaceLanguage == .system
            ? AppLanguage.fromLocalizationIdentifier(locale.identifier) ?? .en : interfaceLanguage
        fullName = locale.localizedString(forIdentifier: identifier)
            ?? locale.localizedString(forLanguageCode: base)
            ?? language
        let names = Self.shortNames[base]
        let abbreviation: String?
        switch resolvedLanguage {
        case .zhHans: abbreviation = names?.hans
        case .zhHant: abbreviation = names?.hant
        case .ja: abbreviation = names?.japanese
        case .ko: abbreviation = names?.korean
        case .system, .en: abbreviation = nil
        }
        self.abbreviation = abbreviation ?? String(base.prefix(3)).uppercased()
    }
}
