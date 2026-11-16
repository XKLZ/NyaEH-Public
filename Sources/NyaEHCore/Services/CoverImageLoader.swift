// 本文件负责按展示尺寸后台降采样封面，并合并相同封面的并发加载请求。

import AppKit
import Foundation
import ImageIO

struct DecodedCoverImage: @unchecked Sendable {
    let image: NSImage
    let cost: Int
}

struct LoadedCoverState: @unchecked Sendable {
    let image: NSImage
    let path: String
    let pixelBucket: Int
}

struct CoverImageCacheClient: @unchecked Sendable {
    let image: @Sendable (String, Int) -> CachedCoverImage?
    let store: @Sendable (NSImage, String, Int, Int) -> Void

    static let shared = CoverImageCacheClient(
        image: { path, pixelBucket in
            CoverImageCache.shared.cachedImage(for: path, minimumPixelBucket: pixelBucket)
        },
        store: { image, path, pixelBucket, cost in
            CoverImageCache.shared.store(
                image,
                for: path,
                pixelBucket: pixelBucket,
                cost: cost
            )
        }
    )
}

struct CoverDecodeScheduler: Sendable {
    private let permitPool: CoverDecodePermitPool

    init(maxConcurrentDecodes: Int) {
        permitPool = CoverDecodePermitPool(limit: max(maxConcurrentDecodes, 1))
    }

    func run<Value: Sendable>(
        _ operation: @escaping @Sendable () -> Value
    ) async -> Value? {
        let requestID = UUID()
        guard await permitPool.acquire(requestID: requestID) else {
            return nil
        }
        guard !Task.isCancelled else {
            await permitPool.release()
            return nil
        }

        let value = operation()
        await permitPool.release()
        return value
    }
}

private actor CoverDecodePermitPool {
    private struct Waiter {
        let requestID: UUID
        let continuation: CheckedContinuation<Bool, Never>
    }

    private let limit: Int
    private var activeCount = 0
    private var waiters: [Waiter] = []
    private var pendingRequestIDs: Set<UUID> = []
    private var cancelledRequestIDs: Set<UUID> = []

    init(limit: Int) {
        self.limit = limit
    }

    func acquire(requestID: UUID) async -> Bool {
        guard !Task.isCancelled else {
            return false
        }
        if cancelledRequestIDs.remove(requestID) != nil {
            return false
        }
        if activeCount < limit {
            activeCount += 1
            return true
        }

        pendingRequestIDs.insert(requestID)
        return await withTaskCancellationHandler {
            await waitForPermit(requestID: requestID)
        } onCancel: {
            Task {
                await cancel(requestID: requestID)
            }
        }
    }

    func release() {
        while !waiters.isEmpty {
            let waiter = waiters.removeFirst()
            if cancelledRequestIDs.remove(waiter.requestID) != nil {
                waiter.continuation.resume(returning: false)
                continue
            }
            waiter.continuation.resume(returning: true)
            return
        }
        activeCount = max(activeCount - 1, 0)
    }

    private func waitForPermit(requestID: UUID) async -> Bool {
        await withCheckedContinuation { continuation in
            pendingRequestIDs.remove(requestID)
            if Task.isCancelled || cancelledRequestIDs.remove(requestID) != nil {
                continuation.resume(returning: false)
            } else {
                waiters.append(Waiter(requestID: requestID, continuation: continuation))
            }
        }
    }

    private func cancel(requestID: UUID) {
        if let index = waiters.firstIndex(where: { $0.requestID == requestID }) {
            let waiter = waiters.remove(at: index)
            waiter.continuation.resume(returning: false)
        } else if pendingRequestIDs.contains(requestID) {
            cancelledRequestIDs.insert(requestID)
        }
    }
}

