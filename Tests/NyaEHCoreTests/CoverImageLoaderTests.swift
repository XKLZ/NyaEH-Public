import AppKit
import Foundation
import Testing
@testable import NyaEHCore

private final class CoverDecodeGate: @unchecked Sendable {
    private let condition = NSCondition()
    private var isOpen = false
    private var isWaiting = false
    private var waitingContinuations: [CheckedContinuation<Void, Never>] = []

    func wait() {
        condition.lock()
        isWaiting = true
        let continuations = waitingContinuations
        waitingContinuations.removeAll()
        condition.unlock()
        continuations.forEach { $0.resume() }

        condition.lock()
        while !isOpen {
            condition.wait()
        }
        condition.unlock()
    }

    func waitUntilBlocked() async {
        await withCheckedContinuation { continuation in
            condition.lock()
            if isWaiting {
                condition.unlock()
                continuation.resume()
            } else {
                waitingContinuations.append(continuation)
                condition.unlock()
            }
        }
    }

    func open() {
        condition.lock()
        isOpen = true
        condition.broadcast()
        condition.unlock()
    }
}

private final class CoverDecodeProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var activeCount = 0
    private var maximumActiveCount = 0
    private var decodeCounts: [String: Int] = [:]
    private var gates: [String: CoverDecodeGate] = [:]

    func installGate(
        _ gate: CoverDecodeGate = CoverDecodeGate(),
        for path: String
    ) -> CoverDecodeGate {
        lock.withLock {
            gates[path] = gate
        }
        return gate
    }

    func decode(path: String, delay: TimeInterval = 0) -> DecodedCoverImage? {
        let gate = lock.withLock { () -> CoverDecodeGate? in
            activeCount += 1
            maximumActiveCount = max(maximumActiveCount, activeCount)
            decodeCounts[path, default: 0] += 1
            return gates[path]
        }

        if delay > 0 {
            Thread.sleep(forTimeInterval: delay)
        }
        gate?.wait()

        lock.withLock {
            activeCount -= 1
        }
        return DecodedCoverImage(
            image: NSImage(size: NSSize(width: 8, height: 12)),
            cost: 8 * 12 * 4
        )
    }

    func decodeCount(for path: String) -> Int {
        lock.withLock { decodeCounts[path, default: 0] }
    }

    var maximumConcurrency: Int {
        lock.withLock { maximumActiveCount }
    }
}

private final class CoverCacheProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var storeCountStorage = 0

    var client: CoverImageCacheClient {
        CoverImageCacheClient(
            image: { _, _ in nil },
            store: { [self] _, _, _, _ in
                lock.withLock {
                    storeCountStorage += 1
                }
            }
        )
    }

    var storeCount: Int {
        lock.withLock { storeCountStorage }
    }
}

private func waitUntil(
    timeout: Duration = .seconds(5),
    condition: @escaping @Sendable () -> Bool
) async -> Bool {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while clock.now < deadline {
        if condition() {
            return true
        }
        try? await Task.sleep(for: .milliseconds(5))
    }
    return condition()
}

private func waitUntilWaiterCount(
    _ expectedCount: Int,
    loader: CoverImageLoader,
    path: String,
    targetPixelSize: CGFloat,
    timeout: Duration = .seconds(5)
) async -> Bool {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while clock.now < deadline {
        if await loader.inFlightWaiterCount(
            for: path,
            targetPixelSize: targetPixelSize
        ) == expectedCount {
            return true
        }
        try? await Task.sleep(for: .milliseconds(5))
    }
    return await loader.inFlightWaiterCount(
        for: path,
        targetPixelSize: targetPixelSize
    ) == expectedCount
}

@Suite("Cover image decode scheduling", .serialized)
struct CoverImageLoaderTests {
    @Test("decode scheduler limits work to four concurrent operations")
    func decodeSchedulerLimitsConcurrency() async {
        let scheduler = CoverDecodeScheduler(maxConcurrentDecodes: 4)
        let probe = CoverDecodeProbe()
        let gate = CoverDecodeGate()
        for index in 0..<12 {
            _ = probe.installGate(gate, for: "cover-\(index)")
        }

        let run = Task {
            await withTaskGroup(of: DecodedCoverImage?.self) { group in
                for index in 0..<12 {
                    group.addTask {
                        await scheduler.run {
                            probe.decode(path: "cover-\(index)")
                        } ?? nil
                    }
                }
                for await _ in group {}
            }
        }

        #expect(await waitUntil { probe.maximumConcurrency == 4 })
        gate.open()
        await run.value
        #expect(probe.maximumConcurrency == 4)
    }

