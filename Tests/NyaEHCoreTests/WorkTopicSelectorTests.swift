import AppKit
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import NyaEHCore

struct WorkTopicSelectorTests {
    @Test func wheelRoutesOnlyVerticalMouseEvents() {
        func distance(_ x: CGFloat, _ y: CGFloat, precise: Bool = false,
                      phase: NSEvent.Phase = [], momentum: NSEvent.Phase = []) -> CGFloat? {
            WorkTopicWheel.horizontalDistance(deltaX: x, deltaY: y, precise: precise,
                                             phase: phase, momentum: momentum, lineStep: 16)
        }
        #expect(distance(0, -3) == 48)
        #expect(distance(0, 2) == -32)
        #expect(distance(0, -7, precise: true) == 7)
        #expect(distance(2, -3) == nil)
        #expect(distance(0, 0) == nil)
        #expect(distance(0, 8, precise: true, phase: .changed) == nil)
        #expect(distance(0, 8, precise: true, momentum: .changed) == nil)
    }

    @MainActor
    @Test func quickHoverPreviewsOnlyTheLatestRoleAndSuspendsDuringMomentum() async throws {
        let motion = WorkTopicMotionCoordinator(dwell: .zero)
        var selected: [Int64] = []
        motion.enter(1) { selected.append(1) }
        motion.enter(2) { selected.append(2) }
        motion.leave(1)
        #expect(motion.previewID == 2)
        motion.setScrolling(true)
        #expect(motion.previewID == nil)
        try await Task.sleep(for: .milliseconds(15))
        #expect(selected.isEmpty)
        #expect(motion.commitCount == 0)
        #expect(motion.largePortraitRequestCount == 0)

        motion.enter(3) { selected.append(3) }
        motion.setScrolling(false)
        try await waitFor { selected == [3] }
        #expect(selected == [3])
    }

    @MainActor
    @Test func wheelAndNavigationCancelOutstandingDwell() async throws {
        let motion = WorkTopicMotionCoordinator(dwell: .zero)
        var commits = 0
        motion.enter(8) { commits += 1 }
        motion.wheelMoved()
        #expect(motion.previewID == nil)
        motion.clear()
        try await Task.sleep(for: .milliseconds(160))
        #expect(commits == 0)
    }

    private func character(_ id: Int64) -> TagDisplaySummary {
        .init(id: id, namespace: "character", name: "role", rawValue: "character:role", displayName: "R", count: 1)
    }

    @MainActor
    @Test func exchangeVacatesBothSlotsAndReturnsTheOldRoleBeforeMountingTheFinalShelf() async throws {
        let motion = WorkTopicMotionCoordinator(scheduleAnimation: { _, _ in nil })
        motion.pageSize = CGSize(width: 900, height: 700)
        motion.selectorViewport = CGRect(x: 0, y: 0, width: 300, height: 100)
        let sources = (1...3).map { index in
            let source = WorkTopicCardSource()
            source.bounds = CGRect(x: 70 * (index - 1), y: 5, width: 64, height: 88)
            motion.mount(source, id: Int64(index))
            return source
        }
        var selections = [Int64]()
        motion.show(character(1), request: nil, restore: true, reduceMotion: false) { selections.append($0) }
        #expect(motion.shelfID == 1)
        #expect(sources[0].isVacant)
        let oldStage = CGRect(x: 18, y: 180, width: 220, height: 400)
        motion.locateStage(for: 1, bounds: oldStage)
        motion.show(character(2), request: nil, reduceMotion: false) { selections.append($0) }
        try await waitFor { motion.flight != nil }
        let first = try #require(motion.flight)
        #expect(first.incoming.character.id == 2 && first.outgoing?.character.id == 1)
        #expect(first.outgoingStage == oldStage)
        #expect(sources[0].isVacant && sources[1].isVacant)
        #expect(motion.shelfIsExiting && motion.shelfID == 1)

        motion.show(character(3), request: nil, reduceMotion: false) { selections.append($0) }
        #expect(motion.flight?.id == first.id)
        motion.finish(first.id)
        #expect(motion.shelfID == nil)
        try await waitFor { motion.flight != nil }
        let next = try #require(motion.flight)
        #expect(next.outgoing?.character.id == 2 && next.incoming.character.id == 3)
        #expect(!sources[0].isVacant && sources[1].isVacant && sources[2].isVacant)
        motion.finish(first.id)
        #expect(motion.flight?.id == next.id)
        motion.finish(next.id)
        #expect(motion.shelfID == 3 && !motion.shelfIsExiting)
        #expect(!sources[0].isVacant && !sources[1].isVacant && sources[2].isVacant)
        #expect(selections.last == 3)

        motion.clear()
        #expect(!sources[2].isVacant && motion.shelfID == nil)
    }

