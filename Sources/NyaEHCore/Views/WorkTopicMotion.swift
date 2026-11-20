import SwiftUI

@MainActor @Observable final class WorkTopicCardSource {
    @ObservationIgnored var bounds = CGRect.zero
    var isLifted = false
    var isVacant = false
    var returnedImage: CGImage?
}

/// The page owns the coordinator. The selector only confirms an intent; a single decoded
/// portrait stays with the character from takeoff through landing and its eventual return.
@MainActor @Observable final class WorkTopicMotionCoordinator {
    struct Portrait {
        let character: TagDisplaySummary
        let request: WorkTopicAvatarRequest?
        let image: CGImage?
    }

    struct Exchange: Identifiable {
        let id = UUID()
        let started = Date.now
        let incoming: Portrait
        let outgoing: Portrait?
        let outgoingStage: CGRect?
        let incomingSlot: CGRect?
        let returnSlot: CGRect?
        let fadesOnly: Bool

        var duration: TimeInterval { fadesOnly ? 0.15 : 0.38 }
    }

    private struct Intent {
        let character: TagDisplaySummary
        let request: WorkTopicAvatarRequest?
        let restore: Bool
        let reduceMotion: Bool
        let select: (Tag.DatabaseID) -> Void
    }

    private(set) var active: Portrait?
    private(set) var flight: Exchange?
    private(set) var shelfID: Tag.DatabaseID?
    private(set) var shelfIsExiting = false
    private(set) var animateShelfEntrance = false
    var shelfExitDuration: TimeInterval { flight?.fadesOnly == true ? 0.12 : 0.22 }
    @ObservationIgnored private(set) var commitCount = 0
    @ObservationIgnored private(set) var largePortraitRequestCount = 0
    @ObservationIgnored private(set) var previewCount = 0
    @ObservationIgnored private(set) var flightCount = 0
    @ObservationIgnored var selectorViewport = CGRect.zero
    @ObservationIgnored var pageSize = CGSize.zero
    @ObservationIgnored private var returnedSlot: Tag.DatabaseID?
    @ObservationIgnored private var stage: (id: Tag.DatabaseID, bounds: CGRect)?
    @ObservationIgnored private var sources: [Tag.DatabaseID: WorkTopicCardSource] = [:]

    @ObservationIgnored private var candidate: Tag.DatabaseID?
    @ObservationIgnored private var selectHovered: (() -> Void)?
    @ObservationIgnored private var dwell: Task<Void, Never>?
    @ObservationIgnored private var wheelQuiet: Task<Void, Never>?
    @ObservationIgnored private var scrolling = false
    private(set) var previewID: Tag.DatabaseID? {
        didSet {
            guard previewID != oldValue else { return }
            if let oldValue { sources[oldValue]?.isLifted = false }
            if let previewID { sources[previewID]?.isLifted = true }
        }
    }

    @ObservationIgnored private var pending: Intent?
    @ObservationIgnored private var preparation: Task<Void, Never>?
    @ObservationIgnored private var preparationID: UUID?
    @ObservationIgnored private var retirement: Task<Void, Never>?
    @ObservationIgnored private var mountedShelfID: Tag.DatabaseID?
    @ObservationIgnored private var landingAwaitingRemoval: UUID?
    @ObservationIgnored private var landing: Task<Void, Never>?
    typealias ScheduleAnimation = @MainActor (Duration, @escaping @MainActor () -> Void) -> Task<Void, Never>?
    private let scheduleAnimation: ScheduleAnimation
    private let dwellDuration: Duration
    private let load: @Sendable (WorkTopicAvatarRequest) async -> CGImage?

    init(dwell: Duration = .milliseconds(150), scheduleAnimation: ScheduleAnimation? = nil,
         load: @escaping @Sendable (WorkTopicAvatarRequest) async -> CGImage? = WorkTopicAvatarCache.stageImage(for:)) {
        dwellDuration = dwell
        self.load = load
        self.scheduleAnimation = scheduleAnimation ?? { delay, action in
            Task {
                do { try await Task.sleep(for: delay) } catch { return }
                action()
            }
        }
    }

