import SwiftUI

/// One gallery owns its samples, reading records and primary choices for its entire presentation.
@MainActor @Observable
final class DevelopmentCardSamples: BookCardLibrary, BookCardInteraction {
    private(set) var groups: [[LibraryBook]] = []
    private var records: [LibraryBook.ID: BookReadingState] = [:]
    private let open: (DevelopmentCardSamples, LibraryBook) -> Void
    private(set) var notice: String?

    init(localizer: AppLocalizer, open: @escaping (LibraryBook) -> Void) {
        self.open = { _, book in open(book) }
        let titles: [L10nKey] = [.singleBook, .samplePair, .sampleTrio, .sampleDozen,
                                 .sampleMissing, .cardRead, .sampleReadCount, .sampleUnknownPages]
        for (section, count) in [1, 2, 3, 12, 1, 1, 1, 1].enumerated() {
            let missing = section == 4
            let editions = (0..<count).map { version -> LibraryBook in
                let id = Int64((section + 1) * 100 + version)
                let code = ["japanese", "chinese", "english"][version % 3]
                let language = BookCardLanguageLabel(code, interfaceLanguage: localizer.language).fullName
                let label = count > 3 ? "\(language) · \(version + 1)" : language
                let title = localizer.string(titles[section]) + (version == 0 ? "" : " · " + label)
                let book = LibraryBook(databaseID: id, title: title, hash: "sample-\(id)", filepath: "",
                                       type: .archive, status: .correct, rating: missing ? nil : 3.8,
                                       pages: missing || section == 7 ? nil : section == 3 ? 1300 : 120,
                                       versionGroupID: count > 1 ? Int64(section) : nil,
                                       isPrimaryVersion: version == 0, versionLabel: count > 1 ? label : nil,
                                       languageCode: missing ? "unknown" : code, isFullColor: !missing && version % 2 == 0,
                                       censorship: missing ? "unknown" : version == 0 ? "mosaic censorship" : "uncensored",
                                       mark: section == 2, readCount: section == 6 ? 12 : 0)
                var state = BookReadingState.initial(bookID: id, totalPages: book.pages ?? 0)
                switch section {
                case 1: state.currentPageIndex = 11
                case 2: state.currentPageIndex = 98
                case 3: state.currentPageIndex = 1249
                case 5, 6: state.completedAt = state.updatedAt
                case 7: state.currentPageIndex = 36
                default: break
                }
                records[book.id] = state
                return book
            }
            groups.append(editions)
        }
    }

    init(groups: [[LibraryBook]], records: [LibraryBook.ID: BookReadingState],
         open: @escaping (DevelopmentCardSamples, LibraryBook) -> Void) {
        self.groups = groups
        self.records = records
        self.open = open
    }

    var displayed: [LibraryBook] { groups.compactMap { $0.first(where: \.isPrimaryVersion) } }

    func bookForCard(_ book: LibraryBook) -> LibraryBook {
        self.book(id: book.id) ?? book
    }

    func book(id: LibraryBook.ID) -> LibraryBook? {
        groups.lazy.compactMap { $0.first { $0.id == id } }.first
    }

    func setCardCompleted(_ completed: Bool, book: LibraryBook) {
        if completed {
            updateProgress(book: book, page: records[book.id]?.currentPageIndex ?? 0,
                           total: records[book.id]?.totalPages ?? book.pages ?? 0, completed: true)
        } else {
            records.removeValue(forKey: book.id)
        }
    }

    func cardVersionAlternatives(to book: LibraryBook, showsUserHidden: Bool) -> [LibraryBook] {
        guard let group = groups.first(where: { $0.first?.versionGroupID == book.versionGroupID }) else { return [] }
        return BookCardVersionChoices.alternatives(to: book, among: group, showsUserHidden: showsUserHidden)
    }

    func readingState(for book: LibraryBook) -> BookReadingState? { records[book.id] }

    func setCardMarked(_ marked: Bool, book: LibraryBook) {
        guard let group = groups.firstIndex(where: { $0.contains { $0.id == book.id } }) else { return }
        for index in groups[group].indices { groups[group][index].mark = marked }
    }

    func setPrimaryVersion(_ book: LibraryBook, completion: ((String?) -> Void)?) {
        guard let group = groups.firstIndex(where: { $0.contains { $0.id == book.id } }) else { return }
        for index in groups[group].indices {
            groups[group][index].isPrimaryVersion = groups[group][index].id == book.id
        }
        completion?(nil)
    }

    func read(_ book: LibraryBook) { open(self, book) }
    func showNotice(_ message: String) { notice = message }

    func updateProgress(book: LibraryBook, page: Int, total: Int, completed: Bool?) {
        guard let id = book.databaseID else { return }
        var record = records[book.id] ?? .initial(bookID: id, totalPages: total)
        record.currentPageIndex = page
        record.totalPages = total
        record.updatedAt = Timestamp.nowMilliseconds()
        if let completed { record.completedAt = completed ? record.updatedAt : nil }
        records[book.id] = record
    }

    func installCover(path: String) {
        for group in groups.indices {
            for edition in groups[group].indices { groups[group][edition].coverPath = path }
        }
    }
}

