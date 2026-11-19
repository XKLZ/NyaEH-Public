import SwiftUI

/// Preserve the two home queries independently: favorites represent works, arrivals represent files.
@MainActor
struct DevelopmentShelfSource {
    let samples: DevelopmentCardSamples
    let days: [HomeArrivalDay]
    private let recentIDs: [LibraryBook.ID]
    private let favoriteGroups: Set<Int>

    init(favorites: [LibraryBook], recent: [LibraryBook], days: [HomeArrivalDay]? = nil,
         companions: (LibraryBook) -> [LibraryBook],
         record: (LibraryBook) -> BookReadingState?, open: @escaping (DevelopmentCardSamples, LibraryBook) -> Void) {
        self.days = days ?? HomeArrivalDay.latest(from: recent.sorted(by: HomeArrivalDay.newer))
        recentIDs = recent.prefix(10).map(\.id)
        let marked = Set(favorites.map(\.id))
        var included = Set<LibraryBook.ID>()
        var groups: [[LibraryBook]] = []
        var eligible = Set<Int>()
        var records: [LibraryBook.ID: BookReadingState] = [:]
        for seed in favorites + recent where !included.contains(seed.id) {
            let editions = ([seed] + companions(seed)).filter { included.insert($0.id).inserted }
            if editions.contains(where: { marked.contains($0.id) }) || !seed.mark { eligible.insert(groups.count) }
            groups.append(editions)
            for edition in editions { records[edition.id] = record(edition) }
        }
        favoriteGroups = eligible
        samples = DevelopmentCardSamples(groups: groups, records: records, open: open)
    }

    var favorites: [LibraryBook] {
        samples.groups.enumerated().compactMap { index, group in
            guard favoriteGroups.contains(index), let original = group.first, original.mark else { return nil }
            return group.first { $0.isPrimaryVersion && !$0.isUserHidden } ?? original
        }
    }

    var recent: [LibraryBook] { recentIDs.compactMap(samples.book(id:)) }
}

struct ShelfPreviewLayout {
    static let nodeGutter: CGFloat = 20
    static let dateWidth: CGFloat = 96
    static let dateGap: CGFloat = 12
    let sideDate: Bool
    let columns: Int

    init(available: CGFloat, cardWidth: CGFloat) {
        let inner = available - Self.nodeGutter
        let besideDate = inner - Self.dateWidth - Self.dateGap
        sideDate = besideDate >= 2 * cardWidth + BookCardMetrics.shelfSpacing
        let gridWidth = sideDate ? besideDate : inner
        columns = max(1, Int((gridWidth + BookCardMetrics.shelfSpacing) / (cardWidth + BookCardMetrics.shelfSpacing)))
    }

    static func controlGutter(count: Int, cardWidth: CGFloat, available: CGFloat) -> CGFloat {
        let rowWidth = CGFloat(count) * cardWidth + CGFloat(max(0, count - 1)) * BookCardMetrics.shelfSpacing
        return count > 1 && rowWidth > available ? 36 : 0
    }
}

struct ShelfArrivalDay: Identifiable {
    let id: Date
    var books: [LibraryBook]

    static func groups(_ books: [LibraryBook], expanded: Bool, calendar: Calendar = .current) -> [Self] {
        var groups: [Self] = []
        for book in books.prefix(expanded ? 10 : 4) {
            let day = calendar.startOfDay(for: Date(timeIntervalSince1970: Double(book.createdAt) / 1000))
            if groups.last?.id == day {
                groups[groups.count - 1].books.append(book)
            } else {
                groups.append(Self(id: day, books: [book]))
            }
        }
        return groups
    }

    static func caption(_ book: LibraryBook, localizer: AppLocalizer) -> String {
        var parts = VersionLabelFormatter.labels(from: book.versionLabel)
        let metadata = BookCardMetadata(book: book)
        if let code = metadata.language {
            let language = BookCardLanguageLabel(code, interfaceLanguage: localizer.language)
            let aliases: [String: [String]] = ["chinese": ["中文", "汉化", "漢化", "中国翻訳"],
                "japanese": ["日文", "日语", "日本語"], "english": ["英文", "英语", "英語"]]
            let alreadyLabeled = parts.contains { label in
                [code, language.fullName, language.abbreviation].contains { label.caseInsensitiveCompare($0) == .orderedSame }
                    || (aliases[code.lowercased()] ?? []).contains { label.contains($0) }
            }
            if !alreadyLabeled { parts.append(language.fullName) }
        }
        if let pages = metadata.pages { parts.append(localizer.bookPageCount(pages)) }
        return parts.joined(separator: " · ")
    }
}

