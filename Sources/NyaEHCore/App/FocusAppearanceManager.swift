// Keep pointer and keyboard focus appearance separate without changing the responder chain.

import AppKit
import Observation
import SwiftUI

enum FocusAppearanceMode: Equatable {
    case browsing
    case keyboardNavigation
    case textEditing
}

enum FocusAppearanceInput: Equatable {
    case tab
    case directionalNavigation
    case mouseDown(onEditableText: Bool)
    case textEditingBegan
    case textEditingEnded
    case windowResignedKey
}

struct FocusAppearanceAccessibilitySettings: Equatable {
    var fullKeyboardAccessEnabled = false
    var voiceOverEnabled = false
    var switchControlEnabled = false

    // Full Keyboard Access still shows the focus effect during keyboard navigation,
    // but a mouse click returns to browsing. Assistive navigation retains its cue.
    var requiresPersistentFocusEffect: Bool {
        voiceOverEnabled || switchControlEnabled
    }
}

struct FocusAppearanceState: Equatable {
    private(set) var mode: FocusAppearanceMode = .browsing

    mutating func receive(_ input: FocusAppearanceInput) {
        switch input {
        case .tab, .directionalNavigation:
            mode = .keyboardNavigation
        case .mouseDown(let onEditableText):
            mode = onEditableText ? .textEditing : .browsing
        case .textEditingBegan:
            mode = .textEditing
        case .textEditingEnded:
            if mode == .textEditing { mode = .browsing }
        case .windowResignedKey:
            mode = .browsing
        }
    }

    func hidesDefaultFocusEffect(accessibility: FocusAppearanceAccessibilitySettings) -> Bool {
        mode == .browsing && !accessibility.requiresPersistentFocusEffect
    }
}

enum FocusAppearanceEventPolicy {
    static func isNavigationTab(keyCode: UInt16, modifiers: NSEvent.ModifierFlags) -> Bool {
        guard keyCode == 48 else { return false }
        return modifiers.intersection([.command, .control, .option, .function]).isEmpty
    }
}

@MainActor @Observable
final class FocusAppearanceManager {
    private(set) var state = FocusAppearanceState()
    private(set) var accessibilitySettings = FocusAppearanceAccessibilitySettings()

    var hidesDefaultFocusEffect: Bool {
        state.hidesDefaultFocusEffect(accessibility: accessibilitySettings)
    }

    func receive(_ input: FocusAppearanceInput) {
        var next = state
        next.receive(input)
        if next != state { state = next }
    }

    func refreshAccessibilitySettings() {
        let settings = FocusAppearanceAccessibilitySettings(
            fullKeyboardAccessEnabled: NSApp.isFullKeyboardAccessEnabled,
            voiceOverEnabled: NSWorkspace.shared.isVoiceOverEnabled,
            switchControlEnabled: NSWorkspace.shared.isSwitchControlEnabled
        )
        if accessibilitySettings != settings { accessibilitySettings = settings }
    }
}

private struct BrowsingFocusEffectHiddenKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var browsingFocusEffectHidden: Bool {
        get { self[BrowsingFocusEffectHiddenKey.self] }
        set { self[BrowsingFocusEffectHiddenKey.self] = newValue }
    }
}

private struct ManagedFocusAppearance: ViewModifier {
    @State private var manager = FocusAppearanceManager()

    func body(content: Content) -> some View {
        content
            .environment(manager)
            .focusEffectDisabled(manager.hidesDefaultFocusEffect)
            .environment(\.browsingFocusEffectHidden, manager.hidesDefaultFocusEffect)
            .background {
                FocusAppearanceEventBridge(manager: manager)
                    .frame(width: 0, height: 0)
            }
    }
}

extension View {
    func managedFocusAppearance() -> some View {
        modifier(ManagedFocusAppearance())
    }
}

struct FocusAppearanceEventBridge: NSViewRepresentable {
    let manager: FocusAppearanceManager

    func makeCoordinator() -> Coordinator { Coordinator(manager: manager) }

    func makeNSView(context: Context) -> ObserverView {
        ObserverView(coordinator: context.coordinator)
    }

