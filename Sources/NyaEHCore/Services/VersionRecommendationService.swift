// 本文件生成版本组推荐，组合标题/tag 规则和可选封面相似度，推荐在接受前不会改动书籍归组。

import Foundation

struct VersionRecommendationService {
    private let bookRepository: LibraryBookRepository
    private let recommendationRepository: VersionRecommendationRepository
    private let coverVectorSearch: CoverVectorSearch?

    init(
        bookRepository: LibraryBookRepository,
        recommendationRepository: VersionRecommendationRepository,
        coverVectorSearch: CoverVectorSearch? = nil
    ) {
        self.bookRepository = bookRepository
        self.recommendationRepository = recommendationRepository
        self.coverVectorSearch = coverVectorSearch
    }

    func refreshRecommendations(
        useCoverSimilarity: Bool = false,
        maximumCoverDistance: Double = Self.defaultCoverSimilarityMaximumDistance,
        focusBookIDs: Set<LibraryBook.DatabaseID> = [],
        progress: (@Sendable (VersionRecommendationRefreshProgress) -> Void)? = nil,
        progressPhases: VersionRecommendationRefreshProgressPhases = .default
    ) throws {
        // 这里只重建“建议缓存”。是否真正创建/加入版本组，必须等用户在服务层接受推荐后再事务化写入。
        progress?(VersionRecommendationRefreshProgress(phase: progressPhases.readingLibrary, fractionCompleted: 0.05))
        let books = try bookRepository.fetchAll()
        let features = books.compactMap { BookFeature(book: $0, requiresCorrectStatus: !focusBookIDs.isEmpty) }
        progress?(VersionRecommendationRefreshProgress(phase: progressPhases.readingCoverVectors, fractionCompleted: 0.25))
        let coverAnalysis = useCoverSimilarity
            ? coverAnalysis(features: features, maximumCoverDistance: maximumCoverDistance)
            : .empty
        // 封面相似度开启时作为优先门槛；缺少向量时退回标题和 tag 规则，保证缓存可渐进生成。
        progress?(VersionRecommendationRefreshProgress(phase: progressPhases.computingCandidates, fractionCompleted: 0.55))
        let candidates = makeCreateGroupCandidates(
            features: features,
            coverAnalysis: coverAnalysis,
            maximumCoverDistance: maximumCoverDistance,
            requiringAnyBookID: focusBookIDs
        )
            + makeAddToGroupCandidates(
                features: features,
                coverAnalysis: coverAnalysis,
                maximumCoverDistance: maximumCoverDistance,
                affectedBookIDs: focusBookIDs
            )
        progress?(VersionRecommendationRefreshProgress(phase: progressPhases.writingCache, fractionCompleted: 0.85))
        try recommendationRepository.replacePending(with: candidates)
        progress?(VersionRecommendationRefreshProgress(phase: progressPhases.completed, fractionCompleted: 1))
    }

