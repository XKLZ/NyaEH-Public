// 本文件生成合集推荐，基于已物化元数据和标题结构缓存候选关系。

import Foundation

struct CollectionRecommendationService {
    private let bookRepository: LibraryBookRepository
    private let recommendationRepository: CollectionRecommendationRepository
    private let semanticVectorSearch: SemanticTitleVectorSearch?

    init(
        bookRepository: LibraryBookRepository,
        recommendationRepository: CollectionRecommendationRepository,
        semanticVectorSearch: SemanticTitleVectorSearch? = nil
    ) {
        self.bookRepository = bookRepository
        self.recommendationRepository = recommendationRepository
        self.semanticVectorSearch = semanticVectorSearch
    }

    func refreshRecommendations(
        focusBookIDs: Set<LibraryBook.DatabaseID> = [],
        semanticConfiguration: SemanticSeriesConfiguration = .disabled,
        progress: (@Sendable (CollectionRecommendationRefreshProgress) -> Void)? = nil,
        progressPhases: CollectionRecommendationRefreshProgressPhases = .default
    ) throws {
        progress?(CollectionRecommendationRefreshProgress(phase: progressPhases.readingLibrary, fractionCompleted: 0.05))
        let books = try bookRepository.fetchAll()
        progress?(CollectionRecommendationRefreshProgress(phase: progressPhases.parsingTitles, fractionCompleted: 0.25))
        let features = books.compactMap {
            CollectionBookFeature(book: $0, requiresCorrectStatus: !focusBookIDs.isEmpty)
        }
        let semanticAnalysis = makeSemanticAnalysis(
            features: features,
            configuration: semanticConfiguration
        )
        progress?(CollectionRecommendationRefreshProgress(phase: progressPhases.computingCandidates, fractionCompleted: 0.55))
        let addCandidates = makeAddToCollectionCandidates(
            features: features,
            semanticAnalysis: semanticAnalysis,
            semanticConfiguration: semanticConfiguration,
            affectedBookIDs: focusBookIDs
        )
        let addCandidateBookIDs = Set(addCandidates.flatMap(\.bookIDs))
        let rawCreateCandidates = makeCreateCollectionCandidates(
            features: features,
            semanticAnalysis: semanticAnalysis,
            semanticConfiguration: semanticConfiguration,
            excludingBookIDs: addCandidateBookIDs,
            requiringAnyBookID: focusBookIDs
        )
        let createCandidates = try suppressDismissedCreateOverlaps(
            rawCreateCandidates,
            features: features
        )
        let candidates = createCandidates + addCandidates
        progress?(CollectionRecommendationRefreshProgress(phase: progressPhases.writingCache, fractionCompleted: 0.85))
        try recommendationRepository.replacePending(with: candidates)
        progress?(CollectionRecommendationRefreshProgress(phase: progressPhases.completed, fractionCompleted: 1))
    }

    @discardableResult
    func updateRecommendationsIncrementally(
        focusBookIDs: Set<LibraryBook.DatabaseID> = [],
        semanticConfiguration: SemanticSeriesConfiguration = .disabled,
        progress: (@Sendable (CollectionRecommendationRefreshProgress) -> Void)? = nil,
        progressPhases: CollectionRecommendationRefreshProgressPhases = .default
    ) throws -> Bool {
        guard let completedAt = try recommendationRepository.latestRefreshCompletedAt() else {
            try refreshRecommendations(
                focusBookIDs: focusBookIDs,
                semanticConfiguration: semanticConfiguration,
                progress: progress,
                progressPhases: progressPhases
            )
            return true
        }

        progress?(CollectionRecommendationRefreshProgress(phase: progressPhases.readingLibrary, fractionCompleted: 0.05))
        let books = try bookRepository.fetchAll()
        progress?(CollectionRecommendationRefreshProgress(phase: progressPhases.parsingTitles, fractionCompleted: 0.25))
        let features = books.compactMap {
            CollectionBookFeature(book: $0, requiresCorrectStatus: !focusBookIDs.isEmpty)
        }
        let affectedBookIDs = focusBookIDs.isEmpty
            ? Set<LibraryBook.DatabaseID>(features.filter { $0.book.updatedAt > completedAt }.map(\.id))
            : focusBookIDs.intersection(features.map(\.id))
        let affectedCollectionIDs = Set<BookCollection.DatabaseID>(features.compactMap { feature in
            affectedBookIDs.contains(feature.id) ? feature.book.collectionID : nil
        })
        guard !affectedBookIDs.isEmpty || !affectedCollectionIDs.isEmpty else {
            progress?(CollectionRecommendationRefreshProgress(phase: progressPhases.completed, fractionCompleted: 1))
            return false
        }

        let semanticAnalysis = makeSemanticAnalysis(
            features: features,
            configuration: semanticConfiguration,
            focusBookIDs: affectedBookIDs
        )
        progress?(CollectionRecommendationRefreshProgress(phase: progressPhases.computingCandidates, fractionCompleted: 0.55))
        let addCandidates = makeAddToCollectionCandidates(
            features: features,
            semanticAnalysis: semanticAnalysis,
            semanticConfiguration: semanticConfiguration,
            affectedBookIDs: affectedBookIDs,
            affectedCollectionIDs: affectedCollectionIDs
        )
        let addCandidateBookIDs = Set<LibraryBook.DatabaseID>(addCandidates.flatMap(\.bookIDs))
        let rawCreateCandidates = makeCreateCollectionCandidates(
            features: features,
            semanticAnalysis: semanticAnalysis,
            semanticConfiguration: semanticConfiguration,
            excludingBookIDs: addCandidateBookIDs,
            requiringAnyBookID: affectedBookIDs
        )
        let createCandidates = try suppressDismissedCreateOverlaps(
            rawCreateCandidates,
            features: features
        )
        progress?(CollectionRecommendationRefreshProgress(phase: progressPhases.writingCache, fractionCompleted: 0.85))
        try recommendationRepository.mergePendingIncremental(
            with: createCandidates + addCandidates,
            affectedBookIDs: affectedBookIDs,
            affectedCollectionIDs: affectedCollectionIDs
        )
        progress?(CollectionRecommendationRefreshProgress(phase: progressPhases.completed, fractionCompleted: 1))
        return true
    }

    func pendingCreateCollectionRecommendations() throws -> [CollectionRecommendationDisplayItem] {
        try displayItems(
            for: recommendationRepository.fetchPending(kind: .createCollection, targetCollectionID: nil)
        )
    }

