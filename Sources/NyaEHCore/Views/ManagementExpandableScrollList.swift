import AppKit
import SwiftUI

struct ManagementExpansionContext: Equatable {
    let groupID: Int64?
    var page = 1
    var query = ""
    var pageSize: Int?
}

struct ManagementExpandableScrollList<Item: Identifiable, Row: View, Preview: View>: View where Item.ID: Sendable {
    let items: [Item]
    let context: ManagementExpansionContext
    var usesGlassPreview = false
    @ViewBuilder let row: (Item, ManagementCardExpansionState, ManagementCardExpansionController<Item.ID>) -> Row

    @ViewBuilder let preview: (Item) -> Preview

    @State private var presenter = ManagementHoverPreviewPresenter<Item.ID>()
    @State private var expansion = ManagementCardExpansionController<Item.ID>()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 8) {
                ForEach(items) { item in
                    row(item, expansion.state(for: item.id), expansion)
                        .contentShape(RoundedRectangle(cornerRadius: 8))
                        .background(ManagementPreviewAnchor(id: item.id, presenter: presenter))
                        .onContinuousHover { phase in
                            switch phase {
                            case .active:
                                expansion.pointerActive(at: NSEvent.mouseLocation, for: item.id)
                            case .ended:
                                expansion.setHovering(false, for: item.id)
                            }
                        }
                        .onDisappear { expansion.cardDisappeared(item.id) }
                        .overlay {
                            if expansion.state(for: item.id).isHovering {
                                RoundedRectangle(cornerRadius: 8)
                                    .stroke(Color.accentColor.opacity(0.4), lineWidth: 1)
                                    .allowsHitTesting(false)
                                    .transition(.identity)
                                    .transaction { $0.animation = nil }
                            }
                        }
                }
            }
            .padding(.vertical, 2)
            // The list reads the expanded IDs so its layout and row transitions share a transaction.
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.22), value: expansion.expandedIDs)
        }
        .background(ManagementPreviewLifetime(presenter: presenter))
        .onScrollPhaseChange { _, phase in
            expansion.setScrolling(phase != .idle, pointerLocation: NSEvent.mouseLocation)
            if phase != .idle { presenter.hideImmediately() }
        }
        .onChange(of: expansion.previewID) { _, _ in updatePreview() }
        .onChange(of: colorScheme) { _, _ in updatePreview() }
        .onChange(of: reduceMotion) { _, _ in updatePreview() }
        .onChange(of: items.map(\.id)) { _, ids in
            expansion.retainCards(Set(ids))
            if expansion.previewID != nil { updatePreview() }
        }
        .onChange(of: context) { _, _ in
            presenter.hideImmediately()
            expansion.reset()
        }
        .onDisappear {
            presenter.dispose()
            expansion.reset()
        }
    }

    private func updatePreview() {
        guard let id = expansion.previewID, let item = items.first(where: { $0.id == id }) else {
            presenter.hide(reduceMotion: reduceMotion)
            return
        }
        presenter.show(id: id, content: AnyView(preview(item)), reduceMotion: reduceMotion,
                       usesGlassSurface: usesGlassPreview,
                       colorScheme: colorScheme, onHover: { [weak expansion] hovering in
            expansion?.setPreviewHovering(hovering, for: id)
        }, onInvalidate: { [weak expansion] in
            expansion?.suspendPreviews(pointerLocation: NSEvent.mouseLocation)
        })
    }
}

struct ManagementCardExpandedContent<Content: View>: View {
    let isExpanded: Bool
    @ViewBuilder let content: Content
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        if isExpanded {
            content
                .transition(
                    reduceMotion
                        ? .opacity.animation(.easeInOut(duration: 0.12))
                        : .modifier(
                            active: ManagementCardRevealModifier(progress: 0),
                            identity: ManagementCardRevealModifier(progress: 1)
                        )
                )
        }
    }
}

private struct ManagementCardRevealModifier: AnimatableModifier {
    // Animation interpolation only accesses this value; UI rendering stays on the main actor.
    nonisolated var progress: CGFloat
    nonisolated var animatableData: CGFloat {
        get { progress }
        set { progress = newValue }
    }

    func body(content: Content) -> some View {
        content
            .opacity(progress)
            .mask(alignment: .top) {
                Rectangle().scaleEffect(y: progress, anchor: .top)
            }
    }
}
