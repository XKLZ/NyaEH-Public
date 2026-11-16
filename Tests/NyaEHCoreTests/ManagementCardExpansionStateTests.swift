import Foundation
import Testing
@testable import NyaEHCore

@Suite("Management card expansion")
struct ManagementCardExpansionStateTests {
    @Test("delayed hover changes preview visibility without changing inline layout")
    func hoverPreviewsSeparately() {
        var state = ManagementCardExpansionState()
        state.setHovering(true)
        #expect(state.isHovering)
        #expect(state.pendingHoverTarget == true)
        state.setPreviewVisible(true)
        #expect(state.isPreviewVisible)
        #expect(!state.isExpanded)
        state.setHovering(false)
        #expect(state.isPreviewVisible)
        #expect(state.pendingHoverTarget == false)
        state.setPreviewVisible(false)
        #expect(!state.isPreviewVisible)
    }

    @Test("disclosure pin survives hover and suppresses reopening until pointer exit")
    func disclosurePinSurvivesHover() {
        var state = ManagementCardExpansionState()
        state.setHovering(true)
        state.togglePinned()
        state.setHovering(false)
        #expect(state.isExpanded)
        #expect(state.pendingHoverTarget == nil)
        state.setHovering(true)
        state.togglePinned()
        #expect(!state.isExpanded)
        #expect(state.pendingHoverTarget == nil)
        state.setHovering(false)
        state.setHovering(true)
        #expect(state.pendingHoverTarget == true)
    }

    @Test("keyboard disclosure works without a pointer")
    func keyboardDisclosure() {
        var state = ManagementCardExpansionState()
        state.togglePinned()
        #expect(state.isExpanded)
        state.togglePinned()
        #expect(!state.isExpanded)
    }

    @MainActor
    @Test("quick pointer pass cancels opening and reaches the sleeper")
    func quickPassCancelsOpening() async {
        let delay = ManagementHoverDelayGate()
        let controller = ManagementCardExpansionController<Int>(sleep: { try await delay.sleep($0) })
        controller.setHovering(true, for: 1)
        let task = controller.pendingTask(for: 1)
        await delay.waitForRequests(1)
        #expect(await delay.duration(for: 0) == .milliseconds(350))
        #expect(controller.state(for: 1).isHovering)
        #expect(!controller.state(for: 1).isExpanded)
        controller.setHovering(false, for: 1)
        await task?.value
        #expect(await delay.wasCancelled(0))
        #expect(!controller.state(for: 1).isExpanded)
        #expect(controller.pendingRequestCount == 0)
    }

    @MainActor
    @Test("returning to an expanded card cancels closing without another opening wait")
    func returnCancelsClosing() async {
        let delay = ManagementHoverDelayGate()
        let controller = ManagementCardExpansionController<Int>(sleep: { try await delay.sleep($0) })
        controller.setHovering(true, for: 1)
        let opening = controller.pendingTask(for: 1)
        await delay.waitForRequests(1)
        await delay.finish(0)
        await opening?.value
        #expect(controller.previewID == 1)
        #expect(controller.expandedIDs.isEmpty)

        controller.setHovering(false, for: 1)
        let closing = controller.pendingTask(for: 1)
        await delay.waitForRequests(2)
        #expect(await delay.duration(for: 1) == .milliseconds(150))
        controller.setHovering(true, for: 1)
        await closing?.value
        #expect(controller.state(for: 1).isPreviewVisible)
        #expect(controller.previewID == 1)
        #expect(controller.pendingRequestCount == 0)

        controller.setHovering(false, for: 1)
        let finalClosing = controller.pendingTask(for: 1)
        await delay.waitForRequests(3)
        await delay.finish(2)
        await finalClosing?.value
        #expect(controller.previewID == nil)
        #expect(controller.expandedIDs.isEmpty)
    }

    @MainActor
    @Test("late cancelled work cannot publish or clear its replacement")
    func staleRequestCannotReplaceNewIntent() async {
        let delay = ManagementHoverDelayGate(ignoresCancellation: true)
        let controller = ManagementCardExpansionController<Int>(sleep: { try await delay.sleep($0) })
        controller.setHovering(true, for: 1)
        let old = controller.pendingTask(for: 1)
        await delay.waitForRequests(1)
        controller.setHovering(false, for: 1)
        controller.setHovering(true, for: 1)
        let replacement = controller.pendingTask(for: 1)
        await delay.waitForRequests(2)
        await delay.finish(0)
        await old?.value
        #expect(controller.previewID == nil)
        #expect(controller.pendingRequestCount == 1)
        await delay.finish(1)
        await replacement?.value
        #expect(controller.state(for: 1).isPreviewVisible)
        #expect(controller.previewID == 1)
        #expect(controller.pendingRequestCount == 0)
    }

