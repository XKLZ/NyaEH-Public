import AppKit
import SwiftUI

enum MainWindowGeometry {
    static let minimumContentSize = CGSize(width: 920, height: 560)
    static let minimumSidebarWidth: CGFloat = 160
    static let defaultSidebarWidth: CGFloat = 200
    static let maximumSidebarWidth: CGFloat = 400

    static func isValid(_ size: CGSize) -> Bool {
        size.width.isFinite && size.height.isFinite && size.width > 0 && size.height > 0
    }

    static func initialSize(_ savedSize: CGSize?, availableSize: CGSize) -> CGSize? {
        guard let savedSize, isValid(savedSize), isValid(availableSize) else { return nil }
        return CGSize(
            width: min(max(savedSize.width, minimumContentSize.width), availableSize.width),
            height: min(max(savedSize.height, minimumContentSize.height), availableSize.height)
        )
    }

    static func sidebarWidth(_ width: CGFloat) -> CGFloat? {
        guard width.isFinite, width > 0 else { return nil }
        return min(max(width.rounded(), minimumSidebarWidth), maximumSidebarWidth)
    }
}

/// Observes only the window hosting this view. SwiftUI still owns its placement and delegate.
struct MainWindowSizeObserver: NSViewRepresentable {
    let preferences: AppPreferences

    func makeNSView(context: Context) -> ObserverView { ObserverView(preferences: preferences) }
    func updateNSView(_ view: ObserverView, context: Context) {}
    static func dismantleNSView(_ view: ObserverView, coordinator: ()) { view.observeWindow(nil) }

    final class ObserverView: NSView {
        private let preferences: AppPreferences
        private weak var observedWindow: NSWindow?
        private var pendingSave: Task<Void, Never>?
        private var isEnteringFullScreen = false

        init(preferences: AppPreferences) {
            self.preferences = preferences
            super.init(frame: .zero)
        }

        required init?(coder: NSCoder) { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            observeWindow(window)
        }

        func observeWindow(_ window: NSWindow?) {
            guard observedWindow !== window else { return }
            NotificationCenter.default.removeObserver(self)
            pendingSave?.cancel()
            pendingSave = nil
            isEnteringFullScreen = false
            observedWindow = window
            guard let window else { return }

            let center = NotificationCenter.default
            center.addObserver(self, selector: #selector(didResize), name: NSWindow.didResizeNotification, object: window)
            center.addObserver(self, selector: #selector(finishedResizing), name: NSWindow.didEndLiveResizeNotification, object: window)
            center.addObserver(self, selector: #selector(willEnterFullScreen), name: NSWindow.willEnterFullScreenNotification, object: window)
            center.addObserver(self, selector: #selector(fullScreenTransitionFinished), name: NSWindow.didEnterFullScreenNotification, object: window)
            center.addObserver(self, selector: #selector(fullScreenTransitionFinished), name: NSWindow.didExitFullScreenNotification, object: window)
            center.addObserver(self, selector: #selector(flushPendingSave), name: NSWindow.willCloseNotification, object: window)
            center.addObserver(self, selector: #selector(flushPendingSave), name: NSApplication.willTerminateNotification, object: nil)
        }

        @objc private func didResize() {
            guard let window = observedWindow, window.isVisible, !window.inLiveResize,
                  canSave(window) else { return }
            // Coalesce non-live resizes, such as system window tiling.
            pendingSave?.cancel()
            pendingSave = Task { [weak self] in
                do { try await Task.sleep(for: .milliseconds(200)) }
                catch { return }
                self?.flushPendingSave()
            }
        }

        @objc private func finishedResizing() {
            pendingSave?.cancel()
            pendingSave = nil
            saveSize()
        }

        @objc private func willEnterFullScreen() {
            flushPendingSave()
            isEnteringFullScreen = true
        }

        @objc private func fullScreenTransitionFinished() {
            isEnteringFullScreen = false
        }

        @objc private func flushPendingSave() {
            guard let pendingSave else { return }
            pendingSave.cancel()
            self.pendingSave = nil
            saveSize()
        }

        private func canSave(_ window: NSWindow) -> Bool {
            !isEnteringFullScreen && !window.styleMask.contains(.fullScreen) && !window.isMiniaturized
        }

        private func saveSize() {
            guard let window = observedWindow, canSave(window) else { return }
            preferences.saveMainWindowSize(window.contentRect(forFrameRect: window.frame).size)
        }
    }
}

/// Uses the AppKit user-resize marker to ignore resizing caused by layout or sidebar visibility.
struct MainSidebarWidthObserver: NSViewRepresentable {
    let preferences: AppPreferences

    func makeNSView(context: Context) -> ObserverView { ObserverView(preferences: preferences) }
    func updateNSView(_ view: ObserverView, context: Context) {}
    static func dismantleNSView(_ view: ObserverView, coordinator: ()) {
        NotificationCenter.default.removeObserver(view)
    }

    final class ObserverView: NSView {
        private let preferences: AppPreferences

        init(preferences: AppPreferences) {
            self.preferences = preferences
            super.init(frame: .zero)
            NotificationCenter.default.addObserver(
                self, selector: #selector(splitViewDidResize(_:)),
                name: NSSplitView.didResizeSubviewsNotification, object: nil
            )
        }

        required init?(coder: NSCoder) { nil }

        @objc private func splitViewDidResize(_ notification: Notification) {
            guard notification.userInfo?["NSSplitViewUserResizeKey"] as? Bool == true,
                  notification.userInfo?["NSSplitViewDividerIndex"] as? Int == 0,
                  let splitView = notification.object as? NSSplitView, splitView.isVertical,
                  let sidebar = splitView.arrangedSubviews.first, isDescendant(of: sidebar),
                  !splitView.isSubviewCollapsed(sidebar), !sidebar.isHiddenOrHasHiddenAncestor else { return }
            preferences.saveMainSidebarWidth(sidebar.frame.width)
        }
    }
}
