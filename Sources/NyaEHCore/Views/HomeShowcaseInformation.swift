import SwiftUI

enum HomeShowcaseTypography {
    static func title(width: CGFloat) -> Font { .system(size: min(36, max(28, width / 19)), weight: .bold) }
    static func heading(width: CGFloat) -> Font { .system(size: width < 600 ? 17 : 22, weight: .semibold) }
    static let credit = Font.callout
    static let metadata = Font.callout
    @MainActor static let tag = NSFont.systemFont(ofSize: 11)
    static let reading = Font.callout.weight(.medium)
    static let selector = Font.system(size: 13, weight: .medium)
}

enum HomeShowcaseControl: Hashable {
    case cover, title, reader, heading(HomeShowcaseGroup), thumbnail(HomeShowcaseSelection)
}

struct HomePanelBackground: View {
    let tint: Color
    let symbol: String
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        Color(nsColor: .windowBackgroundColor)
            .overlay {
                LinearGradient(colors: [tint.opacity(scheme == .dark ? 0.56 : 0.46), tint.opacity(0.16), .clear],
                               startPoint: .leading, endPoint: .trailing)
            }
            .overlay {
                GeometryReader { box in
                    ZStack {
                        Image(systemName: symbol)
                            .font(.system(size: min(box.size.height * 0.72, box.size.width * 0.26), weight: .ultraLight))
                            .foregroundStyle(tint)
                            .id(symbol)
                            .transition(.scale(scale: 0.94).combined(with: .opacity))
                    }
                    .animation(reduceMotion ? nil : .easeInOut(duration: 0.22), value: symbol)
                    .rotationEffect(.degrees(-12))
                    .opacity(scheme == .dark ? 0.21 : 0.15)
                    .padding(.trailing, box.size.width * 0.035)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
                }
            }
            .accessibilityHidden(true)
            .allowsHitTesting(false)
    }
}

struct HomeShowcaseInformation<Selector: View>: View {
    let book: LibraryBook
    let title: String
    let width: CGFloat
    let height: CGFloat
    let catalog: CatalogStore?
    let translates: Bool
    let localizer: AppLocalizer
    let progressTint: Color
    let readIdentifier: String
    let focus: FocusState<HomeShowcaseControl?>.Binding
    @Binding var tagPreview: LibraryBook.ID?
    let onSelect: (LibraryBook) -> Void
    var navigate: (KeyPress) -> KeyPress.Result = { _ in .ignored }
    @ViewBuilder var selector: () -> Selector

    @Environment(\.bookCardActions) private var actions
    @Environment(\.bookCardCatalog) private var cards
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.nyaehAccentColor) private var accent
    @Environment(\.self) private var environment
    @State private var hoveringRead = false
    @State private var position = ScrollPosition(edge: .top)

    var body: some View {
        let state = cards?.readingState(for: book)
        let reading = BookCardReadingStatus(state: state, openCount: book.readCount)
        VStack(alignment: .leading, spacing: 10) {
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: height < 340 ? 8 : 14) {
                    Button { onSelect(book) } label: {
                        Text(title)
                            .font(HomeShowcaseTypography.title(width: width))
                            .multilineTextAlignment(.leading).lineLimit(3)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .buttonStyle(.plain).focused(focus, equals: .title)
                    .showcaseKeys(navigate).help(title)

                    HomeShowcaseDetails(book: book, catalog: catalog, translates: translates,
                                        localizer: localizer, tagPreview: $tagPreview)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .showcaseFade(book.id, reduceMotion: reduceMotion)
            }
            .scrollBounceBehavior(.basedOnSize)
            .defaultScrollAnchor(.top, for: .alignment)
            .scrollPosition($position)

            HStack(alignment: .bottom, spacing: 10) {
                VStack(alignment: .leading, spacing: 6) {
                    if case let .reading(page, total) = reading {
                        CardPageProgress(current: page, total: total, showsNumber: true, size: .showcase, fillOpacity: 0.4)
                            .environment(\.nyaehAccentColor, progressTint)
                            .frame(maxWidth: 240)
                            .accessibilityLabel(localizer.string(.readerContinue))
                            .accessibilityValue(BookCardMetrics.progressLabel(page: page))
                            .animation(reduceMotion ? nil : .easeInOut(duration: 0.22), value: reading)
                    }
                    let controls = width < 660
                        ? AnyLayout(VStackLayout(alignment: .leading, spacing: 2))
                        : AnyLayout(HStackLayout(spacing: 6))
                    controls { readButton(state); readCount }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                selector()
            }
        }
        .onChange(of: book.id) { tagPreview = nil; position.scrollTo(edge: .top) }
    }

    private func readButton(_ state: BookReadingState?) -> some View {
        let active = hoveringRead || focus.wrappedValue == .reader
        let resolved = accent.resolve(in: environment)
        let darkInk = BookCardMetrics.prefersDarkInk(linearRed: resolved.linearRed, green: resolved.linearGreen,
                                                     blue: resolved.linearBlue)
        return Button { actions?.read(book) } label: {
            Label(localizer.string(BookDetailReadingActionPolicy.titleKey(for: state)), systemImage: "book")
                .font(HomeShowcaseTypography.reading).lineLimit(1)
                .padding(.horizontal, 9).padding(.vertical, 6)
                .foregroundStyle(active ? (darkInk ? Color.black : .white) : .primary)
                .background(accent.opacity(active ? 1 : 0.20), in: RoundedRectangle(cornerRadius: 7))
                .contentShape(Rectangle())
                .animation(reduceMotion ? nil : .easeInOut(duration: 0.16), value: active)
        }
        .buttonStyle(.plain).focused(focus, equals: .reader).showcaseKeys(navigate)
        .onHover { hoveringRead = $0 }
        .accessibilityIdentifier(readIdentifier)
    }

    @ViewBuilder private var readCount: some View {
        if book.readCount > 0 {
            Text(String(format: localizer.string(.cardTimesRead), book.readCount.formatted()))
                .font(HomeShowcaseTypography.reading).foregroundStyle(.secondary).lineLimit(1)
        }
    }
}

