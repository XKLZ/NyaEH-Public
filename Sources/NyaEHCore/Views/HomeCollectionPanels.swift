import SwiftUI

/// Both panels are sized by the same viewport as the lead showcase.
struct HomeCollectionPanels: View {
    let favorites: HomeFavoritePreview
    let days: [HomeArrivalDay]
    let height: CGFloat
    let cardWidth: Int
    let titleMode: BookTitleDisplayMode
    let localizer: AppLocalizer
    let onSelect: (LibraryBook) -> Void
    let onFavorites: () -> Void
    let onSearch: () -> Void

    var body: some View {
        if !favorites.books.isEmpty {
            FavoriteShowcase(preview: favorites, cardWidth: cardWidth, titleMode: titleMode,
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
    let titleMode: BookTitleDisplayMode
    let localizer: AppLocalizer
    let onSelect: (LibraryBook) -> Void
    let onManage: () -> Void
    @State private var selection: LibraryBook.ID?
    @FocusState private var focused: LibraryBook.ID?
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private var rose: Color { scheme == .dark ? Color(red: 1, green: 0.65, blue: 0.73) : Color(red: 0.62, green: 0.12, blue: 0.27) }

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
                let selectorWidth = min(300, w * 0.28)
                VStack(alignment: .leading, spacing: headingGap) {
                    Button(localizer.string(.myFavorites), action: onManage)
                        .font(.system(size: w < 600 ? 17 : 22, weight: .semibold))
                        .foregroundStyle(rose)
                        .buttonStyle(.plain)
                        .help(localizer.string(.favoriteManagement))
                        .accessibilityIdentifier("home.favorites.heading")
                        .frame(height: headingHeight, alignment: .topLeading)
                    HStack(spacing: inset) {
                        Button { onSelect(book) } label: {
                            BookCoverThumbnail(book: book, width: coverWidth, height: contentHeight, cornerRadius: 6,
                                               fitsEntireImage: true, showsFitBackground: false)
                                .shadow(color: .black.opacity(scheme == .dark ? 0.4 : 0.2), radius: 8, y: 5)
                                .showcaseFade(book.id, reduceMotion: reduceMotion)
                        }
                        .buttonStyle(.plain).accessibilityLabel(title)
                        .accessibilityIdentifier("home.favorites.cover")
                        .contextMenu { BookCardMenu(book: book, titleDisplayMode: titleMode, localizer: localizer,
                                                    selection: nil, beforeNavigation: nil, showDetail: onSelect) }
                        VStack(alignment: .leading, spacing: 12) {
                            Button { onSelect(book) } label: {
                                Text(title).font(.system(size: min(36, max(20, w / 29)), weight: .bold, design: .serif))
                                    .multilineTextAlignment(.leading).lineLimit(3).help(title)
                            }.buttonStyle(.plain)
                            let meta = BookCardMetadata(book: book)
                            if let rating = meta.rating { BookCardRating(rating: rating, localizer: localizer, size: .showcase) }
                            let details = [meta.language.map { BookCardLanguageLabel($0, interfaceLanguage: localizer.language).fullName },
                                           meta.isFullColor ? localizer.string(.fullColor) : nil, meta.pages.map(localizer.bookPageCount)]
                                .compactMap { $0 }.joined(separator: " · ")
                            if !details.isEmpty { Text(details).font(.callout).foregroundStyle(.secondary).lineLimit(2) }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .showcaseFade(book.id, reduceMotion: reduceMotion)
                        selector(current: book, height: contentHeight)
                            .frame(width: selectorWidth, height: contentHeight, alignment: .bottomTrailing)
                    }
                    .frame(height: contentHeight)
                }
                .padding(inset)
                .frame(width: w, height: h)
                .background(alignment: .leading) {
                    LinearGradient(colors: scheme == .dark
                                   ? [Color(red: 0.28, green: 0.09, blue: 0.15), Color(red: 0.10, green: 0.075, blue: 0.09), .black]
                                   : [Color(red: 1, green: 0.86, blue: 0.9), Color(red: 1, green: 0.96, blue: 0.965), .white],
                                   startPoint: .bottomLeading, endPoint: .topTrailing)
                        .overlay(alignment: .leading) {
                            Image(systemName: "heart").font(.system(size: h * 0.79, weight: .ultraLight))
                                .foregroundStyle(rose.opacity(0.13)).rotationEffect(.degrees(-14)).offset(x: -h * 0.18)
                                .accessibilityHidden(true)
                        }.allowsHitTesting(false)
                }
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
    @Environment(\.nyaehAccentColor) private var accent
    @Environment(\.colorScheme) private var scheme
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
                    HStack {
                        Text(localizer.string(.recentlyAdded)).font(.title2.weight(.semibold))
                        Spacer()
                        Button(action: onSearch) {
                            Label(localizer.string(.arrivalSearch), systemImage: "arrow.up.right")
                                .font(.callout.weight(.medium))
                        }.buttonStyle(.plain).foregroundStyle(accent)
                    }
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
                .background {
                    LinearGradient(colors: [Color(nsColor: .controlBackgroundColor),
                                            accent.opacity(scheme == .dark ? 0.08 : 0.045)],
                                   startPoint: .topLeading, endPoint: .bottomTrailing)
                        .background(Color(nsColor: .windowBackgroundColor))
                }
            }
            .modifier(HomePanelSurface())
            .onChange(of: focusedDay) { _, id in if let id { selectedDay = id } }
        }
    }
}

private struct HomePanelSurface: ViewModifier {
    @Environment(\.colorScheme) private var scheme
    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: 14, style: .continuous)
        content.clipShape(shape)
            .overlay { shape.strokeBorder(.primary.opacity(scheme == .dark ? 0.10 : 0.045)).allowsHitTesting(false) }
            .shadow(color: .black.opacity(scheme == .dark ? 0.27 : 0.09), radius: 9, y: 4)
    }
}
