// 本文件解析系列标题中的顺序标记，同时保留可供上下文语义模型使用的自然语言标题 stem。

import Foundation

enum SeriesOrdinalKind: String, Codable, Equatable, Sendable {
    case explicitMarker
    case namedChapter
    case romanNumeral
    case terminalNumber
    case suffixedNumber
    case catalogNumber
}

enum SeriesOrdinalConfidence: String, Codable, Equatable, Sendable {
    case high
    case medium
}

struct SeriesOrdinalEvidence: Codable, Equatable, Sendable {
    var marker: String
    var key: String
    var sortValue: Int
    var numberingFamily: String?
    var kind: SeriesOrdinalKind
    var confidence: SeriesOrdinalConfidence
    /// Range in the normalized, compact title used by this parser.
    var normalizedTitleRange: Range<Int>
}

enum SeriesTitleOrdinalState: Equatable, Sendable {
    case explicit(SeriesOrdinalEvidence)
    case cleanUnnumbered
    case rejected(String)
}

struct SeriesTitleAnalysis: Equatable, Sendable {
    var comparisonTitle: String
    var seriesStem: String
    var semanticStem: String
    var ordinalState: SeriesTitleOrdinalState

    var ordinalEvidence: SeriesOrdinalEvidence? {
        guard case .explicit(let evidence) = ordinalState else {
            return nil
        }
        return evidence
    }

    var isCleanUnnumbered: Bool {
        ordinalState == .cleanUnnumbered
    }

    init?(title: String) {
        let preparedTitle = SeriesTitlePattern.preparedTitle(title)
        guard !preparedTitle.isEmpty else {
            return nil
        }

        let extracted = SeriesTitlePattern.extractSeriesPattern(preparedTitle)
        let rawStem = extracted?.stem ?? preparedTitle
        let semanticStem = SeriesTitlePattern.semanticStem(rawStem)
        let seriesStem = SeriesTitlePattern.comparisonTitle(semanticStem)
        let comparisonTitle = SeriesTitlePattern.comparisonTitle(preparedTitle)
        guard !comparisonTitle.isEmpty, seriesStem.count >= 2, !semanticStem.isEmpty else {
            return nil
        }

        self.comparisonTitle = comparisonTitle
        self.seriesStem = seriesStem
        self.semanticStem = semanticStem
        if let extracted {
            let sortValue = SeriesTitlePattern.ordinalSortValue(extracted.ordinal)
            ordinalState = .explicit(
                SeriesOrdinalEvidence(
                    marker: extracted.ordinal,
                    key: sortValue == Int.max
                        ? extracted.ordinal.folding(
                            options: [.caseInsensitive, .widthInsensitive],
                            locale: nil
                        )
                        : String(sortValue),
                    sortValue: sortValue,
                    numberingFamily: extracted.numberingFamily,
                    kind: extracted.kind,
                    confidence: extracted.confidence,
                    normalizedTitleRange: extracted.range
                )
            )
        } else if let rejectionReason = SeriesTitlePattern.unnumberedRejectionReason(preparedTitle) {
            ordinalState = .rejected(rejectionReason)
        } else {
            ordinalState = .cleanUnnumbered
        }
    }
}

struct SeriesTitlePattern: Equatable, Sendable {
    var comparisonTitle: String
    var seriesStem: String
    var semanticStem: String
    var ordinalEvidence: SeriesOrdinalEvidence

    var ordinalMarker: String? { ordinalEvidence.marker }
    var ordinalKey: String { ordinalEvidence.key }
    var ordinalSortValue: Int { ordinalEvidence.sortValue }
    var numberingFamily: String? { ordinalEvidence.numberingFamily }

    init?(title: String) {
        guard let analysis = SeriesTitleAnalysis(title: title),
              let ordinalEvidence = analysis.ordinalEvidence else {
            return nil
        }
        comparisonTitle = analysis.comparisonTitle
        seriesStem = analysis.seriesStem
        semanticStem = analysis.semanticStem
        self.ordinalEvidence = ordinalEvidence
    }