struct DevelopmentCardGallery: View {
    let samples: DevelopmentCardSamples
    let archive: URL
    let localizer: AppLocalizer
    let back: () -> Void
    @State private var width = BookCardMetrics.defaultWidth
    @State private var background = L10nKey.samplePlain
    @State private var mode = L10nKey.sampleCompare
    @State private var inspected: LibraryBook?
    @State private var cover: URL?
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Button(action: back) { Label(localizer.string(.back), systemImage: "chevron.left") }
                Text(localizer.string(.sampleGallery)).font(.title2.bold())
            }
            Picker(localizer.string(.sampleGallery), selection: $mode) {
                ForEach([L10nKey.sampleCompare, .sampleUnifiedOnly, .sampleStandardOnly], id: \.self) {
                    Text(localizer.string($0)).tag($0)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            HStack {
                Picker(localizer.string(.sampleBackground), selection: $background) {
                    ForEach([L10nKey.samplePlain, .sampleMaterial, .sampleTinted], id: \.self) {
                        Text(localizer.string($0)).tag($0)
                    }
                }
                .pickerStyle(.segmented)
                Stepper("\(width) pt", value: $width, in: BookCardMetrics.minimumWidth...BookCardMetrics.maximumWidth,
                        step: BookCardMetrics.step)
                    .fixedSize()
                    .accessibilityLabel(localizer.string(.sampleWidth))
                    .accessibilityValue("\(width) pt")
            }
            if let notice = samples.notice { Text(notice).font(.caption).foregroundStyle(.secondary) }
            GeometryReader { geometry in
                ScrollView {
                    if mode == .sampleCompare {
                        comparison(availableWidth: geometry.size.width)
                    } else {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: CGFloat(width), maximum: CGFloat(width)),
                                                     spacing: 16)], alignment: .leading, spacing: 22) {
                            ForEach(samples.displayed) { book in
                                card(book, appearance: mode == .sampleUnifiedOnly ? .unified : .standard)
                            }
                        }
                        .padding(16)
                    }
                }
            }
            .background { backdrop }
            .editionDeckHost()
        }
        .padding()
        .environment(\.bookCardCatalog, samples)
        .environment(\.bookCardActions, samples)
        .environment(\.bookCardFields, .all)
        .environment(\.bookCardAggregatesVersions, true)
        .popover(item: $inspected) { book in
            VStack(alignment: .leading, spacing: 8) {
                Text(BookTitleFormatter.displayTitle(for: book, mode: .originalTitle)).font(.headline)
                Button(localizer.string(.cardDirectRead)) {
                    inspected = nil
                    samples.read(book)
                }
            }
            .padding()
        }
        .environment(\.navigateCardGroup, nil)
        .task {
            // Decode only the configured test archive; all samples can share its first page.
            let session = try? await Task.detached { try ReaderArchiveSession(archiveURL: archive, securityScopedRootURL: nil) }.value
            guard let thumbnail = await session?.loadThumbnails(indices: [0], maximumPixelSize: 512).thumbnails.first,
                  let data = thumbnail.image?.tiffRepresentation, !Task.isCancelled else { return }
            let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension("tiff")
            do {
                try data.write(to: file, options: .atomic)
                cover = file
                samples.installCover(path: file.path)
            } catch { return }
        }
        .onDisappear {
            if let cover {
                CoverImageCache.shared.removeImage(for: cover.path)
                try? FileManager.default.removeItem(at: cover)
            }
        }
    }

    private func card(_ book: LibraryBook, appearance: BookCardMetrics.Appearance) -> some View {
        BookCardView(book: book, titleDisplayMode: .originalTitle, localizer: localizer,
                     metrics: .init(width: width, appearance: appearance)) { inspected = $0 }
            .bookCardHoverSurface()
    }

    private func comparison(availableWidth: CGFloat) -> some View {
        let spacing: CGFloat = 16
        let columnWidth = (availableWidth - 2 * spacing - spacing) / 2
        let perSide = max(1, Int((columnWidth + spacing) / (CGFloat(width) + spacing)))
        let books = samples.displayed
        let rowStarts = Array(stride(from: 0, to: books.count, by: perSide))
        return VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: spacing) {
                ForEach([L10nKey.sampleStandard, .sampleUnified], id: \.self) { label in
                    Text(localizer.string(label)).font(.headline)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            LazyVStack(alignment: .leading, spacing: 22) {
                ForEach(rowStarts, id: \.self) { start in
                    let row = books[start..<min(start + perSide, books.count)]
                    HStack(alignment: .top, spacing: spacing) {
                        ForEach([BookCardMetrics.Appearance.standard, .unified], id: \.self) { appearance in
                            HStack(alignment: .top, spacing: spacing) {
                                ForEach(row) { book in card(book, appearance: appearance) }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
            }
        }
        .padding(spacing)
    }

    @ViewBuilder private var backdrop: some View {
        switch background {
        case .sampleMaterial:
            Rectangle().fill(.regularMaterial)
        case .sampleTinted:
            Color.brown.opacity(colorScheme == .dark ? 0.48 : 0.23)
        default:
            Color(nsColor: .windowBackgroundColor)
        }
    }
}
