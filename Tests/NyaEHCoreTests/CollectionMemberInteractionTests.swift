import Testing
@testable import NyaEHCore

struct CollectionMemberInteractionTests {
    private let ids = ["a", "b", "c", "d", "e", "f"]

    @Test("selection follows click, command, shift and secondary-click toggle rules")
    func selection() {
        var state = CollectionMemberSelectionState()
        state.select("b", orderedIDs: ids)
        #expect(state.selectedIDs == ["b"])
        state.select("d", orderedIDs: ids, command: true)
        #expect(state.selectedIDs == ["b", "d"])
        state.select("f", orderedIDs: ids, shift: true)
        #expect(state.selectedIDs == ["b", "d", "e", "f"])
        state.toggleForSecondaryClick("e", orderedIDs: ids)
        #expect(state.selectedIDs == ["b", "d", "f"])
        state.toggleForSecondaryClick("a", orderedIDs: ids)
        #expect(state.selectedIDs == ["a", "b", "d", "f"])
        #expect(state.menuTargetIDs(for: "b") == ["a", "b", "d", "f"])
        #expect(state.menuTargetIDs(for: "e") == ["e"])
        state.select("a", orderedIDs: ids, command: true)
        #expect(state.selectedIDs == ["b", "d", "f"])
        state.toggleForSecondaryClick("b", orderedIDs: ids)
        state.toggleForSecondaryClick("d", orderedIDs: ids)
        state.toggleForSecondaryClick("f", orderedIDs: ids)
        #expect(state.selectedIDs.isEmpty)
    }

    @Test("Finder reveal only accepts an existing absolute file path")
    func finderReveal() {
        #expect(CollectionMemberFinderReveal.fileURL(for: "", fileExists: { _ in true }) == nil)
        #expect(CollectionMemberFinderReveal.fileURL(for: "book.cbz", fileExists: { _ in true }) == nil)
        #expect(CollectionMemberFinderReveal.fileURL(for: "/tmp/book.cbz", fileExists: { _ in false }) == nil)
        #expect(CollectionMemberFinderReveal.fileURL(for: "/tmp/book.cbz", fileExists: { _ in true })?.path == "/tmp/book.cbz")
    }

    @Test("deleting a series selects its next visible neighbor, then previous")
    func deletionNeighbor() {
        let middle = CollectionDeletionFollowUp(deletedID: "b", orderedIDs: ["a", "b", "c"])
        #expect(middle.neighbor(availableIDs: ["a", "c"]) == "c")
        #expect(middle.neighbor(availableIDs: ["a"]) == "a")
        let last = CollectionDeletionFollowUp(deletedID: "c", orderedIDs: ["a", "b", "c"])
        #expect(last.neighbor(availableIDs: ["a", "b"]) == "b")
        #expect(last.neighbor(availableIDs: []) == nil)
    }

    @Test("selection removes missing members and clears its anchor")
    func selectionCleanup() {
        var state = CollectionMemberSelectionState()
        state.select("b", orderedIDs: ids)
        state.select("d", orderedIDs: ids, command: true)
        state.retain(["a", "b", "c"])
        #expect(state.selectedIDs == ["b"])
        #expect(state.anchorID == nil)
        state.clear()
        #expect(state.selectedIDs.isEmpty)
    }

    @Test("dragging nonadjacent members inserts one stable block")
    func blockInsertion() {
        #expect(CollectionMemberOrderPlanner.inserted(ids, selectedIDs: ["b", "d"], beforeIndex: 6)
            == ["a", "c", "e", "f", "b", "d"])
        #expect(CollectionMemberOrderPlanner.inserted(ids, selectedIDs: ["b", "d"], beforeIndex: 0)
            == ["b", "d", "a", "c", "e", "f"])
        #expect(CollectionMemberOrderPlanner.inserted(ids, selectedIDs: ["b", "d"], beforeIndex: 3) == ids)
        #expect(CollectionMemberOrderPlanner.inserted(ids, selectedIDs: ["c"], beforeIndex: 3) == ids)
        #expect(CollectionMemberOrderPlanner.inserted(ids, selectedIDs: ["c"], beforeIndex: 9) == ids)
    }

    @Test("menu moves continuous runs one slot and boundaries as a block")
    func menuMoves() {
        #expect(CollectionMemberOrderPlanner.shifted(ids, selectedIDs: ["b", "c", "e"], direction: .up)
            == ["b", "c", "a", "e", "d", "f"])
        #expect(CollectionMemberOrderPlanner.shifted(ids, selectedIDs: ["b", "c", "e"], direction: .down)
            == ["a", "d", "b", "c", "f", "e"])
        #expect(CollectionMemberOrderPlanner.movedToBoundary(ids, selectedIDs: ["b", "e"], atStart: true)
            == ["b", "e", "a", "c", "d", "f"])
        #expect(CollectionMemberOrderPlanner.movedToBoundary(ids, selectedIDs: ["b", "e"], atStart: false)
            == ["a", "c", "d", "f", "b", "e"])
    }
}