    @discardableResult
    func updateRecommendationsIncrementally(
        useCoverSimilarity: Bool = false,
        maximumCoverDistance: Double = Self.defaultCoverSimilarityMaximumDistance,
        focusBookIDs: Set<LibraryBook.DatabaseID> = [],
        progress: (@Sendable (VersionRecommendationRefreshProgress) -> Void)? = nil,
        progressPhases: VersionRecommendationRefreshProgressPhases = .default
    ) throws -> Bool {
        guard let completedAt = try recommendationRepository.latestRefreshCompletedAt() else {
            try refreshRecommendations(
                useCoverSimilarity: useCoverSimilarity,
                maximumCoverDistance: maximumCoverDistance,
                focusBookIDs: focusBookIDs,
                progress: progress,
                progressPhases: progressPhases
            )
            return true
        }

        progress?(VersionRecommendationRefreshProgress(phase: progressPhases.readingLibrary, fractionCompleted: 0.05))
        let books = try bookRepository.fetchAll()
        let features = books.compactMap { BookFeature(book: $0, requiresCorrectStatus: !focusBookIDs.isEmpty) }
        let affectedBookIDs = focusBookIDs.isEmpty
            ? Set<LibraryBook.DatabaseID>(features.filter { $0.book.updatedAt > completedAt }.map(\.id))
            : focusBookIDs.intersection(features.map(\.id))
        let affectedVersionGroupIDs = Set<BookVersionGroup.DatabaseID>(features.compactMap { feature in
            affectedBookIDs.contains(feature.id) ? feature.book.versionGroupID : nil
        })
        guard !affectedBookIDs.isEmpty || !affectedVersionGroupIDs.isEmpty else {
            progress?(VersionRecommendationRefreshProgress(phase: progressPhases.completed, fractionCompleted: 1))
            return false
        }

        progress?(VersionRecommendationRefreshProgress(phase: progressPhases.readingCoverVectors, fractionCompleted: 0.25))
        let affectedGroupMemberIDs = Set<LibraryBook.DatabaseID>(features.compactMap { feature in
            guard let groupID = feature.book.versionGroupID,
                  affectedVersionGroupIDs.contains(groupID) else {
                return nil
            }
            return feature.id
        })
        let coverFocusBookIDs = affectedBookIDs.union(affectedGroupMemberIDs)
        let coverAnalysis = useCoverSimilarity
            ? coverAnalysis(
                features: features,
                maximumCoverDistance: maximumCoverDistance,
                focusBookIDs: coverFocusBookIDs
            )
            : .empty
        progress?(VersionRecommendationRefreshProgress(phase: progressPhases.computingCandidates, fractionCompleted: 0.55))
        let addCandidates = makeAddToGroupCandidates(
            features: features,
            coverAnalysis: coverAnalysis,
            maximumCoverDistance: maximumCoverDistance,
            affectedBookIDs: affectedBookIDs,
            affectedVersionGroupIDs: affectedVersionGroupIDs
        )
        let addCandidateBookIDs = Set<LibraryBook.DatabaseID>(addCandidates.flatMap(\.bookIDs))
        let createCandidates = makeCreateGroupCandidates(
            features: features,
            coverAnalysis: coverAnalysis,
            maximumCoverDistance: maximumCoverDistance,
            excludingBookIDs: addCandidateBookIDs,
            requiringAnyBookID: affectedBookIDs
        )
        progress?(VersionRecommendationRefreshProgress(phase: progressPhases.writingCache, fractionCompleted: 0.85))
        try recommendationRepository.mergePendingIncremental(
            with: createCandidates + addCandidates,
            affectedBookIDs: affectedBookIDs,
            affectedVersionGroupIDs: affectedVersionGroupIDs
        )
        progress?(VersionRecommendationRefreshProgress(phase: progressPhases.completed, fractionCompleted: 1))
        return true
    }

    func pendingCreateGroupRecommendations() throws -> [VersionRecommendationDisplayItem] {
        try displayItems(
            for: recommendationRepository.fetchPending(kind: .createGroup, targetVersionGroupID: nil)
        )
    }

    func pendingAddToGroupRecommendations(
        groupID: BookVersionGroup.DatabaseID
    ) throws -> [VersionRecommendationDisplayItem] {
        try displayItems(
            for: recommendationRepository.fetchPending(kind: .addToGroup, targetVersionGroupID: groupID)
        )
    }

    func pendingAddToGroupCounts() throws -> [BookVersionGroup.DatabaseID: Int] {
        try recommendationRepository.fetchPendingAddToGroupCounts()
    }

    func latestRefreshCompletedAt() throws -> Int64? {
        try recommendationRepository.latestRefreshCompletedAt()
    }

    func markAccepted(_ recommendation: VersionRecommendation) throws {
        guard let recommendationID = recommendation.databaseID else {
            throw NyaEHError.groupingRepositoryUnavailable
        }
        try recommendationRepository.updateStatus(recommendationID: recommendationID, status: .accepted)
    }

