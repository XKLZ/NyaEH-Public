// 本文件定义 MetadataBatchConfiguration 领域模型，是数据库、服务层和 SwiftUI 视图之间传递业务状态的结构。

import Foundation

enum MetadataBatchIntervalStrategy: String, CaseIterable, Identifiable, Codable, Sendable {
    case random

    var id: String { rawValue }

    var titleKey: L10nKey {
        switch self {
        case .random:
            return .metadataBatchIntervalRandom
        }
    }
}

struct MetadataBatchConfiguration: Equatable, Sendable {
    var fetchConfiguration: GalleryMetadataFetchConfiguration
    var intervalStrategy: MetadataBatchIntervalStrategy
    var minDelaySeconds: Int
    var maxDelaySeconds: Int
    var retryCount: Int
    var limit: Int

    init(
        fetchConfiguration: GalleryMetadataFetchConfiguration,
        intervalStrategy: MetadataBatchIntervalStrategy = .random,
        minDelaySeconds: Int = 8,
        maxDelaySeconds: Int = 20,
        retryCount: Int = 2,
        limit: Int = 50
    ) {
        self.fetchConfiguration = fetchConfiguration
        self.intervalStrategy = intervalStrategy
        self.minDelaySeconds = minDelaySeconds
        self.maxDelaySeconds = max(minDelaySeconds, maxDelaySeconds)
        self.retryCount = min(max(retryCount, 0), 5)
        self.limit = limit == 0 ? 0 : min(max(limit, 1), 500)
    }

    func nextDelaySeconds() -> Int {
        switch intervalStrategy {
        case .random:
            guard maxDelaySeconds > minDelaySeconds else {
                return minDelaySeconds
            }
            return Int.random(in: minDelaySeconds...maxDelaySeconds)
        }
    }
}

enum MetadataBatchRunState: String, Codable, Sendable {
    case idle
    case running
    case paused
    case cancelled
    case completed
}

struct MetadataBatchProgress: Equatable, Sendable {
    var state: MetadataBatchRunState = .idle
    var total: Int = 0
    var processed: Int = 0
    var succeeded: Int = 0
    var failed: Int = 0
    var skipped: Int = 0
    var currentTitle: String?
    var lastError: String?
    var nextRequestAt: Date?

    var isActive: Bool {
        state == .running || state == .paused
    }
}
