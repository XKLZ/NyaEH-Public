import AppKit
import SwiftUI

/// Keeps native menu tracking separate from SwiftUI's dynamic label/glass layout.
/// Catalog state remains owned by SwiftUI; the coordinator only presents it.
struct NativeSearchScopeMenu: NSViewRepresentable {
    @Binding var selection: BookSearchScope
    let isActive: Bool
    let localizer: AppLocalizer
    let selectionAction: SearchScopeMenuSelection

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeNSView(context: Context) -> SearchScopePopUpButton {
        makeButton(coordinator: context.coordinator)
    }

    func makeButton(coordinator: Coordinator) -> SearchScopePopUpButton {
        let button = SearchScopePopUpButton(
            title: "",
            image: nil,
            pullDownMenu: coordinator.menu
        )
        button.bezelStyle = .glass
        button.borderShape = .capsule
        button.font = SearchScopeMenuMetrics.font
        button.symbolConfiguration = .init(pointSize: 13, weight: .semibold)
        button.imagePosition = .imageLeading
        button.imageHugsTitle = true
        button.lineBreakMode = .byTruncatingTail
        button.autoenablesItems = false
        button.setContentHuggingPriority(.required, for: .horizontal)
        button.setContentCompressionResistancePriority(.required, for: .horizontal)
        coordinator.attach(button)
        return button
    }

    func updateNSView(_ button: SearchScopePopUpButton, context: Context) {
        context.coordinator.synchronize(parent: self)
    }

    func sizeThatFits(
        _ proposal: ProposedViewSize,
        nsView: SearchScopePopUpButton,
        context: Context
    ) -> CGSize? {
        // Read the last applied native size, including while a menu is tracking.
        // No geometry preferences, constraints or bindings are changed here.
        nsView.presentationSize
    }

    static func dismantleNSView(_ button: SearchScopePopUpButton, coordinator: Coordinator) {
        coordinator.invalidate()
        button.menu = nil
    }

    @MainActor
    final class Coordinator: NSObject, NSMenuDelegate {
        let menu = NSMenu()
        private var parent: NativeSearchScopeMenu
        private weak var button: SearchScopePopUpButton?
        private var sectionItems: [(L10nKey, NSMenuItem)] = []
        private var scopeItems: [BookSearchScope: NSMenuItem] = [:]
        private var scopeImages: [BookSearchScope: NSImage] = [:]
        private var appliedPresentation: Presentation?
        private var pendingSelection: (scope: BookSearchScope, previous: BookSearchScope)?
        private let presentationUpdate = SearchDeferredAction()
        private(set) var isTracking = false
        private var isWaitingForDefaultPass = false
        private var isValid = true

        init(parent: NativeSearchScopeMenu) {
            self.parent = parent
            super.init()
            menu.autoenablesItems = false
            menu.delegate = self
            let groups: [(L10nKey, [BookSearchScope])] = [
                (.searchScopeGroupLibrary, [.all, .marked, .hidden]),
                (.searchScopeGroupReading, [.continueReading, .unread, .completed]),
                (.searchScopeGroupAttention, [.metadataPending, .broken, .missing])
            ]
            for (index, group) in groups.enumerated() {
                if index > 0 { menu.addItem(.separator()) }
                let header = NSMenuItem.sectionHeader(title: parent.localizer.string(group.0))
                sectionItems.append((group.0, header))
                menu.addItem(header)
                for scope in group.1 {
                    let item = NSMenuItem(
                        title: parent.localizer.string(scope.titleKey),
                        action: #selector(chooseScope(_:)),
                        keyEquivalent: ""
                    )
                    item.target = self
                    item.representedObject = scope.rawValue
                    let image = NSImage(systemSymbolName: scope.systemImage, accessibilityDescription: nil)
                    image?.isTemplate = true
                    item.image = image
                    scopeImages[scope] = image
                    scopeItems[scope] = item
                    menu.addItem(item)
                }
            }
        }

        func attach(_ button: SearchScopePopUpButton) {
            self.button = button
            applyPresentationIfNeeded()
        }

        /// One-way synchronization. Native setters are skipped for identical
        /// values, and tracking freezes all native presentation properties.
        func synchronize(parent: NativeSearchScopeMenu) {
            guard isValid else { return }
            self.parent = parent
            if !parent.isActive {
                pendingSelection = nil
                parent.selectionAction.cancel()
                if isTracking {
                    menu.cancelTracking()
                    return
                }
            }
            guard !isTracking, !isWaitingForDefaultPass else { return }
            applyPresentationIfNeeded()
        }