    func pendingAddToCollectionRecommendations(
        collectionID: BookCollection.DatabaseID
    ) throws -> [CollectionRecommendationDisplayItem] {
        try displayItems(
            for: recommendationRepository.fetchPending(kind: .addToCollection, targetCollectionID: collectionID)
        )
    }

    func pendingAddToCollectionCounts() throws -> [BookCollection.DatabaseID: Int] {
        try recommendationRepository.fetchPendingAddToCollectionCounts()
    }

    func latestRefreshCompletedAt() throws -> Int64? {
        try recommendationRepository.latestRefreshCompletedAt()
    }

    /// Uses the exact production feature and mutual-neighbor path so offline
    /// calibration never drifts into a second, simplified implementation.
    func semanticEdgeDiagnostics(
        configuration: SemanticSeriesConfiguration = .diagnostic
    ) throws -> [CollectionSemanticEdgeDiagnostic] {
        let features = try bookRepository.fetchAll().compactMap {
            CollectionBookFeature(book: $0)
        }
        return makeSemanticAnalysis(features: features, configuration: configuration).diagnostics
    }

    func recommendationFeatures() throws -> [CollectionBookFeature] {
        try bookRepository.fetchAll().compactMap {
            CollectionBookFeature(book: $0)
        }
    }

    func markAccepted(_ recommendation: CollectionRecommendation) throws {
        guard let recommendationID = recommendation.databaseID else {
            throw NyaEHError.groupingRepositoryUnavailable
        }
        try recommendationRepository.updateStatus(recommendationID: recommendationID, status: .accepted)
    }

    func dismiss(_ recommendation: CollectionRecommendation) throws {
        guard let recommendationID = recommendation.databaseID else {
            throw NyaEHError.groupingRepositoryUnavailable
        }
        try recommendationRepository.updateStatus(recommendationID: recommendationID, status: .dismissed)
    }

    private func displayItems(
        for recommendations: [CollectionRecommendation]
    ) throws -> [CollectionRecommendationDisplayItem] {
        try recommendations.compactMap { recommendation in
            guard let recommendationID = recommendation.databaseID else {
                return nil
            }
            let books = try recommendationRepository.fetchMemberBookIDs(recommendationID: recommendationID)
                .compactMap { try bookRepository.fetch(id: $0) }
            guard !books.isEmpty else {
                return nil
            }
            return CollectionRecommendationDisplayItem(recommendation: recommendation, books: books)
        }
    }

    private func makeCreateCollectionCandidates(
        features: [CollectionBookFeature],
        semanticAnalysis: CollectionSemanticAnalysis,
        semanticConfiguration: SemanticSeriesConfiguration,
        excludingBookIDs: Set<LibraryBook.DatabaseID> = [],
        requiringAnyBookID requiredBookIDs: Set<LibraryBook.DatabaseID> = []
    ) -> [CollectionRecommendationCandidate] {
        let uncollected = features.filter { $0.book.collectionID == nil && !excludingBookIDs.contains($0.id) }
        let featureByID = Dictionary(uniqueKeysWithValues: uncollected.map { ($0.id, $0) })
        let explicitlyNumbered = uncollected.filter(\.hasExplicitOrdinal)
        var pairs = candidatePairs(features: explicitlyNumbered)
        for pair in semanticAnalysis.distances.keys
            where featureByID[pair.lhs]?.hasExplicitOrdinal == true
                && featureByID[pair.rhs]?.hasExplicitOrdinal == true {
            pairs.insert(pair)
        }
        var pairMatches: [CollectionPairMatch] = []
        for pair in pairs {
            guard let lhs = featureByID[pair.lhs],
                  let rhs = featureByID[pair.rhs],
                  let match = match(
                    lhs,
                    rhs,
                    semanticDistance: semanticAnalysis.distances[pair],
                    semanticConfiguration: semanticConfiguration
                  ) else {
                continue
            }
            pairMatches.append(CollectionPairMatch(lhs: pair.lhs, rhs: pair.rhs, result: match))
        }

        var parent = CollectionUnionFind(ids: explicitlyNumbered.map(\.id))
        for match in pairMatches where match.result.hasLexicalMatch {
            parent.union(match.lhs, match.rhs)
        }

        var groupsByRoot: [LibraryBook.DatabaseID: [LibraryBook.DatabaseID]] = [:]
        for id in explicitlyNumbered.map(\.id) {
            groupsByRoot[parent.root(id), default: []].append(id)
        }
        var clusters = groupsByRoot.values.map { $0.sorted() }
        let matchByPair = Dictionary(
            uniqueKeysWithValues: pairMatches.map {
                (CollectionBookPair($0.lhs, $0.rhs), $0.result)
            }
        )

        // Lexical components may be joined by semantic evidence, but only when every
        // cross-component pair is structurally compatible. This prevents a single
        // semantic bridge from transitively merging unrelated title families.
        while true {
            var selected: (left: Int, right: Int, score: Int)?
            for leftIndex in clusters.indices {
                for rightIndex in clusters.index(after: leftIndex)..<clusters.endIndex {
                    let crossPairs = clusters[leftIndex].flatMap { leftID in
                        clusters[rightIndex].map { rightID in
                            CollectionBookPair(leftID, rightID)
                        }
                    }
                    let semanticScores = crossPairs.compactMap { pair -> Int? in
                        guard let result = matchByPair[pair], result.hasSemanticMatch else {
                            return nil
                        }
                        return result.score
                    }
                    guard let bridgeScore = semanticScores.max(),
                          crossPairs.allSatisfy({ pair in
                              guard let lhs = featureByID[pair.lhs],
                                    let rhs = featureByID[pair.rhs] else {
                                  return false
                              }
                              return semanticCompatibility(lhs, rhs).isAccepted
                          }) else {
                        continue
                    }
                    if selected == nil || bridgeScore > selected!.score {
                        selected = (leftIndex, rightIndex, bridgeScore)
                    }
                }
            }
            guard let selected else { break }
            clusters[selected.left].append(contentsOf: clusters[selected.right])
            clusters[selected.left].sort()
            clusters.remove(at: selected.right)
        }

        clusters = attachImplicitFirstVolumes(
            to: clusters,
            candidates: uncollected.filter(\.isCleanUnnumbered),
            featureByID: featureByID,
            semanticAnalysis: semanticAnalysis,
            semanticConfiguration: semanticConfiguration
        )
        let orderedClusters = clusters.map {
            orderedBookIDs($0, featureByID: featureByID)
        }
        let ordinalUniqueClusters = orderedClusters
            .filter { $0.count >= 2 }
            .filter { ids in
                Set(ids.compactMap { featureByID[$0]?.effectiveOrdinalKey }).count == ids.count
            }
        return ordinalUniqueClusters
            .filter { ids in
                requiredBookIDs.isEmpty || !Set(ids).isDisjoint(with: requiredBookIDs)
            }
            .compactMap { ids in
                var relatedMatches: [CollectionMatchResult] = []
                var matchedPairs = 0
                for lhsIndex in ids.indices {
                    for rhsIndex in ids.index(after: lhsIndex)..<ids.endIndex {
                        guard let lhs = featureByID[ids[lhsIndex]],
                              let rhs = featureByID[ids[rhsIndex]] else {
                            continue
                        }
                        let pairDistance = semanticAnalysis.distances[CollectionBookPair(lhs.id, rhs.id)]
                        if let match = match(
                            lhs,
                            rhs,
                            semanticDistance: pairDistance,
                            semanticConfiguration: semanticConfiguration
                        ) ?? implicitFirstMatch(
                            lhs,
                            rhs,
                            semanticDistance: pairDistance,
                            semanticConfiguration: semanticConfiguration
                        ) {
                            matchedPairs += 1
                            relatedMatches.append(match)
                        }
                    }
                }
                guard matchedPairs >= ids.count - 1,
                      let lowestScore = relatedMatches.map(\.score).min(),
                      lowestScore >= 82 else {
                    return nil
                }
                let reasons = orderedReasons(relatedMatches.flatMap(\.reasons))
                return CollectionRecommendationCandidate(
                    kind: .createCollection,
                    targetCollectionID: nil,
                    bookIDs: ids,
                    score: lowestScore,
                    reasons: Array(reasons.prefix(5)),
                    fingerprint: "collection-create:\(ids.map(String.init).joined(separator: "."))"
                )
            }
            .sorted { $0.score > $1.score }
    }