    func mount(_ source: WorkTopicCardSource, id: Tag.DatabaseID) {
        sources[id] = source
        source.isLifted = previewID == id
        source.isVacant = active?.character.id == id || flight?.outgoing?.character.id == id
    }

    func unmount(_ source: WorkTopicCardSource, id: Tag.DatabaseID) {
        guard sources[id] === source else { return }
        sources.removeValue(forKey: id)
        source.returnedImage = nil
        leave(id)
    }

    func slot(_ id: Tag.DatabaseID) -> CGRect? {
        guard let rect = sources[id]?.bounds, !rect.isEmpty,
              selectorViewport.contains(CGPoint(x: rect.midX, y: rect.midY)) else { return nil }
        return rect
    }

    func returnSlot(for exchange: Exchange) -> CGRect? {
        guard let original = exchange.returnSlot, let id = exchange.outgoing?.character.id else { return nil }
        // A retreating card can follow its slot under the sidebar. The departing
        // card, in contrast, has already left the selector and keeps its takeoff point.
        guard let source = sources[id] else { return original }
        return source.bounds.offsetBy(dx: 0, dy: source.isLifted ? -4 : 0)
    }

    func locateStage(for id: Tag.DatabaseID, bounds: CGRect) {
        stage = (id, bounds)
    }

    func enter(_ id: Tag.DatabaseID, select: @escaping () -> Void) {
        guard candidate != id else { return }
        candidate = id
        selectHovered = select
        scheduleHover()
    }

    func leave(_ id: Tag.DatabaseID) {
        guard candidate == id else { return }
        candidate = nil
        selectHovered = nil
        suspendHover()
    }

    func setScrolling(_ active: Bool) {
        guard scrolling != active else { return }
        scrolling = active
        scheduleHover()
    }

