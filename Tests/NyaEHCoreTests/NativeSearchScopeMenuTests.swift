import AppKit
import SwiftUI
import Testing
@testable import NyaEHCore

@MainActor
@Suite("Native search scope menu")
struct NativeSearchScopeMenuTests {
    @Test("scope changes preserve native menu and item identity across tracking cycles")
    func stableMenuAcrossScopeChanges() throws {
        let state = SelectionState()
        let view = menuView(state)
        let coordinator = view.makeCoordinator()
        let button = view.makeButton(coordinator: coordinator)
        defer { NativeSearchScopeMenu.dismantleNSView(button, coordinator: coordinator) }
        let menu = try #require(button.menu)
        let itemIdentities = menu.items.map(ObjectIdentifier.init)
        #expect(button.pullsDown)
        #expect(!button.usesItemFromMenu)
        #expect(button.bezelStyle == .glass)
        #expect(button.borderShape == .capsule)
        #expect(menu.items.filter(\.isSectionHeader).count == 3)
        #expect(menu.items.compactMap { $0.representedObject as? String }.count == BookSearchScope.allCases.count)
        for scope in BookSearchScope.allCases {
            let entry = try item(scope, in: menu)
            #expect(entry.image != nil)
            #expect(entry.title == AppLocalizer(language: .zhHans).string(scope.titleKey))
        }

        for scope in [.all, .marked, .hidden, .unread, .all] as [BookSearchScope] {
            state.scope = scope
            for _ in 0..<5 { coordinator.synchronize(parent: menuView(state)) }
            #expect(button.title == AppLocalizer(language: .zhHans).string(scope.titleKey))
            #expect(button.intrinsicContentSize == SearchScopeMenuMetrics.size(for: button.title))
            coordinator.menuWillOpen(menu)
            coordinator.menuDidClose(menu)
            drainDefaultRunLoop()
            #expect(button.menu === menu)
            #expect(menu.items.map(ObjectIdentifier.init) == itemIdentities)
            #expect(menu.items.filter { $0.state == .on }.count == 1)
            #expect(try item(scope, in: menu).state == .on)
        }
        #expect(state.writes == 0)
    }

    @Test("tracking freezes title, dimensions, menu text and checkmarks until a later default pass")
    func presentationChangesWaitForTrackingExit() throws {
        let state = SelectionState()
        let view = menuView(state)
        let coordinator = view.makeCoordinator()
        let button = view.makeButton(coordinator: coordinator)
        defer { NativeSearchScopeMenu.dismantleNSView(button, coordinator: coordinator) }
        let title = button.title
        let size = button.intrinsicContentSize
        let unread = try item(.unread, in: coordinator.menu)
        let unreadTitle = unread.title

        coordinator.menuWillOpen(coordinator.menu)
        state.scope = .unread
        coordinator.synchronize(parent: menuView(state, language: .en))
        drainDefaultRunLoop()
        #expect(button.title == title)
        #expect(button.intrinsicContentSize == size)
        #expect(unread.title == unreadTitle)
        #expect(unread.state == .off)

        coordinator.menuDidClose(coordinator.menu)
        // SwiftUI can synchronize again while AppKit is still unwinding close.
        coordinator.synchronize(parent: menuView(state, language: .en))
        #expect(button.title == title)
        #expect(button.intrinsicContentSize == size)
        #expect(unread.title == unreadTitle)
        drainDefaultRunLoop()
        #expect(button.title == AppLocalizer(language: .en).string(.searchScopeUnread))
        #expect(unread.title == button.title)
        #expect(unread.state == .on)
        #expect(state.writes == 0)
    }

    @Test("an action before close waits for tracking exit and submits exactly once")
    func actionBeforeClose() throws {
        let state = SelectionState()
        let view = menuView(state)
        let coordinator = view.makeCoordinator()
        let button = view.makeButton(coordinator: coordinator)
        defer { NativeSearchScopeMenu.dismantleNSView(button, coordinator: coordinator) }
        coordinator.menuWillOpen(coordinator.menu)
        coordinator.chooseScope(try item(.hidden, in: coordinator.menu))
        drainDefaultRunLoop()
        #expect(state.scope == .all)
        #expect(state.writes == 0)
        coordinator.menuDidClose(coordinator.menu)
        #expect(state.writes == 0)
        drainDefaultRunLoop()
        #expect(state.scope == .hidden)
        #expect(state.writes == 1)
        coordinator.synchronize(parent: menuView(state))
        coordinator.menuWillOpen(coordinator.menu)
        coordinator.menuDidClose(coordinator.menu)
        drainDefaultRunLoop()
        #expect(state.writes == 1)
        #expect(button.title == AppLocalizer(language: .zhHans).string(.searchScopeHidden))
    }