@MainActor
final class DevelopmentShelfSession {
    let library: DevelopmentShelfSource
    private let open: (DevelopmentCardSamples, LibraryBook, Bool) -> Void
    private let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    lazy var fixtures = makeFixtures()

    init(catalog: CatalogStore, open: @escaping (DevelopmentCardSamples, LibraryBook, Bool) -> Void) {
        self.open = open
        let days = catalog.homeArrivalDays
        let existing = Set(catalog.recentlyAddedBooks.map(\.id))
        let extra = days.flatMap(\.bookIDs).filter { !existing.contains($0) }.compactMap(catalog.book(id:))
        library = DevelopmentShelfSource(favorites: catalog.homeFavoritePreview.candidates,
                                         recent: catalog.recentlyAddedBooks + extra, days: days,
                                         companions: catalog.versionCompanions(for:), record: catalog.readingState(for:)) {
            open($0, $1, false)
        }
    }

    func removeFixtureCovers() {
        guard let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else { return }
        for file in files { CoverImageCache.shared.removeImage(for: file.path) }
        try? FileManager.default.removeItem(at: directory)
    }

    private func makeFixtures() -> DevelopmentShelfSource {
        let names = ["潮汐图志", "潮汐图志", "月面来信", "深夜电车", "无人岛上的最后一座玻璃温室与迟到了整个夏天的信",
                     "云端气象台", "海岸线", "植物备忘录", "候鸟", "流星列车", "雨后的街道"]
        let symbols = ["water.waves", "water.waves", "moon.stars", "tram", "leaf", "cloud.sun", "sailboat", "camera.macro", "bird", "sparkles", "cloud.rain"]
        let inks: [Color] = [.indigo, .cyan, .orange, .purple, .mint, .blue, .teal, .green, .red, .pink, .brown]
        let today = Calendar.current.startOfDay(for: Date())
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let books = names.indices.map { index -> LibraryBook in
            let file = directory.appendingPathComponent("cover-\(index).tiff")
            let artwork = ZStack(alignment: .bottomLeading) {
                LinearGradient(colors: [inks[index], inks[index].mix(with: .black, by: 0.64)], startPoint: .topLeading, endPoint: .bottomTrailing)
                Circle().stroke(.white.opacity(0.36), lineWidth: 1).frame(width: 220, height: 220).offset(x: 30, y: -63)
                VStack(alignment: .leading, spacing: 12) {
                    Image(systemName: symbols[index]).font(.system(size: 52, weight: .light))
                    Spacer()
                    Text(names[index]).font(.system(size: 25, weight: .bold, design: .serif)).lineLimit(3)
                }.foregroundStyle(.white).padding(18)
            }.frame(width: 190, height: 246).clipped()
            let renderer = ImageRenderer(content: artwork)
            try? renderer.nsImage?.tiffRepresentation?.write(to: file)
            let date = Calendar.current.date(byAdding: .day, value: -(index < 8 ? 0 : 1 + (index - 8) / 2), to: today) ?? today
            let timestamp = Int64(date.timeIntervalSince1970 * 1000) + Int64(10 - index)
            return LibraryBook(databaseID: Int64(index + 1), title: names[index], coverPath: file.path,
                               hash: "debug-shelf-\(index)", filepath: "", type: .archive, status: .correct,
                               rating: index == 4 ? nil : 3.8, pages: index == 4 ? nil : 32 + 4 * index,
                               versionGroupID: index < 2 ? 1 : nil, isPrimaryVersion: index != 1,
                               versionLabel: index == 0 ? "日文原版" : index == 1 ? "汉化版" : nil,
                               languageCode: index == 4 ? "unknown" : index == 1 ? "chinese" : "japanese",
                               isFullColor: index.isMultiple(of: 3), mark: true, createdAt: timestamp)
        }
        return DevelopmentShelfSource(favorites: books.filter(\.isPrimaryVersion), recent: books,
                                      companions: { book in books.filter { book.versionGroupID != nil && $0.versionGroupID == book.versionGroupID } },
                                      record: { book in
            guard let id = book.databaseID, id <= 2 else { return nil }
            var state = BookReadingState.initial(bookID: id, totalPages: book.pages ?? 0)
            state.currentPageIndex = Int(id) * 3
            return state
        }) { [open] in open($0, $1, true) }
    }
}
