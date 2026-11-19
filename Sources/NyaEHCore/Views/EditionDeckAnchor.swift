import SwiftUI

/// Placement uses bottom-left coordinates so the two possible anchor edges are explicit.
struct EditionDeckPlacement: Equatable {
    static let tileHeight: CGFloat = 42
    static let gap: CGFloat = 5
    static let step = tileHeight + gap

    let frame: CGRect
    let growsUp: Bool
    let needsScroll: Bool

    init(anchor: CGRect, viewport: CGRect, count: Int) {
        let desired = max(Self.tileHeight, CGFloat(count) * Self.step - Self.gap)
        let above = max(0, viewport.maxY - anchor.minY)
        // The front tile expands from its original lower edge in both directions.
        let frontTop = min(viewport.maxY, anchor.minY + Self.tileHeight)
        let below = max(0, frontTop - viewport.minY)
        growsUp = above >= desired || (below < desired && above >= below)
        let height = min(desired, growsUp ? above : below)
        frame = CGRect(x: anchor.minX, y: growsUp ? anchor.minY : frontTop - height,
                       width: anchor.width, height: height)
        needsScroll = height < desired
    }
}

// A single reversible timeline. Reading it backwards naturally gathers the farthest visible tile first.
struct EditionDeckMotion {
    let layout: EditionDeckPlacement
    let count: Int
    private let top: CGFloat
    let visible: ClosedRange<Int>

    init(layout: EditionDeckPlacement, count: Int, scrollTop: CGFloat?) {
        self.layout = layout
        self.count = count
        let step = EditionDeckPlacement.step
        let maxOffset = max(0, CGFloat(count) * step - EditionDeckPlacement.gap - layout.frame.height)
        top = min(maxOffset, max(0, scrollTop ?? (layout.growsUp ? maxOffset : 0)))
        let first = min(count - 1, Int(floor((top + EditionDeckPlacement.gap) / step)))
        let last = max(first, min(count - 1, Int(ceil((top + layout.frame.height) / step)) - 1))
        visible = layout.growsUp ? (count - 1 - last)...(count - 1 - first) : first...last
    }

    var restingHeight: CGFloat { BookCardMetrics.metadataRowHeight }

    var duration: Double { 0.18 + min(0.12, Double(visible.count - 1) * 0.025) }

    func amount(for index: Int, progress: CGFloat) -> CGFloat {
        guard visible.contains(index) else { return 1 }
        let rank = Double(index - visible.lowerBound) / Double(max(1, visible.count - 1))
        let t = min(1, max(0, (progress * duration - rank * (duration - 0.18)) / 0.18))
        return t * t * (3 - 2 * t)
    }

    func returnOffset(for index: Int) -> CGFloat {
        let row = layout.growsUp ? count - 1 - index : index
        let bottom = CGFloat(row) * EditionDeckPlacement.step - top + EditionDeckPlacement.tileHeight
        let anchor = layout.growsUp ? layout.frame.height : EditionDeckPlacement.tileHeight
        return anchor - bottom
    }
}

@MainActor @Observable
final class EditionDeckSession {
    enum Phase { case open, closing, finished }
    private(set) var phase = Phase.open
    private(set) var keyboard: Bool
    private(set) var saving = false
    private(set) var committed = false
    private(set) var revision = 0
    private var reversible = false
    private var anchorHovered: Bool
    private var panelHovered = false
    @ObservationIgnored private var grace: Task<Void, Never>?

    init(keyboard: Bool, anchorHovered: Bool) {
        self.keyboard = keyboard
        self.anchorHovered = anchorHovered
    }

    var isPresented: Bool { phase != .finished }
    var canSelect: Bool { phase == .open && !saving }

    func hover(_ inside: Bool, panel: Bool) {
        if panel { panelHovered = inside } else { anchorHovered = inside }
        grace?.cancel()
        if inside && reversible && phase == .closing {
            revision += 1
            phase = .open
        }
        guard !anchorHovered, !panelHovered, !keyboard, canSelect else { return }
        grace = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(150)) } catch { return }
            self?.dismiss(reversible: true)
        }
    }

    func openFromKeyboard() {
        guard isPresented, !committed else { return }
        grace?.cancel()
        keyboard = true
        if phase == .closing { revision += 1; phase = .open }
    }

    func dismiss(reversible: Bool = false) {
        if phase == .closing && !reversible { self.reversible = false }
        guard canSelect else { return }
        grace?.cancel()
        self.reversible = reversible
        revision += 1
        phase = .closing
    }

    func beginSave() {
        guard canSelect else { return }
        grace?.cancel()
        saving = true
    }

    func finishSave(succeeded: Bool) {
        guard saving else { return }
        saving = false
        guard isPresented else { return }
        if succeeded {
            committed = true
            dismiss()
        } else {
            keyboard = true
        }
    }

    func finishRetraction(revision: Int) {
        if self.revision == revision && phase == .closing { end() }
    }

    func sourceLeft() {
        if !committed { end() }
    }

    func end() {
        grace?.cancel()
        phase = .finished
    }
}

struct EditionDeckRequest {
    let session: EditionDeckSession
    let bounds: Anchor<CGRect>
    let count: Int
    let cards: (EditionDeckPlacement) -> AnyView
}

struct EditionDeckPreference: PreferenceKey {
    static var defaultValue: EditionDeckRequest? { nil }
    static func reduce(value: inout EditionDeckRequest?, nextValue: () -> EditionDeckRequest?) {
        if let request = nextValue() { value = request }
    }
}

extension View {
    func editionDeckHost(page: [String] = []) -> some View {
        overlayPreferenceValue(EditionDeckPreference.self) { request in
            EditionDeckOverlay(request: request)
                .id(page)
        }
        .transformPreference(EditionDeckPreference.self) { $0 = nil }
    }
}

private struct EditionDeckOverlay: View {
    let request: EditionDeckRequest?
    // A committed primary change may replace the grid cell. Keep its last resolved slot for the return trip.
    @State private var retained: EditionDeckRequest?
    @State private var lastBounds: CGRect?

    var body: some View {
        GeometryReader { geometry in
            let bounds = request.map { geometry[$0.bounds] }
            let active = request ?? (retained?.session.committed == true ? retained : nil)
            let viewport = CGRect(origin: .zero, size: geometry.size)
            ZStack(alignment: .topLeading) {
                if let active, active.session.isPresented, let rect = bounds ?? lastBounds {
                    if viewport.intersects(rect) {
                        let anchor = CGRect(x: rect.minX, y: viewport.height - rect.maxY,
                                            width: rect.width, height: rect.height)
                        let layout = EditionDeckPlacement(anchor: anchor, viewport: viewport, count: active.count)
                        Color.clear.contentShape(Rectangle()).onTapGesture { active.session.dismiss() }
                        active.cards(layout)
                            .id(ObjectIdentifier(active.session))
                            .position(x: layout.frame.midX, y: viewport.height - layout.frame.midY)
                    } else {
                        Color.clear.task { active.session.end() }
                    }
                }
            }
            .onChange(of: request.map { ObjectIdentifier($0.session) }, initial: true) {
                if let request {
                    retained = request
                    lastBounds = bounds
                } else if retained?.session.committed != true { retained = nil }
            }
            .onChange(of: bounds) { _, rect in
                if let rect { lastBounds = rect }
            }
            .onChange(of: retained?.session.isPresented) { _, presented in
                if presented == false { retained = nil; lastBounds = nil }
            }
            .onDisappear { retained?.session.end() }
        }
    }
}
