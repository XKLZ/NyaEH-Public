// 本文件定义系列标题语义模型、可重建索引状态和近邻查询协议。

import Foundation

enum SemanticTitleSourceKind: String, Codable, Sendable {
    case title
    case titleJpn = "title_jpn"
}

struct SemanticEmbeddingProfile: Codable, Equatable, Sendable {
    var modelIdentifier: String
    var revision: Int
    var dimension: Int
    var maximumSequenceLength: Int
    var preprocessingVersion: Int
    var poolingVersion: Int

    var signature: String {
        [
            modelIdentifier,
            "r\(revision)",
            "d\(dimension)",
            "p\(preprocessingVersion)",
            "m\(poolingVersion)"
        ].joined(separator: ":")
    }
}

enum SemanticEmbeddingAssetState: Equatable, Sendable {
    case unavailable
    case available(SemanticEmbeddingProfile)
    case failed(String)

    var profile: SemanticEmbeddingProfile? {
        guard case .available(let profile) = self else {
            return nil
        }
        return profile
    }
}

struct SemanticTitleInput: Equatable, Sendable {
    var bookID: LibraryBook.DatabaseID
    var sourceKind: SemanticTitleSourceKind
    var text: String
    var languageCode: String?
    var sourceHash: String
}

struct SemanticTitleVector: Equatable, Sendable {
    var input: SemanticTitleInput
    var profile: SemanticEmbeddingProfile
    var featureData: Data
}

struct SemanticTitleVectorNeighbor: Equatable, Sendable {
    var bookID: LibraryBook.DatabaseID
    var distance: Double
}

struct SemanticTitleVectorEntry: Equatable, Sendable {
    var databaseID: Int64?
    var generationID: Int64
    var bookID: LibraryBook.DatabaseID
    var sourceKind: SemanticTitleSourceKind
    var sourceHash: String
    var languageCode: String?
    var featureData: Data?
    var failureMessage: String?
}

struct SemanticTitleVectorIndexStats: Equatable, Sendable {
    var assetState: SemanticEmbeddingAssetState
    var vectorCount: Int
    var failureCount: Int
    var missingCount: Int
    var staleCount: Int
    var eligibleBookCount: Int
    var activeProfile: SemanticEmbeddingProfile?

    var isReady: Bool {
        guard let assetProfile = assetState.profile,
              let activeProfile else {
            return false
        }
        return activeProfile == assetProfile
            && SemanticSeriesConfiguration.precisionFirst.supports(activeProfile)
            && vectorCount > 0
    }

    static let empty = SemanticTitleVectorIndexStats(
        assetState: .unavailable,
        vectorCount: 0,
        failureCount: 0,
        missingCount: 0,
        staleCount: 0,
        eligibleBookCount: 0,
        activeProfile: nil
    )
}

struct SemanticTitleVectorIndexProgress: Equatable, Sendable {
    var phase: String
    var completed: Int
    var total: Int
    var failed: Int

    var fractionCompleted: Double {
        guard total > 0 else {
            return 0
        }
        return min(max(Double(completed) / Double(total), 0), 1)
    }

    static let idle = SemanticTitleVectorIndexProgress(phase: "", completed: 0, total: 1, failed: 0)
}

struct SemanticSeriesConfiguration: Equatable, Sendable {
    var isEnabled: Bool
    var maximumSquaredDistance: Double
    var mutualNeighborLimit: Int

    static let disabled = SemanticSeriesConfiguration(
        isEnabled: false,
        maximumSquaredDistance: 0,
        mutualNeighborLimit: 3
    )

    // 0.30 只作为离线诊断和人工复核候选的宽上限。
    static let diagnostic = SemanticSeriesConfiguration(
        isEnabled: true,
        maximumSquaredDistance: 0.30,
        mutualNeighborLimit: 3
    )

    // preprocessing-v3 的开发版正式阈值来自三态标注训练/验证；
    // 0.30 继续只用于离线诊断，不进入用户可见推荐。
    static let precisionFirst = SemanticSeriesConfiguration(
        isEnabled: true,
        maximumSquaredDistance: 0.2767,
        mutualNeighborLimit: 3
    )

    func supports(_ profile: SemanticEmbeddingProfile) -> Bool {
        isEnabled
            && !profile.modelIdentifier.isEmpty
            && profile.revision == 1
            && profile.dimension == 512
            && profile.maximumSequenceLength == 256
            && profile.preprocessingVersion == 3
            && profile.poolingVersion == 1
    }
}

protocol ContextualTitleEmbeddingGenerating: Sendable {
    func assetState() async -> SemanticEmbeddingAssetState
    func requestAssets() async throws -> SemanticEmbeddingProfile
    func prepareModel() async throws -> SemanticEmbeddingProfile
    func vector(for input: SemanticTitleInput) async throws -> SemanticTitleVector
    func unloadModel() async
}

protocol SemanticTitleVectorSearch: Sendable {
    func activeProfile() throws -> SemanticEmbeddingProfile?
    func indexedBookIDs() throws -> Set<LibraryBook.DatabaseID>
    func nearestNeighbors(
        bookID: LibraryBook.DatabaseID,
        among candidateBookIDs: Set<LibraryBook.DatabaseID>,
        limit: Int
    ) throws -> [SemanticTitleVectorNeighbor]
}

protocol SemanticTitleVectorRepository: SemanticTitleVectorSearch {
    func activeGenerationID() throws -> Int64?
    func activeEntries(bookID: LibraryBook.DatabaseID) throws -> [SemanticTitleVectorEntry]
    func beginGeneration(profile: SemanticEmbeddingProfile) throws -> Int64
    func upsertVector(_ vector: SemanticTitleVector, generationID: Int64) throws
    func markFailure(
        input: SemanticTitleInput,
        profile: SemanticEmbeddingProfile,
        generationID: Int64,
        message: String
    ) throws
    func activateGeneration(_ generationID: Int64) throws
    func discardGeneration(_ generationID: Int64) throws
    func deleteEntries(bookID: LibraryBook.DatabaseID, generationID: Int64) throws
    func storedVectorCount() throws -> Int
    func storedFailureCount() throws -> Int
    func pruneOrphanedVectors(existingBookIDs: Set<LibraryBook.DatabaseID>) throws -> Int
    func clear() throws
}
