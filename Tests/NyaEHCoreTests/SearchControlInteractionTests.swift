import AppKit
import SwiftUI
import Testing
@testable import NyaEHCore

@MainActor
@Suite("Search control callbacks")
struct SearchControlInteractionTests {
    @Test("scope selection waits until default run-loop mode and commits only once")
    func scopeSelectionExitsMenuTracking() {
        let state = ControlState()
        let selection = SearchScopeMenuSelection()
        selection.select(.marked, selection: scopeBinding(state))
        #expect(state.scope == .all)
        #expect(state.scopeWrites == 0)
        _ = RunLoop.main.run(mode: .eventTracking, before: Date(timeIntervalSinceNow: 0.001))
        #expect(state.scopeWrites == 0)

        drainDefaultRunLoop()
        #expect(state.scope == .marked)
        #expect(state.scopeWrites == 1)
        drainDefaultRunLoop()
        #expect(state.scopeWrites == 1)
    }

    @Test("reselecting the current scope does not submit and cancels an older selection")
    func repeatedScopeSelection() {
        let state = ControlState()
        let selection = SearchScopeMenuSelection()
        selection.select(.marked, selection: scopeBinding(state))
        selection.select(.all, selection: scopeBinding(state))
        drainDefaultRunLoop()
        #expect(state.scope == .all)
        #expect(state.scopeWrites == 0)
    }

    @Test("the latest scope choice supersedes pending choices")
    func latestScopeSelectionWins() {
        let state = ControlState()
        let selection = SearchScopeMenuSelection()
        selection.select(.marked, selection: scopeBinding(state))
        selection.select(.unread, selection: scopeBinding(state))
        drainDefaultRunLoop()
        #expect(state.scope == .unread)
        #expect(state.scopeWrites == 1)
    }

    @Test("leaving Search cancels its pending scope callback")
    func scopeSelectionCancellation() {
        let state = ControlState()
        let selection = SearchScopeMenuSelection()
        selection.select(.marked, selection: scopeBinding(state))
        selection.cancel()
        drainDefaultRunLoop()
        #expect(state.scope == .all)
        #expect(state.scopeWrites == 0)
    }

    @Test("a restored scope supersedes a pending menu action")
    func restoredScopeSupersedesMenu() {
        let state = ControlState()
        let selection = SearchScopeMenuSelection()
        selection.select(.marked, selection: scopeBinding(state))
        state.scope = .hidden
        drainDefaultRunLoop()
        #expect(state.scope == .hidden)
        #expect(state.scopeWrites == 0)
    }

    @Test("AppKit synchronization does not synchronously write bindings or submit searches")
    func nativeSynchronizationIsOneWay() {
        let state = ControlState(text: "foo")
        let view = searchField(state)
        let coordinator = view.makeCoordinator()
        let field = view.makeSearchField(coordinator: coordinator)
        defer { NativeSearchField.dismantleNSView(field, coordinator: coordinator) }
        for _ in 0..<20 { coordinator.synchronize(field, parent: view) }
        #expect(field.stringValue == "foo")
        #expect(state.textWrites == 0)
        #expect(state.rangeWrites == 0)
        #expect(state.commits == 0)
        #expect(field.sendsWholeSearchString)
        #expect(!field.sendsSearchStringImmediately)
        drainDefaultRunLoop()
        #expect(state.range == NSRange(location: 0, length: 3))
        #expect(state.rangeWrites == 1)
        #expect(state.commits == 0)
    }