    private func makeAddToCollectionCandidates(
        features: [CollectionBookFeature],
        semanticAnalysis: CollectionSemanticAnalysis,
        semanticConfiguration: SemanticSeriesConfiguration,
        affectedBookIDs: Set<LibraryBook.DatabaseID> = [],
        affectedCollectionIDs: Set<BookCollection.DatabaseID> = []
    ) -> [CollectionRecommendationCandidate] {
        let grouped = features.filter { $0.book.collectionID != nil }
        let uncollected = features.filter { $0.book.collectionID == nil }
        let collections = Dictionary(grouping: grouped, by: { $0.book.collectionID! })
        let collectionIndex = collectionTokenIndex(collections: collections)
        let featureByID = Dictionary(uniqueKeysWithValues: features.map { ($0.id, $0) })
        let semanticCollectionIndex = semanticCollectionIndex(
            distances: semanticAnalysis.distances,
            featureByID: featureByID
        )

        var candidates: [RankedAddToCollectionCandidate] = []
        for book in uncollected {
            let possibleCollectionIDs = Set(book.bucketTokens.flatMap { collectionIndex[$0] ?? [] })
                .union(semanticCollectionIndex[book.id] ?? [])
            for collectionID in possibleCollectionIDs {
                if !affectedBookIDs.isEmpty || !affectedCollectionIDs.isEmpty {
                    guard affectedBookIDs.contains(book.id) || affectedCollectionIDs.contains(collectionID) else {
                        continue
                    }
                }
                guard let members = collections[collectionID] else {
                    continue
                }
                let selectedMatches: [CollectionMatchResult]
                let supportCount: Int
                if book.isCleanUnnumbered {
                    guard implicitFirstQualification(
                        book,
                        numberedMemberIDs: members.map(\.id),
                        featureByID: featureByID,
                        semanticAnalysis: semanticAnalysis,
                        semanticConfiguration: semanticConfiguration
                    ) else {
                        continue
                    }
                    let implicitMatches = members.compactMap { member -> (CollectionBookFeature, CollectionMatchResult)? in
                        guard let result = implicitFirstMatch(
                            book,
                            member,
                            semanticDistance: semanticAnalysis.distances[CollectionBookPair(book.id, member.id)],
                            semanticConfiguration: semanticConfiguration
                        ) else {
                            return nil
                        }
                        return (member, result)
                    }
                    if let second = implicitMatches.first(where: { $0.0.ordinalKey == "2" }) {
                        selectedMatches = [second.1]
                    } else {
                        selectedMatches = Array(
                            implicitMatches
                                .map(\.1)
                                .sorted { $0.score > $1.score }
                                .prefix(2)
                        )
                    }
                    supportCount = implicitMatches.count
                } else {
                    if let ordinalKey = book.ordinalKey,
                       members.contains(where: { $0.ordinalKey == ordinalKey }) {
                        continue
                    }
                    let matches = members.compactMap {
                        match(
                            book,
                            $0,
                            semanticDistance: semanticAnalysis.distances[CollectionBookPair(book.id, $0.id)],
                            semanticConfiguration: semanticConfiguration
                        )
                    }
                    let lexicalMatches = matches.filter(\.hasLexicalMatch)
                    let semanticMatches = matches
                        .filter { $0.hasSemanticMatch && !$0.hasLexicalMatch }
                        .sorted { $0.score > $1.score }
                    supportCount = matches.count
                    if let lexicalBest = lexicalMatches.max(by: { $0.score < $1.score }) {
                        selectedMatches = [lexicalBest]
                    } else if members.count == 1,
                              let semanticBest = semanticMatches.first,
                              semanticBest.hasSameNumberingFamily {
                        selectedMatches = [semanticBest]
                    } else if semanticMatches.count >= 2 {
                        selectedMatches = Array(semanticMatches.prefix(2))
                    } else {
                        let unnumberedMembers = members.filter(\.isCleanUnnumbered)
                        let numberedMembers = members.filter(\.hasExplicitOrdinal)
                        guard book.ordinalKey == "2",
                              numberedMembers.isEmpty,
                              unnumberedMembers.count == 1,
                              let implicitMatch = implicitFirstMatch(
                                unnumberedMembers[0],
                                book,
                                semanticDistance: semanticAnalysis.distances[
                                    CollectionBookPair(unnumberedMembers[0].id, book.id)
                                ],
                                semanticConfiguration: semanticConfiguration
                              ) else {
                            continue
                        }
                        selectedMatches = [implicitMatch]
                    }
                }
                guard let score = selectedMatches.map(\.score).min() else {
                    continue
                }
                let reasons = orderedReasons(selectedMatches.flatMap(\.reasons))
                let hasLexicalEvidence = selectedMatches.contains(where: \.hasLexicalMatch)
                let hasSemanticEvidence = selectedMatches.contains(where: \.hasSemanticMatch)
                let evidenceTier: Int
                if hasLexicalEvidence && hasSemanticEvidence {
                    evidenceTier = 3
                } else if hasLexicalEvidence {
                    evidenceTier = 2
                } else {
                    evidenceTier = 1
                }
                let minimumSemanticDistance = members.compactMap {
                    semanticAnalysis.distances[CollectionBookPair(book.id, $0.id)]
                }.min()
                candidates.append(
                    RankedAddToCollectionCandidate(
                        candidate: CollectionRecommendationCandidate(
                            kind: .addToCollection,
                            targetCollectionID: collectionID,
                            bookIDs: [book.id],
                            score: score,
                            reasons: Array(reasons.prefix(5)),
                            fingerprint: "collection-add:\(collectionID):\(book.id)"
                        ),
                        rank: CollectionAddTargetRank(
                            score: score,
                            evidenceTier: evidenceTier,
                            supportCount: supportCount,
                            minimumSemanticDistance: minimumSemanticDistance
                        )
                    )
                )
            }
        }

        let uniqueTargets = Dictionary(grouping: candidates, by: { $0.candidate.bookIDs[0] })
            .values
            .compactMap { matches -> CollectionRecommendationCandidate? in
                let ordered = matches.sorted { lhs, rhs in
                    lhs.rank.isBetter(than: rhs.rank)
                }
                guard let best = ordered.first else {
                    return nil
                }
                if ordered.count > 1, best.rank == ordered[1].rank {
                    return nil
                }
                return best.candidate
            }

        return uniqueTargets.sorted { lhs, rhs in
            if lhs.targetCollectionID == rhs.targetCollectionID {
                return lhs.score > rhs.score
            }
            return (lhs.targetCollectionID ?? 0) < (rhs.targetCollectionID ?? 0)
        }
    }

