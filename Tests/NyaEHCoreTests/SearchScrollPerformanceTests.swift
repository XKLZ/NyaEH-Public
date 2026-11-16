import AppKit
import Foundation
import Testing
@testable import NyaEHCore

private actor SearchCoverPrefetchProbe {
    private var requests: [CoverPrefetchRequest] = []

    func append(_ request: CoverPrefetchRequest) {
        requests.append(request)
    }

    func snapshot() -> [CoverPrefetchRequest] {
        requests
    }
}

@Suite("Search scroll interaction and presentation", .serialized)
struct SearchScrollPerformanceTests {
    @Test("scroll activity publishes only real phase transitions")
    func scrollActivityPublishesOnlyTransitions() {
        var state = SearchScrollActivityState()

        let unchangedIdle = state.update(isScrolling: false)
        let started = state.update(isScrolling: true)
        let unchangedActive = state.update(isScrolling: true)
        let stopped = state.update(isScrolling: false)
        #expect(!unchangedIdle)
        #expect(started)
        #expect(!unchangedActive)
        #expect(stopped)
    }

    @Test("hover remains disarmed until the pointer moves after scrolling")
    func hoverRequiresPointerMovementAfterScroll() {
        var gate = SearchScrollHoverGate()

        let initialHover = gate.pointerBecameActive(at: .zero, isScrolling: false)
        #expect(initialHover)
        gate.scrollActivityChanged(isScrolling: true)
        let duringScroll = gate.pointerBecameActive(at: CGPoint(x: 20, y: 20), isScrolling: true)
        #expect(!duringScroll)

        gate.scrollActivityChanged(isScrolling: false)
        let firstIdleSample = gate.pointerBecameActive(at: CGPoint(x: 20, y: 20), isScrolling: false)
        let subpixelMovement = gate.pointerBecameActive(at: CGPoint(x: 20.4, y: 20), isScrolling: false)
        let realMovement = gate.pointerBecameActive(at: CGPoint(x: 22, y: 20), isScrolling: false)
        #expect(!firstIdleSample)
        #expect(!subpixelMovement)
        #expect(realMovement)
    }

    @Test("book card hover visual state preserves feedback with reduced motion")
    func bookCardHoverVisualStateRespectsReducedMotion() {
        let idle = BookCardHoverVisualState.resolve(isHovered: false, reduceMotion: false)
        #expect(idle.coverScale == 1)
        #expect(idle.collectionCoverScale == 1)
        #expect(idle.verticalOffset == 0)
        #expect(idle.surfaceOpacity == 0)
        #expect(idle.borderOpacity == 0)
        #expect(idle.shadowOpacity == 0)

        let hovered = BookCardHoverVisualState.resolve(isHovered: true, reduceMotion: false)
        #expect(hovered.coverScale == 1.02)
        #expect(hovered.collectionCoverScale == 1.012)
        #expect(hovered.verticalOffset == -2)
        #expect(hovered.surfaceOpacity == 1)
        #expect(hovered.borderOpacity == 1)
        #expect(hovered.shadowOpacity == 0.12)

        let reduced = BookCardHoverVisualState.resolve(isHovered: true, reduceMotion: true)
        #expect(reduced.coverScale == 1)
        #expect(reduced.collectionCoverScale == 1)
        #expect(reduced.verticalOffset == 0)
        #expect(reduced.surfaceOpacity == 1)
        #expect(reduced.borderOpacity == 1)
        #expect(reduced.shadowOpacity == 0)
    }

    @Test("prefetch planner follows the visible window direction")
    func prefetchPlannerFollowsVisibleDirection() {
        let forward = SearchCoverPrefetchPlanner.plan(
            visibleIndices: [4, 5, 6],
            previousVisibleCenter: nil,
            itemCount: 20
        )
        #expect(forward.indices == [7, 8, 9, 10, 11, 12])

        let backward = SearchCoverPrefetchPlanner.plan(
            visibleIndices: [2, 3, 4],
            previousVisibleCenter: 10,
            itemCount: 20
        )
        #expect(backward.indices == [0, 1])
    }

