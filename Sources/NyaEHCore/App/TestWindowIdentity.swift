import AppKit
import SwiftUI

/// SwiftUI child navigation titles may replace the root title. This bridge preserves
/// a test-only prefix on the owning window without changing production navigation.
struct TestWindowIdentity: NSViewRepresentable {
    let name: String
    func makeNSView(context: Context) -> IdentityView { IdentityView(name: name) }
    func updateNSView(_ view: IdentityView, context: Context) { view.name = name; view.applyTitle() }
    static func dismantleNSView(_ view: IdentityView, coordinator: ()) { view.observation = nil }

    final class IdentityView: NSView {
        var name: String
        var observation: NSKeyValueObservation?
        init(name: String) { self.name = name; super.init(frame: .zero) }
        required init?(coder: NSCoder) { return nil }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            observation = nil
            guard let window else { return }
            // NSWindow.title changes are UI operations on the main actor; KVO's callback
            // is synchronous with the mutation. The weak capture does not retain a window.
            observation = window.observe(\.title, options: [.new]) { [weak self] _, _ in
                MainActor.assumeIsolated { self?.applyTitle() }
            }
            applyTitle()
        }
        func applyTitle() {
            guard let window, !window.title.hasPrefix(name) else { return }
            window.title = name + " · " + window.title
        }
    }
}