private struct HomeShowcaseDetails: View {
    let book: LibraryBook
    let catalog: CatalogStore?
    let translates: Bool
    let localizer: AppLocalizer
    @Binding var tagPreview: LibraryBook.ID?
    @State private var credits: HomeShowcaseResult<Request, [TagDisplaySummary]>?

    private struct Request: Equatable {
        let id: LibraryBook.ID
        let tags: String
        let revision: Int
        let translates: Bool
    }

    var body: some View {
        let request = Request(id: book.id, tags: book.tags, revision: catalog?.tagSummaryRevision ?? 0, translates: translates)
        let tags = credits?.value(for: request) ?? []
        let metadata = BookCardMetadata(book: book)
        VStack(alignment: .leading, spacing: 12) {
            creditsLine(tags, first: .artist, second: .group)
            creditsLine(tags, first: .parody, second: .character)
            SearchResultTagFlowLayout(spacing: 10, lineSpacing: 6) {
                if let rating = metadata.rating { BookCardRating(rating: rating, localizer: localizer, size: .showcase) }
                if let code = metadata.language {
                    let language = BookCardLanguageLabel(code, interfaceLanguage: localizer.language)
                    Text(language.abbreviation).fontWeight(.semibold)
                        .padding(.horizontal, 6).frame(height: 24)
                        .background(.secondary.opacity(0.13), in: RoundedRectangle(cornerRadius: 4))
                        .help(language.fullName).accessibilityLabel(language.fullName)
                }
                if metadata.isFullColor {
                    glyph("paintpalette", localizer.string(.fullColor))
                }
                if let censorship = metadata.censorship {
                    glyph(censorship == "uncensored" ? "eye" : "eye.slash", localizer.versionCensorshipDescription(censorship))
                }
                if let pages = metadata.pages { Text(localizer.bookPageCount(pages)).monospacedDigit().frame(height: 24) }
            }
            .font(HomeShowcaseTypography.metadata)
            let content = tags.filter {
                !["language", "artist", "group", "parody", "character"].contains($0.namespace)
                    && !BookDetailTagOrganizer.hiddenRawValues.contains($0.rawValue.lowercased())
            }
            let groups = Dictionary(grouping: content, by: \.namespace)
            ForEach(groups.keys.sorted(), id: \.self) { namespace in
                let members = groups[namespace] ?? []
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(searchTagNamespaceTitle(namespace, localizer: localizer))
                        .font(HomeShowcaseTypography.credit).foregroundStyle(.secondary)
                    HomeShowcaseTags(tags: members.filter(\.isFollowed) + members.filter { !$0.isFollowed },
                                     onPreview: { open in
                                         if open { tagPreview = book.id }
                                         else if tagPreview == book.id { tagPreview = nil }
                                     })
                }
            }
        }
        .task(id: request) {
            let tags = await catalog?.searchResultTags(for: book, isTagTranslationEnabled: translates) ?? []
            guard !Task.isCancelled else { return }
            credits = .init(key: request, value: tags)
        }
    }

    @ViewBuilder
    private func creditsLine(_ tags: [TagDisplaySummary], first: TagCategoryTab, second: TagCategoryTab) -> some View {
        let left = tags.filter { $0.namespace == first.namespace }.map(\.displayText).joined(separator: ", ")
        let right = tags.filter { $0.namespace == second.namespace }.map(\.displayText).joined(separator: ", ")
        if !left.isEmpty || !right.isEmpty {
            HStack(alignment: .firstTextBaseline, spacing: 7) {
                if !left.isEmpty { credit(left, category: first) }
                if !left.isEmpty && !right.isEmpty { Text("|").foregroundStyle(.tertiary).accessibilityHidden(true) }
                if !right.isEmpty { credit(right, category: second) }
            }
            .font(HomeShowcaseTypography.credit).foregroundStyle(.secondary)
        }
    }

    private func credit(_ text: String, category: TagCategoryTab) -> some View {
        let name = localizer.string(category.titleKey)
        return Label(text, systemImage: category.toolbarSystemImage)
            .labelStyle(.titleAndIcon)
            .help(name)
            .accessibilityLabel(Text(name + " " + text))
    }

    private func glyph(_ icon: String, _ description: String) -> some View {
        Image(systemName: icon).frame(height: 24).help(description).accessibilityLabel(description)
    }
}