    @MainActor
    @Test(.timeLimit(.minutes(1))) func coldPreparationKeepsTheOldShelfAndReusesExactlyOneDecodedImage() async throws {
        let bitmap = try #require(CGContext(data: nil, width: 64, height: 88, bitsPerComponent: 8,
                                            bytesPerRow: 256, space: CGColorSpaceCreateDeviceRGB(),
                                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let image = try #require(bitmap.makeImage())
        let (loads, started) = AsyncStream<Int64>.makeStream()
        defer { started.finish() }
        let gate = PortraitGate(started: started)
        var requests = loads.makeAsyncIterator()
        let motion = WorkTopicMotionCoordinator(scheduleAnimation: { _, _ in nil }, load: { request in await gate.load(request) })
        var selected: Int64?
        motion.show(character(1), request: nil, restore: true, reduceMotion: false) { selected = $0 }
        let request = WorkTopicAvatarRequest(url: URL(fileURLWithPath: "/synthetic/portrait.png"), revision: 1, pixels: 1200)
        motion.show(character(2), request: request, reduceMotion: false) { selected = $0 }
        try #require(await requests.next() == 1)
        #expect(motion.flight == nil && motion.shelfID == 1 && !motion.shelfIsExiting)
        #expect(selected == 1)
        motion.show(character(3), request: .init(url: request.url, revision: 2, pixels: 1200), reduceMotion: false) {
            selected = $0
        }
        try #require(await requests.next() == 2)
        await gate.complete(revision: 1, with: image)
        #expect(selected == 1)
        await gate.complete(revision: 2, with: image)
        try await waitFor { motion.flight != nil }
        let flight = try #require(motion.flight)
        #expect(flight.incoming.image === image)
        #expect(flight.fadesOnly) // Neither thumbnail slot is visible.
        #expect(selected == 3 && motion.shelfID == 1)
        motion.finish(flight.id)
        #expect(motion.image(for: 3) === image)
        #expect(motion.shelfID == 3)
    }

    @MainActor
    @Test(.timeLimit(.minutes(1))) func firstVisitWaitsForTheSlotAndReturnRestoresTheShelfImmediately() async throws {
        let motion = WorkTopicMotionCoordinator(scheduleAnimation: { _, _ in nil })
        motion.pageSize = CGSize(width: 850, height: 700)
        motion.selectorViewport = CGRect(x: 0, y: 70, width: 590, height: 108)
        motion.locateStage(for: 1, bounds: CGRect(x: 16, y: 192, width: 170, height: 600))
        let (selections, continuation) = AsyncStream<Int64>.makeStream()
        motion.show(character(1), request: nil, reduceMotion: false) { id in
            continuation.yield(id)
            continuation.finish()
        }
        let firstSlot = WorkTopicCardSource()
        firstSlot.bounds = CGRect(x: 200, y: 80, width: 64, height: 88)
        motion.mount(firstSlot, id: 1)
        #expect(!firstSlot.isVacant && motion.shelfID == nil)
        var events = selections.makeAsyncIterator()
        let selectedID = await events.next()
        try #require(selectedID == 1)
        let arrival = try #require(motion.flight)
        #expect(!arrival.fadesOnly && arrival.outgoing == nil)
        #expect(firstSlot.isVacant && motion.shelfID == nil)
        motion.finish(arrival.id)
        #expect(motion.shelfID == 1 && motion.animateShelfEntrance)
        motion.clear()
        motion.show(character(1), request: nil, restore: true, reduceMotion: false) { _ in }
        #expect(motion.flight == nil && motion.shelfID == 1 && !motion.animateShelfEntrance)
        #expect(firstSlot.isVacant)
    }

