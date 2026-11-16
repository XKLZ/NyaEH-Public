// 本文件定义可跨启动恢复的导入批次与逐书处理状态。

import Foundation

enum ImportPipelineBatchStatus: String, Codable, Sendable {
    case running
    case waitingForReview
    case paused
    case completed
}

enum ImportPipelineBatchStage: String, Codable, Sendable {
    case metadata
    case versionAnalysis
    case versionReview
    case collectionAnalysis
    case collectionReview
    case completed
}

enum ImportPipelineItemStage: String, Codable, Sendable {
    case metadataPending
    case metadataRunning
    case metadataDeferred
    case versionAnalysisPending
    case versionReviewPending
    case collectionAnalysisPending
    case collectionReviewPending
    case completed
    case completedMetadataSkipped
    case sourceNeedsAttention

    var isIncomplete: Bool {
        self != .completed && self != .completedMetadataSkipped
    }
}

enum ImportMetadataSource: String, Codable, Sendable {
    case galleryURL
    case localCache
    case hashSearch
    case manual
    case skipped
}

struct ImportPipelineBatch: Identifiable, Equatable, Sendable {
    typealias ID = Int64

    var id: ID
    var status: ImportPipelineBatchStatus
    var stage: ImportPipelineBatchStage
    var pauseReason: String?
    var deletedCount: Int = 0
    var totalCount: Int
    var readyCount: Int
    var deferredCount: Int
    var reviewCount: Int
    var failedCount: Int
    var createdAt: Int64
    var startedAt: Int64?
    var completedAt: Int64?
    var updatedAt: Int64
}

struct ImportPipelineItem: Identifiable, Equatable, Sendable {
    typealias ID = Int64

    var id: ID
    var batchID: ImportPipelineBatch.ID?
    var bookID: LibraryBook.DatabaseID
    var sourceHash: String
    var sourceMtime: Int64?
    var stage: ImportPipelineItemStage
    var metadataSource: ImportMetadataSource?
    var preferredGalleryURL: String?
    var attemptCount: Int
    var lastErrorKind: String?
    var lastErrorMessage: String?
    var retryAfter: Int64?
    var createdAt: Int64
    var updatedAt: Int64
    var completedAt: Int64?
}

struct ImportPipelineSnapshot: Equatable, Sendable {
    var activeBatch: ImportPipelineBatch?
    var items: [ImportPipelineItem]

    static let empty = ImportPipelineSnapshot(activeBatch: nil, items: [])

    var itemsByBookID: [LibraryBook.DatabaseID: ImportPipelineItem] {
        Dictionary(uniqueKeysWithValues: items.map { ($0.bookID, $0) })
    }

    var incompleteCount: Int {
        items.count(where: { $0.stage.isIncomplete })
    }
}
