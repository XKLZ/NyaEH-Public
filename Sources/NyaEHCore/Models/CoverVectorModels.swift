// 本文件定义 CoverVectorModels 领域模型，是数据库、服务层和 SwiftUI 视图之间传递业务状态的结构。

import Foundation

struct CoverFeatureVector: Equatable, Sendable {
    var bookID: LibraryBook.DatabaseID
    var coverHash: String
    var visionRevision: Int
    var elementType: Int
    var elementCount: Int
    var featureData: Data
    var createdAt: Int64
    var updatedAt: Int64

    init(
        bookID: LibraryBook.DatabaseID,
        coverHash: String,
        visionRevision: Int,
        elementType: Int,
        elementCount: Int,
        featureData: Data,
        createdAt: Int64 = Timestamp.nowMilliseconds(),
        updatedAt: Int64 = Timestamp.nowMilliseconds()
    ) {
        self.bookID = bookID
        self.coverHash = coverHash
        self.visionRevision = visionRevision
        self.elementType = elementType
        self.elementCount = elementCount
        self.featureData = featureData
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

struct CoverFeatureQuery: Equatable, Sendable {
    var visionRevision: Int
    var elementType: Int
    var elementCount: Int
    var featureData: Data
}

struct CoverVectorEntry: Equatable, Sendable {
    var bookID: LibraryBook.DatabaseID
    var coverHash: String?
    var visionRevision: Int?
    var elementType: Int?
    var elementCount: Int?
    var featureData: Data?
    var failureMessage: String?
    var createdAt: Int64
    var updatedAt: Int64
}

struct CoverVectorNeighbor: Equatable, Sendable {
    var bookID: LibraryBook.DatabaseID
    var distance: Double
}

struct CoverImageSearchMatch: Equatable, Sendable {
    var book: LibraryBook
    var distance: Double

    var confidence: CoverImageSearchConfidence {
        distance <= CoverImageSearchConfiguration.highConfidenceMaximumDistance
            ? .high
            : .similar
    }
}

enum CoverImageSearchConfidence: String, Equatable, Sendable {
    case high
    case similar
}

enum CoverImageSearchConfiguration {
    static let highConfidenceMaximumDistance = 20.0
    static let maximumDistance = 120.0
    static let maximumResultCount = 50
}

struct CoverVectorIndexStats: Equatable, Sendable {
    var vectorCount: Int
    var failureCount: Int
    var missingCount: Int
    var staleCount: Int
    var totalBooksWithCovers: Int

    static let empty = CoverVectorIndexStats(
        vectorCount: 0,
        failureCount: 0,
        missingCount: 0,
        staleCount: 0,
        totalBooksWithCovers: 0
    )
}

struct CoverVectorIndexProgress: Equatable, Sendable {
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

    static let idle = CoverVectorIndexProgress(phase: "", completed: 0, total: 1, failed: 0)
}

protocol CoverVectorSearch: Sendable {
    func indexedBookIDs() throws -> Set<LibraryBook.DatabaseID>
    func nearestNeighbors(bookID: LibraryBook.DatabaseID, limit: Int) throws -> [CoverVectorNeighbor]
    func nearestNeighbors(query: CoverFeatureQuery, limit: Int) throws -> [CoverVectorNeighbor]
}

protocol CoverVectorRepository: CoverVectorSearch {
    func fetchEntry(bookID: LibraryBook.DatabaseID) throws -> CoverVectorEntry?
    func upsertVector(_ vector: CoverFeatureVector) throws
    func markFailure(bookID: LibraryBook.DatabaseID, coverHash: String?, message: String) throws
    func deleteVector(bookID: LibraryBook.DatabaseID) throws
    func pruneOrphanedVectors(existingBookIDs: Set<LibraryBook.DatabaseID>) throws -> Int
    func clear() throws
    func storedVectorCount() throws -> Int
    func storedFailureCount() throws -> Int
}