        func menuWillOpen(_ menu: NSMenu) {
            guard isValid, parent.isActive else {
                menu.cancelTracking()
                return
            }
            presentationUpdate.cancel()
            isWaitingForDefaultPass = false
            isTracking = true
        }

        func menuDidClose(_ menu: NSMenu) {
            isTracking = false
            guard isValid else { return }
            isWaitingForDefaultPass = true
            commitPendingSelection()
            // NSMenuDelegate forbids menu changes in menuDidClose. Wait until
            // tracking and the enclosing display/layout pass have both exited.
            presentationUpdate.schedule { [weak self] in
                guard let self, self.isValid, !self.isTracking else { return }
                self.isWaitingForDefaultPass = false
                self.applyPresentationIfNeeded()
            }
        }

        @objc func chooseScope(_ sender: NSMenuItem) {
            guard isValid, parent.isActive,
                  let rawValue = sender.representedObject as? String,
                  let scope = BookSearchScope(rawValue: rawValue) else { return }
            pendingSelection = (scope, parent.selection)
            // AppKit may deliver the item action either before or after close.
            if !isTracking { commitPendingSelection() }
        }

        private func commitPendingSelection() {
            guard let pendingSelection else { return }
            self.pendingSelection = nil
            guard parent.isActive, parent.selection == pendingSelection.previous else { return }
            parent.selectionAction.select(pendingSelection.scope, selection: parent.$selection)
        }

        private func applyPresentationIfNeeded() {
            guard isValid, !isTracking, !isWaitingForDefaultPass, let button else { return }
            let next = Presentation(scope: parent.selection, language: parent.localizer.language, isActive: parent.isActive)
            guard next != appliedPresentation else { return }
            let title = parent.localizer.string(next.scope.titleKey)
            if appliedPresentation?.language != next.language {
                menu.title = parent.localizer.string(.advancedSearchScope)
                for (key, header) in sectionItems {
                    header.title = parent.localizer.string(key)
                }
                for (scope, item) in scopeItems {
                    item.title = parent.localizer.string(scope.titleKey)
                }
                button.setAccessibilityLabel(parent.localizer.string(.advancedSearchScope))
            }
            if appliedPresentation?.scope != next.scope || appliedPresentation?.language != next.language {
                for (scope, item) in scopeItems {
                    let state: NSControl.StateValue = scope == next.scope ? .on : .off
                    if item.state != state { item.state = state }
                }
                if button.title != title { button.title = title }
                let image = scopeImages[next.scope]
                if button.image !== image { button.image = image }
                button.toolTip = title
                button.setAccessibilityValue(title)
                button.setPresentationSize(SearchScopeMenuMetrics.size(for: title))
            }
            if button.isEnabled != next.isActive { button.isEnabled = next.isActive }
            appliedPresentation = next
        }

        func invalidate() {
            isValid = false
            pendingSelection = nil
            presentationUpdate.cancel()
            parent.selectionAction.cancel()
            menu.cancelTracking()
            isTracking = false
            isWaitingForDefaultPass = false
            menu.delegate = nil
            for item in scopeItems.values { item.target = nil; item.action = nil }
            button = nil
        }

        private struct Presentation: Equatable {
            let scope: BookSearchScope
            let language: AppLanguage
            let isActive: Bool
        }
    }
}

enum SearchScopeMenuMetrics {
    static let height: CGFloat = 34
    static let horizontalPadding: CGFloat = 12
    static let maximumWidth: CGFloat = 160
    static var font: NSFont { .systemFont(ofSize: 13, weight: .semibold) }

    static func size(for title: String) -> CGSize {
        let titleWidth = (title as NSString).size(withAttributes: [.font: font]).width
        let iconAndArrowWidth: CGFloat = 16 + 6 + 10 + 6
        return CGSize(
            width: min(maximumWidth, ceil(titleWidth + iconAndArrowWidth + 2 * horizontalPadding)),
            height: height
        )
    }
}

final class SearchScopePopUpButton: NSPopUpButton {
    private(set) var presentationSize = CGSize(width: 80, height: SearchScopeMenuMetrics.height)

    override var intrinsicContentSize: NSSize { presentationSize }

    func setPresentationSize(_ size: CGSize) {
        guard presentationSize != size else { return }
        presentationSize = size
        invalidateIntrinsicContentSize()
    }
}
