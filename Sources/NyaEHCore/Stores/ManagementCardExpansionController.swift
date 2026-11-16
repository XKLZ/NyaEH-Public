import Foundation
import Observation

/// Transient UI state owned by one expandable list, never by the catalog or preferences.
@MainActor
@Observable
final class ManagementCardExpansionController<ID: Hashable & Sendable> {
    static var openingDelay: Duration { .milliseconds(350) }
    static var closingDelay: Duration { .milliseconds(150) }

    private(set) var previewID: ID?
    @ObservationIgnored private var isScrolling = false
    @ObservationIgnored private var requiresPointerMovement = false
    @ObservationIgnored private var pointerBaseline: CGPoint?

    private var states: [ID: ManagementCardExpansionState] = [:]
    @ObservationIgnored private var pending: [ID: PendingRequest] = [:]
    @ObservationIgnored private var nextRevision: UInt64 = 0
    @ObservationIgnored private let sleep: @Sendable (Duration) async throws -> Void

    private struct PendingRequest {
        let revision: UInt64
        let task: Task<Void, Never>
    }

    init(sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }) {
        self.sleep = sleep
    }

    deinit {
        for request in pending.values { request.task.cancel() }
    }

    var expandedIDs: Set<ID> {
        Set(states.compactMap { $0.value.isExpanded ? $0.key : nil })
    }

    var pendingRequestCount: Int { pending.count }

    // Tests can await a snapshot of cancelled/replaced work without relying on wall-clock timing.
    func pendingTask(for id: ID) -> Task<Void, Never>? { pending[id]?.task }

    func state(for id: ID) -> ManagementCardExpansionState {
        states[id] ?? ManagementCardExpansionState()
    }

    func pointerActive(at location: CGPoint, for id: ID) {
        guard !isScrolling else { return }
        if requiresPointerMovement {
            guard let baseline = pointerBaseline else {
                pointerBaseline = location
                return
            }
            guard hypot(location.x - baseline.x, location.y - baseline.y) >= 1 else { return }
            requiresPointerMovement = false
        }
        pointerBaseline = location
        setHovering(true, for: id)
    }

    func setScrolling(_ scrolling: Bool, pointerLocation: CGPoint) {
        isScrolling = scrolling
        if scrolling { suspendPreviews(pointerLocation: pointerLocation) }
        if requiresPointerMovement { pointerBaseline = pointerLocation }
    }

    /// Preserve explicit pins while invalidating all automatic previews and their work.
    func suspendPreviews(pointerLocation: CGPoint? = nil) {
        for request in pending.values { request.task.cancel() }
        pending.removeAll()
        for id in Array(states.keys) { states[id]?.clearHover() }
        previewID = nil
        requiresPointerMovement = true
        pointerBaseline = pointerLocation
    }

    func setPreviewHovering(_ hovering: Bool, for id: ID) {
        guard previewID == id else { return }
        cancelPending(for: id)
        states[id]?.setPreviewHovered(hovering)
        if let target = state(for: id).pendingHoverTarget { schedule(target, for: id) }
    }

    func setHovering(_ hovering: Bool, for id: ID) {
        var state = state(for: id)
        guard state.isHovering != hovering else { return }
        cancelPending(for: id)
        state.setHovering(hovering)
        states[id] = state
        guard let target = state.pendingHoverTarget else { return }
        schedule(target, for: id)
    }

    func togglePinned(for id: ID) {
        cancelPending(for: id)
        var state = state(for: id)
        state.togglePinned()
        states[id] = state
        if previewID == id { previewID = nil }
    }

    func cardDisappeared(_ id: ID) {
        cancelPending(for: id)
        guard var state = states[id] else { return }
        state.clearHover()
        if previewID == id { previewID = nil }
        // A lazy row can disappear while scrolling; retain its explicit pin until list exit.
        states[id] = state
    }

    func retainCards(_ ids: Set<ID>) {
        for id in Set(states.keys).union(pending.keys).subtracting(ids) {
            cancelPending(for: id)
            states[id] = nil
            if previewID == id { previewID = nil }
        }
    }

    func reset() {
        for request in pending.values { request.task.cancel() }
        pending.removeAll()
        states.removeAll()
        previewID = nil
        isScrolling = false
        requiresPointerMovement = false
        pointerBaseline = nil
    }

    private func cancelPending(for id: ID) {
        pending.removeValue(forKey: id)?.task.cancel()
    }

    private func schedule(_ target: Bool, for id: ID) {
        nextRevision &+= 1
        let revision = nextRevision
        let delay = target ? Self.openingDelay : Self.closingDelay
        let sleep = sleep
        // The list owns these tasks. Each checks UI request identity before and after waiting;
        // replacement, row disappearance, and list exit cancel the corresponding work.
        let task = Task { @MainActor [weak self] in
            guard self?.pending[id]?.revision == revision else { return }
            do {
                try await sleep(delay)
            } catch {
                self?.finishRequest(for: id, revision: revision)
                return
            }
            guard !Task.isCancelled, let self,
                  pending[id]?.revision == revision else { return }
            finishRequest(for: id, revision: revision)
            var state = state(for: id)
            guard state.pendingHoverTarget == target else { return }
            if target {
                if let previous = previewID, previous != id {
                    cancelPending(for: previous)
                    states[previous]?.setPreviewVisible(false)
                    states[previous]?.setPreviewHovered(false)
                }
                previewID = id
            } else if previewID == id {
                previewID = nil
            }
            state.setPreviewVisible(target)
            states[id] = state
        }
        pending[id] = PendingRequest(revision: revision, task: task)
    }

    private func finishRequest(for id: ID, revision: UInt64) {
        guard pending[id]?.revision == revision else { return }
        pending[id] = nil
    }
}