    private func suppressDismissedCreateOverlaps(
        _ candidates: [CollectionRecommendationCandidate],
        features: [CollectionBookFeature]
    ) throws -> [CollectionRecommendationCandidate] {
        let dismissed = try recommendationRepository.fetchDismissedCreateDecisions()
            .filter { !$0.bookIDs.isEmpty }
        guard !dismissed.isEmpty else {
            return candidates
        }
        let featureByID = Dictionary(uniqueKeysWithValues: features.map { ($0.id, $0) })
        return candidates.filter { candidate in
            let candidateIDs = Set(candidate.bookIDs)
            let overlapping = dismissed.filter { decision in
                let dismissedIDs = Set(decision.bookIDs)
                let denominator = min(candidateIDs.count, dismissedIDs.count)
                guard denominator > 0 else { return false }
                return Double(candidateIDs.intersection(dismissedIDs).count) / Double(denominator) >= 0.80
            }
            guard !overlapping.isEmpty else {
                return true
            }
            return overlapping.allSatisfy { decision in
                let previousIDs = Set(decision.bookIDs)
                let addedIDs = candidateIDs.subtracting(previousIDs)
                let addedExplicitOrdinal = addedIDs.contains {
                    featureByID[$0]?.hasExplicitOrdinal == true
                }
                let addedImplicitFirst = addedIDs.contains {
                    featureByID[$0]?.isCleanUnnumbered == true
                } && candidate.reasons.contains("implicitFirstVolume")
                let gainedImplicitEvidence = candidate.reasons.contains("implicitFirstVolume")
                    && !decision.recommendation.reasons.contains("implicitFirstVolume")
                let improvedScore = candidate.score >= decision.recommendation.score + 4
                return addedExplicitOrdinal
                    || addedImplicitFirst
                    || gainedImplicitEvidence
                    || improvedScore
            }
        }
    }

    private func candidatePairs(features: [CollectionBookFeature]) -> Set<CollectionBookPair> {
        let buckets = features.reduce(into: [String: [CollectionBookFeature]]()) { result, feature in
            for token in feature.bucketTokens {
                result[token, default: []].append(feature)
            }
        }

        var pairs = Set<CollectionBookPair>()
        for bucket in buckets.values {
            guard bucket.count >= 2, bucket.count <= Self.maximumBucketSize else {
                continue
            }
            for lhsIndex in bucket.indices {
                for rhsIndex in bucket.index(after: lhsIndex)..<bucket.endIndex {
                    pairs.insert(CollectionBookPair(bucket[lhsIndex].id, bucket[rhsIndex].id))
                }
            }
        }
        return pairs
    }

    private func attachImplicitFirstVolumes(
        to clusters: [[LibraryBook.DatabaseID]],
        candidates: [CollectionBookFeature],
        featureByID: [LibraryBook.DatabaseID: CollectionBookFeature],
        semanticAnalysis: CollectionSemanticAnalysis,
        semanticConfiguration: SemanticSeriesConfiguration
    ) -> [[LibraryBook.DatabaseID]] {
        guard !clusters.isEmpty, !candidates.isEmpty else {
            return clusters
        }

        var uniqueClusterByCandidate: [LibraryBook.DatabaseID: Int] = [:]
        for candidate in candidates {
            let eligibleClusters = clusters.indices.filter { clusterIndex in
                implicitFirstQualification(
                    candidate,
                    numberedMemberIDs: clusters[clusterIndex],
                    featureByID: featureByID,
                    semanticAnalysis: semanticAnalysis,
                    semanticConfiguration: semanticConfiguration
                )
            }
            if eligibleClusters.count == 1 {
                uniqueClusterByCandidate[candidate.id] = eligibleClusters[0]
            }
        }

        let candidatesByCluster = Dictionary(grouping: uniqueClusterByCandidate.keys) {
            uniqueClusterByCandidate[$0]!
        }
        var result = clusters
        for (clusterIndex, candidateIDs) in candidatesByCluster where candidateIDs.count == 1 {
            result[clusterIndex].append(candidateIDs[0])
        }
        return result
    }

