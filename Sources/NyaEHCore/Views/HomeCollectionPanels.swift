import SwiftUI

/// Both panels are sized by the same viewport as the lead showcase.
struct HomeCollectionPanels: View {
    let favorites: HomeFavoritePreview
    let days: [HomeArrivalDay]
    let height: CGFloat
    let cardWidth: Int
    var catalog: CatalogStore? = nil
    var translatesTags = false
    let titleMode: BookTitleDisplayMode
    let localizer: AppLocalizer
    let onSelect: (LibraryBook) -> Void
    let onFavorites: () -> Void
    let onSearch: () -> Void

    var body: some View {
        if !favorites.books.isEmpty {
            FavoriteShowcase(preview: favorites, cardWidth: cardWidth, catalog: catalog,
                             translatesTags: translatesTags, titleMode: titleMode,
                             localizer: localizer, onSelect: onSelect, onManage: onFavorites)
                .frame(height: height)
        }
        if !days.isEmpty {
            ArrivalShowcase(days: days, cardWidth: cardWidth, titleMode: titleMode,
                            localizer: localizer, onSelect: onSelect, onSearch: onSearch)
                .frame(height: height)
        }
    }
}

private struct FavoriteShowcase: View {
    let preview: HomeFavoritePreview
    let cardWidth: Int
    var catalog: CatalogStore? = nil
    var translatesTags = false
    let titleMode: BookTitleDisplayMode
    let localizer: AppLocalizer
    let onSelect: (LibraryBook) -> Void
    let onManage: () -> Void
    @FocusState private var infoFocus: HomeShowcaseControl?
    @State private var tagPreview: LibraryBook.ID?
    @State private var fadedEdges: Edge.Set = []
    @State private var selection: LibraryBook.ID?
    @FocusState private var focused: LibraryBook.ID?
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private var rose: Color { scheme == .dark ? Color(red: 1, green: 0.65, blue: 0.73) : Color(red: 0.62, green: 0.12, blue: 0.27) }

    private var roseTint: Color {
        scheme == .dark ? Color(red: 0.57, green: 0.12, blue: 0.22) : .pink
    }

    var body: some View {
        let selectable = preview.hasMore ? preview.books.dropLast() : preview.books
        if let book = selectable.first(where: { $0.id == selection }) ?? selectable.first {
            GeometryReader { box in
                let w = box.size.width
                let h = box.size.height
                let inset: CGFloat = w < 720 ? 14 : 24
                let title = BookTitleFormatter.displayTitle(for: book, mode: titleMode)
                let headingHeight: CGFloat = w < 600 ? 22 : 28
                let headingGap: CGFloat = 8
                let contentHeight = max(1, h - 2 * inset - headingHeight - headingGap)
                let coverWidth = min(w * 0.30, contentHeight * 0.78)
                let selectorWidth = min(300, (w - coverWidth - 3 * inset) * 0.50)
                VStack(alignment: .leading, spacing: headingGap) {
                    Button(localizer.string(.myFavorites), action: onManage)
                        .font(HomeShowcaseTypography.heading(width: w))
                        .foregroundStyle(rose)
                        .buttonStyle(.plain)
                        .help(localizer.string(.favoriteManagement))
                        .accessibilityIdentifier("home.favorites.heading")
                        .frame(height: headingHeight, alignment: .topLeading)
                    HStack(spacing: inset) {
                        Button { onSelect(book) } label: {
                            BookCoverThumbnail(book: book, width: coverWidth, height: contentHeight, cornerRadius: 6,
                                               fitsEntireImage: true, showsFitBackground: false, perspectivePreview: true)
                                .shadow(color: .black.opacity(scheme == .dark ? 0.4 : 0.2), radius: 8, y: 5)
                                .showcaseFade(book.id, reduceMotion: reduceMotion)
                        }
                        .buttonStyle(.plain).accessibilityLabel(title)
                        .accessibilityIdentifier("home.favorites.cover")
                        .contextMenu { BookCardMenu(book: book, titleDisplayMode: titleMode, localizer: localizer,
                                                    selection: nil, beforeNavigation: nil, showDetail: onSelect) }
                        HomeShowcaseInformation(book: book, title: title, width: w, height: contentHeight,
                                                catalog: catalog, translates: translatesTags, localizer: localizer,
                                                progressTint: roseTint, readIdentifier: "home.favorites.read", focus: $infoFocus,
                                                tagPreview: $tagPreview, onSelect: onSelect) {
                            selector(current: book, height: contentHeight)
                                .frame(width: selectorWidth)
                        }
                    }
                    .frame(height: contentHeight)
                }
                .padding(inset)
                .frame(width: w, height: h)
                .background { HomePanelBackground(tint: roseTint, symbol: "heart") }
            }
            .modifier(HomePanelSurface())
            .onChange(of: focused) { _, id in
                if let id, selectable.contains(where: { $0.id == id }) { selection = id }
            }
        }
    }