    @MainActor
    @Test func obscuredStageAndReducedMotionUseShortFades() async throws {
        let motion = WorkTopicMotionCoordinator(scheduleAnimation: { _, _ in nil })
        motion.pageSize = CGSize(width: 800, height: 700)
        motion.selectorViewport = CGRect(x: 0, y: 60, width: 500, height: 100)
        for id in 1...3 {
            let source = WorkTopicCardSource()
            source.bounds = CGRect(x: 80 * id, y: 66, width: 64, height: 88)
            motion.mount(source, id: Int64(id))
        }
        motion.show(character(1), request: nil, restore: true, reduceMotion: false) { _ in }
        motion.locateStage(for: 1, bounds: CGRect(x: 16, y: -300, width: 170, height: 400))
        motion.show(character(2), request: nil, reduceMotion: false) { _ in }
        try await waitFor { motion.flight != nil }
        let hidden = try #require(motion.flight)
        #expect(hidden.fadesOnly && hidden.duration == 0.15)
        motion.finish(hidden.id)
        motion.locateStage(for: 2, bounds: CGRect(x: 16, y: 180, width: 170, height: 400))
        motion.show(character(3), request: nil, reduceMotion: true) { _ in }
        try await waitFor { motion.flight != nil }
        let reduced = try #require(motion.flight)
        #expect(reduced.fadesOnly && reduced.duration == 0.15)
        motion.finish(reduced.id)
        #expect(motion.shelfID == 3 && motion.flightCount == 0)
    }

    @MainActor
    @Test func landingWaitsForThePreviousCarouselToActuallyDisappear() async throws {
        var completions: [Duration: @MainActor () -> Void] = [:]
        let motion = WorkTopicMotionCoordinator(scheduleAnimation: { delay, action in
            completions[delay] = action
            return nil
        })
        motion.show(character(1), request: nil, restore: true, reduceMotion: false) { _ in }
        motion.shelfDidAppear(1)
        motion.show(character(2), request: nil, reduceMotion: true) { _ in }
        try await waitFor { motion.flight != nil }
        let exchange = try #require(motion.flight)
        #expect(motion.shelfExitDuration == 0.12 && exchange.duration == 0.15)
        let retire = try #require(completions[.seconds(motion.shelfExitDuration)])
        let land = try #require(completions[.seconds(exchange.duration)])
        retire()
        #expect(motion.shelfID == nil)
        land()
        #expect(motion.shelfID == nil && motion.flight?.id == exchange.id)
        motion.shelfDidDisappear(99) // An unrelated old callback must not complete this exchange.
        #expect(motion.shelfID == nil)
        motion.shelfDidDisappear(1)
        #expect(motion.shelfID == 2 && motion.flight == nil)
    }

    @MainActor
    @Test func clickingAndUsingArrowsRevokesTheStationaryPointersDwell() async throws {
        let motion = WorkTopicMotionCoordinator(dwell: .milliseconds(25))
        var selected: [Int64] = []
        motion.enter(2) { selected.append(2) }
        motion.confirmByInput()
        selected.append(2)
        motion.confirmByInput()
        selected.append(3)
        motion.enter(2) { selected.append(2) } // Still inside the very same tracking area.
        try await Task.sleep(for: .milliseconds(50))
        #expect(selected == [2, 3])
    }