    @Test("input and pauses update the draft and range without submitting")
    func nativeEditingRemainsDraftOnly() {
        let state = ControlState()
        let view = searchField(state)
        let coordinator = view.makeCoordinator()
        let field = view.makeSearchField(coordinator: coordinator)
        defer { NativeSearchField.dismantleNSView(field, coordinator: coordinator) }
        for value in ["f", "fo", "foo", "foo "] {
            field.stringValue = value
            coordinator.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: field))
            drainDefaultRunLoop()
            #expect(state.text == value)
            #expect(state.commits == 0)
        }
        let rangeWrites = state.rangeWrites
        coordinator.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: field))
        #expect(state.rangeWrites == rangeWrites)
        #expect(state.textWrites == 4)
    }

    @Test("Return consumes the native command and the search action each commits once")
    func explicitCommitPaths() {
        let state = ControlState(text: "foo")
        let view = searchField(state)
        let coordinator = view.makeCoordinator()
        let field = view.makeSearchField(coordinator: coordinator)
        defer { NativeSearchField.dismantleNSView(field, coordinator: coordinator) }
        #expect(coordinator.control(field, textView: NSTextView(), doCommandBy: #selector(NSResponder.insertNewline(_:))))
        #expect(state.commits == 1)
        coordinator.commitSearch(field)
        #expect(state.commits == 2)
    }

    @Test("fallback selection uses UTF-16 offsets")
    func fallbackSelectionUsesUTF16() {
        let state = ControlState(text: "😀 😀 😀")
        let view = searchField(state)
        let coordinator = view.makeCoordinator()
        let field = view.makeSearchField(coordinator: coordinator)
        defer { NativeSearchField.dismantleNSView(field, coordinator: coordinator) }
        drainDefaultRunLoop()
        #expect(state.range == NSRange(location: 6, length: 2))
    }

    @Test("selection notifications coalesce and do not write during AppKit layout")
    func selectionNotificationsAreDeferred() {
        let state = ControlState(text: "foo bar")
        let view = searchField(state)
        let coordinator = view.makeCoordinator()
        let field = FieldWithEditor()
        field.stringValue = state.text
        field.editor.string = state.text
        field.editor.selectedRange = NSRange(location: 1, length: 0)
        coordinator.controlTextDidBeginEditing(Notification(name: NSControl.textDidBeginEditingNotification, object: field))
        #expect(state.range == NSRange(location: 0, length: 3))
        state.rangeWrites = 0
        field.editor.selectedRange = NSRange(location: 5, length: 0)
        postSelectionChange(field.editor)
        postSelectionChange(field.editor)
        #expect(state.rangeWrites == 0)
        drainDefaultRunLoop()
        #expect(state.range == NSRange(location: 4, length: 3))
        #expect(state.rangeWrites == 1)
        postSelectionChange(field.editor)
        drainDefaultRunLoop()
        #expect(state.rangeWrites == 1)
        #expect(state.commits == 0)
        NativeSearchField.dismantleNSView(field, coordinator: coordinator)
    }

    @Test("teardown cancels a pending selection update and detaches its observer")
    func selectionNotificationsCancelOnTeardown() {
        let state = ControlState(text: "foo bar")
        let view = searchField(state)
        let coordinator = view.makeCoordinator()
        let field = FieldWithEditor()
        field.stringValue = state.text
        field.editor.string = state.text
        coordinator.controlTextDidBeginEditing(Notification(name: NSControl.textDidBeginEditingNotification, object: field))
        state.rangeWrites = 0
        field.editor.selectedRange = NSRange(location: 5, length: 0)
        postSelectionChange(field.editor)
        NativeSearchField.dismantleNSView(field, coordinator: coordinator)
        postSelectionChange(field.editor)
        drainDefaultRunLoop()
        #expect(state.rangeWrites == 0)
    }

    @Test("a newer programmatic draft invalidates a pending range update")
    func latestProgrammaticDraftWins() {
        let state = ControlState(text: "foo")
        let view = searchField(state)
        let coordinator = view.makeCoordinator()
        let field = view.makeSearchField(coordinator: coordinator)
        defer { NativeSearchField.dismantleNSView(field, coordinator: coordinator) }
        state.text = "bar baz "
        coordinator.synchronize(field, parent: view)
        #expect(state.rangeWrites == 0)
        drainDefaultRunLoop()
        #expect(state.range == NSRange(location: 4, length: 3))
        #expect(state.rangeWrites == 1)
        #expect(state.commits == 0)
    }

    @Test("deactivation cancels pending range publications")
    func inactiveFieldCancelsRangeUpdate() {
        let state = ControlState(text: "foo")
        let view = searchField(state)
        let coordinator = view.makeCoordinator()
        let field = view.makeSearchField(coordinator: coordinator)
        coordinator.synchronize(field, parent: searchField(state, isActive: false))
        drainDefaultRunLoop()
        #expect(state.rangeWrites == 0)
        NativeSearchField.dismantleNSView(field, coordinator: coordinator)
    }

    @Test("search menu choices have localized titles and valid system symbols")
    func menuChoiceTitlesAndSymbols() {
        let keys = SearchResultSortKey.allCases.map(\.titleKey) + SearchResultLayout.allCases.map(\.titleKey)
            + [.searchToolbarTools, .searchToolbarDisplay]
        for language in AppLanguage.concreteLanguages {
            let localizer = AppLocalizer(language: language)
            for key in keys {
                #expect(!localizer.string(key).isEmpty)
                #expect(localizer.string(key) != key.rawValue)
            }
        }
        let symbols = SearchResultSortKey.allCases.map(\.systemImage) + SearchResultLayout.allCases.map(\.systemImage)
        for symbol in symbols {
            #expect(NSImage(systemSymbolName: symbol, accessibilityDescription: nil) != nil)
        }
    }

    private func scopeBinding(_ state: ControlState) -> Binding<BookSearchScope> {
        Binding(get: { state.scope }, set: { state.scope = $0; state.scopeWrites += 1 })
    }

    private func searchField(_ state: ControlState, isActive: Bool = true) -> NativeSearchField {
        NativeSearchField(
            text: Binding(get: { state.text }, set: { state.text = $0; state.textWrites += 1 }),
            placeholder: "Search",
            activeTokenRange: Binding(get: { state.range }, set: { state.range = $0; state.rangeWrites += 1 }),
            isActive: isActive,
            onCommit: { state.commits += 1 },
            onMoveSuggestion: { _ in false },
            onDismissSuggestions: { false }
        )
    }

    private func postSelectionChange(_ editor: NSTextView) {
        NotificationCenter.default.post(name: NSTextView.didChangeSelectionNotification, object: editor)
    }

    private func drainDefaultRunLoop() {
        for _ in 0..<3 {
            _ = RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 0.001))
        }
    }

    @MainActor
    private final class ControlState {
        var scope: BookSearchScope = .all
        var scopeWrites = 0
        var text: String
        var textWrites = 0
        var range: NSRange?
        var rangeWrites = 0
        var commits = 0

        init(text: String = "") { self.text = text }
    }

    private final class FieldWithEditor: NSSearchField {
        let editor = NSTextView()
        override func currentEditor() -> NSText? { editor }
    }
}