    func dismiss(_ recommendation: VersionRecommendation) throws {
        guard let recommendationID = recommendation.databaseID else {
            throw NyaEHError.groupingRepositoryUnavailable
        }
        try recommendationRepository.updateStatus(recommendationID: recommendationID, status: .dismissed)
    }

    private func displayItems(
        for recommendations: [VersionRecommendation]
    ) throws -> [VersionRecommendationDisplayItem] {
        try recommendations.compactMap { recommendation in
            guard let recommendationID = recommendation.databaseID else {
                return nil
            }
            let books = try recommendationRepository.fetchMemberBookIDs(recommendationID: recommendationID)
                .compactMap { try bookRepository.fetch(id: $0) }
            guard !books.isEmpty else {
                return nil
            }
            return VersionRecommendationDisplayItem(recommendation: recommendation, books: books)
        }
    }

    private func makeCreateGroupCandidates(
        features: [BookFeature],
        coverAnalysis: CoverAnalysis,
        maximumCoverDistance: Double,
        excludingBookIDs: Set<LibraryBook.DatabaseID> = [],
        requiringAnyBookID requiredBookIDs: Set<LibraryBook.DatabaseID> = []
    ) -> [VersionRecommendationCandidate] {
        let ungrouped = features.filter { $0.book.versionGroupID == nil && !excludingBookIDs.contains($0.id) }
        let featureByID = Dictionary(uniqueKeysWithValues: ungrouped.map { ($0.id, $0) })
        var candidatePairs = candidateBookPairs(features: ungrouped)
        for pair in coverAnalysis.distances.keys {
            if featureByID[pair.lhs] != nil, featureByID[pair.rhs] != nil {
                candidatePairs.insert(pair)
            }
        }

        var pairMatches: [PairMatch] = []
        for pair in candidatePairs {
            guard let lhs = featureByID[pair.lhs],
                  let rhs = featureByID[pair.rhs],
                  let match = match(
                    lhs,
                    rhs,
                    strictness: .createGroup,
                    coverDistance: coverAnalysis.distances[BookPair(lhs.id, rhs.id)],
                    bothHaveCoverVectors: coverAnalysis.bothHaveVectors(lhs.id, rhs.id),
                    maximumCoverDistance: maximumCoverDistance
                  ) else {
                continue
            }
            pairMatches.append(PairMatch(lhs: pair.lhs, rhs: pair.rhs, score: match.score, reasons: match.reasons))
        }

        var parent = UnionFind(ids: ungrouped.map(\.id))
        for match in pairMatches {
            parent.union(match.lhs, match.rhs)
        }

        var groupsByRoot: [LibraryBook.DatabaseID: [LibraryBook.DatabaseID]] = [:]
        for id in ungrouped.map(\.id) {
            groupsByRoot[parent.root(id), default: []].append(id)
        }
        let groupedIDs = groupsByRoot.values
            .map { $0.sorted() }
            .filter { $0.count >= 2 }
            .filter { ids in
                requiredBookIDs.isEmpty || !Set(ids).isDisjoint(with: requiredBookIDs)
            }

        return groupedIDs.compactMap { ids in
            var relatedMatches: [MatchResult] = []
            for lhsIndex in ids.indices {
                for rhsIndex in ids.index(after: lhsIndex)..<ids.endIndex {
                    guard let lhs = featureByID[ids[lhsIndex]],
                          let rhs = featureByID[ids[rhsIndex]],
                          let match = match(
                            lhs,
                            rhs,
                            strictness: .createGroup,
                            coverDistance: coverAnalysis.distances[BookPair(lhs.id, rhs.id)],
                            bothHaveCoverVectors: coverAnalysis.bothHaveVectors(lhs.id, rhs.id),
                            maximumCoverDistance: maximumCoverDistance
                          ) else {
                        return nil
                    }
                    relatedMatches.append(match)
                }
            }
            guard let lowestScore = relatedMatches.map(\.score).min(), lowestScore >= 88 else {
                return nil
            }
            let reasons = orderedReasons(relatedMatches.flatMap(\.reasons))
            return VersionRecommendationCandidate(
                kind: .createGroup,
                targetVersionGroupID: nil,
                bookIDs: ids,
                score: lowestScore,
                reasons: Array(reasons.prefix(4)),
                fingerprint: "create:\(ids.map(String.init).joined(separator: "."))"
            )
        }
        .sorted { $0.score > $1.score }
    }

