import SwiftUI

struct DevelopmentShelfPreview: View {
    let session: DevelopmentShelfSession
    let localizer: AppLocalizer
    let titleMode: BookTitleDisplayMode
    let onOpenRecentSearch: () -> Void
    let back: () -> Void
    @State private var width: Int
    @State private var mode = L10nKey.shelfRedesign
    @State private var data = L10nKey.shelfLibrary
    @State private var single = false
    @State private var expanded = false
    @State private var inspected: LibraryBook?
    @State private var managing = false
    @State private var positions = HomeShelfPositions()

    init(session: DevelopmentShelfSession, localizer: AppLocalizer, titleMode: BookTitleDisplayMode,
         initialWidth: Int, onOpenRecentSearch: @escaping () -> Void, back: @escaping () -> Void) {
        self.session = session
        self.localizer = localizer
        self.titleMode = titleMode
        self.onOpenRecentSearch = onOpenRecentSearch
        self.back = back
        _width = State(initialValue: initialWidth)
    }

    private var source: DevelopmentShelfSource { data == .shelfLibrary ? session.library : session.fixtures }

    var body: some View {
        GeometryReader { viewport in
            preview(panelHeight: viewport.size.height / 2)
        }
    }

    private func preview(panelHeight: CGFloat) -> some View {
        let snapshot = source
        return VStack(alignment: .leading, spacing: 12) {
            HStack {
                Button(action: back) { Label(localizer.string(.back), systemImage: "chevron.left") }
                Text(localizer.string(.shelfPreview)).font(.title2.bold())
            }
            picker([.shelfCurrent, .shelfRedesign], $mode)
            HStack {
                picker([.shelfLibrary, .shelfFixtures], $data).fixedSize()
                if data == .shelfFixtures {
                    Toggle(localizer.string(.shelfSingle), isOn: $single)
                }
                Spacer()
                Stepper("\(width) pt", value: $width, in: BookCardMetrics.minimumWidth...BookCardMetrics.maximumWidth,
                        step: BookCardMetrics.step).fixedSize().accessibilityLabel(localizer.string(.sampleWidth))
            }
            if let notice = snapshot.samples.notice { Text(notice).font(.caption).foregroundStyle(.secondary) }
            Divider()
            GeometryReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 28) {
                        let favorites = data == .shelfFixtures && single ? Array(snapshot.favorites.prefix(1)) : snapshot.favorites
                        let sectionWidth = max(0, proxy.size.width - 32)
                        let gutter = ShelfPreviewLayout.controlGutter(count: favorites.count, cardWidth: CGFloat(width),
                                                                     available: sectionWidth)
                        if mode == .shelfRedesign {
                            HomeCollectionPanels(favorites: HomeFavoritePreview(favorites: favorites), days: snapshot.days, height: panelHeight,
                                                 cardWidth: width, titleMode: titleMode, localizer: localizer,
                                                 onSelect: { inspected = $0 }, onFavorites: { managing = true },
                                                 onSearch: onOpenRecentSearch)
                        } else {
                            if !favorites.isEmpty { shelf(.myFavorites, Array(favorites.prefix(HomeFavoritePreview.limit)), gutter: gutter) }
                            if !snapshot.recent.isEmpty {
                                arrivals(snapshot.recent, available: sectionWidth - 2 * gutter)
                                    .padding(.horizontal, gutter)
                            }
                        }
                        if favorites.isEmpty && snapshot.recent.isEmpty {
                            Text(localizer.string(.noBooks)).foregroundStyle(.secondary)
                        }
                    }
                    .padding(16).frame(maxWidth: .infinity, alignment: .leading)
                }
                .editionDeckHost()
                .id(data)
            }
        }
        .padding()
        .popover(item: $inspected) { book in
            VStack(alignment: .leading, spacing: 10) {
                Text(title(book)).font(.headline)
                Text(ShelfArrivalDay.caption(book, localizer: localizer)).foregroundStyle(.secondary)
                Button(localizer.string(.cardDirectRead)) { inspected = nil; snapshot.samples.read(book) }
            }.padding().frame(maxWidth: 360)
        }
        .sheet(isPresented: $managing) {
            VStack(alignment: .leading) {
                HStack {
                    Text(localizer.string(.favoriteManagement)).font(.title2.bold())
                    Spacer()
                    Button(localizer.string(.back)) { managing = false }.keyboardShortcut(.cancelAction)
                }
                List(snapshot.favorites) { book in
                    HStack {
                        Text(title(book)).lineLimit(2)
                        Spacer()
                        Button { snapshot.samples.setCardMarked(false, book: book) } label: {
                            Image(systemName: "heart.fill").foregroundStyle(.red)
                        }.buttonStyle(.plain).accessibilityLabel(localizer.string(.toggleMarked))
                    }
                }
            }.padding().frame(minWidth: 380, minHeight: 300)
        }
        .environment(\.bookCardCatalog, snapshot.samples)
        .environment(\.bookCardActions, snapshot.samples)
        .environment(\.navigateCardGroup, nil)
        .onChange(of: data) { expanded = false; positions = HomeShelfPositions() }
        .onDisappear { session.removeFixtureCovers() }
    }

    private func picker(_ keys: [L10nKey], _ selection: Binding<L10nKey>) -> some View {
        Picker(localizer.string(.shelfPreview), selection: selection) {
            ForEach(keys, id: \.self) { key in Text(localizer.string(key)).tag(key) }
        }.pickerStyle(.segmented).labelsHidden()
    }

    private func title(_ book: LibraryBook) -> String { BookTitleFormatter.displayTitle(for: book, mode: titleMode) }

    private func shelf(_ key: L10nKey, _ books: [LibraryBook], gutter: CGFloat?) -> some View {
        HomeShelfSection(title: localizer.string(key), books: books, titleDisplayMode: titleMode,
                         metrics: .init(width: width), leadingBleed: 0, localizer: localizer,
                         onSelect: { inspected = $0 }, action: key == .myFavorites
                            ? .init(title: localizer.string(.favoriteManagement), systemImage: "arrow.forward.circle",
                                    perform: { managing = true }) : nil,
                         position: positions.position(for: key), exhibitGutter: gutter)
    }

    private func arrivals(_ books: [LibraryBook], available: CGFloat) -> some View {
        let days = ShelfArrivalDay.groups(books, expanded: expanded)
        let layout = ShelfPreviewLayout(available: available, cardWidth: CGFloat(width))
        return VStack(alignment: .leading, spacing: 16) {
            Text(localizer.string(.recentlyAdded)).font(.title2.weight(.semibold))
            VStack(alignment: .leading, spacing: 0) {
                ForEach(days) { day in
                    arrivalGroup(day, layout: layout)
                        .padding(.bottom, day.id == days.last?.id ? 0 : 22)
                        .background(alignment: .topLeading) {
                            GeometryReader { geometry in
                                Path { path in
                                    let start: CGFloat = day.id == days.first?.id ? 9 : 0
                                    let end: CGFloat = day.id == days.last?.id ? 9 : geometry.size.height
                                    path.move(to: CGPoint(x: 5, y: start))
                                    path.addLine(to: CGPoint(x: 5, y: end))
                                }.stroke(.secondary.opacity(0.32), lineWidth: 1)
                            }.allowsHitTesting(false)
                        }
                        .overlay(alignment: .topLeading) {
                            Circle().strokeBorder(Calendar.current.isDateInToday(day.id) ? accent : .secondary, lineWidth: 1)
                                .background(Calendar.current.isDateInToday(day.id) ? accent : Color(nsColor: .windowBackgroundColor), in: Circle())
                                .frame(width: 10, height: 10).padding(.top, 4)
                                .allowsHitTesting(false).accessibilityHidden(true)
                        }
                }
            }
            if books.count > 4 {
                Button(expanded ? localizer.string(.collapseSection) :
                        String(format: localizer.string(.shelfMore), books.count - 4)) { expanded.toggle() }
                    .controlSize(.small)
                    .padding(.leading, ShelfPreviewLayout.nodeGutter)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @Environment(\.nyaehAccentColor) private var accent

    private func arrivalGroup(_ day: ShelfArrivalDay, layout: ShelfPreviewLayout) -> some View {
        let flow = layout.sideDate ? AnyLayout(HStackLayout(alignment: .top, spacing: ShelfPreviewLayout.dateGap))
                                   : AnyLayout(VStackLayout(alignment: .leading, spacing: 10))
        return flow {
            Text(dateLabel(day.id))
                .font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
                .frame(width: layout.sideDate ? ShelfPreviewLayout.dateWidth : nil, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
            LazyVGrid(columns: Array(repeating: GridItem(.fixed(CGFloat(width)), spacing: BookCardMetrics.shelfSpacing),
                                      count: layout.columns), alignment: .leading, spacing: BookCardMetrics.shelfSpacing) {
                ForEach(day.books) { book in
                    BookCardButton(book: book, titleDisplayMode: titleMode, localizer: localizer,
                                   metrics: .init(width: width)) { inspected = $0 }
                }
            }
            .environment(\.bookCardAggregatesVersions, false)
        }
        .padding(.leading, ShelfPreviewLayout.nodeGutter)
    }

    private func dateLabel(_ date: Date) -> String {
        if Calendar.current.isDateInToday(date) { return localizer.string(.shelfToday) }
        if Calendar.current.isDateInYesterday(date) { return localizer.string(.shelfYesterday) }
        let locale = localizer.language.localizationIdentifier.map(Locale.init(identifier:)) ?? .current
        return date.formatted(Date.FormatStyle(date: .abbreviated, time: .omitted, locale: locale))
    }
}
