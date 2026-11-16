// 本文件提供 BookTitleDisplayMode 支撑工具，承载格式化、环境值、缓存或本地化等横切逻辑。

import Foundation

enum BookTitleDisplayMode: String, CaseIterable, Identifiable, Sendable {
    case originalTitle
    case japaneseTitle
    case compactTitle
    case compactJapaneseTitle

    var id: String { rawValue }

    var titleKey: L10nKey {
        switch self {
        case .originalTitle:
            return .bookTitleOriginal
        case .japaneseTitle:
            return .bookTitleJapanese
        case .compactTitle:
            return .bookTitleCompact
        case .compactJapaneseTitle:
            return .bookTitleCompactJapanese
        }
    }

    var next: BookTitleDisplayMode {
        let modes = Self.allCases
        guard let index = modes.firstIndex(of: self) else {
            return .originalTitle
        }

        return modes[modes.index(after: index) == modes.endIndex ? modes.startIndex : modes.index(after: index)]
    }
}

enum BookTitleFormatter {
    private static let compactTitlePattern = #"^\d+[-]?\s*|\s*(\[[^\]]*\]|\([^\)]*\)|【[^】]*】|（[^）]*）)\s*"#

    static func compactTitle(_ title: String) -> String {
        title
            .replacingOccurrences(of: compactTitlePattern, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"^\s*[-–—]\s*"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func displayTitle(for book: LibraryBook, mode: BookTitleDisplayMode) -> String {
        switch mode {
        case .originalTitle:
            return book.title
        case .japaneseTitle:
            return nonEmpty(book.titleJpn) ?? book.title
        case .compactTitle:
            return compactTitle(book.title, fallback: book.title)
        case .compactJapaneseTitle:
            let source = nonEmpty(book.titleJpn) ?? book.title
            return compactTitle(source, fallback: source)
        }
    }

    private static func compactTitle(_ title: String, fallback: String) -> String {
        let compacted = compactTitle(title)
        return compacted.isEmpty ? fallback : compacted
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            return nil
        }

        return value
    }
}
