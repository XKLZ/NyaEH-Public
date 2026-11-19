import Foundation

struct HomeFavoritePreview: Sendable {
    static let limit = 10

    // Keep one extra candidate so the strip can distinguish an exact fit from overflow.
    let candidates: [LibraryBook]
    var books: ArraySlice<LibraryBook> { candidates.prefix(Self.limit) }
    var hasMore: Bool { candidates.count > Self.limit }

    init(favorites: [LibraryBook]) {
        let visible = favorites.filter { !$0.isUserHidden }
        candidates = Array(visible.sorted(by: Self.precedes).prefix(Self.limit + 1))
    }

    private static func precedes(_ lhs: LibraryBook, _ rhs: LibraryBook) -> Bool {
        if lhs.lastReadAt != rhs.lastReadAt {
            return (lhs.lastReadAt ?? .min) > (rhs.lastReadAt ?? .min)
        }
        if lhs.posted != rhs.posted {
            return (lhs.posted ?? .min) > (rhs.posted ?? .min)
        }
        let order = lhs.title.localizedCaseInsensitiveCompare(rhs.title)
        return order == .orderedSame ? lhs.id < rhs.id : order == .orderedAscending
    }
}