    private func makeAddToGroupCandidates(
        features: [BookFeature],
        coverAnalysis: CoverAnalysis,
        maximumCoverDistance: Double,
        affectedBookIDs: Set<LibraryBook.DatabaseID> = [],
        affectedVersionGroupIDs: Set<BookVersionGroup.DatabaseID> = []
    ) -> [VersionRecommendationCandidate] {
        let grouped = features.filter { $0.book.versionGroupID != nil }
        let ungrouped = features.filter { $0.book.versionGroupID == nil }
        let groups = Dictionary(grouping: grouped, by: { $0.book.versionGroupID! })
        let groupIndex = groupTokenIndex(groups: groups)
        let featureByID = Dictionary(uniqueKeysWithValues: features.map { ($0.id, $0) })
        let coverGroupIndex = coverGroupIndex(coverDistances: coverAnalysis.distances, featuresByID: featureByID)

        var candidates: [VersionRecommendationCandidate] = []
        for book in ungrouped {
            let possibleGroupIDs = Set(book.matchTokens.flatMap { groupIndex[$0] ?? [] })
                .union(coverGroupIndex[book.id] ?? [])
            for groupID in possibleGroupIDs {
                if !affectedBookIDs.isEmpty || !affectedVersionGroupIDs.isEmpty {
                    guard affectedBookIDs.contains(book.id) || affectedVersionGroupIDs.contains(groupID) else {
                        continue
                    }
                }
                guard let members = groups[groupID],
                      let best = members.compactMap({
                        match(
                            book,
                            $0,
                            strictness: .addToGroup,
                            coverDistance: coverAnalysis.distances[BookPair(book.id, $0.id)],
                            bothHaveCoverVectors: coverAnalysis.bothHaveVectors(book.id, $0.id),
                            maximumCoverDistance: maximumCoverDistance
                        )
                      }).max(by: { $0.score < $1.score }) else {
                    continue
                }
                candidates.append(
                    VersionRecommendationCandidate(
                        kind: .addToGroup,
                        targetVersionGroupID: groupID,
                        bookIDs: [book.id],
                        score: best.score,
                        reasons: Array(best.reasons.prefix(4)),
                        fingerprint: "add:\(groupID):\(book.id)"
                    )
                )
            }
        }

        return candidates.sorted { lhs, rhs in
            if lhs.targetVersionGroupID == rhs.targetVersionGroupID {
                return lhs.score > rhs.score
            }
            return (lhs.targetVersionGroupID ?? 0) < (rhs.targetVersionGroupID ?? 0)
        }
    }

    private func coverGroupIndex(
        coverDistances: [BookPair: Double],
        featuresByID: [LibraryBook.DatabaseID: BookFeature]
    ) -> [LibraryBook.DatabaseID: Set<BookVersionGroup.DatabaseID>] {
        coverDistances.reduce(into: [LibraryBook.DatabaseID: Set<BookVersionGroup.DatabaseID>]()) { result, entry in
            guard let lhs = featuresByID[entry.key.lhs],
                  let rhs = featuresByID[entry.key.rhs] else {
                return
            }
            if lhs.book.versionGroupID == nil, let groupID = rhs.book.versionGroupID {
                result[lhs.id, default: []].insert(groupID)
            }
            if rhs.book.versionGroupID == nil, let groupID = lhs.book.versionGroupID {
                result[rhs.id, default: []].insert(groupID)
            }
        }
    }

