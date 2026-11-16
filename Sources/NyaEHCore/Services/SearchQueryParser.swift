// 本文件解析强搜索语法，把标题、标签、包含/排除、OR 和精确匹配转换为查询模型。

import Foundation

enum SearchQueryParser {
    static func parse(_ query: String) -> ParsedSearchQuery {
        var parsed = ParsedSearchQuery()
        for token in tokenize(query) {
            parse(token, into: &parsed)
        }
        return parsed
    }

    private static func parse(_ token: SearchToken, into parsed: inout ParsedSearchQuery) {
        var text = token.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            return
        }

        var isExcluded = false
        var isOptional = false
        if text.hasPrefix("-") {
            isExcluded = true
            text.removeFirst()
        } else if text.hasPrefix("~") {
            isOptional = true
            text.removeFirst()
        }

        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            return
        }

        if text.lowercased().hasPrefix("weak:") {
            text.removeFirst("weak:".count)
        }

        let lowered = text.lowercased()
        if lowered.hasPrefix("title:") {
            let value = normalizedTerm(String(text.dropFirst("title:".count)))
            guard !value.isEmpty else { return }
            parsed.titleTerms.append(SearchTitleTerm(text: value, isExcluded: isExcluded, scope: .title))
            return
        }

        if let filePrefix = fileSearchPrefix(in: lowered) {
            let value = normalizedTerm(String(text.dropFirst(filePrefix.count)))
            guard !value.isEmpty else { return }
            parsed.titleTerms.append(SearchTitleTerm(text: value, isExcluded: isExcluded, scope: .file))
            return
        }

        if lowered.hasPrefix("tag:") {
            let value = normalizedTagName(String(text.dropFirst("tag:".count)))
            appendTag(
                namespace: nil,
                name: value.name,
                isExact: value.isExact,
                isExcluded: isExcluded,
                isOptional: isOptional,
                token: token,
                parsed: &parsed
            )
            return
        }

        if let colonIndex = text.firstIndex(of: ":") {
            let namespaceText = String(text[..<colonIndex])
            if let namespace = SearchNamespace.canonical(namespaceText) {
                let tail = String(text[text.index(after: colonIndex)...])
                let value = normalizedTagName(tail)
                appendTag(
                    namespace: namespace,
                    name: value.name,
                    isExact: value.isExact,
                    isExcluded: isExcluded,
                    isOptional: isOptional,
                    token: token,
                    parsed: &parsed
                )
                return
            }
        }

        parsed.titleTerms.append(SearchTitleTerm(text: normalizedTerm(text), isExcluded: isExcluded, scope: .any))
    }

    private static func fileSearchPrefix(in lowered: String) -> String? {
        for prefix in ["file:", "filename:", "path:"] where lowered.hasPrefix(prefix) {
            return prefix
        }
        return nil
    }

    private static func appendTag(
        namespace: String?,
        name: String,
        isExact: Bool,
        isExcluded: Bool,
        isOptional: Bool,
        token: SearchToken,
        parsed: inout ParsedSearchQuery
    ) {
        guard !name.isEmpty else {
            return
        }

        let constraint = SearchTagConstraint(
            namespace: namespace,
            name: name,
            isExact: isExact
        )
        if isExcluded {
            parsed.excludedTags.append(constraint)
        } else if isOptional {
            parsed.optionalTags.append(constraint)
        } else {
            parsed.requiredTags.append(constraint)
        }

        parsed.tokenHighlights.append(
            SearchTokenHighlight(
                range: token.range,
                displayText: token.text,
                state: isExcluded ? .excluded : .selected
            )
        )
    }

    private static func normalizedTagName(_ text: String) -> (name: String, isExact: Bool) {
        var value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        var isExact = false
        if value.hasSuffix("$") {
            isExact = true
            value.removeLast()
        }
        if value.hasSuffix("*") || value.hasSuffix("%") {
            value.removeLast()
        }
        value = normalizedTerm(value).replacingOccurrences(of: "_", with: " ")
        return (value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(), isExact)
    }

    private static func normalizedTerm(_ text: String) -> String {
        var value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.count >= 2, value.first == "\"", value.last == "\"" {
            value.removeFirst()
            value.removeLast()
        }
        return value.replacingOccurrences(of: "\\\"", with: "\"")
    }

    private static func tokenize(_ query: String) -> [SearchToken] {
        var tokens: [SearchToken] = []
        var index = query.startIndex

        while index < query.endIndex {
            while index < query.endIndex, query[index].isWhitespace || query[index] == "," {
                index = query.index(after: index)
            }
            guard index < query.endIndex else { break }

            let start = index
            var inQuote = false
            while index < query.endIndex {
                let character = query[index]
                if character == "\"" {
                    inQuote.toggle()
                } else if !inQuote, character.isWhitespace || character == "," {
                    break
                }
                index = query.index(after: index)
            }

            let tokenText = String(query[start..<index])
            tokens.append(SearchToken(text: tokenText, range: start..<index))
        }

        return tokens
    }
}

private struct SearchToken {
    var text: String
    var range: Range<String.Index>
}
