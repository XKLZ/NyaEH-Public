import AppKit
import SwiftUI

/// A list-owned bridge: extends beyond split-column clipping without becoming key/main.
@MainActor
final class ManagementHoverPreviewPresenter<ID: Hashable & Sendable>: NSObject {
    private struct WeakAnchor { weak var view: NSView? }
    private var anchors: [ID: WeakAnchor] = [:]
    private var panel: ManagementPreviewPanel?
    private var hostingView: NSHostingView<AnyView>?
    private weak var hostWindow: NSWindow?
    private var displayedID: ID?
    private var revision: UInt64 = 0
    private var onInvalidate: (() -> Void)?

    func register(_ view: NSView, for id: ID) { anchors[id] = WeakAnchor(view: view) }

    func unregister(_ view: NSView, for id: ID) {
        guard anchors[id]?.view === view else { return }
        anchors[id] = nil
        if displayedID == id { hideImmediately() }
    }

    func show(id: ID, content: AnyView, reduceMotion: Bool, usesGlassSurface: Bool, colorScheme: ColorScheme,
              onHover: @escaping (Bool) -> Void, onInvalidate: @escaping () -> Void) {
        guard let anchor = anchors[id]?.view, let window = anchor.window,
              let screen = window.screen, NSApp.isActive, window.isVisible else {
            hideImmediately()
            return
        }
        self.onInvalidate = onInvalidate
        let available = ManagementHoverPreviewPlacement.size(in: screen.visibleFrame)
        // Measure only the cached text/tag subtree, at the actual preview width.
        let measured = NSHostingView(rootView: content
            .padding(14)
            .frame(width: available.width)
            .fixedSize(horizontal: false, vertical: true))
        let height = min(available.height, max(80, measured.fittingSize.height))
        let frame = ManagementHoverPreviewPlacement.frame(
            anchor: window.convertToScreen(anchor.convert(anchor.bounds, to: nil)),
            previewSize: CGSize(width: available.width, height: height),
            visibleFrame: screen.visibleFrame
        )
        let root = AnyView(ManagementHoverPreviewSurface(content: content, onHover: onHover,
            usesGlassSurface: usesGlassSurface)
            .frame(width: frame.width, height: frame.height)
            .environment(\.colorScheme, colorScheme))
        let panel = panel ?? makePanel()
        let changingTarget = displayedID != id
        revision &+= 1
        if hostWindow !== window {
            detachFromHost()
            hostWindow = window
            window.addChildWindow(panel, ordered: .above)
            for name in [NSWindow.didResignKeyNotification, NSWindow.willCloseNotification,
                         NSWindow.didMiniaturizeNotification, NSWindow.didMoveNotification,
                         NSWindow.didResizeNotification] {
                NotificationCenter.default.addObserver(self, selector: #selector(hostInvalidated), name: name, object: window)
            }
            NotificationCenter.default.addObserver(self, selector: #selector(hostInvalidated),
                                                   name: NSApplication.didResignActiveNotification, object: NSApp)
        }
        if let hostingView {
            hostingView.rootView = root
        } else {
            let hosting = NSHostingView(rootView: root)
            panel.contentView = hosting
            hostingView = hosting
        }
        panel.setFrame(frame, display: true)
        displayedID = id
        self.panel = panel
        if !panel.isVisible || changingTarget {
            panel.alphaValue = 0
            panel.orderFront(nil)
            NSAnimationContext.runAnimationGroup { context in
                context.duration = reduceMotion ? 0.12 : 0.22
                context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                panel.animator().alphaValue = 1
            }
        } else {
            // A cancelled close must retarget opacity from its current presentation value.
            NSAnimationContext.runAnimationGroup { context in
                context.duration = reduceMotion ? 0.12 : 0.22
                panel.animator().alphaValue = 1
            }
        }
    }

    func hide(reduceMotion: Bool) {
        guard let panel, panel.isVisible else { return }
        revision &+= 1
        let request = revision
        NSAnimationContext.runAnimationGroup { context in
            context.duration = reduceMotion ? 0.12 : 0.22
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            panel.animator().alphaValue = 0
        } completionHandler: { [weak self] in
            // AppKit animation completions are delivered on the main thread.
            MainActor.assumeIsolated {
                guard let self, self.revision == request else { return }
                self.hideImmediately()
            }
        }
    }

    func hideImmediately() {
        revision &+= 1
        panel?.orderOut(nil)
        panel?.contentView = nil
        hostingView = nil
        displayedID = nil
        detachFromHost()
    }

    func dispose() {
        hideImmediately()
        panel?.close()
        panel = nil
        anchors.removeAll()
        onInvalidate = nil
    }

    @objc private func hostInvalidated(_ notification: Notification) { invalidate() }

    private func invalidate() {
        hideImmediately()
        onInvalidate?()
    }

    private func detachFromHost() {
        NotificationCenter.default.removeObserver(self)
        if let panel { hostWindow?.removeChildWindow(panel) }
        hostWindow = nil
    }

    private func makePanel() -> ManagementPreviewPanel {
        let panel = ManagementPreviewPanel(contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .none
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.acceptsMouseMovedEvents = true
        panel.hidesOnDeactivate = true
        panel.becomesKeyOnlyIfNeeded = true
        panel.collectionBehavior = [.transient, .ignoresCycle, .fullScreenAuxiliary]
        return panel
    }
}

private final class ManagementPreviewPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

private struct ManagementHoverPreviewSurface: View {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    let content: AnyView
    let onHover: (Bool) -> Void
    let usesGlassSurface: Bool

    private let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)

    var body: some View {
        ScrollView {
            content
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background {
            if !usesGlassSurface || reduceTransparency {
                shape.fill(Color(nsColor: .controlBackgroundColor))
            }
        }
        .clipShape(shape)
        .overlay {
            shape
                .stroke(Color(nsColor: .separatorColor).opacity(usesGlassSurface ? 0.45 : 1), lineWidth: 0.5)
                .allowsHitTesting(false)
        }
        .modifier(ManagementPreviewGlassModifier(enabled: usesGlassSurface && !reduceTransparency, shape: shape))
        .onHover(perform: onHover)
    }
}

private struct ManagementPreviewGlassModifier: ViewModifier {
    let enabled: Bool
    let shape: RoundedRectangle

    @ViewBuilder
    func body(content: Content) -> some View {
        if enabled {
            content.glassEffect(.regular, in: shape)
        } else {
            content
        }
    }
}

struct ManagementPreviewAnchor<ID: Hashable & Sendable>: NSViewRepresentable {
    let id: ID
    let presenter: ManagementHoverPreviewPresenter<ID>

    func makeNSView(context: Context) -> AnchorView {
        let view = AnchorView()
        view.presenter = presenter
        view.id = id
        presenter.register(view, for: id)
        return view
    }

    func updateNSView(_ nsView: AnchorView, context: Context) {
        presenter.register(nsView, for: id)
    }

    static func dismantleNSView(_ nsView: AnchorView, coordinator: ()) {
        if let id = nsView.id { nsView.presenter?.unregister(nsView, for: id) }
    }

    final class AnchorView: NSView {
        weak var presenter: ManagementHoverPreviewPresenter<ID>?
        var id: ID?
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}

/// Guarantees disposal even when the SwiftUI owner is removed rather than merely hidden.
struct ManagementPreviewLifetime<ID: Hashable & Sendable>: NSViewRepresentable {
    let presenter: ManagementHoverPreviewPresenter<ID>
    func makeCoordinator() -> ManagementHoverPreviewPresenter<ID> { presenter }
    func makeNSView(context: Context) -> NSView { NSView() }
    func updateNSView(_ nsView: NSView, context: Context) {}
    static func dismantleNSView(_ nsView: NSView, coordinator: ManagementHoverPreviewPresenter<ID>) {
        coordinator.dispose()
    }
}