    @Test("cancelled prefetch session does not publish queued requests")
    func cancelledPrefetchSessionDoesNotPublish() async {
        let probe = SearchCoverPrefetchProbe()
        let prefetcher = SearchCoverPrefetcher { request in
            try? await Task.sleep(for: .milliseconds(80))
            guard !Task.isCancelled else { return }
            await probe.append(request)
        }
        let sessionID = UUID()
        let generation = SearchCoverPrefetchGeneration(
            resultGeneration: UUID(),
            layout: "card",
            cardWidth: 180
        )
        let requests = (0..<12).map { index in
            [CoverPrefetchRequest(path: "cover-\(index)", pixelBucket: 256)]
        }

        await prefetcher.configure(
            sessionID: sessionID,
            generation: generation,
            requestsByItem: requests
        )
        for index in 0...2 {
            await prefetcher.visibilityChanged(
                sessionID: sessionID,
                generation: generation,
                index: index,
                isVisible: true
            )
        }
        await prefetcher.cancel(sessionID: sessionID)
        try? await Task.sleep(for: .milliseconds(160))

        #expect(await probe.snapshot().isEmpty)
    }

    @Test("changing the prefetch layout generation cancels the previous plan")
    func changingPrefetchLayoutCancelsPreviousPlan() async {
        let probe = SearchCoverPrefetchProbe()
        let prefetcher = SearchCoverPrefetcher { request in
            try? await Task.sleep(for: .milliseconds(80))
            guard !Task.isCancelled else { return }
            await probe.append(request)
        }
        let sessionID = UUID()
        let resultGeneration = UUID()
        let cardGeneration = SearchCoverPrefetchGeneration(
            resultGeneration: resultGeneration,
            layout: "card",
            cardWidth: 180
        )
        let rowGeneration = SearchCoverPrefetchGeneration(
            resultGeneration: resultGeneration,
            layout: "row",
            cardWidth: 180
        )
        let cardRequests = (0..<12).map { index in
            [CoverPrefetchRequest(path: "card-\(index)", pixelBucket: 512)]
        }
        let rowRequests = (0..<12).map { index in
            [CoverPrefetchRequest(path: "row-\(index)", pixelBucket: 128)]
        }

        await prefetcher.configure(
            sessionID: sessionID,
            generation: cardGeneration,
            requestsByItem: cardRequests
        )
        await prefetcher.visibilityChanged(
            sessionID: sessionID,
            generation: cardGeneration,
            index: 0,
            isVisible: true
        )
        await prefetcher.configure(
            sessionID: sessionID,
            generation: rowGeneration,
            requestsByItem: rowRequests
        )
        for index in 0...2 {
            await prefetcher.visibilityChanged(
                sessionID: sessionID,
                generation: rowGeneration,
                index: index,
                isVisible: true
            )
        }
        try? await Task.sleep(for: .milliseconds(180))

        let published = await probe.snapshot()
        #expect(!published.isEmpty)
        #expect(published.allSatisfy { $0.path.hasPrefix("row-") && $0.pixelBucket == 128 })
    }

    @Test("rating model emits one five-symbol presentation")
    func ratingModelEmitsExpectedSymbols() {
        #expect(BookRatingStarsModel(rating: nil).symbols == Array(repeating: "star", count: 5))
        #expect(BookRatingStarsModel(rating: 2.5).symbols == [
            "star.fill", "star.fill", "star.leadinghalf.filled", "star", "star"
        ])
    }

    @Test("cover cache reuses a higher pixel bucket")
    func coverCacheReusesHigherPixelBucket() {
        let path = "test-cover-\(UUID().uuidString)"
        let image = NSImage(size: NSSize(width: 16, height: 24))
        CoverImageCache.shared.store(image, for: path, pixelBucket: 512, cost: 16 * 24 * 4)
        defer { CoverImageCache.shared.removeImage(for: path) }

        let cached = CoverImageCache.shared.cachedImage(for: path, minimumPixelBucket: 128)
        #expect(cached?.image === image)
        #expect(cached?.pixelBucket == 512)
    }
}
