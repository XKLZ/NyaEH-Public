import Foundation

enum HomeShowcaseGroup: CaseIterable, Hashable {
    case continuing, recent, recommended

    var backgroundSymbol: String {
        switch self {
        case .continuing: "book.pages"
        case .recent: "clock.arrow.circlepath"
        case .recommended: "sparkles"
        }
    }

    var title: L10nKey {
        switch self {
        case .continuing: .readerContinue
        case .recent: .recentlyViewed
        case .recommended: .todayRecommendations
        }
    }
}

struct HomeShowcaseSelection: Hashable {
    let group: HomeShowcaseGroup
    let id: LibraryBook.ID
}

struct HomeShowcaseBooks {
    private let groups: [HomeShowcaseGroup: [LibraryBook]]

    init(continuing: [LibraryBook], recent: [LibraryBook], recommended: [LibraryBook]) {
        groups = [.continuing: Array(continuing.prefix(5)),
                  .recent: Array(recent.prefix(5)),
                  .recommended: Array(recommended.prefix(5))]
    }

    subscript(group: HomeShowcaseGroup) -> [LibraryBook] { groups[group] ?? [] }

    func first(in group: HomeShowcaseGroup) -> HomeShowcaseSelection? {
        self[group].first.map { HomeShowcaseSelection(group: group, id: $0.id) }
    }

    func resolve(_ selection: HomeShowcaseSelection?) -> HomeShowcaseSelection? {
        if let selection, let fallback = first(in: selection.group) {
            return self[selection.group].contains { $0.id == selection.id } ? selection : fallback
        }
        return first(in: .continuing) ?? first(in: .recommended) ?? first(in: .recent)
    }

    func book(for selection: HomeShowcaseSelection) -> LibraryBook? {
        self[selection.group].first { $0.id == selection.id }
    }

    func changingRow(from selection: HomeShowcaseSelection, offset: Int) -> HomeShowcaseSelection {
        let rows = HomeShowcaseGroup.allCases.filter { !self[$0].isEmpty }
        guard let row = rows.firstIndex(of: selection.group),
              let column = self[selection.group].firstIndex(where: { $0.id == selection.id }) else { return selection }
        let next = rows[(row + offset % rows.count + rows.count) % rows.count]
        let book = self[next][min(column, self[next].count - 1)]
        return HomeShowcaseSelection(group: next, id: book.id)
    }

    func adjacent(to selection: HomeShowcaseSelection, offset: Int) -> HomeShowcaseSelection {
        let books = self[selection.group]
        guard let index = books.firstIndex(where: { $0.id == selection.id }) else { return selection }
        let next = (index + offset % books.count + books.count) % books.count
        return HomeShowcaseSelection(group: selection.group, id: books[next].id)
    }
}

struct HomeShowcasePlayback: Equatable {
    let selection: HomeShowcaseSelection
    let ids: [LibraryBook.ID]

    init?(selection: HomeShowcaseSelection, ids: [LibraryBook.ID], visible: Bool, active: Bool,
          interacting: Bool, reduceMotion: Bool) {
        guard visible, active, !interacting, !reduceMotion, ids.count > 1 else { return nil }
        self.selection = selection
        self.ids = ids
    }
}

// A completed lookup belongs only to the edition and inputs that requested it.
struct HomeShowcaseResult<Key: Equatable, Value> {
    let key: Key
    let value: Value

    func value(for request: Key) -> Value? {
        request == key ? value : nil
    }
}

struct HomeShowcaseHover {
    private(set) var pending: HomeShowcaseGroup?

    mutating func hover(_ group: HomeShowcaseGroup, inside: Bool) {
        if inside { pending = group }
        else if pending == group { pending = nil }
    }

    func selection(afterDwellingOn group: HomeShowcaseGroup, in books: HomeShowcaseBooks,
                   current: HomeShowcaseSelection) -> HomeShowcaseSelection? {
        guard group == pending, group != current.group else { return nil }
        return books.first(in: group)
    }
}

/// Fits tags in their original order, reserving room for the actual overflow count.
struct HomeTagPreviewLayout {
    var rows: [[Int]] = []
    var hidden = 0

    init(widths: [CGFloat], available: CGFloat, gap: CGFloat, maximumRows: Int = 2, moreWidth: (Int) -> CGFloat) {
        guard available > 0, !widths.isEmpty else { return }
        var used: CGFloat = 0
        rows = [[]]
        for (index, width) in widths.enumerated() {
            let item = min(width, available)
            if !rows[rows.count - 1].isEmpty && used + gap + item > available {
                guard rows.count < maximumRows else { break }
                rows.append([])
                used = 0
            }
            used += (rows[rows.count - 1].isEmpty ? 0 : gap) + item
            rows[rows.count - 1].append(index)
        }
        hidden = widths.count - rows.reduce(0) { $0 + $1.count }
        guard hidden > 0 else { return }
        let finalRow = rows.count - 1
        while let last = rows[finalRow].last, used + gap + moreWidth(hidden) > available {
            rows[finalRow].removeLast()
            used -= min(widths[last], available) + (rows[finalRow].isEmpty ? 0 : gap)
            hidden += 1
        }
    }
}