    private func implicitFirstQualification(
        _ candidate: CollectionBookFeature,
        numberedMemberIDs: [LibraryBook.DatabaseID],
        featureByID: [LibraryBook.DatabaseID: CollectionBookFeature],
        semanticAnalysis: CollectionSemanticAnalysis,
        semanticConfiguration: SemanticSeriesConfiguration
    ) -> Bool {
        guard candidate.isCleanUnnumbered else {
            return false
        }
        let members = numberedMemberIDs.compactMap { featureByID[$0] }
        guard members.count == numberedMemberIDs.count,
              members.allSatisfy(\.hasExplicitOrdinal),
              !members.contains(where: { $0.ordinalKey == "1" }),
              members.allSatisfy({ $0.numberingFamily == nil }) else {
            return false
        }

        let supportedMembers = members.filter { member in
            implicitFirstMatch(
                candidate,
                member,
                semanticDistance: semanticAnalysis.distances[CollectionBookPair(candidate.id, member.id)],
                semanticConfiguration: semanticConfiguration
            ) != nil
        }
        if let secondVolume = members.first(where: { $0.ordinalKey == "2" }) {
            return supportedMembers.contains(where: { $0.id == secondVolume.id })
        }
        return supportedMembers.count >= 2
    }

    private func implicitFirstMatch(
        _ lhs: CollectionBookFeature,
        _ rhs: CollectionBookFeature,
        semanticDistance: Double?,
        semanticConfiguration: SemanticSeriesConfiguration
    ) -> CollectionMatchResult? {
        let implicit: CollectionBookFeature
        let explicit: CollectionBookFeature
        if lhs.isCleanUnnumbered, rhs.hasExplicitOrdinal {
            implicit = lhs
            explicit = rhs
        } else if rhs.isCleanUnnumbered, lhs.hasExplicitOrdinal {
            implicit = rhs
            explicit = lhs
        } else {
            return nil
        }
        guard explicit.ordinalKey != "1",
              explicit.numberingFamily == nil,
              !implicit.artistTags.isDisjoint(with: explicit.artistTags),
              !implicit.groupTags.isDisjoint(with: explicit.groupTags) else {
            return nil
        }
        if let leftCategory = implicit.category,
           let rightCategory = explicit.category,
           leftCategory != rightCategory {
            return nil
        }
        guard let lexicalEvidence = implicitFirstLexicalEvidence(implicit, explicit) else {
            return nil
        }

        let semanticCompatibility = semanticCompatibility(implicit, explicit)
        let hasSemanticMatch = semanticConfiguration.isEnabled
            && semanticCompatibility.isAccepted
            && semanticDistance.map { $0 <= semanticConfiguration.maximumSquaredDistance } == true
        var score = 82 + Int((14 * lexicalEvidence.strength).rounded())
        var reasons = ["seriesTitle", "implicitFirstVolume", "artist", "group"]
        if hasSemanticMatch {
            reasons.append("semanticTitle")
        }
        if implicit.category != nil && implicit.category == explicit.category {
            score += 4
            reasons.append("category")
        }
        if hasSemanticMatch, semanticCompatibility.crossesExplicitWorks {
            score -= 4
            reasons.append("crossWorkPublication")
        }
        return CollectionMatchResult(
            score: min(score, 96),
            reasons: orderedReasons(reasons),
            hasLexicalMatch: true,
            hasSemanticMatch: hasSemanticMatch,
            hasSameNumberingFamily: false
        )
    }

    private func implicitFirstLexicalEvidence(
        _ implicit: CollectionBookFeature,
        _ explicit: CollectionBookFeature
    ) -> SeriesImplicitFirstEvidence? {
        SeriesOrdinalResolver.implicitFirstEvidence(
            implicit.ordinalResolution,
            explicit.ordinalResolution
        )
    }

    private func collectionTokenIndex(
        collections: [BookCollection.DatabaseID: [CollectionBookFeature]]
    ) -> [String: [BookCollection.DatabaseID]] {
        collections.reduce(into: [String: [BookCollection.DatabaseID]]()) { result, entry in
            let tokens = Set(entry.value.flatMap(\.bucketTokens))
            for token in tokens {
                result[token, default: []].append(entry.key)
            }
        }
    }

    private func semanticCollectionIndex(
        distances: [CollectionBookPair: Double],
        featureByID: [LibraryBook.DatabaseID: CollectionBookFeature]
    ) -> [LibraryBook.DatabaseID: Set<BookCollection.DatabaseID>] {
        distances.reduce(into: [LibraryBook.DatabaseID: Set<BookCollection.DatabaseID>]()) { result, entry in
            guard let lhs = featureByID[entry.key.lhs],
                  let rhs = featureByID[entry.key.rhs] else {
                return
            }
            if lhs.book.collectionID == nil, let collectionID = rhs.book.collectionID {
                result[lhs.id, default: []].insert(collectionID)
            }
            if rhs.book.collectionID == nil, let collectionID = lhs.book.collectionID {
                result[rhs.id, default: []].insert(collectionID)
            }
        }
    }

    private func match(
        _ lhs: CollectionBookFeature,
        _ rhs: CollectionBookFeature,
        semanticDistance: Double?,
        semanticConfiguration: SemanticSeriesConfiguration
    ) -> CollectionMatchResult? {
        guard !lhs.artistTags.isDisjoint(with: rhs.artistTags),
              !lhs.groupTags.isDisjoint(with: rhs.groupTags) else {
            return nil
        }
        if let leftCategory = lhs.category,
           let rightCategory = rhs.category,
           leftCategory != rightCategory {
            return nil
        }
        guard let lhsOrdinalKey = lhs.ordinalKey,
              let rhsOrdinalKey = rhs.ordinalKey,
              lhsOrdinalKey != rhsOrdinalKey else {
            return nil
        }

        let stemScore = lhs.titleAnalyses.flatMap { left in
            rhs.titleAnalyses.map { right in
                titleSimilarity(left.seriesStem, right.seriesStem)
            }
        }.max() ?? 0
        let hasLexicalMatch = stemScore >= Self.minimumStemSimilarity
        let semanticCompatibility = semanticCompatibility(lhs, rhs)
        if semanticCompatibility.rejectionReason == "numbering_family_mismatch" {
            return nil
        }
        let hasSemanticMatch = semanticConfiguration.isEnabled
            && semanticCompatibility.isAccepted
            && semanticDistance.map { $0 <= semanticConfiguration.maximumSquaredDistance } == true
        guard hasLexicalMatch || hasSemanticMatch else {
            return nil
        }

        let lexicalStrength = min(max(
            (stemScore - Self.minimumStemSimilarity) / (1 - Self.minimumStemSimilarity),
            0
        ), 1)
        let semanticStrength = semanticDistance.map {
            min(max(1 - ($0 / max(semanticConfiguration.maximumSquaredDistance, 0.000_001)), 0), 1)
        } ?? 0
        let evidenceStrength = max(lexicalStrength, semanticStrength)
        var score = 82 + Int((14 * evidenceStrength).rounded())
        var reasons = ["artist", "group"]
        if hasLexicalMatch {
            reasons.append("seriesTitle")
        }
        if hasSemanticMatch {
            reasons.append("semanticTitle")
        }
        if lhs.category != nil && lhs.category == rhs.category {
            score += 4
            reasons.append("category")
        }
        if hasSemanticMatch, semanticCompatibility.crossesExplicitWorks {
            score -= 4
            reasons.append("crossWorkPublication")
        }
        score = min(score, 100)
        return CollectionMatchResult(
            score: score,
            reasons: orderedReasons(reasons),
            hasLexicalMatch: hasLexicalMatch,
            hasSemanticMatch: hasSemanticMatch,
            hasSameNumberingFamily: semanticCompatibility.hasSameNumberingFamily
        )
    }