    private func selector(current: LibraryBook, height: CGFloat) -> some View {
        let thumb = max(34, min(CGFloat(cardWidth) * 0.34, height * 0.24))
        let thumbHeight = thumb * 1.29
        return ScrollView(.horizontal) {
            HStack(spacing: 6) {
                ForEach(preview.books) { candidate in
                    let more = preview.hasMore && candidate.id == preview.books.last?.id
                    let name = more ? localizer.string(.favoriteManagement)
                        : BookTitleFormatter.displayTitle(for: candidate, mode: titleMode)
                    Button {
                        if more { onManage() } else { selection = candidate.id }
                    } label: {
                        BookCoverThumbnail(book: candidate, width: thumb, height: thumbHeight, cornerRadius: 4)
                            .transformEnvironment(\.coverPrivacyRevealAllowed) { $0 = $0 && !more }
                            .blur(radius: more ? 3 : 0)
                            .overlay {
                                if more {
                                    Color.black.opacity(0.32)
                                    Image(systemName: "ellipsis").foregroundStyle(.white)
                                }
                            }
                            .clipShape(RoundedRectangle(cornerRadius: 4))
                            .overlay {
                                RoundedRectangle(cornerRadius: 4)
                                    .strokeBorder(candidate.id == current.id ? rose : .clear, lineWidth: 2)
                            }
                    }
                    .buttonStyle(.plain)
                    .focused($focused, equals: candidate.id)
                    .onHover { if $0 && !more { selection = candidate.id } }
                    .help(name).accessibilityLabel(name)
                    .accessibilityIdentifier(more ? "home.favorites.more" : "home.favorites.choice." + candidate.id)
                    .accessibilityAddTraits(current.id == candidate.id ? .isSelected : [])
                }
            }
        }
        .onScrollGeometryChange(for: Edge.Set.self) { geometry in
            var edges: Edge.Set = []
            if geometry.visibleRect.minX > 1 { edges.insert(.leading) }
            if geometry.visibleRect.maxX < geometry.contentSize.width - 1 { edges.insert(.trailing) }
            return edges
        } action: { _, edges in fadedEdges = edges }
        .mask {
            HStack(spacing: 0) {
                if fadedEdges.contains(.leading) {
                    LinearGradient(colors: [.clear, .black], startPoint: .leading, endPoint: .trailing).frame(width: 16)
                }
                Rectangle()
                if fadedEdges.contains(.trailing) {
                    LinearGradient(colors: [.black, .clear], startPoint: .leading, endPoint: .trailing).frame(width: 16)
                }
            }
        }
        .defaultScrollAnchor(.trailing, for: .alignment)
        .scrollBounceBehavior(.basedOnSize)
        .frame(height: thumbHeight + 6)
    }
}

private struct ArrivalShowcase: View {
    let days: [HomeArrivalDay]
    let cardWidth: Int
    let titleMode: BookTitleDisplayMode
    let localizer: AppLocalizer
    let onSelect: (LibraryBook) -> Void
    let onSearch: () -> Void
    @Environment(\.bookCardCatalog) private var catalog
    private let accent = Color.blue
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var selectedDay: Date?
    @FocusState private var focusedDay: Date?

