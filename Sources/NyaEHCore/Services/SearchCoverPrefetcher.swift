// 本文件根据 Search 当前可见项目窗口，使用共享封面加载器低优先级预热相邻项目。

import Foundation

struct CoverPrefetchRequest: Hashable, Sendable {
    let path: String
    let pixelBucket: Int
}

struct SearchCoverPrefetchGeneration: Hashable, Sendable {
    let resultGeneration: UUID
    let layout: String
    let cardWidth: Int
}

struct SearchCoverPrefetchPlan: Equatable, Sendable {
    let indices: [Int]
    let visibleCenter: Double?
}

enum SearchCoverPrefetchPlanner {
    static func plan(
        visibleIndices: Set<Int>,
        previousVisibleCenter: Double?,
        itemCount: Int
    ) -> SearchCoverPrefetchPlan {
        guard itemCount > 0,
              let minimum = visibleIndices.min(),
              let maximum = visibleIndices.max() else {
            return SearchCoverPrefetchPlan(indices: [], visibleCenter: previousVisibleCenter)
        }

        let center = Double(minimum + maximum) / 2
        let windowSize = min(max(visibleIndices.count, 6), 30)
        let isMovingForward = previousVisibleCenter.map { center >= $0 } ?? true
        let range: Range<Int>
        if isMovingForward {
            let lowerBound = min(maximum + 1, itemCount)
            range = lowerBound..<min(lowerBound + windowSize, itemCount)
        } else {
            let upperBound = max(minimum, 0)
            range = max(upperBound - windowSize, 0)..<upperBound
        }
        return SearchCoverPrefetchPlan(indices: Array(range), visibleCenter: center)
    }
}

actor SearchCoverPrefetcher {
    typealias Loader = @Sendable (CoverPrefetchRequest) async -> Void

    static let shared = SearchCoverPrefetcher { request in
        _ = await CoverImageLoader.shared.image(
            for: request.path,
            targetPixelSize: CGFloat(request.pixelBucket)
        )
    }

    private struct Session {
        var generation: SearchCoverPrefetchGeneration
        var requestsByItem: [[CoverPrefetchRequest]]
        var visibleIndices: Set<Int> = []
        var previousVisibleCenter: Double?
        var scheduledIndices: [Int] = []
        var task: Task<Void, Never>?
    }

    private let loader: Loader
    private var sessions: [UUID: Session] = [:]

    init(loader: @escaping Loader) {
        self.loader = loader
    }

    func configure(
        sessionID: UUID,
        generation: SearchCoverPrefetchGeneration,
        requestsByItem: [[CoverPrefetchRequest]]
    ) {
        if let session = sessions[sessionID], session.generation == generation {
            return
        }
        sessions[sessionID]?.task?.cancel()
        sessions[sessionID] = Session(
            generation: generation,
            requestsByItem: requestsByItem
        )
    }

    func visibilityChanged(
        sessionID: UUID,
        generation: SearchCoverPrefetchGeneration,
        index: Int,
        isVisible: Bool
    ) {
        guard var session = sessions[sessionID],
              session.generation == generation,
              session.requestsByItem.indices.contains(index) else {
            return
        }

        if isVisible {
            session.visibleIndices.insert(index)
        } else {
            session.visibleIndices.remove(index)
        }

        let plan = SearchCoverPrefetchPlanner.plan(
            visibleIndices: session.visibleIndices,
            previousVisibleCenter: session.previousVisibleCenter,
            itemCount: session.requestsByItem.count
        )
        session.previousVisibleCenter = plan.visibleCenter
        guard plan.indices != session.scheduledIndices else {
            sessions[sessionID] = session
            return
        }

        session.scheduledIndices = plan.indices
        session.task?.cancel()
        let requests = Self.uniqueRequests(
            for: plan.indices,
            requestsByItem: session.requestsByItem
        )
        let loader = loader
        session.task = Task(priority: .utility) {
            try? await Task.sleep(for: .milliseconds(40))
            guard !Task.isCancelled else { return }
            for request in requests {
                guard !Task.isCancelled else { return }
                await loader(request)
            }
        }
        sessions[sessionID] = session
    }

    func cancel(sessionID: UUID) {
        sessions.removeValue(forKey: sessionID)?.task?.cancel()
    }

    func visibleIndices(sessionID: UUID) -> Set<Int> {
        sessions[sessionID]?.visibleIndices ?? []
    }

    private static func uniqueRequests(
        for indices: [Int],
        requestsByItem: [[CoverPrefetchRequest]]
    ) -> [CoverPrefetchRequest] {
        var seen: Set<CoverPrefetchRequest> = []
        return indices.flatMap { index -> [CoverPrefetchRequest] in
            guard requestsByItem.indices.contains(index) else { return [] }
            return requestsByItem[index].filter { seen.insert($0).inserted }
        }
    }
}