    private func orderedBookIDs(
        _ ids: [LibraryBook.DatabaseID],
        featureByID: [LibraryBook.DatabaseID: CollectionBookFeature]
    ) -> [LibraryBook.DatabaseID] {
        ids.sorted { lhsID, rhsID in
            guard let lhs = featureByID[lhsID], let rhs = featureByID[rhsID] else {
                return lhsID < rhsID
            }
            if lhs.effectiveOrdinalSortValue != rhs.effectiveOrdinalSortValue {
                return lhs.effectiveOrdinalSortValue < rhs.effectiveOrdinalSortValue
            }
            return lhs.book.title.localizedStandardCompare(rhs.book.title) == .orderedAscending
        }
    }

    private func titleSimilarity(_ lhs: String, _ rhs: String) -> Double {
        SeriesOrdinalResolver.titleSimilarity(lhs, rhs)
    }

    private func orderedReasons(_ reasons: [String]) -> [String] {
        let order = [
            "seriesTitle",
            "semanticTitle",
            "implicitFirstVolume",
            "artist",
            "group",
            "category",
            "crossWorkPublication"
        ]
        let reasonSet = Set(reasons)
        return order.filter { reasonSet.contains($0) }
    }

    private func semanticCompatibility(
        _ lhs: CollectionBookFeature,
        _ rhs: CollectionBookFeature
    ) -> CollectionSemanticCompatibility {
        guard !lhs.artistTags.isDisjoint(with: rhs.artistTags),
              !lhs.groupTags.isDisjoint(with: rhs.groupTags) else {
            return .rejected("creator_mismatch")
        }
        if let leftCategory = lhs.category,
           let rightCategory = rhs.category,
           leftCategory != rightCategory {
            return .rejected("category_conflict")
        }
        let leftFamilies = Set([lhs.numberingFamily].compactMap { $0 })
        let rightFamilies = Set([rhs.numberingFamily].compactMap { $0 })
        switch (lhs.ordinalKey, rhs.ordinalKey) {
        case let (.some(leftOrdinal), .some(rightOrdinal)):
            guard leftOrdinal != rightOrdinal else {
                return .rejected("duplicate_ordinal")
            }
        case (.none, .none):
            return .rejected("missing_ordinal")
        case (.none, .some), (.some, .none):
            guard lhs.isCleanUnnumbered || rhs.isCleanUnnumbered,
                  leftFamilies.isEmpty,
                  rightFamilies.isEmpty else {
                return .rejected("implicit_first_ineligible")
            }
        }
        if !leftFamilies.isEmpty,
           !rightFamilies.isEmpty,
           leftFamilies.isDisjoint(with: rightFamilies) {
            return .rejected("numbering_family_mismatch")
        }
        let sharedFamily = leftFamilies.intersection(rightFamilies).sorted().first
        let anchor = sharedDistinctiveAnchor(lhs, rhs)
            ?? sharedFamily.flatMap { isDistinctiveAnchor($0, for: lhs, and: rhs) ? $0 : nil }
        guard let anchor else {
            return .rejected("missing_distinctive_anchor")
        }

        let leftWorks = explicitParodies(lhs.parodyTags)
        let rightWorks = explicitParodies(rhs.parodyTags)
        return CollectionSemanticCompatibility(
            isAccepted: true,
            rejectionReason: nil,
            titleAnchor: anchor,
            hasSameNumberingFamily: sharedFamily != nil,
            crossesExplicitWorks: !leftWorks.isEmpty
                && !rightWorks.isEmpty
                && leftWorks.isDisjoint(with: rightWorks)
        )
    }

    private func sharedDistinctiveAnchor(
        _ lhs: CollectionBookFeature,
        _ rhs: CollectionBookFeature
    ) -> String? {
        var best = ""
        for left in lhs.titleAnalyses {
            for right in rhs.titleAnalyses {
                let common = longestCommonSubstring(left.seriesStem, right.seriesStem)
                if common.count > best.count {
                    best = common
                }
            }
        }
        let normalized = best.trimmingCharacters(in: .whitespacesAndNewlines)
        return isDistinctiveAnchor(normalized, for: lhs, and: rhs) ? normalized : nil
    }

    private func isDistinctiveAnchor(
        _ anchor: String,
        for lhs: CollectionBookFeature,
        and rhs: CollectionBookFeature
    ) -> Bool {
        let compact = normalizedAnchorText(anchor)
        let containsNonASCII = compact.unicodeScalars.contains { $0.value > 127 }
        guard compact.count >= (containsNonASCII ? 3 : 4) else {
            return false
        }
        let metadataNames = lhs.artistTags
            .union(lhs.groupTags)
            .union(rhs.artistTags)
            .union(rhs.groupTags)
            .map(normalizedAnchorText)
        return !metadataNames.contains(compact)
    }