actor CoverImageLoader {
    typealias Decoder = @Sendable (String, Int) -> DecodedCoverImage?

    static let shared = CoverImageLoader(maxConcurrentDecodes: 4)

    private struct RequestKey: Hashable {
        let path: String
        let pixelBucket: Int
    }

    private struct InFlightRequest {
        let requestID: UUID
        let task: Task<DecodedCoverImage?, Never>
        var waiterIDs: Set<UUID>
    }

    private let scheduler: CoverDecodeScheduler
    private let decoder: Decoder
    private let cache: CoverImageCacheClient
    private var inFlight: [RequestKey: InFlightRequest] = [:]

    init(
        maxConcurrentDecodes: Int = 4,
        decoder: @escaping Decoder = CoverImageLoader.decode,
        cache: CoverImageCacheClient = .shared
    ) {
        scheduler = CoverDecodeScheduler(maxConcurrentDecodes: maxConcurrentDecodes)
        self.decoder = decoder
        self.cache = cache
    }

    func inFlightWaiterCount(for path: String, targetPixelSize: CGFloat) -> Int {
        let key = RequestKey(
            path: path,
            pixelBucket: Self.pixelBucket(for: targetPixelSize)
        )
        return inFlight[key]?.waiterIDs.count ?? 0
    }

    func image(for path: String, targetPixelSize: CGFloat) async -> NSImage? {
        await loadedImage(for: path, targetPixelSize: targetPixelSize)?.image
    }

    func loadedImage(for path: String, targetPixelSize: CGFloat) async -> LoadedCoverState? {
        let bucket = Self.pixelBucket(for: targetPixelSize)
        if let cached = cache.image(path, bucket) {
            return LoadedCoverState(
                image: cached.image,
                path: path,
                pixelBucket: cached.pixelBucket
            )
        }

        let key = RequestKey(path: path, pixelBucket: bucket)
        let waiterID = UUID()
        let request: InFlightRequest
        if var existing = inFlight[key] {
            existing.waiterIDs.insert(waiterID)
            inFlight[key] = existing
            request = existing
        } else {
            let requestID = UUID()
            let scheduler = scheduler
            let decoder = decoder
            let task = Task.detached(priority: .utility) {
                await scheduler.run {
                    decoder(path, bucket)
                } ?? nil
            }
            request = InFlightRequest(
                requestID: requestID,
                task: task,
                waiterIDs: [waiterID]
            )
            inFlight[key] = request
        }

        let decoded = await withTaskCancellationHandler {
            await request.task.value
        } onCancel: {
            Task {
                await self.cancelWaiter(
                    waiterID,
                    key: key,
                    requestID: request.requestID
                )
            }
        }
        let callerWasCancelled = Task.isCancelled
        let shouldStore = finishWaiter(
            waiterID,
            key: key,
            requestID: request.requestID,
            callerWasCancelled: callerWasCancelled
        )

        if shouldStore, let decoded {
            cache.store(decoded.image, path, bucket, decoded.cost)
        }
        guard !callerWasCancelled, let decoded else {
            return nil
        }
        return LoadedCoverState(image: decoded.image, path: path, pixelBucket: bucket)
    }

    private func cancelWaiter(_ waiterID: UUID, key: RequestKey, requestID: UUID) {
        guard var request = inFlight[key], request.requestID == requestID else {
            return
        }
        request.waiterIDs.remove(waiterID)
        if request.waiterIDs.isEmpty {
            inFlight[key] = nil
            request.task.cancel()
        } else {
            inFlight[key] = request
        }
    }

    private func finishWaiter(
        _ waiterID: UUID,
        key: RequestKey,
        requestID: UUID,
        callerWasCancelled: Bool
    ) -> Bool {
        guard var request = inFlight[key], request.requestID == requestID else {
            return false
        }
        request.waiterIDs.remove(waiterID)
        let hasLiveConsumer = !callerWasCancelled || !request.waiterIDs.isEmpty
        inFlight[key] = nil
        return hasLiveConsumer
    }

    nonisolated static func pixelBucket(for targetPixelSize: CGFloat) -> Int {
        switch targetPixelSize {
        case ...128: 128
        case ...256: 256
        default: 512
        }
    }

    nonisolated static func decode(path: String, maximumPixelSize: Int) -> DecodedCoverImage? {
        autoreleasepool {
            let url = URL(fileURLWithPath: path) as CFURL
            guard let source = CGImageSourceCreateWithURL(url, nil) else { return nil }
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceShouldCacheImmediately: true,
                kCGImageSourceThumbnailMaxPixelSize: maximumPixelSize
            ]
            guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
                return nil
            }
            let size = NSSize(width: image.width, height: image.height)
            return DecodedCoverImage(
                image: NSImage(cgImage: image, size: size),
                cost: image.bytesPerRow * image.height
            )
        }
    }
}
