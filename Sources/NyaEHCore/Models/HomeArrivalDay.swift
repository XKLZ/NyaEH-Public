import Foundation

struct HomeArrivalDay: Identifiable, Equatable, Sendable {
    let id: Date
    private(set) var bookIDs: [LibraryBook.ID]
    private(set) var hasMore: Bool
    static let previewLimit = 7

    /// The input uses the same newest-first ordering as the library's added-time sort.
    static func latest(from sorted: [LibraryBook], calendar: Calendar = .current) -> [Self] {
        var days: [Self] = []
        var currentStart = Date.distantFuture
        for book in sorted where !book.isUserHidden {
            let date = Date(timeIntervalSince1970: Double(book.createdAt) / 1000)
            if days.isEmpty || date < currentStart {
                guard days.count < 3, let day = calendar.dateInterval(of: .day, for: date) else { break }
                currentStart = day.start
                days.append(Self(id: day.start, bookIDs: [], hasMore: false))
            }
            let index = days.count - 1
            if days[index].bookIDs.count < previewLimit {
                days[index].bookIDs.append(book.id)
            } else {
                days[index].hasMore = true
                if days.count == 3 { break }
            }
        }
        return days
    }

    static func newer(_ lhs: LibraryBook, _ rhs: LibraryBook) -> Bool {
        if lhs.createdAt != rhs.createdAt { return lhs.createdAt > rhs.createdAt }
        let order = lhs.title.localizedCaseInsensitiveCompare(rhs.title)
        return order == .orderedSame ? lhs.id < rhs.id : order == .orderedAscending
    }

    func label(localizer: AppLocalizer) -> String {
        if Calendar.current.isDateInToday(id) { return localizer.string(.shelfToday) }
        if Calendar.current.isDateInYesterday(id) { return localizer.string(.shelfYesterday) }
        let locale = localizer.language.localizationIdentifier.map(Locale.init(identifier:)) ?? .current
        return id.formatted(Date.FormatStyle(date: .abbreviated, time: .omitted, locale: locale))
    }
}