    private func normalizedAnchorText(_ value: String) -> String {
        value.precomposedStringWithCompatibilityMapping
            .folding(options: [.caseInsensitive, .widthInsensitive, .diacriticInsensitive], locale: nil)
            .lowercased()
            .replacingOccurrences(of: #"[\p{P}\p{S}\s]+"#, with: "", options: .regularExpression)
    }

    private func longestCommonSubstring(_ lhs: String, _ rhs: String) -> String {
        SeriesOrdinalResolver.longestCommonSubstring(lhs, rhs)
    }

    private func explicitParodies(_ values: Set<String>) -> Set<String> {
        Set(values.filter {
            !["original", "origin"].contains($0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
        })
    }

    private static let minimumStemSimilarity = 0.88
    private static let maximumBucketSize = 500
    private static let maximumSemanticBucketSize = 500

    private func makeSemanticAnalysis(
        features: [CollectionBookFeature],
        configuration: SemanticSeriesConfiguration,
        focusBookIDs: Set<LibraryBook.DatabaseID> = []
    ) -> CollectionSemanticAnalysis {
        guard configuration.isEnabled,
              configuration.mutualNeighborLimit > 0,
              configuration.maximumSquaredDistance > 0,
              let semanticVectorSearch,
              let activeProfile = try? semanticVectorSearch.activeProfile(),
              configuration.supports(activeProfile) else {
            return .empty
        }
        let indexedIDs = (try? semanticVectorSearch.indexedBookIDs()) ?? []
        let buckets = features.reduce(into: [String: [CollectionBookFeature]]()) { result, feature in
            for token in feature.metadataBucketTokens {
                result[token, default: []].append(feature)
            }
        }
        let featureByID = Dictionary(uniqueKeysWithValues: features.map { ($0.id, $0) })
        var distances: [CollectionBookPair: Double] = [:]
        var diagnosticsByPair: [CollectionBookPair: CollectionSemanticEdgeDiagnostic] = [:]
        for bucket in buckets.values {
            guard bucket.count >= 2, bucket.count <= Self.maximumSemanticBucketSize else {
                continue
            }
            let candidateIDs = Set(bucket.map(\.id)).intersection(indexedIDs)
            guard candidateIDs.count >= 2 else {
                continue
            }
            let queryIDs = focusBookIDs.isEmpty
                ? candidateIDs
                : candidateIDs.filter { focusBookIDs.contains($0) }
            var ranks: [LibraryBook.DatabaseID: [LibraryBook.DatabaseID: SemanticNeighborRank]] = [:]
            for bookID in queryIDs {
                guard let neighbors = try? semanticVectorSearch.nearestNeighbors(
                    bookID: bookID,
                    among: candidateIDs,
                    limit: configuration.mutualNeighborLimit
                ) else {
                    continue
                }
                for (offset, neighbor) in neighbors.enumerated() {
                    ranks[bookID, default: [:]][neighbor.bookID] = SemanticNeighborRank(
                        rank: offset + 1,
                        distance: neighbor.distance
                    )
                }
            }
            let neighborIDs = Set(ranks.values.flatMap(\.keys))
            for neighborID in neighborIDs where ranks[neighborID] == nil {
                guard let neighbors = try? semanticVectorSearch.nearestNeighbors(
                    bookID: neighborID,
                    among: candidateIDs,
                    limit: configuration.mutualNeighborLimit
                ) else {
                    continue
                }
                for (offset, neighbor) in neighbors.enumerated() {
                    ranks[neighborID, default: [:]][neighbor.bookID] = SemanticNeighborRank(
                        rank: offset + 1,
                        distance: neighbor.distance
                    )
                }
            }
            for (bookID, neighbors) in ranks {
                for (neighborID, rank) in neighbors {
                    guard let reverse = ranks[neighborID]?[bookID],
                          rank.rank <= configuration.mutualNeighborLimit,
                          reverse.rank <= configuration.mutualNeighborLimit else {
                        continue
                    }
                    if !focusBookIDs.isEmpty,
                       !focusBookIDs.contains(bookID),
                       !focusBookIDs.contains(neighborID) {
                        continue
                    }
                    let distance = min(rank.distance, reverse.distance)
                    guard distance <= configuration.maximumSquaredDistance else {
                        continue
                    }
                    let pair = CollectionBookPair(bookID, neighborID)
                    guard let lhs = featureByID[pair.lhs],
                          let rhs = featureByID[pair.rhs] else {
                        continue
                    }
                    let compatibility = semanticCompatibility(lhs, rhs)
                    let diagnostic = CollectionSemanticEdgeDiagnostic(
                        lhsBookID: pair.lhs,
                        rhsBookID: pair.rhs,
                        distance: distance,
                        lhsRank: pair.lhs == bookID ? rank.rank : reverse.rank,
                        rhsRank: pair.rhs == neighborID ? reverse.rank : rank.rank,
                        isAccepted: compatibility.isAccepted,
                        rejectionReason: compatibility.rejectionReason,
                        titleAnchor: compatibility.titleAnchor,
                        lhsOrdinalEvidence: lhs.ordinalEvidenceSummary,
                        rhsOrdinalEvidence: rhs.ordinalEvidenceSummary,
                        crossesExplicitWorks: compatibility.crossesExplicitWorks
                    )
                    if let existing = diagnosticsByPair[pair] {
                        if diagnostic.distance < existing.distance {
                            diagnosticsByPair[pair] = diagnostic
                        }
                    } else {
                        diagnosticsByPair[pair] = diagnostic
                    }
                    if compatibility.isAccepted {
                        distances[pair] = min(distances[pair] ?? distance, distance)
                    }
                }
            }
        }
        return CollectionSemanticAnalysis(
            distances: distances,
            diagnostics: diagnosticsByPair.values.sorted {
                if $0.distance == $1.distance {
                    return $0.fingerprint < $1.fingerprint
                }
                return $0.distance < $1.distance
            }
        )
    }
}

struct CollectionBookFeature: Sendable {
    var book: LibraryBook
    var id: LibraryBook.DatabaseID
    var ordinalResolution: SeriesOrdinalResolution
    var titleAnalyses: [SeriesTitleAnalysis]
    var titlePatterns: [SeriesTitlePattern]
    var ordinalKey: String?
    var ordinalSortValue: Int
    var numberingFamily: String?
    var category: String?
    var artistTags: Set<String>
    var groupTags: Set<String>
    var parodyTags: Set<String>
    var bucketTokens: Set<String>
    var metadataBucketTokens: Set<String>

    var hasExplicitOrdinal: Bool {
        ordinalKey != nil
    }

    var isCleanUnnumbered: Bool {
        ordinalKey == nil && titleAnalyses.allSatisfy(\.isCleanUnnumbered)
    }

    var effectiveOrdinalKey: String? {
        ordinalKey ?? (isCleanUnnumbered ? "1" : nil)
    }

    var effectiveOrdinalSortValue: Int {
        ordinalSortValue == Int.max && isCleanUnnumbered ? 1 : ordinalSortValue
    }

    init?(book: LibraryBook, requiresCorrectStatus: Bool = false) {
        guard let id = book.databaseID,
              book.exist,
              !requiresCorrectStatus || book.status == .correct,
              book.isPrimaryVersion,
              let ordinalResolution = SeriesOrdinalResolver.resolution(for: book),
              ordinalResolution.rejectionReason == nil else {
            return nil
        }
        let sourceTitles = [book.titleJpn, book.title].compactMap { $0 }
        let titleAnalyses = ordinalResolution.analyses
        let titlePatterns = sourceTitles.compactMap(SeriesTitlePattern.init(title:))
        let tags = Dictionary(grouping: TagParser.parseJSON(book.tags), by: \.namespace)
            .mapValues { Set($0.map(\.name)) }
        let artistTags = tags["artist"] ?? []
        let groupTags = tags["group"] ?? []
        guard !artistTags.isEmpty, !groupTags.isEmpty else {
            return nil
        }

        self.book = book
        self.id = id
        self.ordinalResolution = ordinalResolution
        self.titleAnalyses = titleAnalyses
        self.titlePatterns = titlePatterns
        ordinalKey = ordinalResolution.ordinalKey
        ordinalSortValue = ordinalResolution.ordinalSortValue
        numberingFamily = ordinalResolution.numberingFamily
        let normalizedCategory = book.category?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        category = normalizedCategory?.isEmpty == true ? nil : normalizedCategory
        self.artistTags = artistTags
        self.groupTags = groupTags
        parodyTags = tags["parody"] ?? []

        var tokens = Set<String>()
        var metadataTokens = Set<String>()
        for artist in artistTags {
            for group in groupTags {
                let metadataToken = "artist:\(artist)|group:\(group)"
                tokens.insert(metadataToken)
                metadataTokens.insert(metadataToken)
                for analysis in titleAnalyses {
                    tokens.insert("\(metadataToken)|stem-prefix:\(String(analysis.seriesStem.prefix(12)))")
                }
            }
        }
        bucketTokens = tokens
        metadataBucketTokens = metadataTokens
    }

    var ordinalEvidenceSummary: String {
        let explicit = titlePatterns.map { pattern in
            let family = pattern.numberingFamily.map { ":\($0)" } ?? ""
            return "\(pattern.ordinalEvidence.kind.rawValue)\(family)=\(pattern.ordinalKey)"
        }
        if !explicit.isEmpty {
            return explicit.joined(separator: " | ")
        }
        return isCleanUnnumbered ? "clean_unnumbered=1(inferred)" : "ambiguous"
    }

    func sharesCreator(with other: CollectionBookFeature) -> Bool {
        id != other.id
            && !artistTags.isDisjoint(with: other.artistTags)
            && !groupTags.isDisjoint(with: other.groupTags)
    }
}

private struct SemanticNeighborRank {
    var rank: Int
    var distance: Double
}

struct CollectionSemanticEdgeDiagnostic: Equatable, Sendable {
    var lhsBookID: LibraryBook.DatabaseID
    var rhsBookID: LibraryBook.DatabaseID
    var distance: Double
    var lhsRank: Int
    var rhsRank: Int
    var isAccepted: Bool
    var rejectionReason: String?
    var titleAnchor: String?
    var lhsOrdinalEvidence: String
    var rhsOrdinalEvidence: String
    var crossesExplicitWorks: Bool

    var fingerprint: String {
        "collection-edge:\(min(lhsBookID, rhsBookID)):\(max(lhsBookID, rhsBookID))"
    }
}

private struct CollectionSemanticCompatibility {
    var isAccepted: Bool
    var rejectionReason: String?
    var titleAnchor: String?
    var hasSameNumberingFamily: Bool
    var crossesExplicitWorks: Bool

    static func rejected(_ reason: String) -> CollectionSemanticCompatibility {
        CollectionSemanticCompatibility(
            isAccepted: false,
            rejectionReason: reason,
            titleAnchor: nil,
            hasSameNumberingFamily: false,
            crossesExplicitWorks: false
        )
    }
}

private struct CollectionSemanticAnalysis {
    var distances: [CollectionBookPair: Double]
    var diagnostics: [CollectionSemanticEdgeDiagnostic]

    static let empty = CollectionSemanticAnalysis(distances: [:], diagnostics: [])
}

struct CollectionBookPair: Hashable {
    var lhs: LibraryBook.DatabaseID
    var rhs: LibraryBook.DatabaseID

    init(_ lhs: LibraryBook.DatabaseID, _ rhs: LibraryBook.DatabaseID) {
        self.lhs = min(lhs, rhs)
        self.rhs = max(lhs, rhs)
    }
}

private struct CollectionPairMatch {
    var lhs: LibraryBook.DatabaseID
    var rhs: LibraryBook.DatabaseID
    var result: CollectionMatchResult
}

private struct RankedAddToCollectionCandidate {
    var candidate: CollectionRecommendationCandidate
    var rank: CollectionAddTargetRank
}

private struct CollectionAddTargetRank: Equatable {
    var score: Int
    var evidenceTier: Int
    var supportCount: Int
    var minimumSemanticDistance: Double?

    func isBetter(than other: CollectionAddTargetRank) -> Bool {
        if score != other.score {
            return score > other.score
        }
        if evidenceTier != other.evidenceTier {
            return evidenceTier > other.evidenceTier
        }
        if supportCount != other.supportCount {
            return supportCount > other.supportCount
        }
        switch (minimumSemanticDistance, other.minimumSemanticDistance) {
        case let (.some(lhs), .some(rhs)):
            return lhs < rhs
        case (.some, .none):
            return true
        case (.none, .some):
            return false
        case (.none, .none):
            return false
        }
    }
}

private struct CollectionMatchResult {
    var score: Int
    var reasons: [String]
    var hasLexicalMatch: Bool
    var hasSemanticMatch: Bool
    var hasSameNumberingFamily: Bool
}

private struct CollectionUnionFind {
    private var parents: [LibraryBook.DatabaseID: LibraryBook.DatabaseID]

    init(ids: [LibraryBook.DatabaseID]) {
        parents = Dictionary(uniqueKeysWithValues: ids.map { ($0, $0) })
    }

    mutating func root(_ id: LibraryBook.DatabaseID) -> LibraryBook.DatabaseID {
        let parent = parents[id] ?? id
        if parent == id {
            return id
        }
        let resolved = root(parent)
        parents[id] = resolved
        return resolved
    }

    mutating func union(_ lhs: LibraryBook.DatabaseID, _ rhs: LibraryBook.DatabaseID) {
        let leftRoot = root(lhs)
        let rightRoot = root(rhs)
        if leftRoot != rightRoot {
            parents[rightRoot] = leftRoot
        }
    }
}
