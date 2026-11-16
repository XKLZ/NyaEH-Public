import AppKit
import Testing
@testable import NyaEHCore

@Suite("Focus appearance", .serialized)
struct FocusAppearanceManagerTests {
    @Test("Tab navigation remains visible until a non-editing mouse click")
    func keyboardAndPointerTransitions() {
        var state = FocusAppearanceState()
        let accessibility = FocusAppearanceAccessibilitySettings()
        #expect(state.hidesDefaultFocusEffect(accessibility: accessibility))

        state.receive(.tab)
        state.receive(.tab)
        #expect(state.mode == .keyboardNavigation)
        #expect(!state.hidesDefaultFocusEffect(accessibility: accessibility))

        state.receive(.mouseDown(onEditableText: false))
        #expect(state.mode == .browsing)
        #expect(state.hidesDefaultFocusEffect(accessibility: accessibility))
    }

    @Test("Editing keeps its focus cue, and ending editing does not undo Tab navigation")
    func editingTransitions() {
        var state = FocusAppearanceState()
        let accessibility = FocusAppearanceAccessibilitySettings()
        state.receive(.mouseDown(onEditableText: true))
        #expect(state.mode == .textEditing)
        #expect(!state.hidesDefaultFocusEffect(accessibility: accessibility))

        state.receive(.tab)
        state.receive(.textEditingEnded)
        #expect(state.mode == .keyboardNavigation)

        state.receive(.textEditingBegan)
        state.receive(.textEditingEnded)
        #expect(state.mode == .browsing)
        state.receive(.tab)
        state.receive(.windowResignedKey)
        #expect(state.mode == .browsing)
    }

    @Test("Full Keyboard Access follows mouse and Tab navigation")
    func fullKeyboardAccessFollowsInputMode() {
        var state = FocusAppearanceState()
        let accessibility = FocusAppearanceAccessibilitySettings(fullKeyboardAccessEnabled: true)
        #expect(state.hidesDefaultFocusEffect(accessibility: accessibility))
        state.receive(.tab)
        #expect(!state.hidesDefaultFocusEffect(accessibility: accessibility))
        state.receive(.mouseDown(onEditableText: false))
        #expect(state.hidesDefaultFocusEffect(accessibility: accessibility))
        state.receive(.tab)
        #expect(!state.hidesDefaultFocusEffect(accessibility: accessibility))
    }

    @Test("VoiceOver and Switch Control retain system focus cues")
    func assistiveNavigationOverride() {
        for accessibility in [
            FocusAppearanceAccessibilitySettings(voiceOverEnabled: true),
            FocusAppearanceAccessibilitySettings(switchControlEnabled: true),
            FocusAppearanceAccessibilitySettings(
                fullKeyboardAccessEnabled: true,
                voiceOverEnabled: true,
                switchControlEnabled: true
            ),
        ] {
            var state = FocusAppearanceState()
            #expect(!state.hidesDefaultFocusEffect(accessibility: accessibility))
            state.receive(.tab)
            state.receive(.mouseDown(onEditableText: false))
            #expect(!state.hidesDefaultFocusEffect(accessibility: accessibility))
        }
    }

    @Test("Only ordinary Tab and Shift-Tab enable keyboard navigation")
    func tabPolicy() {
        #expect(FocusAppearanceEventPolicy.isNavigationTab(keyCode: 48, modifiers: []))
        #expect(FocusAppearanceEventPolicy.isNavigationTab(keyCode: 48, modifiers: [.shift]))
        #expect(!FocusAppearanceEventPolicy.isNavigationTab(keyCode: 48, modifiers: [.command]))
        #expect(!FocusAppearanceEventPolicy.isNavigationTab(keyCode: 48, modifiers: [.control]))
        #expect(!FocusAppearanceEventPolicy.isNavigationTab(keyCode: 48, modifiers: [.option]))
        #expect(!FocusAppearanceEventPolicy.isNavigationTab(keyCode: 49, modifiers: []))
    }

    @Test("Editable hit targets include text fields and text views")
    @MainActor
    func editableHitTargets() {
        let container = NSView()
        let field = NSTextField()
        container.addSubview(field)
        #expect(FocusAppearanceEventBridge.Coordinator.isEditableText(field))
        field.isEditable = false
        #expect(!FocusAppearanceEventBridge.Coordinator.isEditableText(field))

        let editor = NSTextView()
        container.addSubview(editor)
        #expect(FocusAppearanceEventBridge.Coordinator.isEditableText(editor))
        #expect(!FocusAppearanceEventBridge.Coordinator.isEditableText(container))
    }

}