    func wheelMoved() {
        wheelQuiet?.cancel()
        wheelQuiet = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(100)) } catch { return }
            guard let self else { return }
            self.wheelQuiet = nil
            self.scheduleHover()
        }
        suspendHover()
    }

    private func scheduleHover() {
        suspendHover()
        guard !scrolling, wheelQuiet == nil, let candidate, selectHovered != nil else { return }
        previewID = candidate
        previewCount += 1
        dwell = Task { [weak self, dwellDuration] in
            do { try await Task.sleep(for: dwellDuration) } catch { return }
            guard let self, self.candidate == candidate else { return }
            self.dwell = nil
            let action = self.selectHovered
            self.selectHovered = nil
            action?()
        }
    }

    private func suspendHover() {
        dwell?.cancel()
        dwell = nil
        previewID = nil
    }

    func confirmByInput(keepLift: Bool = false) {
        // A click or arrow key has already chosen a role. A timer left under the
        // stationary pointer must not overrule that choice 150 milliseconds later.
        dwell?.cancel()
        dwell = nil
        selectHovered = nil
        if !keepLift { previewID = nil }
    }

    func cancelHover() {
        suspendHover()
        wheelQuiet?.cancel()
        wheelQuiet = nil
        scrolling = false
        candidate = nil
        selectHovered = nil
    }

    func show(_ character: TagDisplaySummary, request: WorkTopicAvatarRequest?,
              restore: Bool = false, reduceMotion: Bool, select: @escaping (Tag.DatabaseID) -> Void) {
        if let pending, pending.character == character, pending.request == request { return }
        preparation?.cancel()
        preparation = nil
        preparationID = nil
        pending = nil
        if active?.character == character, active?.request == request {
            // Selecting the active destination again also revokes an outstanding replacement.
            if flight == nil && shelfID == nil { settleShelf(animate: !restore) }
            return
        }
        pending = Intent(character: character, request: request, restore: restore, reduceMotion: reduceMotion, select: select)
        if flight == nil { preparePending() }
    }

    private func preparePending() {
        guard let intent = pending else { return }
        let token = UUID()
        preparationID = token
        let needsFirstLayout = active == nil && !intent.restore && sources[intent.character.id] == nil
        // Restore navigation and the shelf immediately. An uncached asset can resolve in place.
        if intent.restore && active == nil {
            active = Portrait(character: intent.character, request: nil, image: nil)
            sources[intent.character.id]?.isVacant = true
            settleShelf(animate: false)
            intent.select(intent.character.id)
            if intent.request == nil {
                preparationID = nil
                pending = nil
                return
            }
        }
        if intent.request != nil { largePortraitRequestCount += 1 }
        preparation = Task { [weak self, load] in
            let image: CGImage?
            if let request = intent.request { image = await load(request) } else { image = nil }
            if needsFirstLayout {
                do { try await Task.sleep(for: .milliseconds(16)) } catch { return }
            }
            guard !Task.isCancelled, let self, self.preparationID == token else { return }
            self.preparation = nil
            self.preparationID = nil
            self.pending = nil
            self.begin(intent, image: image)
        }
    }

    private func begin(_ intent: Intent, image: CGImage?) {
        let incoming = Portrait(character: intent.character, request: intent.request, image: image)
        let outgoing = active
        let id = incoming.character.id
        if intent.restore || outgoing?.character.id == id {
            if let previous = outgoing?.character.id, previous != id { sources[previous]?.isVacant = false }
            active = incoming
            sources[id]?.isVacant = true
            settleShelf(animate: false)
            if outgoing?.character.id != id { intent.select(id) }
            return
        }

        let incomingSlot = slot(id)?.offsetBy(dx: 0, dy: previewID == id && !intent.reduceMotion ? -4 : 0)
        let returnSlot = outgoing.flatMap { slot($0.character.id) }
        let hasEndpoint = incomingSlot != nil || returnSlot != nil
        let visibleStage = stage.map { WorkTopicFlightPath.stageVisible($0.bounds, viewport: pageSize, below: selectorViewport.maxY) } ?? true
        let exchange = Exchange(incoming: incoming, outgoing: outgoing,
                                outgoingStage: stage?.id == outgoing?.character.id ? stage?.bounds : nil,
                                incomingSlot: incomingSlot, returnSlot: returnSlot,
                                fadesOnly: intent.reduceMotion || !hasEndpoint || !visibleStage)
        active = incoming
        flight = exchange
        sources[id]?.isVacant = true
        shelfIsExiting = shelfID != nil
        commitCount += 1
        if !exchange.fadesOnly { flightCount += 1 }
        intent.select(id)

        if let previous = shelfID {
            retirement = scheduleAnimation(.seconds(shelfExitDuration)) { [weak self] in
                guard let self, self.flight?.id == exchange.id, self.shelfID == previous else { return }
                self.retirement = nil
                self.shelfID = nil
            }
        }
        landing = scheduleAnimation(.seconds(exchange.duration)) { [weak self] in
            self?.finish(exchange.id)
        }
    }

    func shelfDidAppear(_ id: Tag.DatabaseID) {
        if shelfID == id || flight?.outgoing?.character.id == id { mountedShelfID = id }
    }

    func shelfDidDisappear(_ id: Tag.DatabaseID) {
        guard mountedShelfID == id else { return }
        mountedShelfID = nil
        if let token = landingAwaitingRemoval { finish(token) }
    }

    func finish(_ token: UUID) {
        guard let exchange = flight, exchange.id == token else { return }
        retirement?.cancel()
        retirement = nil
        shelfID = nil
        // SwiftUI can process removal after the animation clock has finished (for
        // example, while the main loop is busy). Publish no replacement until that
        // particular carousel has actually left the tree.
        if mountedShelfID != nil {
            landingAwaitingRemoval = token
            return
        }
        landingAwaitingRemoval = nil
        landing?.cancel()
        landing = nil
        flight = nil
        if let previous = returnedSlot { sources[previous]?.returnedImage = nil }
        returnedSlot = exchange.outgoing?.character.id
        if let outgoing = exchange.outgoing, let slot = sources[outgoing.character.id] {
            // Keep the exact last flight raster in its small resting slot. At most one
            // returned cell retains a stage-sized image, even after visiting an entire work.
            slot.returnedImage = outgoing.image
            slot.isVacant = false
        }
        if pending != nil {
            // Keep the last selection's old shelf retired while the next portrait decodes.
            shelfID = nil
            shelfIsExiting = false
            preparePending()
        } else {
            settleShelf(animate: true)
        }
    }

    private func settleShelf(animate: Bool) {
        animateShelfEntrance = animate
        shelfIsExiting = false
        shelfID = active?.character.id
    }

    func image(for id: Tag.DatabaseID) -> CGImage? {
        active?.character.id == id ? active?.image : nil
    }

    func clear() {
        cancelHover()
        preparation?.cancel()
        preparation = nil
        preparationID = nil
        pending = nil
        retirement?.cancel()
        retirement = nil
        mountedShelfID = nil
        landingAwaitingRemoval = nil
        landing?.cancel()
        landing = nil
        if let id = active?.character.id { sources[id]?.isVacant = false }
        if let id = flight?.outgoing?.character.id { sources[id]?.isVacant = false }
        if let returnedSlot { sources[returnedSlot]?.returnedImage = nil }
        returnedSlot = nil
        active = nil
        flight = nil
        stage = nil
        settleShelf(animate: false)
    }
}

