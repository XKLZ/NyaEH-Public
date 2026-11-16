import SwiftUI
import Testing
@testable import NyaEHCore

@Suite("Search mode keyboard selection")
struct SearchModeControlTests {
    @Test("arrow keys select one segment and stop at the ends", arguments: SearchMode.allCases)
    func arrowsSelectOneSegment(focusedMode: SearchMode) {
        #expect(SearchModeKeyboardSelection.selection(for: .leftArrow, focusedMode: focusedMode) == .broad)
        #expect(SearchModeKeyboardSelection.selection(for: .rightArrow, focusedMode: focusedMode) == .exact)
    }

    @Test("space activates the focused segment without deselecting it", arguments: SearchMode.allCases)
    func spacePreservesRepeatedSelection(focusedMode: SearchMode) {
        let selection = SearchModeKeyboardSelection.selection(for: .space, focusedMode: focusedMode)
        #expect(selection == focusedMode)
        #expect(SearchModeKeyboardSelection.selection(for: .space, focusedMode: selection) == focusedMode)
    }

    @Test("mode shortcuts ignore key presses outside the mode control")
    func keysRequireModeFocus() {
        for key: KeyEquivalent in [.leftArrow, .rightArrow, .space] {
            #expect(SearchModeKeyboardSelection.selection(for: key, focusedMode: nil) == nil)
        }
    }

    @Test("suggestion and search keys are not consumed by mode selection")
    func unrelatedKeysAreIgnored() {
        for mode in SearchMode.allCases {
            for key: KeyEquivalent in [.upArrow, .downArrow, .escape, .return] {
                #expect(SearchModeKeyboardSelection.selection(for: key, focusedMode: mode) == nil)
            }
        }
    }
}
