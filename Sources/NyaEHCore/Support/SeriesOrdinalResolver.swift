// 本文件集中解析系列成员顺序，供推荐和合集排序共享，避免 ordinal 规则漂移。

import Foundation

struct SeriesImplicitFirstEvidence: Equatable, Sendable {
    var strength: Double
    var anchor: String
}

struct SeriesOrdinalResolution: Equatable, Sendable {
    var analyses: [SeriesTitleAnalysis]
    var explicitEvidence: SeriesOrdinalEvidence?
    var numberingFamily: String?
    var rejectionReason: String?

    var ordinalKey: String? {
        explicitEvidence?.key
    }

    var ordinalSortValue: Int {
        explicitEvidence?.sortValue ?? Int.max
    }

    var isExplicit: Bool {
        explicitEvidence != nil
    }

    var isCleanUnnumbered: Bool {
        explicitEvidence == nil
            && rejectionReason == nil
            && !analyses.isEmpty
            && analyses.allSatisfy(\.isCleanUnnumbered)
    }

    init?(titleJpn: String?, title: String) {
        var sourceTitles: [String] = []
        for value in [titleJpn, title].compactMap({ $0 }) {
            let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !normalized.isEmpty, !sourceTitles.contains(normalized) else {
                continue
            }
            sourceTitles.append(normalized)
        }
        let analyses = sourceTitles.compactMap(SeriesTitleAnalysis.init(title:))
        guard !analyses.isEmpty else {
            return nil
        }
        self.analyses = analyses

        if let rejected = analyses.compactMap({ analysis -> String? in
            guard case .rejected(let reason) = analysis.ordinalState else {
                return nil
            }
            return reason
        }).first {
            explicitEvidence = nil
            numberingFamily = nil
            rejectionReason = rejected
            return
        }

        let evidence = analyses.compactMap(\.ordinalEvidence)
        let ordinalKeys = Set(evidence.map(\.key))
        let families = Set(evidence.compactMap(\.numberingFamily))
        guard ordinalKeys.count <= 1, families.count <= 1 else {
            explicitEvidence = nil
            numberingFamily = nil
            rejectionReason = "dual_title_conflict"
            return
        }

        explicitEvidence = evidence.min { lhs, rhs in
            lhs.sortValue < rhs.sortValue
        }
        numberingFamily = !evidence.isEmpty
            && evidence.allSatisfy({ $0.numberingFamily != nil })
            ? families.first
            : nil
        rejectionReason = nil
    }
}

struct SeriesCollectionSortPlan: Equatable, Sendable {
    var orderedPrimaryBookIDs: [LibraryBook.DatabaseID]
    var inferredFirstBookID: LibraryBook.DatabaseID?
}

enum SeriesOrdinalSortPolicy: Equatable, Sendable {
    /// Applies the strict implicit-first evidence gate used while inferring a series.
    case strictInference
    /// The user has already confirmed membership, so clean unnumbered books lead
    /// the explicit ordinal sequence without being labeled as inferred volume 1.
    case confirmedCollection
}

enum SeriesOrdinalResolver {
    static let minimumImplicitFirstStemSimilarity = 0.94
    static let minimumImplicitFirstCJKAnchorLength = 5
    static let minimumImplicitFirstLatinAnchorLength = 8
    static let minimumImplicitFirstAnchorCoverage = 0.65

    static func resolution(for book: LibraryBook) -> SeriesOrdinalResolution? {
        SeriesOrdinalResolution(titleJpn: book.titleJpn, title: book.title)
    }