    @Test("queued decode is skipped after cancellation")
    func queuedDecodeIsSkippedAfterCancellation() async {
        let scheduler = CoverDecodeScheduler(maxConcurrentDecodes: 1)
        let probe = CoverDecodeProbe()
        let firstGate = probe.installGate(for: "first")

        let first = Task {
            await scheduler.run {
                probe.decode(path: "first")
            }
        }
        await firstGate.waitUntilBlocked()

        let queued = Task {
            await scheduler.run {
                probe.decode(path: "queued")
            }
        }
        try? await Task.sleep(for: .milliseconds(20))
        queued.cancel()
        firstGate.open()

        _ = await first.value
        let queuedResult = await queued.value
        #expect(queuedResult == nil)
        #expect(probe.decodeCount(for: "queued") == 0)
    }

    @Test("same cover request coalesces and stores once")
    func sameCoverRequestCoalescesAndStoresOnce() async {
        let decodeProbe = CoverDecodeProbe()
        let cacheProbe = CoverCacheProbe()
        let gate = decodeProbe.installGate(for: "shared-cover")
        let loader = CoverImageLoader(
            maxConcurrentDecodes: 4,
            decoder: { path, _ in decodeProbe.decode(path: path) },
            cache: cacheProbe.client
        )

        let first = Task {
            await loader.image(for: "shared-cover", targetPixelSize: 256)
        }
        await gate.waitUntilBlocked()
        let second = Task {
            await loader.image(for: "shared-cover", targetPixelSize: 256)
        }
        #expect(
            await waitUntilWaiterCount(
                2,
                loader: loader,
                path: "shared-cover",
                targetPixelSize: 256
            )
        )
        gate.open()

        #expect(await first.value != nil)
        #expect(await second.value != nil)
        #expect(decodeProbe.decodeCount(for: "shared-cover") == 1)
        #expect(cacheProbe.storeCount == 1)
    }

    @Test("queued cover with no waiters is not decoded")
    func queuedCoverWithoutWaitersIsNotDecoded() async {
        let decodeProbe = CoverDecodeProbe()
        let cacheProbe = CoverCacheProbe()
        let gate = decodeProbe.installGate(for: "running-cover")
        let loader = CoverImageLoader(
            maxConcurrentDecodes: 1,
            decoder: { path, _ in decodeProbe.decode(path: path) },
            cache: cacheProbe.client
        )

        let running = Task {
            await loader.image(for: "running-cover", targetPixelSize: 128)
        }
        await gate.waitUntilBlocked()

        let queued = Task {
            await loader.image(for: "offscreen-cover", targetPixelSize: 128)
        }
        #expect(await waitUntilWaiterCount(1, loader: loader, path: "offscreen-cover", targetPixelSize: 128))
        queued.cancel()
        // Cancellation hops to the loader actor. Wait until the waiter is removed before
        // releasing the permit; a sleep cannot establish ordering under parallel test load.
        #expect(await waitUntilWaiterCount(0, loader: loader, path: "offscreen-cover", targetPixelSize: 128))
        gate.open()

        #expect(await running.value != nil)
        #expect(await queued.value == nil)
        #expect(decodeProbe.decodeCount(for: "offscreen-cover") == 0)
        #expect(cacheProbe.storeCount == 1)
    }

    @Test("running decode may finish after cancellation without cache or view delivery")
    func runningDecodeCancellationSuppressesDelivery() async {
        let decodeProbe = CoverDecodeProbe()
        let cacheProbe = CoverCacheProbe()
        let gate = decodeProbe.installGate(for: "cancelled-cover")
        let loader = CoverImageLoader(
            maxConcurrentDecodes: 1,
            decoder: { path, _ in decodeProbe.decode(path: path) },
            cache: cacheProbe.client
        )

        let request = Task {
            await loader.image(for: "cancelled-cover", targetPixelSize: 512)
        }
        await gate.waitUntilBlocked()
        request.cancel()
        gate.open()

        #expect(await request.value == nil)
        #expect(cacheProbe.storeCount == 0)
    }
}