    @Test func curvedPathsHitBothEndpointsAndSeparateTheTwoCardsInFlight() {
        let slot = CGRect(x: 200, y: 80, width: 64, height: 88)
        let stage = CGRect(x: 20, y: 200, width: 190, height: 600)
        #expect(WorkTopicFlightPath.frame(slot: slot, stage: stage, expansion: 0, returning: false) == slot)
        #expect(WorkTopicFlightPath.frame(slot: slot, stage: stage, expansion: 1, returning: true) == stage)
        let incoming = WorkTopicFlightPath.frame(slot: slot, stage: stage, expansion: 0.5, returning: false)
        let outgoing = WorkTopicFlightPath.frame(slot: slot, stage: stage, expansion: 0.5, returning: true)
        #expect(incoming.size == outgoing.size && incoming.midX < outgoing.midX)
    }

    @MainActor private func waitFor(_ predicate: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(2)
        while !predicate() && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    @Test func avatarDecodesToRequestedPixelSizeAndInvalidatesByRevision() async throws {
        let url = TestRunResources.directory.appending(path: "\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: url) }

        func writeImage(width: Int, height: Int, visible: CGRect? = nil) throws {
            let bitmap = try #require(CGContext(data: nil, width: width, height: height,
                                                bitsPerComponent: 8, bytesPerRow: width * 4,
                                                space: CGColorSpaceCreateDeviceRGB(),
                                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            bitmap.setFillColor(CGColor(gray: 0.5, alpha: 1))
            bitmap.fill(visible ?? CGRect(x: 0, y: 0, width: width, height: height))
            let image = try #require(bitmap.makeImage())
            let destination = try #require(CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil))
            CGImageDestinationAddImage(destination, image, nil)
            #expect(CGImageDestinationFinalize(destination))
        }

        let cache = WorkTopicAvatarCache()
        try writeImage(width: 160, height: 320)
        let first = await cache.image(for: .init(url: url, revision: 1, pixels: 80))
        #expect(first?.width == 40)
        #expect(first?.height == 80)
        try writeImage(width: 640, height: 320)
        let next = await cache.image(for: .init(url: url, revision: 2, pixels: 80))
        #expect(next?.width == 80)
        #expect(next?.height == 40)

        // The art deliberately occupies a small, off-center corner of the source.
        try writeImage(width: 80, height: 80, visible: CGRect(x: 8, y: 50, width: 10, height: 20))
        let cropped = try #require(await cache.image(for: .init(url: url, revision: 3, pixels: 80)))
        #expect(cropped.width == 14)
        #expect(cropped.height == 24)
        let croppedURL = url.deletingLastPathComponent().appending(path: "\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: croppedURL) }
        let destination = try #require(CGImageDestinationCreateWithURL(croppedURL as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, cropped, nil)
        #expect(CGImageDestinationFinalize(destination))
        // A second pass must keep the subject rather than crop the vertical mirror region.
        let roundTrip = await cache.image(for: .init(url: croppedURL, revision: 1, pixels: 80))
        #expect(roundTrip?.height == 24)

        try writeImage(width: 80, height: 80, visible: .zero)
        let blank = await cache.image(for: .init(url: url, revision: 4, pixels: 80))
        #expect(blank == nil)
    }

    @Test func cancelledPortraitScanStopsBeforeReportingVisibleArt() async {
        let result = await Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return [UInt8](repeating: 255, count: 128 * 128).withUnsafeBufferPointer { pixels in
                CharacterPortraitImageProcessor.visibleBounds(
                    pixels: pixels, width: 128, height: 128,
                    bytesPerRow: 128, samplesPerPixel: 1, alphaIndex: 0
                )
            }
        }.value
        #expect(result == nil)
    }
}

private actor PortraitGate {
    private var continuations: [Int64: CheckedContinuation<CGImage?, Never>] = [:]

    private let started: AsyncStream<Int64>.Continuation

    init(started: AsyncStream<Int64>.Continuation) { self.started = started }

    func load(_ request: WorkTopicAvatarRequest) async -> CGImage? {
        await withCheckedContinuation { continuation in
            continuations[request.revision] = continuation
            started.yield(request.revision)
        }
    }

    func complete(revision: Int64, with image: CGImage) {
        continuations.removeValue(forKey: revision)?.resume(returning: image)
    }
}
