// 本文件定义 CollectionRecommendation 领域模型，是数据库、服务层和 SwiftUI 视图之间传递业务状态的结构。

import Foundation

enum CollectionRecommendationKind: String, Codable, Sendable {
    case createCollection = "create_collection"
    case addToCollection = "add_to_collection"
}

enum CollectionRecommendationStatus: String, Codable, Sendable {
    case pending
    case accepted
    case dismissed
    case stale
}

struct CollectionRecommendation: Identifiable, Codable, Equatable, Sendable {
    typealias DatabaseID = Int64

    var databaseID: DatabaseID?
    var batchID: Int64?
    var kind: CollectionRecommendationKind
    var targetCollectionID: BookCollection.DatabaseID?
    var score: Int
    var reasons: [String]
    var fingerprint: String
    var status: CollectionRecommendationStatus
    var createdAt: Int64
    var updatedAt: Int64

    var id: String {
        databaseID.map(String.init) ?? fingerprint
    }

    init(
        databaseID: DatabaseID? = nil,
        batchID: Int64? = nil,
        kind: CollectionRecommendationKind,
        targetCollectionID: BookCollection.DatabaseID? = nil,
        score: Int,
        reasons: [String],
        fingerprint: String,
        status: CollectionRecommendationStatus = .pending,
        createdAt: Int64 = Timestamp.nowMilliseconds(),
        updatedAt: Int64 = Timestamp.nowMilliseconds()
    ) {
        self.databaseID = databaseID
        self.batchID = batchID
        self.kind = kind
        self.targetCollectionID = targetCollectionID
        self.score = score
        self.reasons = reasons
        self.fingerprint = fingerprint
        self.status = status
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

struct CollectionRecommendationCandidate: Equatable, Sendable {
    var kind: CollectionRecommendationKind
    var targetCollectionID: BookCollection.DatabaseID?
    var bookIDs: [LibraryBook.DatabaseID]
    var score: Int
    var reasons: [String]
    var fingerprint: String
}

struct CollectionRecommendationDecisionSnapshot: Equatable, Sendable {
    var recommendation: CollectionRecommendation
    var bookIDs: [LibraryBook.DatabaseID]
}

struct CollectionRecommendationDisplayItem: Identifiable, Equatable, Sendable {
    var recommendation: CollectionRecommendation
    var books: [LibraryBook]

    var id: String {
        recommendation.id
    }
}

typealias CollectionRecommendationRefreshProgress = VersionRecommendationRefreshProgress

struct CollectionRecommendationRefreshProgressPhases: Sendable {
    var readingLibrary: String
    var parsingTitles: String
    var computingCandidates: String
    var writingCache: String
    var completed: String

    static let `default` = CollectionRecommendationRefreshProgressPhases(
        readingLibrary: "Reading library...",
        parsingTitles: "Parsing series titles...",
        computingCandidates: "Computing collection recommendations...",
        writingCache: "Writing recommendations...",
        completed: "Collection recommendation refresh finished."
    )
}