private struct WorkTopicStageAnchor: PreferenceKey {
    struct Stage {
        let id: Tag.DatabaseID
        let bounds: Anchor<CGRect>
    }
    static var defaultValue: Stage? { nil }
    static func reduce(value: inout Stage?, nextValue: () -> Stage?) {
        value = nextValue() ?? value
    }
}

extension View {
    func workTopicPortraitStage(characterID: Tag.DatabaseID, motion: WorkTopicMotionCoordinator) -> some View {
        modifier(WorkTopicStageMotion(characterID: characterID, motion: motion))
    }

    func workTopicFlightOverlay<Nameplate: View>(_ motion: WorkTopicMotionCoordinator,
                                                @ViewBuilder nameplate: @escaping (TagDisplaySummary) -> Nameplate) -> some View {
        overlayPreferenceValue(WorkTopicStageAnchor.self) { anchor in
            GeometryReader { proxy in
                if let exchange = motion.flight {
                    let destination = anchor.flatMap { $0.id == exchange.incoming.character.id ? proxy[$0.bounds] : nil }
                    TimelineView(.animation) { timeline in
                        let elapsed = timeline.date.timeIntervalSince(exchange.started)
                        let fraction = min(1, max(0, elapsed / exchange.duration))
                        let progress = CGFloat(fraction * fraction * (3 - 2 * fraction))
                        ZStack {
                            if let outgoing = exchange.outgoing, let stage = exchange.outgoingStage {
                                journey(outgoing, stage: stage, slot: motion.returnSlot(for: exchange), expansion: 1 - progress,
                                        returning: true, fadesOnly: exchange.fadesOnly, viewport: proxy.size,
                                        below: motion.selectorViewport.maxY, nameplate: nameplate)
                            }
                            if let destination {
                                journey(exchange.incoming, stage: destination,
                                        slot: exchange.incomingSlot,
                                        expansion: progress, returning: false, fadesOnly: exchange.fadesOnly, viewport: proxy.size,
                                        below: motion.selectorViewport.maxY, nameplate: nameplate)
                            }
                        }
                        .frame(width: proxy.size.width, height: proxy.size.height, alignment: .topLeading)
                    }
                }
            }
            .onGeometryChange(for: CGSize.self) { $0.size } action: { motion.pageSize = $0 }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
    }

    private func journey<Nameplate: View>(_ portrait: WorkTopicMotionCoordinator.Portrait, stage: CGRect, slot: CGRect?,
                                         expansion: CGFloat, returning: Bool, fadesOnly: Bool,
                                         viewport: CGSize, below top: CGFloat,
                                         nameplate: @escaping (TagDisplaySummary) -> Nameplate) -> some View {
        let canTravel = !fadesOnly && slot != nil && WorkTopicFlightPath.stageVisible(stage, viewport: viewport, below: top)
        let bounds = canTravel ? WorkTopicFlightPath.frame(slot: slot ?? stage, stage: stage, expansion: expansion, returning: returning) : stage
        return WorkTopicCharacterCard(character: portrait.character, image: portrait.image, expansion: canTravel ? expansion : 1) {
            nameplate(portrait.character)
        }
        .frame(width: bounds.width, height: bounds.height)
        .opacity(canTravel ? 1 : expansion)
        .position(x: bounds.midX, y: bounds.midY)
    }
}

enum WorkTopicFlightPath {
    static func stageVisible(_ stage: CGRect, viewport: CGSize, below header: CGFloat) -> Bool {
        let top = max(0, header)
        let visible = CGRect(x: 0, y: top, width: viewport.width, height: max(0, viewport.height - top))
        let intersection = visible.intersection(stage)
        return !stage.isEmpty && intersection.width >= min(stage.width, 20) && intersection.height >= min(stage.height, 20)
    }