    static func implicitFirstEvidence(
        _ implicit: SeriesOrdinalResolution,
        _ explicit: SeriesOrdinalResolution
    ) -> SeriesImplicitFirstEvidence? {
        guard implicit.isCleanUnnumbered,
              explicit.isExplicit,
              explicit.ordinalKey != "1",
              explicit.numberingFamily == nil else {
            return nil
        }

        var best: SeriesImplicitFirstEvidence?
        for left in implicit.analyses {
            for right in explicit.analyses {
                let similarity = titleSimilarity(left.seriesStem, right.seriesStem)
                if similarity >= minimumImplicitFirstStemSimilarity {
                    let normalized = min(max(
                        (similarity - minimumImplicitFirstStemSimilarity)
                            / (1 - minimumImplicitFirstStemSimilarity),
                        0
                    ), 1)
                    let evidence = SeriesImplicitFirstEvidence(
                        strength: max(similarity, normalized),
                        anchor: left.seriesStem.count <= right.seriesStem.count
                            ? left.semanticStem
                            : right.semanticStem
                    )
                    if best == nil || evidence.strength > best!.strength {
                        best = evidence
                    }
                    continue
                }

                let anchor = longestCommonSubstring(left.seriesStem, right.seriesStem)
                let containsNonASCII = anchor.unicodeScalars.contains { $0.value > 127 }
                let minimumLength = containsNonASCII
                    ? minimumImplicitFirstCJKAnchorLength
                    : minimumImplicitFirstLatinAnchorLength
                let shorterCount = min(left.seriesStem.count, right.seriesStem.count)
                guard shorterCount > 0, anchor.count >= minimumLength else {
                    continue
                }
                let coverage = Double(anchor.count) / Double(shorterCount)
                guard coverage >= minimumImplicitFirstAnchorCoverage else {
                    continue
                }
                let evidence = SeriesImplicitFirstEvidence(
                    strength: min(coverage, 1),
                    anchor: anchor
                )
                if best == nil || evidence.strength > best!.strength {
                    best = evidence
                }
            }
        }
        return best
    }

    static func sortPlan(
        for primaryBooks: [LibraryBook],
        policy: SeriesOrdinalSortPolicy = .strictInference
    ) -> SeriesCollectionSortPlan? {
        let entries = primaryBooks.enumerated().compactMap { index, book -> SortEntry? in
            guard let id = book.databaseID else {
                return nil
            }
            return SortEntry(index: index, bookID: id, resolution: resolution(for: book))
        }
        guard entries.count == primaryBooks.count else {
            return nil
        }

        let explicitEntries = entries.filter {
            $0.resolution?.isExplicit == true
                && $0.resolution?.ordinalSortValue != Int.max
        }
        let explicitFamilies = Set(explicitEntries.compactMap { $0.resolution?.numberingFamily })
        let hasOrdinaryExplicit = explicitEntries.contains {
            $0.resolution?.numberingFamily == nil
        }
        guard explicitFamilies.count <= 1,
              !(hasOrdinaryExplicit && !explicitFamilies.isEmpty) else {
            return nil
        }

        let cleanUnnumbered = entries.filter { $0.resolution?.isCleanUnnumbered == true }
        let inferredFirstBookID: LibraryBook.DatabaseID?
        switch policy {
        case .strictInference:
            var inferredBookID: LibraryBook.DatabaseID?
            if cleanUnnumbered.count == 1,
               !explicitEntries.isEmpty,
               explicitFamilies.isEmpty,
               !explicitEntries.contains(where: { $0.resolution?.ordinalKey == "1" }),
               let candidateResolution = cleanUnnumbered[0].resolution {
                let supported = explicitEntries.filter { entry in
                    guard let resolution = entry.resolution else { return false }
                    return implicitFirstEvidence(candidateResolution, resolution) != nil
                }
                if let volumeTwo = explicitEntries.first(where: {
                    $0.resolution?.ordinalKey == "2"
                }) {
                    if supported.contains(where: { $0.bookID == volumeTwo.bookID }) {
                        inferredBookID = cleanUnnumbered[0].bookID
                    }
                } else if Set(supported.compactMap { $0.resolution?.ordinalKey }).count >= 2 {
                    inferredBookID = cleanUnnumbered[0].bookID
                }
            }
            inferredFirstBookID = inferredBookID
        case .confirmedCollection:
            inferredFirstBookID = nil
        }

        let hasSortableStructure: Bool
        switch policy {
        case .strictInference:
            let sortableCount = explicitEntries.count + (inferredFirstBookID == nil ? 0 : 1)
            hasSortableStructure = sortableCount >= 2
        case .confirmedCollection:
            hasSortableStructure = entries.count >= 2
                && explicitEntries.count + cleanUnnumbered.count >= 1
        }
        guard hasSortableStructure else {
            return nil
        }

        let ordered = entries.sorted { lhs, rhs in
            let leftKey = sortKey(
                for: lhs,
                policy: policy,
                inferredFirstBookID: inferredFirstBookID
            )
            let rightKey = sortKey(
                for: rhs,
                policy: policy,
                inferredFirstBookID: inferredFirstBookID
            )
            if leftKey.group != rightKey.group {
                return leftKey.group < rightKey.group
            }
            if leftKey.ordinal != rightKey.ordinal {
                return leftKey.ordinal < rightKey.ordinal
            }
            return lhs.index < rhs.index
        }.map(\.bookID)

        return SeriesCollectionSortPlan(
            orderedPrimaryBookIDs: ordered,
            inferredFirstBookID: inferredFirstBookID
        )
    }