    @Test("actions delivered after close work and repeated selections do not submit")
    func actionAfterCloseAndRepeatedSelection() throws {
        let state = SelectionState()
        let view = menuView(state)
        let coordinator = view.makeCoordinator()
        let button = view.makeButton(coordinator: coordinator)
        defer { NativeSearchScopeMenu.dismantleNSView(button, coordinator: coordinator) }
        let marked = try item(.marked, in: coordinator.menu)
        coordinator.menuWillOpen(coordinator.menu)
        coordinator.menuDidClose(coordinator.menu)
        coordinator.chooseScope(marked)
        #expect(state.writes == 0)
        drainDefaultRunLoop()
        #expect(state.scope == .marked)
        #expect(state.writes == 1)
        coordinator.synchronize(parent: menuView(state))
        coordinator.menuWillOpen(coordinator.menu)
        coordinator.chooseScope(marked)
        coordinator.menuDidClose(coordinator.menu)
        drainDefaultRunLoop()
        #expect(state.writes == 1)
    }

    @Test("a saved-search restoration during tracking supersedes a pending action")
    func restoredScopeSupersedesTrackingAction() throws {
        let state = SelectionState()
        let view = menuView(state)
        let coordinator = view.makeCoordinator()
        let button = view.makeButton(coordinator: coordinator)
        defer { NativeSearchScopeMenu.dismantleNSView(button, coordinator: coordinator) }
        coordinator.menuWillOpen(coordinator.menu)
        coordinator.chooseScope(try item(.marked, in: coordinator.menu))
        state.scope = .unread
        coordinator.synchronize(parent: menuView(state))
        coordinator.menuDidClose(coordinator.menu)
        drainDefaultRunLoop()
        #expect(state.scope == .unread)
        #expect(state.writes == 0)
        #expect(button.title == AppLocalizer(language: .zhHans).string(.searchScopeUnread))
    }

    @Test("deactivation cancels tracked and queued choices")
    func deactivationCancelsChoices() throws {
        let state = SelectionState()
        let view = menuView(state)
        let coordinator = view.makeCoordinator()
        let button = view.makeButton(coordinator: coordinator)
        defer { NativeSearchScopeMenu.dismantleNSView(button, coordinator: coordinator) }
        let unread = try item(.unread, in: coordinator.menu)
        coordinator.menuWillOpen(coordinator.menu)
        coordinator.chooseScope(unread)
        coordinator.synchronize(parent: menuView(state, isActive: false))
        coordinator.menuDidClose(coordinator.menu)
        drainDefaultRunLoop()
        #expect(state.writes == 0)
        #expect(!button.isEnabled)

        coordinator.synchronize(parent: menuView(state))
        coordinator.chooseScope(unread)
        coordinator.synchronize(parent: menuView(state, isActive: false))
        drainDefaultRunLoop()
        #expect(state.writes == 0)
    }

    @Test("teardown cancels queued work and disconnects native actions")
    func teardownCancelsChoices() throws {
        let state = SelectionState()
        let view = menuView(state)
        let coordinator = view.makeCoordinator()
        let button = view.makeButton(coordinator: coordinator)
        let hidden = try item(.hidden, in: coordinator.menu)
        coordinator.chooseScope(hidden)
        NativeSearchScopeMenu.dismantleNSView(button, coordinator: coordinator)
        drainDefaultRunLoop()
        coordinator.chooseScope(hidden)
        drainDefaultRunLoop()
        #expect(state.writes == 0)
        #expect(coordinator.menu.delegate == nil)
        #expect(hidden.target == nil)
        #expect(hidden.action == nil)
        #expect(button.menu == nil)
    }

    @Test("localized titles produce compact bounded dimensions with content padding")
    func compactDimensions() {
        for language in AppLanguage.concreteLanguages {
            let localizer = AppLocalizer(language: language)
            for scope in BookSearchScope.allCases {
                let size = SearchScopeMenuMetrics.size(for: localizer.string(scope.titleKey))
                #expect(size.height == 34)
                #expect(size.width <= 160)
                #expect(size.width > 2 * SearchScopeMenuMetrics.horizontalPadding + 16)
            }
        }
        #expect(SearchScopeMenuMetrics.size(for: String(repeating: "Long ", count: 100)).width == 160)
    }

    private func menuView(
        _ state: SelectionState,
        language: AppLanguage = .zhHans,
        isActive: Bool = true
    ) -> NativeSearchScopeMenu {
        NativeSearchScopeMenu(
            selection: Binding(get: { state.scope }, set: { state.scope = $0; state.writes += 1 }),
            isActive: isActive,
            localizer: AppLocalizer(language: language),
            selectionAction: state.selectionAction
        )
    }

    private func item(_ scope: BookSearchScope, in menu: NSMenu) throws -> NSMenuItem {
        try #require(menu.items.first { ($0.representedObject as? String) == scope.rawValue })
    }

    private func drainDefaultRunLoop() {
        for _ in 0..<3 { _ = RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 0.001)) }
    }

    private final class SelectionState {
        var scope: BookSearchScope = .all
        var writes = 0
        let selectionAction = SearchScopeMenuSelection()
    }
}