    @MainActor
    @Test("pin is immediate, cancels waiting, and manual close requires a fresh hover")
    func pinOverridesWaiting() async {
        let delay = ManagementHoverDelayGate()
        let controller = ManagementCardExpansionController<Int>(sleep: { try await delay.sleep($0) })
        controller.setHovering(true, for: 1)
        let task = controller.pendingTask(for: 1)
        await delay.waitForRequests(1)
        controller.togglePinned(for: 1)
        #expect(controller.state(for: 1).isPinned)
        #expect(controller.state(for: 1).isExpanded)
        await task?.value
        controller.togglePinned(for: 1)
        controller.setHovering(true, for: 1)
        #expect(!controller.state(for: 1).isExpanded)
        #expect(controller.pendingRequestCount == 0)
        controller.setHovering(false, for: 1)
        controller.setHovering(true, for: 1)
        let reopening = controller.pendingTask(for: 1)
        await delay.waitForRequests(2)
        await delay.finish(1)
        await reopening?.value
        #expect(controller.previewID == 1)
        #expect(!controller.state(for: 1).isExpanded)
    }

    @MainActor
    @Test("row disappearance and list exit invalidate pending work and preserve only live pins")
    func disappearanceCancelsWork() async {
        let delay = ManagementHoverDelayGate(ignoresCancellation: true)
        let controller = ManagementCardExpansionController<Int>(sleep: { try await delay.sleep($0) })
        controller.setHovering(true, for: 1)
        let first = controller.pendingTask(for: 1)
        await delay.waitForRequests(1)
        controller.cardDisappeared(1)
        await delay.finish(0)
        await first?.value
        #expect(!controller.state(for: 1).isExpanded)

        controller.togglePinned(for: 1)
        controller.cardDisappeared(1)
        #expect(controller.state(for: 1).isPinned)
        controller.setHovering(true, for: 2)
        let second = controller.pendingTask(for: 2)
        await delay.waitForRequests(2)
        controller.reset()
        await delay.finish(1)
        await second?.value
        #expect(controller.expandedIDs.isEmpty)
        #expect(!controller.state(for: 2).isHovering)
        #expect(controller.pendingRequestCount == 0)
    }

    @MainActor
    @Test("removing a card prunes only its work and state")
    func removingCardPreservesOtherCards() async {
        let delay = ManagementHoverDelayGate()
        let controller = ManagementCardExpansionController<Int>(sleep: { try await delay.sleep($0) })
        controller.togglePinned(for: 1)
        controller.setHovering(true, for: 2)
        let removed = controller.pendingTask(for: 2)
        await delay.waitForRequests(1)
        controller.retainCards([1])
        await removed?.value
        #expect(controller.expandedIDs == [1])
        #expect(!controller.state(for: 2).isHovering)
        #expect(controller.pendingRequestCount == 0)
    }

    @MainActor
    @Test("moving into the preview cancels closing and preserves one shared hover region")
    func previewHoverCancelsClosing() async {
        let delay = ManagementHoverDelayGate()
        let controller = ManagementCardExpansionController<Int>(sleep: { try await delay.sleep($0) })
        controller.setHovering(true, for: 1)
        let opening = controller.pendingTask(for: 1)
        await delay.waitForRequests(1)
        await delay.finish(0)
        await opening?.value
        controller.setHovering(false, for: 1)
        let closing = controller.pendingTask(for: 1)
        await delay.waitForRequests(2)
        controller.setPreviewHovering(true, for: 1)
        await closing?.value
        #expect(controller.previewID == 1)
        #expect(controller.pendingRequestCount == 0)
        controller.setPreviewHovering(false, for: 1)
        let finalClosing = controller.pendingTask(for: 1)
        await delay.waitForRequests(3)
        await delay.finish(2)
        await finalClosing?.value
        #expect(controller.previewID == nil)
    }

