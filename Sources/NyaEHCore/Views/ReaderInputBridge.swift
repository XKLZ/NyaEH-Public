// 本文件将当前阅读器窗口的键盘与滚轮事件转换为纯阅读命令；SwiftUI 仍是阅读状态的唯一来源。

import AppKit
import SwiftUI

struct ReaderInputBridge: NSViewRepresentable {
    let window: NSWindow?
    let isScrollPagingEnabled: Bool
    let isThumbnailSidebarPresented: Bool
    let onCommand: (ReaderCommand) -> Void
    let onActivity: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        context.coordinator.update(
            window: window,
            isScrollPagingEnabled: isScrollPagingEnabled,
            isThumbnailSidebarPresented: isThumbnailSidebarPresented,
            onCommand: onCommand,
            onActivity: onActivity
        )
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.update(
            window: window,
            isScrollPagingEnabled: isScrollPagingEnabled,
            isThumbnailSidebarPresented: isThumbnailSidebarPresented,
            onCommand: onCommand,
            onActivity: onActivity
        )
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.stopMonitoring()
    }

    @MainActor
    final class Coordinator {
        private weak var window: NSWindow?
        private var isScrollPagingEnabled = false
        private var isThumbnailSidebarPresented = false
        private var onCommand: ((ReaderCommand) -> Void)?
        private var onActivity: (() -> Void)?
        private var eventMonitor: Any?
        private var scrollAccumulator = ReaderScrollPagingAccumulator()

        func update(
            window: NSWindow?,
            isScrollPagingEnabled: Bool,
            isThumbnailSidebarPresented: Bool,
            onCommand: @escaping (ReaderCommand) -> Void,
            onActivity: @escaping () -> Void
        ) {
            self.window = window
            self.isScrollPagingEnabled = isScrollPagingEnabled
            self.isThumbnailSidebarPresented = isThumbnailSidebarPresented
            self.onCommand = onCommand
            self.onActivity = onActivity
            startMonitoringIfNeeded()
        }

        func stopMonitoring() {
            guard let eventMonitor else { return }
            NSEvent.removeMonitor(eventMonitor)
            self.eventMonitor = nil
        }

        private func startMonitoringIfNeeded() {
            guard eventMonitor == nil else { return }
            eventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .scrollWheel]) { [weak self] event in
                self?.handle(event) ?? event
            }
        }

        private func handle(_ event: NSEvent) -> NSEvent? {
            guard let window, event.window === window, window.isKeyWindow else { return event }
            switch event.type {
            case .keyDown:
                return handleKeyDown(event, in: window)
            case .scrollWheel:
                return handleScrollWheel(event)
            default:
                return event
            }
        }

        private func handleKeyDown(_ event: NSEvent, in window: NSWindow) -> NSEvent? {
            guard let key = readerKey(for: event) else { return event }
            let command = ReaderKeyboardCommandPolicy.command(
                for: key,
                modifiers: readerModifiers(from: event.modifierFlags),
                isEditingText: isEditingText(in: window)
            )
            guard let command else { return event }
            onActivity?()
            onCommand?(command)
            return nil
        }

        private func handleScrollWheel(_ event: NSEvent) -> NSEvent? {
            onActivity?()
            guard isScrollPagingEnabled else { return event }
            if isThumbnailSidebarPresented,
               ReaderThumbnailSidebarHitTestPolicy.contains(
                   windowX: Double(event.locationInWindow.x),
                   contentWidth: Double(window?.contentView?.bounds.width ?? 0)
               ) {
                return event
            }
            let sample = ReaderScrollSample(
                deltaX: event.scrollingDeltaX,
                deltaY: event.scrollingDeltaY,
                isPrecise: event.hasPreciseScrollingDeltas,
                phase: readerPhase(from: event.phase),
                isMomentum: event.momentumPhase != []
            )
            if let direction = scrollAccumulator.consume(sample, timestamp: event.timestamp) {
                onCommand?(.navigate(direction))
            }
            return nil
        }

        private func readerKey(for event: NSEvent) -> ReaderKeyboardKey? {
            switch event.keyCode {
            case 123: return .leftArrow
            case 124: return .rightArrow
            case 125: return .downArrow
            case 126: return .upArrow
            case 116: return .pageUp
            case 121: return .pageDown
            case 115: return .home
            case 119: return .end
            case 49: return .space
            case 53: return .escape
            default:
                guard let character = event.charactersIgnoringModifiers?.first else { return nil }
                return .character(character)
            }
        }

        private func readerModifiers(from flags: NSEvent.ModifierFlags) -> ReaderKeyboardModifiers {
            var modifiers: ReaderKeyboardModifiers = []
            if flags.contains(.shift) { modifiers.insert(.shift) }
            if flags.contains(.control) { modifiers.insert(.control) }
            if flags.contains(.option) { modifiers.insert(.option) }
            if flags.contains(.command) { modifiers.insert(.command) }
            return modifiers
        }

        private func readerPhase(from phase: NSEvent.Phase) -> ReaderScrollPhase {
            if phase.contains(.mayBegin) { return .mayBegin }
            if phase.contains(.began) { return .began }
            if phase.contains(.changed) { return .changed }
            if phase.contains(.ended) { return .ended }
            if phase.contains(.cancelled) { return .cancelled }
            return .none
        }

        private func isEditingText(in window: NSWindow) -> Bool {
            guard let textView = window.firstResponder as? NSTextView else { return false }
            return textView.isFieldEditor
        }
    }
}
