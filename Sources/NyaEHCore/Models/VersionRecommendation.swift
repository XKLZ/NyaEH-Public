// 本文件定义 VersionRecommendation 领域模型，是数据库、服务层和 SwiftUI 视图之间传递业务状态的结构。

import Foundation

enum VersionRecommendationKind: String, Codable, Sendable {
    case createGroup = "create_group"
    case addToGroup = "add_to_group"
}

enum VersionRecommendationStatus: String, Codable, Sendable {
    case pending
    case accepted
    case dismissed
    case stale
}

struct VersionRecommendation: Identifiable, Codable, Equatable, Sendable {
    typealias DatabaseID = Int64

    var databaseID: DatabaseID?
    var batchID: Int64?
    var kind: VersionRecommendationKind
    var targetVersionGroupID: BookVersionGroup.DatabaseID?
    var score: Int
    var reasons: [String]
    var fingerprint: String
    var status: VersionRecommendationStatus
    var createdAt: Int64
    var updatedAt: Int64

    var id: String {
        databaseID.map(String.init) ?? fingerprint
    }

    init(
        databaseID: DatabaseID? = nil,
        batchID: Int64? = nil,
        kind: VersionRecommendationKind,
        targetVersionGroupID: BookVersionGroup.DatabaseID? = nil,
        score: Int,
        reasons: [String],
        fingerprint: String,
        status: VersionRecommendationStatus = .pending,
        createdAt: Int64 = Timestamp.nowMilliseconds(),
        updatedAt: Int64 = Timestamp.nowMilliseconds()
    ) {
        self.databaseID = databaseID
        self.batchID = batchID
        self.kind = kind
        self.targetVersionGroupID = targetVersionGroupID
        self.score = score
        self.reasons = reasons
        self.fingerprint = fingerprint
        self.status = status
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

struct VersionRecommendationCandidate: Equatable, Sendable {
    var kind: VersionRecommendationKind
    var targetVersionGroupID: BookVersionGroup.DatabaseID?
    var bookIDs: [LibraryBook.DatabaseID]
    var score: Int
    var reasons: [String]
    var fingerprint: String
}

struct VersionRecommendationDisplayItem: Identifiable, Equatable, Sendable {
    var recommendation: VersionRecommendation
    var books: [LibraryBook]

    var id: String {
        recommendation.id
    }
}

struct VersionRecommendationRefreshProgress: Equatable, Sendable {
    var phase: String
    var fractionCompleted: Double

    static let idle = VersionRecommendationRefreshProgress(phase: "", fractionCompleted: 0)
}

struct VersionRecommendationRefreshProgressPhases: Sendable {
    var readingLibrary: String
    var readingCoverVectors: String
    var computingCandidates: String
    var writingCache: String
    var completed: String

    static let `default` = VersionRecommendationRefreshProgressPhases(
        readingLibrary: "Reading library...",
        readingCoverVectors: "Reading cover vectors...",
        computingCandidates: "Computing recommendations...",
        writingCache: "Writing recommendations...",
        completed: "Version recommendation refresh finished."
    )
}
