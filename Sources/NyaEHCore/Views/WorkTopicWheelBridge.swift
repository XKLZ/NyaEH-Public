import AppKit
import SwiftUI

/// AppKit reports ordinary mouse-wheel movement in lines. Touch and momentum
/// phases belong to the native scroll view so its gesture arbitration stays intact.
enum WorkTopicWheel {
    static func horizontalDistance(deltaX: CGFloat, deltaY: CGFloat, precise: Bool,
                                   phase: NSEvent.Phase, momentum: NSEvent.Phase,
                                   lineStep: CGFloat) -> CGFloat? {
        guard phase.isEmpty, momentum.isEmpty, deltaX == 0, deltaY != 0 else { return nil }
        return -deltaY * (precise ? 1 : lineStep)
    }
}

struct WorkTopicWheelBridge: NSViewRepresentable {
    let onWheel: () -> Void

    func makeNSView(context: Context) -> Monitor {
        let monitor = Monitor()
        monitor.onWheel = onWheel
        return monitor
    }

    func updateNSView(_ nsView: Monitor, context: Context) {
        nsView.onWheel = onWheel
    }

    static func dismantleNSView(_ nsView: Monitor, coordinator: ()) {
        nsView.stop()
    }

    final class Monitor: NSView {
        var onWheel: (() -> Void)?
        private var handle: Any?

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            stop()
            guard window != nil else { return }
            handle = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
                guard let self, self.consume(event) else { return event }
                return nil
            }
        }

        func stop() {
            if let handle { NSEvent.removeMonitor(handle) }
            handle = nil
        }

        private func consume(_ event: NSEvent) -> Bool {
            guard let window, event.window === window, window.attachedSheet == nil, !isHiddenOrHasHiddenAncestor,
                  let scroll = enclosingScrollView, let document = scroll.documentView,
                  visibleRect.contains(convert(event.locationInWindow, from: nil)),
                  let content = window.contentView, let parent = content.superview,
                  let hit = content.hitTest(parent.convert(event.locationInWindow, from: nil)),
                  hit == scroll || hit.isDescendant(of: scroll),
                  let distance = WorkTopicWheel.horizontalDistance(
                    deltaX: event.scrollingDeltaX, deltaY: event.scrollingDeltaY,
                    precise: event.hasPreciseScrollingDeltas,
                    phase: event.phase, momentum: event.momentumPhase,
                    lineStep: max(scroll.horizontalLineScroll, 16)
                  ) else { return false }

            let clip = scroll.contentView
            guard document.bounds.width > clip.bounds.width + 1 else { return false }
            onWheel?()
            var bounds = clip.bounds
            bounds.origin.x += distance
            clip.scroll(to: clip.constrainBoundsRect(bounds).origin)
            scroll.reflectScrolledClipView(clip)
            return true
        }
    }
}