    /// The quadratic Bézier control points sit on opposite sides of the direct line.
    static func frame(slot: CGRect, stage: CGRect, expansion t: CGFloat, returning: Bool) -> CGRect {
        let dx = stage.midX - slot.midX
        let dy = stage.midY - slot.midY
        let length = max(1, hypot(dx, dy))
        let bow = min(50, length * 0.16) * (returning ? -1 : 1)
        let bend = 2 * (1 - t) * t * bow
        let center = CGPoint(x: slot.midX + dx * t - bend * dy / length,
                             y: slot.midY + dy * t + bend * dx / length)
        let width = slot.width + (stage.width - slot.width) * t
        let height = slot.height + (stage.height - slot.height) * t
        return CGRect(x: center.x - width / 2, y: center.y - height / 2, width: width, height: height)
    }
}

private struct WorkTopicStageMotion: ViewModifier {
    let characterID: Tag.DatabaseID
    let motion: WorkTopicMotionCoordinator
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var bounds = CGRect.zero
    @State private var localDirection = CGSize.zero

    func body(content: Content) -> some View {
        let visible = motion.active?.character.id == characterID && motion.flight == nil
        let direction = visible && !reduceMotion ? localDirection : CGSize.zero
        content
            .environment(\.workTopicPortraitDirection, direction)
            .rotation3DEffect(.degrees(4 * hypot(direction.width, direction.height)),
                              axis: (x: -direction.height, y: direction.width, z: 0), perspective: 0.35)
            .animation(reduceMotion ? nil : .snappy(duration: 0.16, extraBounce: 0), value: direction)
            .opacity(visible ? 1 : 0)
            .allowsHitTesting(visible)
            .accessibilityHidden(!visible)
            .anchorPreference(key: WorkTopicStageAnchor.self, value: .bounds) {
                .init(id: characterID, bounds: $0)
            }
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(WorkTopicLayoutSpace.page)) } action: {
                bounds = $0
                motion.locateStage(for: characterID, bounds: $0)
            }
            .onChange(of: characterID) { _, id in
                motion.locateStage(for: id, bounds: bounds)
            }
            .contentShape(Rectangle())
            .onContinuousHover { phase in
                switch phase {
                case let .active(point):
                    guard visible, !reduceMotion, !bounds.isEmpty else { return }
                    let x = (point.x / bounds.width - 0.5) * 2
                    let y = (point.y / bounds.height - 0.5) * 2
                    let length = max(1, hypot(x, y))
                    localDirection = CGSize(width: x / length, height: y / length)
                case .ended: localDirection = .zero
                }
            }
    }
}