    private func candidateBookPairs(features: [BookFeature]) -> Set<BookPair> {
        let buckets = features.reduce(into: [String: [BookFeature]]()) { result, feature in
            for token in feature.matchTokens {
                result[token, default: []].append(feature)
            }
        }

        var pairs = Set<BookPair>()
        for bucket in buckets.values {
            guard bucket.count >= 2, bucket.count <= 400 else {
                continue
            }
            for lhsIndex in bucket.indices {
                for rhsIndex in bucket.index(after: lhsIndex)..<bucket.endIndex {
                    pairs.insert(BookPair(bucket[lhsIndex].id, bucket[rhsIndex].id))
                }
            }
        }
        return pairs
    }

    private func groupTokenIndex(groups: [BookVersionGroup.DatabaseID: [BookFeature]]) -> [String: [BookVersionGroup.DatabaseID]] {
        groups.reduce(into: [String: [BookVersionGroup.DatabaseID]]()) { result, entry in
            let tokens = Set(entry.value.flatMap(\.matchTokens))
            for token in tokens {
                result[token, default: []].append(entry.key)
            }
        }
    }

    private func coverAnalysis(
        features: [BookFeature],
        maximumCoverDistance: Double,
        focusBookIDs: Set<LibraryBook.DatabaseID>? = nil
    ) -> CoverAnalysis {
        guard let coverVectorSearch else {
            return .empty
        }
        let indexedIDs = (try? coverVectorSearch.indexedBookIDs()) ?? []
        let featureIDs = Set(features.map(\.id))
        let featuresByID = Dictionary(uniqueKeysWithValues: features.map { ($0.id, $0) })
        let initialQueryIDs = focusBookIDs.map { $0.intersection(featureIDs).intersection(indexedIDs) }
            ?? featureIDs.intersection(indexedIDs)
        var queryIDs = initialQueryIDs
        if focusBookIDs != nil {
            for bookID in initialQueryIDs {
                guard let neighbors = try? coverVectorSearch.nearestNeighbors(
                    bookID: bookID,
                    limit: Self.coverNearestNeighborRankLimit
                ) else {
                    continue
                }
                for neighbor in neighbors where featureIDs.contains(neighbor.bookID) && indexedIDs.contains(neighbor.bookID) {
                    queryIDs.insert(neighbor.bookID)
                }
            }
        }
        var ranks: [LibraryBook.DatabaseID: [LibraryBook.DatabaseID: CoverNeighborRank]] = [:]
        for bookID in queryIDs {
            guard featuresByID[bookID] != nil else {
                continue
            }
            guard let neighbors = try? coverVectorSearch.nearestNeighbors(
                bookID: bookID,
                limit: Self.coverNearestNeighborRankLimit
            ) else {
                continue
            }
            let sortedNeighbors = neighbors
                .filter { featureIDs.contains($0.bookID) }
                .sorted { $0.distance < $1.distance }
            for (offset, neighbor) in sortedNeighbors.prefix(Self.coverNearestNeighborRankLimit).enumerated() {
                ranks[bookID, default: [:]][neighbor.bookID] = CoverNeighborRank(
                    rank: offset + 1,
                    distance: neighbor.distance
                )
            }
        }

        var distances: [BookPair: Double] = [:]
        for (bookID, neighbors) in ranks {
            for (neighborID, rank) in neighbors {
                guard bookID < neighborID,
                      let reverseRank = ranks[neighborID]?[bookID] else {
                    continue
                }
                if let focusBookIDs, !focusBookIDs.contains(bookID), !focusBookIDs.contains(neighborID) {
                    continue
                }
                let distance = min(rank.distance, reverseRank.distance)
                guard distance <= maximumCoverDistance else {
                    continue
                }
                distances[BookPair(bookID, neighborID)] = distance
            }
        }
        return CoverAnalysis(indexedBookIDs: indexedIDs, distances: distances)
    }