private struct HomeShowcaseTags: View {
    let tags: [TagDisplaySummary]
    let onPreview: (Bool) -> Void
    @State private var showingAll = false
    @Environment(\.nyaehAccentColor) private var accent
    @FocusState private var moreFocused: Bool
    @State private var width: CGFloat = 0
    private let gap: CGFloat = 5

    private func chipWidth(_ text: String) -> CGFloat {
        ceil((text as NSString).size(withAttributes: [.font: HomeShowcaseTypography.tag]).width) + 12
    }

    var body: some View {
        let layout = HomeTagPreviewLayout(widths: tags.map { chipWidth($0.displayText) }, available: width,
                                          gap: gap, maximumRows: 1, moreWidth: { chipWidth("+\($0)") })
        VStack(alignment: .leading, spacing: 4) {
            ForEach(layout.rows.indices, id: \.self) { row in
                HStack(spacing: gap) {
                    ForEach(layout.rows[row], id: \.self) { index in
                        chip(tags[index].displayText, followed: tags[index].isFollowed)
                    }
                    if row == layout.rows.count - 1 && layout.hidden > 0 {
                        Button { showingAll = true } label: { chip("+\(layout.hidden)") }
                            .buttonStyle(.plain)
                            .focused($moreFocused)
                            .onHover { if $0 { showingAll = true } }
                            .onChange(of: moreFocused) { _, focused in if focused { showingAll = true } }
                            .popover(isPresented: $showingAll, arrowEdge: .bottom) {
                                ScrollView {
                                    SearchResultTagFlowLayout(spacing: gap, lineSpacing: 5, wrapsLongItems: true) {
                                        ForEach(tags) { tag in
                                            Text(tag.displayText).font(HomeShowcaseTypography.credit)
                                                .foregroundStyle(tag.isFollowed ? accent : Color.primary)
                                                .padding(.horizontal, 6).padding(.vertical, 3)
                                                .background(.secondary.opacity(0.10), in: RoundedRectangle(cornerRadius: 4))
                                        }
                                    }
                                    .padding(12)
                                }
                                .frame(width: 320)
                                .frame(maxHeight: 200)
                                .fixedSize(horizontal: false, vertical: true)
                                .onExitCommand { showingAll = false }
                            }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onChange(of: showingAll) { _, open in onPreview(open) }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
    }

    private func chip(_ text: String, followed: Bool = false) -> some View {
        Text(text).font(Font(HomeShowcaseTypography.tag))
            .lineLimit(1).foregroundStyle(followed ? accent : Color.secondary)
            .padding(.horizontal, 6).frame(height: 19)
            .background((followed ? accent : Color.secondary).opacity(0.10), in: RoundedRectangle(cornerRadius: 4))
            .frame(maxWidth: min(width, chipWidth(text)), alignment: .leading)
            .help(text)
    }
}