    static func titleSimilarity(_ lhs: String, _ rhs: String) -> Double {
        guard !lhs.isEmpty, !rhs.isEmpty else {
            return 0
        }
        if lhs == rhs {
            return 1
        }
        let distance = levenshteinDistance(Array(lhs), Array(rhs))
        let length = max(lhs.count, rhs.count)
        guard length > 0 else {
            return 0
        }
        return max(0, 1 - (Double(distance) / Double(length)))
    }

    static func longestCommonSubstring(_ lhs: String, _ rhs: String) -> String {
        let left = Array(lhs)
        let right = Array(rhs)
        guard !left.isEmpty, !right.isEmpty else { return "" }
        var previous = Array(repeating: 0, count: right.count + 1)
        var bestLength = 0
        var bestEnd = 0
        for leftIndex in left.indices {
            var current = Array(repeating: 0, count: right.count + 1)
            for rightIndex in right.indices where left[leftIndex] == right[rightIndex] {
                current[rightIndex + 1] = previous[rightIndex] + 1
                if current[rightIndex + 1] > bestLength {
                    bestLength = current[rightIndex + 1]
                    bestEnd = leftIndex + 1
                }
            }
            previous = current
        }
        guard bestLength > 0 else { return "" }
        return String(left[(bestEnd - bestLength)..<bestEnd])
    }

    private static func levenshteinDistance(_ lhs: [Character], _ rhs: [Character]) -> Int {
        if lhs.isEmpty { return rhs.count }
        if rhs.isEmpty { return lhs.count }

        var previous = Array(0...rhs.count)
        var current = Array(repeating: 0, count: rhs.count + 1)
        for lhsIndex in 1...lhs.count {
            current[0] = lhsIndex
            for rhsIndex in 1...rhs.count {
                let cost = lhs[lhsIndex - 1] == rhs[rhsIndex - 1] ? 0 : 1
                current[rhsIndex] = min(
                    previous[rhsIndex] + 1,
                    current[rhsIndex - 1] + 1,
                    previous[rhsIndex - 1] + cost
                )
            }
            swap(&previous, &current)
        }
        return previous[rhs.count]
    }

    private static func sortKey(
        for entry: SortEntry,
        policy: SeriesOrdinalSortPolicy,
        inferredFirstBookID: LibraryBook.DatabaseID?
    ) -> (group: Int, ordinal: Int) {
        switch policy {
        case .strictInference:
            if entry.bookID == inferredFirstBookID {
                return (0, 1)
            }
            if let value = entry.resolution?.ordinalSortValue, value != Int.max {
                return (0, value)
            }
            return (1, Int.max)
        case .confirmedCollection:
            if entry.resolution?.isCleanUnnumbered == true {
                return (0, 0)
            }
            if let value = entry.resolution?.ordinalSortValue, value != Int.max {
                return (1, value)
            }
            return (2, Int.max)
        }
    }

    private struct SortEntry {
        var index: Int
        var bookID: LibraryBook.DatabaseID
        var resolution: SeriesOrdinalResolution?
    }
}