    private func match(
        _ lhs: BookFeature,
        _ rhs: BookFeature,
        strictness: MatchStrictness,
        coverDistance: Double?,
        bothHaveCoverVectors: Bool,
        maximumCoverDistance: Double
    ) -> MatchResult? {
        if let leftCategory = lhs.category,
           let rightCategory = rhs.category,
           leftCategory != rightCategory {
            return nil
        }

        let titleScore = titleSimilarity(lhs.normalizedTitle, rhs.normalizedTitle)
        let sharedNamespaces = sharedMetadataNamespaces(lhs, rhs)
        let hasComparableTags = lhs.hasComparableMetadata && rhs.hasComparableMetadata
        let hasMetadataOverlap = !sharedNamespaces.isEmpty
        let hasCoverMatch = coverDistance.map { $0 <= maximumCoverDistance } ?? false

        if bothHaveCoverVectors {
            guard hasCoverMatch, let coverDistance else {
                return nil
            }
            let hasCoverSupport = coverDistance <= Self.nearDuplicateCoverDistance
                || titleScore >= Self.coverTitleSupportMinimumSimilarity
                || hasMetadataOverlap
            guard hasCoverSupport else {
                return nil
            }
            return coverFirstMatchResult(
                titleScore: titleScore,
                coverDistance: coverDistance,
                lhs: lhs,
                rhs: rhs,
                sharedNamespaces: sharedNamespaces,
                maximumCoverDistance: maximumCoverDistance
            )
        }

        let minimumTitleScore = strictness == .createGroup ? 0.88 : 0.9
        guard titleScore >= minimumTitleScore else {
            return nil
        }
        if hasComparableTags && !hasMetadataOverlap && titleScore < 0.96 {
            return nil
        }

        var score = Int((titleScore * 84).rounded())
        var reasons = ["title"]
        if lhs.category != nil && lhs.category == rhs.category {
            score += 8
            reasons.append("category")
        }
        for namespace in sharedNamespaces.sorted() {
            score += namespace == "artist" || namespace == "group" ? 10 : 6
            reasons.append(namespace)
        }
        score = min(score, 100)

        let minimumScore = strictness == .createGroup ? 88 : 90
        guard score >= minimumScore else {
            return nil
        }
        return MatchResult(score: score, reasons: orderedReasons(reasons))
    }

    private func coverFirstMatchResult(
        titleScore: Double,
        coverDistance: Double,
        lhs: BookFeature,
        rhs: BookFeature,
        sharedNamespaces: Set<String>,
        maximumCoverDistance: Double
    ) -> MatchResult {
        let normalizedDistance = min(max(coverDistance / maximumCoverDistance, 0), 1)
        var score = Int((98 - normalizedDistance * 8).rounded())
        var reasons = ["cover"]

        if titleScore >= Self.coverTitleSupportMinimumSimilarity {
            score += Int((titleScore * 4).rounded())
            reasons.append("title")
        }
        if lhs.category != nil && lhs.category == rhs.category {
            score += 3
            reasons.append("category")
        }
        for namespace in sharedNamespaces.sorted() {
            score += namespace == "artist" || namespace == "group" ? 4 : 2
            reasons.append(namespace)
        }

        return MatchResult(score: min(score, 100), reasons: orderedReasons(reasons))
    }

    private func sharedMetadataNamespaces(_ lhs: BookFeature, _ rhs: BookFeature) -> Set<String> {
        var shared = Set<String>()
        for namespace in BookFeature.metadataNamespaces {
            guard let left = lhs.tagsByNamespace[namespace],
                  let right = rhs.tagsByNamespace[namespace],
                  !left.isDisjoint(with: right) else {
                continue
            }
            shared.insert(namespace)
        }
        return shared
    }

