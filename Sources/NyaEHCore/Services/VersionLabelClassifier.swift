// 本文件根据标题与元数据推断版本标签，只用于辅助填充空标签，不覆盖用户选择。

import Foundation

enum VersionLabelClassifier {
    private static let translatedPatterns = [
        "中国翻訳", "中国語", "[中国翻译]", "Chinese", "汉化", "翻譯",
        "無毒漢化", "个人汉化", "机翻", "簡体", "简体"
    ]

    private static let uncensoredPatterns = [
        "無修正", "无修", "Decensored", "去码", "无码", "無碼",
        "全彩無修正", "uncensored"
    ]

    private static let fullColorPatterns = [
        "カラー化", "Colorized", "フルカラー", "全彩", "彩色",
        "カラー版", "full color"
    ]

    static func labels(for book: LibraryBook) -> [String] {
        var labels: [String] = []
        let tags = TagParser.parseJSON(book.tags)
        let searchableTitle = [book.title, book.titleJpn ?? ""].joined(separator: " ")

        if isTranslated(book: book, tags: tags, title: searchableTitle) {
            labels.append(VersionLabelPreset.translated)
        }
        if isFullColor(book: book, tags: tags, title: searchableTitle) {
            labels.append(VersionLabelPreset.fullColor)
        }
        if isUncensored(book: book, tags: tags, title: searchableTitle) {
            labels.append(VersionLabelPreset.uncensored)
        }
        if labels.isEmpty {
            labels.append(VersionLabelPreset.original)
        }
        return labels
    }

    private static func isTranslated(book: LibraryBook, tags: [Tag], title: String) -> Bool {
        if book.isTranslated || hasTag(tags, rawValue: "language:translated") {
            return true
        }
        let languageCode = book.languageCode.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if !languageCode.isEmpty,
           languageCode != "unknown",
           languageCode != "japanese" {
            return true
        }
        return containsAnyPattern(in: title, patterns: translatedPatterns)
    }

    private static func isUncensored(book: LibraryBook, tags: [Tag], title: String) -> Bool {
        if book.censorship.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "uncensored" {
            return true
        }
        if hasTag(tags, rawValue: "other:uncensored") {
            return true
        }
        return containsAnyPattern(in: title, patterns: uncensoredPatterns)
    }

    private static func isFullColor(book: LibraryBook, tags: [Tag], title: String) -> Bool {
        if book.isFullColor || hasTag(tags, rawValue: "other:full color") {
            return true
        }
        return containsAnyPattern(in: title, patterns: fullColorPatterns)
    }

    private static func hasTag(_ tags: [Tag], rawValue: String) -> Bool {
        tags.contains { $0.rawValue.caseInsensitiveCompare(rawValue) == .orderedSame }
    }

    private static func containsAnyPattern(in text: String, patterns: [String]) -> Bool {
        patterns.contains { pattern in
            text.range(of: pattern, options: [.caseInsensitive, .diacriticInsensitive]) != nil
        }
    }
}