    func updateNSView(_ view: ObserverView, context: Context) {
        context.coordinator.manager = manager
        context.coordinator.bind(to: view.window)
    }

    static func dismantleNSView(_ view: ObserverView, coordinator: Coordinator) {
        coordinator.stopMonitoring()
    }

    final class ObserverView: NSView {
        private let coordinator: Coordinator

        init(coordinator: Coordinator) {
            self.coordinator = coordinator
            super.init(frame: .zero)
        }

        required init?(coder: NSCoder) { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            coordinator.bind(to: window)
        }
    }

    @MainActor
    final class Coordinator: NSObject {
        var manager: FocusAppearanceManager
        private weak var window: NSWindow?
        private var eventMonitor: Any?
        private var notifications: [NSObjectProtocol] = []

        var isMonitoring: Bool { eventMonitor != nil }

        init(manager: FocusAppearanceManager) {
            self.manager = manager
            super.init()
        }

        func bind(to window: NSWindow?) {
            guard self.window !== window else { return }
            stopMonitoring()
            self.window = window
            guard let window else { return }
            manager.refreshAccessibilitySettings()

            eventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .leftMouseDown, .rightMouseDown]) { [weak self] event in
                self?.process(event) ?? event
            }

            let center = NotificationCenter.default
            notifications.append(center.addObserver(forName: NSWindow.didResignKeyNotification, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.manager.receive(.windowResignedKey) }
            })
            notifications.append(center.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.stopMonitoring() }
            })
            for name in [NSControl.textDidBeginEditingNotification, NSText.didBeginEditingNotification] {
                center.addObserver(self, selector: #selector(textEditingBegan(_:)), name: name, object: nil)
            }
            for name in [NSControl.textDidEndEditingNotification, NSText.didEndEditingNotification] {
                center.addObserver(self, selector: #selector(textEditingEnded(_:)), name: name, object: nil)
            }
            notifications.append(center.addObserver(forName: NSApplication.didBecomeActiveNotification, object: NSApp, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.manager.refreshAccessibilitySettings() }
            })
        }

        func stopMonitoring() {
            if let eventMonitor { NSEvent.removeMonitor(eventMonitor) }
            eventMonitor = nil
            for notification in notifications { NotificationCenter.default.removeObserver(notification) }
            notifications.removeAll()
            NotificationCenter.default.removeObserver(self)
            window = nil
        }

        func process(_ event: NSEvent) -> NSEvent {
            guard let window, event.window === window else { return event }
            manager.refreshAccessibilitySettings()
            switch event.type {
            case .keyDown:
                if window.isKeyWindow,
                   FocusAppearanceEventPolicy.isNavigationTab(keyCode: event.keyCode, modifiers: event.modifierFlags) {
                    manager.receive(.tab)
                }
            case .leftMouseDown, .rightMouseDown:
                manager.receive(.mouseDown(onEditableText: Self.hitEditableText(event, in: window)))
            default:
                break
            }
            return event
        }

        private func handleTextEditing(_ notification: Notification, began: Bool) {
            guard let window, let view = notification.object as? NSView, view.window === window else { return }
            manager.receive(began ? .textEditingBegan : .textEditingEnded)
        }

        @objc private func textEditingBegan(_ notification: Notification) {
            handleTextEditing(notification, began: true)
        }

        @objc private func textEditingEnded(_ notification: Notification) {
            handleTextEditing(notification, began: false)
        }

        private static func hitEditableText(_ event: NSEvent, in window: NSWindow) -> Bool {
            guard let contentView = window.contentView else { return false }
            let point = contentView.convert(event.locationInWindow, from: nil)
            return isEditableText(contentView.hitTest(point))
        }

        static func isEditableText(_ hitView: NSView?) -> Bool {
            var hitView = hitView
            while let view = hitView {
                if let field = view as? NSTextField, field.isEditable && field.isEnabled { return true }
                if let textView = view as? NSTextView, textView.isEditable { return true }
                hitView = view.superview
            }
            return false
        }
    }
}