    @MainActor
    @Test("late close of an old preview cannot dismiss a new target")
    func switchingTargetsKeepsOnlyLatestPreview() async {
        let delay = ManagementHoverDelayGate(ignoresCancellation: true)
        let controller = ManagementCardExpansionController<Int>(sleep: { try await delay.sleep($0) })
        controller.setHovering(true, for: 1)
        let first = controller.pendingTask(for: 1)
        await delay.waitForRequests(1)
        await delay.finish(0)
        await first?.value
        controller.setHovering(false, for: 1)
        let lateClose = controller.pendingTask(for: 1)
        await delay.waitForRequests(2)
        controller.setHovering(true, for: 2)
        let second = controller.pendingTask(for: 2)
        await delay.waitForRequests(3)
        await delay.finish(2)
        await second?.value
        #expect(controller.previewID == 2)
        #expect(!controller.state(for: 1).isPreviewVisible)
        #expect(controller.expandedIDs.isEmpty)
        await delay.finish(1)
        await lateClose?.value
        controller.setPreviewHovering(true, for: 1)
        #expect(controller.previewID == 2)
        #expect(controller.pendingRequestCount == 0)
    }

    @MainActor
    @Test("pinning a visible preview closes it and only expands that row inline")
    func pinVisiblePreview() async {
        let delay = ManagementHoverDelayGate()
        let controller = ManagementCardExpansionController<Int>(sleep: { try await delay.sleep($0) })
        controller.setHovering(true, for: 1)
        let opening = controller.pendingTask(for: 1)
        await delay.waitForRequests(1)
        await delay.finish(0)
        await opening?.value
        controller.togglePinned(for: 1)
        #expect(controller.previewID == nil)
        #expect(controller.expandedIDs == [1])
        controller.setPreviewHovering(true, for: 1)
        #expect(!controller.state(for: 1).isPreviewVisible)
    }

    @MainActor
    @Test("scrolling invalidates pending work and requires real screen-pointer movement")
    func scrollingRequiresPointerMovement() async {
        let delay = ManagementHoverDelayGate(ignoresCancellation: true)
        let controller = ManagementCardExpansionController<Int>(sleep: { try await delay.sleep($0) })
        let pointer = CGPoint(x: 200, y: 300)
        controller.togglePinned(for: 9)
        controller.pointerActive(at: pointer, for: 1)
        let old = controller.pendingTask(for: 1)
        await delay.waitForRequests(1)
        controller.setScrolling(true, pointerLocation: pointer)
        controller.pointerActive(at: CGPoint(x: 210, y: 310), for: 2)
        #expect(controller.pendingRequestCount == 0)
        controller.setScrolling(false, pointerLocation: pointer)
        controller.pointerActive(at: pointer, for: 2)
        #expect(controller.pendingRequestCount == 0)
        await delay.finish(0)
        await old?.value
        #expect(controller.previewID == nil)
        #expect(controller.expandedIDs == [9])
        controller.pointerActive(at: CGPoint(x: 202, y: 300), for: 2)
        let next = controller.pendingTask(for: 2)
        await delay.waitForRequests(2)
        await delay.finish(1)
        await next?.value
        #expect(controller.previewID == 2)
        controller.suspendPreviews(pointerLocation: pointer)
        #expect(controller.previewID == nil)
        #expect(controller.expandedIDs == [9])
    }

}

private actor ManagementHoverDelayGate {
    private struct Request {
        let continuation: CheckedContinuation<Void, Error>
    }

    private let ignoresCancellation: Bool
    private var requestCount = 0
    private var requests: [Int: Request] = [:]
    private var durations: [Int: Duration] = [:]
    private var cancelled: Set<Int> = []
    private var startWaiters: [(Int, CheckedContinuation<Void, Never>)] = []

    init(ignoresCancellation: Bool = false) { self.ignoresCancellation = ignoresCancellation }

    func sleep(_ duration: Duration) async throws {
        let id = requestCount
        requestCount += 1
        durations[id] = duration
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                requests[id] = Request(continuation: continuation)
                let ready = startWaiters.filter { requestCount >= $0.0 }
                startWaiters.removeAll { requestCount >= $0.0 }
                for (_, waiter) in ready { waiter.resume() }
            }
        } onCancel: {
            Task { await self.cancel(id) }
        }
    }

    func waitForRequests(_ count: Int) async {
        guard requestCount < count else { return }
        await withCheckedContinuation { startWaiters.append((count, $0)) }
    }

    func duration(for id: Int) -> Duration? { durations[id] }
    func wasCancelled(_ id: Int) -> Bool { cancelled.contains(id) }
    func finish(_ id: Int) { requests.removeValue(forKey: id)?.continuation.resume() }

    private func cancel(_ id: Int) {
        cancelled.insert(id)
        if !ignoresCancellation {
            requests.removeValue(forKey: id)?.continuation.resume(throwing: CancellationError())
        }
    }
}
