import Foundation

struct CollectionMemberSelectionState: Equatable {
    private(set) var selectedIDs: Set<LibraryBook.ID> = []
    private(set) var anchorID: LibraryBook.ID?

    mutating func select(_ id: LibraryBook.ID, orderedIDs: [LibraryBook.ID], command: Bool = false, shift: Bool = false) {
        guard orderedIDs.contains(id) else { return }
        if shift, let anchorID,
           let start = orderedIDs.firstIndex(of: anchorID),
           let end = orderedIDs.firstIndex(of: id) {
            let range = min(start, end)...max(start, end)
            selectedIDs.formUnion(orderedIDs[range])
        } else if command {
            if !selectedIDs.insert(id).inserted { selectedIDs.remove(id) }
            anchorID = id
        } else {
            selectedIDs = [id]
            anchorID = id
        }
    }

    mutating func toggleForSecondaryClick(_ id: LibraryBook.ID, orderedIDs: [LibraryBook.ID]) {
        select(id, orderedIDs: orderedIDs, command: true)
    }

    func menuTargetIDs(for id: LibraryBook.ID) -> Set<LibraryBook.ID> {
        selectedIDs.contains(id) ? selectedIDs : [id]
    }

    mutating func retain(_ orderedIDs: [LibraryBook.ID]) {
        selectedIDs.formIntersection(orderedIDs)
        if let anchorID, !orderedIDs.contains(anchorID) { self.anchorID = nil }
    }

    mutating func clear() {
        selectedIDs.removeAll()
        anchorID = nil
    }
}

enum CollectionMemberFinderReveal {
    static func fileURL(for path: String, fileExists: (String) -> Bool) -> URL? {
        guard (path as NSString).isAbsolutePath, fileExists(path) else { return nil }
        return URL(fileURLWithPath: path)
    }
}

struct CollectionDeletionFollowUp {
    let deletedID: BookCollection.ID
    let orderedIDs: [BookCollection.ID]

    func neighbor(availableIDs: [BookCollection.ID]) -> BookCollection.ID? {
        let available = Set(availableIDs)
        guard let deletedIndex = orderedIDs.firstIndex(of: deletedID) else { return availableIDs.first }
        let subsequent = orderedIDs.dropFirst(deletedIndex + 1)
        if let next = subsequent.first(where: available.contains) { return next }
        return orderedIDs.prefix(deletedIndex).reversed().first(where: available.contains) ?? availableIDs.first
    }
}

enum CollectionMemberOrderPlanner {
    static func inserted(
        _ orderedIDs: [LibraryBook.ID],
        selectedIDs: Set<LibraryBook.ID>,
        beforeIndex: Int
    ) -> [LibraryBook.ID] {
        let positions = orderedIDs.indices.filter { selectedIDs.contains(orderedIDs[$0]) }
        guard !positions.isEmpty, (0...orderedIDs.count).contains(beforeIndex),
              let first = positions.first, let last = positions.last,
              !(first...last + 1).contains(beforeIndex) else { return orderedIDs }
        let moving = positions.map { orderedIDs[$0] }
        var remaining = orderedIDs.filter { !selectedIDs.contains($0) }
        let adjusted = beforeIndex - positions.filter { $0 < beforeIndex }.count
        remaining.insert(contentsOf: moving, at: adjusted)
        return remaining
    }

    static func shifted(
        _ orderedIDs: [LibraryBook.ID],
        selectedIDs: Set<LibraryBook.ID>,
        direction: CollectionMoveDirection
    ) -> [LibraryBook.ID] {
        var result = orderedIDs
        switch direction {
        case .up:
            for index in result.indices.dropFirst() where selectedIDs.contains(result[index]) && !selectedIDs.contains(result[index - 1]) {
                result.swapAt(index, index - 1)
            }
        case .down:
            for index in result.indices.dropLast().reversed() where selectedIDs.contains(result[index]) && !selectedIDs.contains(result[index + 1]) {
                result.swapAt(index, index + 1)
            }
        }
        return result
    }

    static func movedToBoundary(
        _ orderedIDs: [LibraryBook.ID],
        selectedIDs: Set<LibraryBook.ID>,
        atStart: Bool
    ) -> [LibraryBook.ID] {
        let moving = orderedIDs.filter { selectedIDs.contains($0) }
        let remaining = orderedIDs.filter { !selectedIDs.contains($0) }
        return atStart ? moving + remaining : remaining + moving
    }
}