    var body: some View {
        if let current = days.first(where: { $0.id == selectedDay }) ?? days.first {
            GeometryReader { box in
                let inset: CGFloat = box.size.width < 720 ? 14 : 24
                let gap: CGFloat = box.size.width < 720 ? 8 : 14
                let area = box.size.width - 2 * inset
                VStack(alignment: .leading, spacing: 10) {
                    Text(localizer.string(.recentlyAdded))
                        .font(HomeShowcaseTypography.heading(width: box.size.width))
                        .foregroundStyle(accent)
                    HStack(spacing: 0) {
                        ForEach(days) { day in
                            if day.id != days.first?.id {
                                Rectangle().fill(.secondary.opacity(0.30)).frame(minWidth: 6, maxWidth: 38, maxHeight: 1)
                            }
                            Button { selectedDay = day.id } label: {
                                HStack(spacing: 5) {
                                    Circle().strokeBorder(day.id == current.id ? accent : .secondary, lineWidth: 1)
                                        .background(day.id == current.id ? accent : .clear, in: Circle()).frame(width: 8, height: 8)
                                    Text(day.label(localizer: localizer)).font(.callout.weight(day.id == current.id ? .semibold : .regular))
                                        .lineLimit(1).minimumScaleFactor(0.78)
                                }.foregroundStyle(day.id == current.id ? Color.primary : .secondary)
                                    .padding(.vertical, 4).contentShape(Rectangle())
                            }
                            .buttonStyle(.plain).focused($focusedDay, equals: day.id)
                            .onHover { if $0 { selectedDay = day.id } }
                            .accessibilityAddTraits(day.id == current.id ? .isSelected : [])
                        }
                        if days.last?.hasEarlierDay == true {
                            LinearGradient(colors: [accent.opacity(0.45), .clear],
                                           startPoint: .leading, endPoint: .trailing)
                                .frame(width: 32, height: 1)
                                .accessibilityHidden(true)
                        }
                    }.fixedSize(horizontal: false, vertical: true)
                    GeometryReader { strip in
                        let books = current.bookIDs.compactMap { catalog?.book(id: $0) }
                        let width = max(1, min(CGFloat(cardWidth), (area - 6 * gap) / 7, (strip.size.height - 25) * 0.78))
                        let coverHeight = width / 0.78
                        HStack(alignment: .top, spacing: gap) {
                            ForEach(books) { book in
                                let more = current.hasMore && book.id == current.bookIDs.last
                                let title = BookTitleFormatter.displayTitle(for: book, mode: titleMode)
                                Button { if more { onSearch() } else { onSelect(book) } } label: {
                                    VStack(alignment: .leading, spacing: 6) {
                                        BookCoverThumbnail(book: book, width: width, height: coverHeight, cornerRadius: 5)
                                            .transformEnvironment(\.coverPrivacyRevealAllowed) { $0 = $0 && !more }
                                            .blur(radius: more ? 4 : 0)
                                            .overlay {
                                                if more {
                                                    Color.black.opacity(0.28)
                                                    Image(systemName: "ellipsis").font(.title3.bold()).foregroundStyle(.white)
                                                }
                                            }
                                            .clipShape(RoundedRectangle(cornerRadius: 5))
                                        Text(more ? localizer.string(.arrivalSearch) : title)
                                            .font(.caption.weight(.medium)).lineLimit(1)
                                    }.frame(width: width, alignment: .leading).contentShape(Rectangle())
                                }
                                .buttonStyle(.plain).help(more ? localizer.string(.arrivalSearch) : title)
                                .contextMenu {
                                    if !more {
                                        BookCardMenu(book: book, titleDisplayMode: titleMode, localizer: localizer,
                                                     selection: nil, beforeNavigation: nil, showDetail: onSelect)
                                    }
                                }
                            }
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                        .showcaseFade(String(current.id.timeIntervalSinceReferenceDate), reduceMotion: reduceMotion)
                    }
                }
                .padding(inset)
                .frame(width: box.size.width, height: box.size.height)
                .background { HomePanelBackground(tint: accent, symbol: "books.vertical") }
            }
            .modifier(HomePanelSurface())
            .onChange(of: focusedDay) { _, id in if let id { selectedDay = id } }
        }
    }
}

struct HomePanelSurface: ViewModifier {
    @Environment(\.colorScheme) private var scheme
    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: 14, style: .continuous)
        content.clipShape(shape)
            .overlay { shape.strokeBorder(.primary.opacity(scheme == .dark ? 0.10 : 0.045)).allowsHitTesting(false) }
            .shadow(color: .black.opacity(scheme == .dark ? 0.27 : 0.09), radius: 9, y: 4)
    }
}