    fileprivate static func preparedTitle(_ title: String) -> String {
        BookTitleFormatter.compactTitle(title)
            .precomposedStringWithCompatibilityMapping
            .folding(options: [.caseInsensitive, .widthInsensitive, .diacriticInsensitive], locale: nil)
            .replacingOccurrences(
                of: #"\s*(?:\[(?:中国翻訳|中国翻译|中文|chinese|無修正|无修|フルカラー|全彩|dl版)[^\]]*\]|【(?:中国翻訳|中国翻译|中文|無修正|无修|フルカラー|全彩|dl版)[^】]*】)\s*"#,
                with: " ",
                options: [.regularExpression, .caseInsensitive]
            )
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    fileprivate static func semanticStem(_ stem: String) -> String {
        stem
            .replacingOccurrences(of: #"[\s\-–—:：・·]+$"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    fileprivate static func comparisonTitle(_ title: String) -> String {
        title
            .replacingOccurrences(of: #"[\p{P}\p{S}\s]+"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    fileprivate static func extractSeriesPattern(_ title: String) -> ExtractedPattern? {
        // Calendar dates are metadata/event evidence, not publication order.
        if title.range(
            of: #"(?:19|20)\d{2}\s*[年./-]\s*\d{1,2}(?:\s*[月./-]\s*\d{1,2}\s*日?)?"#,
            options: .regularExpression
        ) != nil || title.range(
            of: #"(?:^|[^\d])\d{1,2}\s*月\s*\d{1,2}\s*日(?:$|[^\d])"#,
            options: .regularExpression
        ) != nil {
            return nil
        }
        // Decimal revisions such as 2.00/2.10 are version-like, not volume ordinals.
        if title.range(
            of: #"(?:^|[^\d])\d{1,3}[.．]\d{1,3}(?:\s*[-–—:：]\s*.*)?$"#,
            options: .regularExpression
        ) != nil {
            return nil
        }
        if title.range(
            of: #"[0-9０-９一二三四五六七八九十百零〇]+\s*(?:[+＋/&＆])\s*[0-9０-９一二三四五六七八九十百零〇]+"#,
            options: .regularExpression
        ) != nil {
            return nil
        }
        if title.range(
            of: #"^(?:c|sc)\s*[0-9０-９]{1,3}(?:\D|$)"#,
            options: [.regularExpression, .caseInsensitive]
        ) != nil {
            return nil
        }

        let chapterWords = [
            "続々", "前篇", "後篇", "后篇", "前編", "後編", "上巻", "中巻", "下巻",
            "其一", "其二", "其三", "其四", "其五", "続",
            "上", "中", "下", "一", "二", "三", "四", "五", "六", "七", "八", "九", "十"
        ]
        for word in chapterWords.sorted(by: { $0.count > $1.count }) where title.hasSuffix(word) {
            let stem = String(title.dropLast(word.count))
            if comparisonTitle(stem).count >= 2 {
                return ExtractedPattern(
                    stem: stem,
                    ordinal: word,
                    numberingFamily: nil,
                    kind: .namedChapter,
                    confidence: .high,
                    range: (title.count - word.count)..<title.count
                )
            }
        }

        let numeric = #"[0-9０-９一二三四五六七八九十百零〇]+"#
        let decimal = #"[0-9０-９]+"#
        let roman = #"(?:x{0,2}(?:ix|iv|v?i{1,3}))"#

        if let match = firstMatch(
            #"^(.{2,}?)\s*第\s*("# + numeric + #")\s*(話|话|巻|卷|章|部)(?:\s*[-–—:：]\s*.{1,24})?$"#,
            in: title
        ), isUsableOrdinal(match.value(2)) {
            return extracted(
                match: match,
                stem: match.value(1),
                ordinalCapture: 2,
                kind: .explicitMarker,
                confidence: .high
            )
        }

        if let match = firstMatch(
            #"^(.{2,}?)\s*(?:vol(?:ume)?|part|chapter|episode|ep|no)\.?\s*("# + numeric + "|" + roman + #")(?:\s*[-–—:：]\s*.{1,24})?$"#,
            in: title,
            caseInsensitive: true
        ), isUsableOrdinal(match.value(2)) {
            return extracted(
                match: match,
                stem: match.value(1),
                ordinalCapture: 2,
                kind: .explicitMarker,
                confidence: .high
            )
        }

        if let match = firstMatch(
            #"^(.{2,}?)\s*#\s*("# + numeric + "|" + roman + #")(?:\s*[-–—:：]\s*.{1,24})?$"#,
            in: title,
            caseInsensitive: true
        ), isUsableOrdinal(match.value(2)) {
            return extracted(
                match: match,
                stem: match.value(1),
                ordinalCapture: 2,
                kind: .explicitMarker,
                confidence: .high
            )
        }

        if let match = firstMatch(
            #"^(.{2,}?)\s+("# + roman + #")$"#,
            in: title,
            caseInsensitive: true
        ), isUsableOrdinal(match.value(2)) {
            return extracted(
                match: match,
                stem: match.value(1),
                ordinalCapture: 2,
                kind: .romanNumeral,
                confidence: .high
            )
        }

        if let match = firstMatch(
            #"^(.{2,}?)\s*("# + numeric + #")\s*(?:話|话|巻|卷|章|部)$"#,
            in: title
        ), isUsableOrdinal(match.value(2)) {
            return extracted(
                match: match,
                stem: match.value(1),
                ordinalCapture: 2,
                kind: .explicitMarker,
                confidence: .high
            )
        }

        // A Latin identifier directly before the number is retained as a numbering family.
        // Long identifiers (ARCANUM/ARCANUMS) are the publication title itself. Short
        // identifiers (F3) are stripped from the semantic stem and must match exactly
        // across books. Cxx/SCxx remain event codes and are rejected.
        if let match = firstMatch(
            #"^(.*?)([a-z]{1,24})\s*("# + decimal + #")(?:\s*[-–—:：]?\s+.{1,24})?$"#,
            in: title,
            caseInsensitive: true
        ), isUsableOrdinal(match.value(3)) {
            let prefix = normalizedNumberingFamily(match.value(2))
            guard prefix != "c", prefix != "sc" else {
                return nil
            }
            let base = match.value(1).trimmingCharacters(in: .whitespacesAndNewlines)
            let isShortCode = prefix.count <= 3 && !base.isEmpty
            let stem = isShortCode
                ? base
                : "\(base)\(match.value(2))"
            guard comparisonTitle(stem).count >= 2 else {
                return nil
            }
            return ExtractedPattern(
                stem: stem,
                ordinal: match.value(3),
                numberingFamily: prefix,
                kind: .catalogNumber,
                confidence: isShortCode ? .medium : .high,
                range: match.range(3)
            )
        }

        if let match = firstMatch(
            #"^(.{2,}?)\s*("# + numeric + #")\s*[-–—:：]\s*.{1,24}$"#,
            in: title
        ), isUsableOrdinal(match.value(2)) {
            return extracted(
                match: match,
                stem: match.value(1),
                ordinalCapture: 2,
                kind: .suffixedNumber,
                confidence: .high
            )
        }

        if let match = firstMatch(#"^(.{2,}?)\s*("# + numeric + #")$"#, in: title),
           isUsableOrdinal(match.value(2)),
           !hasRejectedTerminalCode(stem: match.value(1)) {
            return extracted(
                match: match,
                stem: match.value(1),
                ordinalCapture: 2,
                kind: .terminalNumber,
                confidence: .high
            )
        }

        if let match = firstMatch(
            #"^(.{2,}?)\s*("# + decimal + #")\s+(.{1,18})$"#,
            in: title
        ), isUsableOrdinal(match.value(2)), !match.value(3).allSatisfy(\.isNumber) {
            return extracted(
                match: match,
                stem: match.value(1),
                ordinalCapture: 2,
                kind: .suffixedNumber,
                confidence: .medium
            )
        }

        // Compact suffix titles are common in Japanese metadata, but only Arabic digits
        // are accepted here. This preserves "プリキュア陵辱17キュアワンダフル" without
        // treating a lexical numeral inside "六畳間" as an ordinal.
        if let match = firstMatch(
            #"^(.{2,}?)("# + decimal + #")([^\s0-9０-９].{0,17})$"#,
            in: title
        ), isUsableOrdinal(match.value(2)),
           !hasRejectedTerminalCode(stem: match.value(1)) {
            return extracted(
                match: match,
                stem: match.value(1),
                ordinalCapture: 2,
                kind: .suffixedNumber,
                confidence: .medium
            )
        }

        return nil
    }

    fileprivate static func unnumberedRejectionReason(_ title: String) -> String? {
        if title.range(
            of: #"(?:19|20)\d{2}\s*[年./-]\s*\d{1,2}(?:\s*[月./-]\s*\d{1,2}\s*日?)?"#,
            options: .regularExpression
        ) != nil || title.range(
            of: #"(?:^|[^\d])\d{1,2}\s*月\s*\d{1,2}\s*日(?:$|[^\d])"#,
            options: .regularExpression
        ) != nil {
            return "date"
        }
        if title.range(
            of: #"(?:^|[^\d])\d{1,3}[.．]\d{1,3}(?:\s*[-–—:：]\s*.*)?$"#,
            options: .regularExpression
        ) != nil {
            return "decimal_revision"
        }
        if title.range(
            of: #"(?:^|\s)(?:c|sc)\s*[0-9０-９]{1,3}(?:\D|$)"#,
            options: [.regularExpression, .caseInsensitive]
        ) != nil {
            return "event_code"
        }
        if title.range(
            of: #"(?:^|[^\d])(?:19|20)\d{2}(?:$|[^\d])"#,
            options: .regularExpression
        ) != nil {
            return "year"
        }
        if title.range(
            of: #"[0-9０-９一二三四五六七八九十百零〇]+\s*(?:[+＋/&＆])\s*[0-9０-９一二三四五六七八九十百零〇]+"#,
            options: .regularExpression
        ) != nil {
            return "combined_volume"
        }
        if title.range(
            of: #"(?:総集編|总集篇|總集篇|番外編|番外篇|外伝|外传|外傳|特別編|特别篇|特別篇|完全版|再録|再录|再錄|\bomnibus\b|\bspecial\b|\bextra\b)"#,
            options: [.regularExpression, .caseInsensitive]
        ) != nil {
            return "special_edition"
        }
        return nil
    }

    private static func extracted(
        match: RegexMatch,
        stem: String,
        ordinalCapture: Int,
        kind: SeriesOrdinalKind,
        confidence: SeriesOrdinalConfidence
    ) -> ExtractedPattern {
        ExtractedPattern(
            stem: stem,
            ordinal: match.value(ordinalCapture),
            numberingFamily: nil,
            kind: kind,
            confidence: confidence,
            range: match.range(ordinalCapture)
        )
    }

    private static func normalizedNumberingFamily(_ value: String) -> String {
        var normalized = value.folding(
            options: [.caseInsensitive, .widthInsensitive, .diacriticInsensitive],
            locale: nil
        ).lowercased()
        if normalized.count > 4, normalized.hasSuffix("s") {
            normalized.removeLast()
        }
        return normalized
    }

    private static func hasRejectedTerminalCode(stem: String) -> Bool {
        guard let match = firstMatch(#"([a-z]{1,3})\s*$"#, in: stem, caseInsensitive: true) else {
            return false
        }
        return ["c", "sc"].contains(normalizedNumberingFamily(match.value(1)))
    }

    private static func isUsableOrdinal(_ ordinal: String) -> Bool {
        guard let value = parsedOrdinalValue(ordinal) else {
            return true
        }
        return !(1900...2099).contains(value)
    }

    private static func firstMatch(
        _ pattern: String,
        in text: String,
        caseInsensitive: Bool = false
    ) -> RegexMatch? {
        let options: NSRegularExpression.Options = caseInsensitive ? [.caseInsensitive] : []
        guard let regex = try? NSRegularExpression(pattern: pattern, options: options) else {
            return nil
        }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let result = regex.firstMatch(in: text, range: range) else {
            return nil
        }
        var values: [String] = []
        var ranges: [Range<Int>] = []
        for index in 0..<result.numberOfRanges {
            let nsRange = result.range(at: index)
            guard nsRange.location != NSNotFound,
                  let stringRange = Range(nsRange, in: text) else {
                values.append("")
                ranges.append(0..<0)
                continue
            }
            values.append(String(text[stringRange]))
            let lower = text.distance(from: text.startIndex, to: stringRange.lowerBound)
            let upper = text.distance(from: text.startIndex, to: stringRange.upperBound)
            ranges.append(lower..<upper)
        }
        return RegexMatch(values: values, ranges: ranges)
    }

    fileprivate static func ordinalSortValue(_ ordinal: String) -> Int {
        if let value = parsedOrdinalValue(ordinal) {
            return value
        }
        let values = [
            "前篇": 1, "前編": 1, "上": 1, "上巻": 1, "其一": 1, "続": 2,
            "中": 2, "中巻": 2, "其二": 2, "続々": 3,
            "後篇": 3, "后篇": 3, "後編": 3, "下": 3, "下巻": 3, "其三": 3,
            "其四": 4, "其五": 5
        ]
        return values[ordinal] ?? Int.max
    }

    private static func parsedOrdinalValue(_ ordinal: String) -> Int? {
        if let decimal = decimalValue(in: ordinal) {
            return decimal
        }
        if let cjk = cjkNumeralValue(in: ordinal) {
            return cjk
        }
        return romanNumeralValue(in: ordinal)
    }

    private static func decimalValue(in ordinal: String) -> Int? {
        let normalized = ordinal.map { character -> Character in
            guard let scalar = character.unicodeScalars.first,
                  scalar.value >= 0xFF10,
                  scalar.value <= 0xFF19 else {
                return character
            }
            return Character(UnicodeScalar(scalar.value - 0xFEE0)!)
        }
        let digits = String(normalized).filter { $0 >= "0" && $0 <= "9" }
        return digits.isEmpty ? nil : Int(digits)
    }

    private static func cjkNumeralValue(in ordinal: String) -> Int? {
        let numerals = ordinal.filter { "零〇一二三四五六七八九十百".contains($0) }
        guard !numerals.isEmpty else {
            return nil
        }

        let digitValues: [Character: Int] = [
            "零": 0, "〇": 0, "一": 1, "二": 2, "三": 3, "四": 4,
            "五": 5, "六": 6, "七": 7, "八": 8, "九": 9
        ]
        let unitValues: [Character: Int] = ["十": 10, "百": 100]
        var total = 0
        var pendingDigit = 0
        for character in numerals {
            if let digit = digitValues[character] {
                pendingDigit = digit
            } else if let unit = unitValues[character] {
                total += (pendingDigit == 0 ? 1 : pendingDigit) * unit
                pendingDigit = 0
            }
        }
        total += pendingDigit
        return total > 0 ? total : nil
    }

    private static func romanNumeralValue(in ordinal: String) -> Int? {
        let value = ordinal.lowercased()
        guard value.range(of: #"^x{0,2}(?:ix|iv|v?i{1,3})$"#, options: .regularExpression) != nil else {
            return nil
        }
        let values: [Character: Int] = ["i": 1, "v": 5, "x": 10]
        var total = 0
        var previous = 0
        for character in value.reversed() {
            let current = values[character] ?? 0
            total += current < previous ? -current : current
            previous = current
        }
        return total > 0 ? total : nil
    }
}

private struct ExtractedPattern {
    var stem: String
    var ordinal: String
    var numberingFamily: String?
    var kind: SeriesOrdinalKind
    var confidence: SeriesOrdinalConfidence
    var range: Range<Int>
}

private struct RegexMatch {
    var values: [String]
    var ranges: [Range<Int>]

    func value(_ index: Int) -> String {
        values.indices.contains(index) ? values[index] : ""
    }

    func range(_ index: Int) -> Range<Int> {
        ranges.indices.contains(index) ? ranges[index] : 0..<0
    }
}
