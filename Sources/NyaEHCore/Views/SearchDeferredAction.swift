import Foundation
import SwiftUI

/// UI callbacks must run outside AppKit's menu-tracking/layout pass. The owner
/// cancels on deactivation or teardown; replacement callbacks supersede old ones.
@MainActor
final class SearchDeferredAction {
    private var generation = 0
    private var pendingAction: (@MainActor () -> Void)?

    func schedule(_ action: @escaping @MainActor () -> Void) {
        generation += 1
        let scheduledGeneration = generation
        pendingAction = action
        RunLoop.main.perform(inModes: [.default]) { [weak self] in
            // This block is scheduled exclusively on the main run loop.
            MainActor.assumeIsolated {
                guard let self, self.generation == scheduledGeneration else { return }
                let action = self.pendingAction
                self.pendingAction = nil
                self.generation += 1
                action?()
            }
        }
    }

    func cancel() {
        generation += 1
        pendingAction = nil
    }
}

@MainActor
final class SearchScopeMenuSelection {
    private let deferredAction = SearchDeferredAction()

    func select(_ scope: BookSearchScope, selection: Binding<BookSearchScope>) {
        let previousScope = selection.wrappedValue
        guard scope != previousScope else {
            cancel()
            return
        }
        deferredAction.schedule {
            // A saved-search restore or another external change supersedes this menu action.
            guard selection.wrappedValue == previousScope else { return }
            selection.wrappedValue = scope
        }
    }

    func cancel() {
        deferredAction.cancel()
    }
}