    private func titleSimilarity(_ lhs: String, _ rhs: String) -> Double {
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

    private func levenshteinDistance(_ lhs: [Character], _ rhs: [Character]) -> Int {
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

    private func orderedReasons(_ reasons: [String]) -> [String] {
        let order = ["cover", "title", "category", "artist", "group", "parody", "character"]
        let reasonSet = Set(reasons)
        return order.filter { reasonSet.contains($0) }
    }

    static let defaultCoverSimilarityMaximumDistance = 20.0
    private static let nearDuplicateCoverDistance = 4.0
    private static let coverTitleSupportMinimumSimilarity = 0.45
    private static let coverNearestNeighborRankLimit = 3
}

private struct BookFeature: Sendable {
    static let metadataNamespaces = ["artist", "group", "parody", "character"]

    var book: LibraryBook
    var id: LibraryBook.DatabaseID
    var normalizedTitle: String
    var category: String?
    var tagsByNamespace: [String: Set<String>]
    var matchTokens: Set<String>

    var hasComparableMetadata: Bool {
        Self.metadataNamespaces.contains { !(tagsByNamespace[$0]?.isEmpty ?? true) }
    }

    init?(book: LibraryBook, requiresCorrectStatus: Bool = false) {
        guard let id = book.databaseID,
              book.exist,
              !requiresCorrectStatus || book.status == .correct else {
            return nil
        }
        let normalizedTitle = Self.normalizedTitle(book.titleJpn ?? book.title)
        guard !normalizedTitle.isEmpty else {
            return nil
        }

        self.book = book
        self.id = id
        self.normalizedTitle = normalizedTitle
        category = book.category?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .nilIfEmpty

        tagsByNamespace = Dictionary(grouping: TagParser.parseJSON(book.tags), by: \.namespace)
            .mapValues { Set($0.map(\.name)) }

        var tokens = Set<String>()
        tokens.insert("title:\(normalizedTitle)")
        tokens.insert("title-prefix:\(String(normalizedTitle.prefix(24)))")
        if let category {
            tokens.insert("category:\(category)")
        }
        for namespace in Self.metadataNamespaces {
            for tag in tagsByNamespace[namespace] ?? [] {
                tokens.insert("\(namespace):\(tag)")
            }
        }
        matchTokens = tokens
    }

    private static func normalizedTitle(_ title: String) -> String {
        BookTitleFormatter.compactTitle(title)
            .folding(options: [.caseInsensitive, .widthInsensitive, .diacriticInsensitive], locale: nil)
            .replacingOccurrences(of: #"[\p{P}\p{S}\s]+"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

}

private struct BookPair: Hashable {
    var lhs: LibraryBook.DatabaseID
    var rhs: LibraryBook.DatabaseID

    init(_ lhs: LibraryBook.DatabaseID, _ rhs: LibraryBook.DatabaseID) {
        self.lhs = min(lhs, rhs)
        self.rhs = max(lhs, rhs)
    }
}

private struct PairMatch {
    var lhs: LibraryBook.DatabaseID
    var rhs: LibraryBook.DatabaseID
    var score: Int
    var reasons: [String]
}

private struct MatchResult {
    var score: Int
    var reasons: [String]
}

private struct CoverNeighborRank {
    var rank: Int
    var distance: Double
}

private struct CoverAnalysis {
    var indexedBookIDs: Set<LibraryBook.DatabaseID>
    var distances: [BookPair: Double]

    static let empty = CoverAnalysis(indexedBookIDs: [], distances: [:])

    func bothHaveVectors(_ lhs: LibraryBook.DatabaseID, _ rhs: LibraryBook.DatabaseID) -> Bool {
        indexedBookIDs.contains(lhs) && indexedBookIDs.contains(rhs)
    }
}

private enum MatchStrictness {
    case createGroup
    case addToGroup
}

private struct UnionFind {
    private var parents: [LibraryBook.DatabaseID: LibraryBook.DatabaseID]

    init(ids: [LibraryBook.DatabaseID]) {
        parents = Dictionary(uniqueKeysWithValues: ids.map { ($0, $0) })
    }

    mutating func root(_ id: LibraryBook.DatabaseID) -> LibraryBook.DatabaseID {
        let parent = parents[id] ?? id
        if parent == id {
            return id
        }
        let rootID = root(parent)
        parents[id] = rootID
        return rootID
    }

    mutating func union(_ lhs: LibraryBook.DatabaseID, _ rhs: LibraryBook.DatabaseID) {
        let leftRoot = root(lhs)
        let rightRoot = root(rhs)
        guard leftRoot != rightRoot else {
            return
        }
        parents[rightRoot] = leftRoot
    }
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}
