import SwiftUI

struct HomeBookShowcase: View {
    let books: HomeShowcaseBooks
    let catalog: CatalogStore
    let pageIsActive: Bool
    let titleMode: BookTitleDisplayMode
    let localizer: AppLocalizer
    let translatesTags: Bool
    let onSelect: (LibraryBook) -> Void

    @Environment(\.bookCardActions) private var actions
    @Environment(\.nyaehAccentColor) private var accent
    @Environment(\.appearsActive) private var windowActive
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @FocusState private var focus: Control?
    @State private var selected: HomeShowcaseSelection?
    @State private var hovering = false
    @State private var visible = false
    @State private var groupHover = HomeShowcaseHover()
    @State private var tagPreview: LibraryBook.ID?
    @State private var scrollPosition = ScrollPosition(edge: .top)

    private enum Control: Hashable {
        case cover, title, reader, heading(HomeShowcaseGroup), thumbnail(HomeShowcaseSelection)
    }

    var body: some View {
        if let current = books.resolve(selected), let book = books.book(for: current) {
            let playback = HomeShowcasePlayback(selection: current, ids: books[current.group].map(\.id),
                                                visible: visible, active: windowActive && pageIsActive,
                                                interacting: hovering || focus != nil || tagPreview == book.id, reduceMotion: reduceMotion)
            GeometryReader { box in
                feature(book, selection: current, width: box.size.width, height: box.size.height)
            }
            .contentShape(Rectangle())
            .onHover { inside in
                hovering = inside
                if !inside { groupHover = HomeShowcaseHover() }
            }
            .onChange(of: current, initial: true) { _, new in selected = new }
            .onChange(of: focus) { _, new in
                groupHover = HomeShowcaseHover()
                switch new {
                case let .thumbnail(choice) where books.book(for: choice) != nil: selected = choice
                case let .heading(group) where group != current.group: selected = books.first(in: group)
                default: break
                }
            }
            .task(id: groupHover.pending) {
                guard let group = groupHover.pending else { return }
                do { try await Task.sleep(for: .milliseconds(100)) } catch { return }
                guard !Task.isCancelled, let live = books.resolve(selected),
                      let next = groupHover.selection(afterDwellingOn: group, in: books, current: live) else { return }
                selected = next
            }
            .onScrollVisibilityChange(threshold: 0.01) { visible = $0 }
            .onDisappear { visible = false; hovering = false; groupHover = HomeShowcaseHover() }
            .task(id: playback) {
                guard let playback else { return }
                do { try await Task.sleep(for: .seconds(6)) } catch { return }
                guard !Task.isCancelled else { return }
                selected = books.adjacent(to: playback.selection, offset: 1)
            }
        }
    }

    private func feature(_ book: LibraryBook, selection: HomeShowcaseSelection, width: CGFloat, height: CGFloat) -> some View {
        let inset: CGFloat = width < 800 ? 14 : 24
        let coverWidth = min(width * 0.30, height * 0.77)
        let title = BookTitleFormatter.displayTitle(for: book, mode: titleMode)
        let state = catalog.readingState(for: book)
        let reading = BookCardReadingStatus(state: state, openCount: book.readCount)
        let controlsWidth = max(1, width - coverWidth - inset * 2)
        let selectorWidth = min(310, controlsWidth * 0.59)
        return HStack(spacing: 0) {
            Button { onSelect(book) } label: {
                BookCoverThumbnail(book: book, width: coverWidth, height: height, cornerRadius: 0,
                                   fitsEntireImage: true, showsFitBackground: false)
                    .showcaseFade(book.id, reduceMotion: reduceMotion)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .focused($focus, equals: .cover)
            .showcaseKeys(navigate)
            .accessibilityLabel(title)

            VStack(alignment: .leading, spacing: 12) {
                ScrollView(.vertical) {
                    VStack(alignment: .leading, spacing: height < 340 ? 8 : 14) {
                        Button {
                            if let current = books.resolve(selected), let target = books.book(for: current) { onSelect(target) }
                        } label: {
                            Text(title)
                                .font(.system(size: min(36, max(28, width / 19)), weight: .bold))
                                .multilineTextAlignment(.leading)
                                .lineLimit(3)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .buttonStyle(.plain)
                        .focused($focus, equals: .title)
                        .showcaseKeys(navigate)
                        .accessibilityLabel(title)
                        .help(title)

                        HomeShowcaseDetails(book: book, catalog: catalog, translates: translatesTags, localizer: localizer,
                                            tagPreview: $tagPreview)
                    }
                    .showcaseFade(book.id, reduceMotion: reduceMotion)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .scrollBounceBehavior(.basedOnSize)
                .defaultScrollAnchor(.top, for: .alignment)
                .scrollPosition($scrollPosition)

                HStack(alignment: .bottom, spacing: 12) {
                    VStack(alignment: .leading, spacing: 8) {
                        BookCardReadingRow(reading: reading, fields: .reading, localizer: localizer, size: .showcase)
                            .frame(maxWidth: 240, minHeight: 24, maxHeight: 24, alignment: .leading)
                            .animation(reduceMotion ? nil : .easeInOut(duration: 0.22), value: reading)
                        Button { actions?.read(book) } label: {
                            Label(localizer.string(BookDetailReadingActionPolicy.titleKey(for: state)), systemImage: "book")
                                .lineLimit(1)
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                        .tint(accent)
                        .focused($focus, equals: .reader)
                        .showcaseKeys(navigate)
                        .accessibilityIdentifier("home.feature.read")
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    shelfSelector(selection, width: selectorWidth, height: height)
                }
            }
            .padding(inset)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(width: width, height: height)
        .background {
            HomeShowcaseBackground(path: book.coverPath)
        }
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .onChange(of: book.id) { tagPreview = nil; scrollPosition.scrollTo(edge: .top) }
    }

    private func shelfSelector(_ current: HomeShowcaseSelection, width: CGFloat, height: CGFloat) -> some View {
        let gap: CGFloat = width < 225 ? 4 : 6
        let thumbWidth = min((width - 4 * gap) / 5, height < 340 ? 35 : 48)
        return VStack(alignment: .trailing, spacing: 6) {
            HStack(spacing: gap) {
                ForEach(HomeShowcaseGroup.allCases, id: \.self) { group in
                    Button {
                        if group != current.group { selected = books.first(in: group) }
                    } label: {
                        Text(localizer.string(group.title))
                            .font(.caption.weight(.medium))
                            .lineLimit(1).minimumScaleFactor(0.75)
                            .foregroundStyle(group == current.group ? .primary : .secondary)
                            .padding(.vertical, 4)
                            .overlay(alignment: .bottom) {
                                Rectangle().fill(group == current.group ? accent : .clear).frame(height: 2)
                            }
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(books[group].isEmpty)
                    .focused($focus, equals: .heading(group))
                    .showcaseKeys(navigate)
                    .onHover { groupHover.hover(group, inside: $0 && !books[group].isEmpty) }
                    .accessibilityAddTraits(group == current.group ? .isSelected : [])
                }
            }
            HStack(spacing: gap) {
                ForEach(books[current.group]) { book in
                    let choice = HomeShowcaseSelection(group: current.group, id: book.id)
                    Button { selected = choice } label: {
                        BookCoverThumbnail(book: book, width: thumbWidth, height: thumbWidth / 0.74,
                                           cornerRadius: 4, fitsEntireImage: true)
                            .clipShape(RoundedRectangle(cornerRadius: 4))
                            .overlay {
                                RoundedRectangle(cornerRadius: 4)
                                    .strokeBorder(choice == current ? accent : .clear, lineWidth: 2)
                            }
                    }
                    .buttonStyle(.plain)
                    .focused($focus, equals: .thumbnail(choice))
                    .showcaseKeys(navigate)
                    .onHover { inside in
                        if inside {
                            groupHover = HomeShowcaseHover()
                            selected = choice
                        }
                    }
                    .accessibilityLabel(BookTitleFormatter.displayTitle(for: book, mode: titleMode))
                    .accessibilityAddTraits(choice == current ? .isSelected : [])
                }
            }
        }
        .frame(width: width, alignment: .trailing)
    }

    private func navigate(_ key: KeyPress) -> KeyPress.Result {
        guard let focused = focus, var current = books.resolve(selected) else { return .ignored }
        if key.key == .escape { focus = .cover; return .handled }
        if case let .heading(group) = focused, group != current.group, let first = books.first(in: group) {
            current = first
        }
        let next: HomeShowcaseSelection
        switch key.key {
        case .leftArrow, .rightArrow:
            next = books.adjacent(to: current, offset: key.key == .leftArrow ? -1 : 1)
        case .upArrow, .downArrow:
            next = books.changingRow(from: current, offset: key.key == .upArrow ? -1 : 1)
        default: return .ignored
        }
        selected = next
        switch focused {
        case .heading, .thumbnail: focus = .thumbnail(next)
        case .title: focus = .cover
        default: break
        }
        return .handled
    }
}

private extension View {
    func showcaseKeys(_ handle: @escaping (KeyPress) -> KeyPress.Result) -> some View {
        onKeyPress(keys: [.leftArrow, .rightArrow, .upArrow, .downArrow, .escape], phases: .down, action: handle)
    }

}

extension View {
    func showcaseFade(_ id: LibraryBook.ID, reduceMotion: Bool) -> some View {
        ZStack(alignment: .topLeading) { self.id(id).transition(ShowcaseDissolve()) }
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.22), value: id)
    }
}

private struct ShowcaseDissolve: Transition {
    func body(content: Content, phase: TransitionPhase) -> some View {
        content.opacity(phase.isIdentity ? 1 : 0)
            .allowsHitTesting(phase.isIdentity)
            .accessibilityHidden(!phase.isIdentity)
    }
}

private struct HomeShowcaseBackground: View {
    let path: String?
    @Environment(\.colorScheme) private var scheme
    @Environment(\.nyaehAccentColor) private var accent
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var lastColor: NSColor?

    var body: some View {
        let cached = path.flatMap { CoverThemeColorCache.shared.cachedColor(coverPath: $0) ?? lastColor }
        let tint = cached.map { Color(nsColor: $0) } ?? accent
        Color(nsColor: .windowBackgroundColor)
            .overlay {
                LinearGradient(colors: [tint.opacity(scheme == .dark ? 0.56 : 0.46), tint.opacity(0.16), tint.opacity(0.07)],
                               startPoint: .leading, endPoint: .trailing)
            }
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.22), value: tint)
            .task(id: path) {
                let cache = CoverThemeColorCache.shared
                guard let path else { lastColor = nil; return }
                if cache.cachedColor(coverPath: path) == nil { _ = await cache.resolveColor(coverPath: path) }
                guard !Task.isCancelled else { return }
                lastColor = cache.cachedColor(coverPath: path)
            }
    }
}

private struct HomeShowcaseDetails: View {
    let book: LibraryBook
    let catalog: CatalogStore
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
        let request = Request(id: book.id, tags: book.tags, revision: catalog.tagSummaryRevision, translates: translates)
        let tags = credits?.value(for: request) ?? []
        let metadata = BookCardMetadata(book: book)
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                credit("person", .tagNamespaceArtist, tags.filter { $0.namespace == "artist" }.map(\.displayText))
                credit("person.2", .tagNamespaceGroup, tags.filter { $0.namespace == "group" }.map(\.displayText))
                if let id = book.collectionID, let name = catalog.collection(id: String(id))?.name {
                    credit("books.vertical", .series, [name])
                }
            }

            SearchResultTagFlowLayout(spacing: 10, lineSpacing: 6) {
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
                if let rating = metadata.rating { BookCardRating(rating: rating, localizer: localizer, size: .showcase) }
            }
            .font(.callout)
            let content = tags.filter { !["language", "artist", "group"].contains($0.namespace) }
            if !content.isEmpty {
                HomeShowcaseTags(tags: content, showingAll: Binding(
                    get: { tagPreview == book.id },
                    set: { open in
                        if open { tagPreview = book.id }
                        else if tagPreview == book.id { tagPreview = nil }
                    }
                ))
            }
        }
        .task(id: request) {
            let tags = await catalog.searchResultTags(for: book, isTagTranslationEnabled: translates)
            guard !Task.isCancelled else { return }
            credits = .init(key: request, value: tags)
        }
    }

    @ViewBuilder
    private func credit(_ icon: String, _ key: L10nKey, _ names: [String]) -> some View {
        if !names.isEmpty {
            let text = names.joined(separator: ", ")
            Label(text, systemImage: icon).font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .help(localizer.string(key)).accessibilityLabel("\(localizer.string(key)) \(text)")
        }
    }

    private func glyph(_ icon: String, _ description: String) -> some View {
        Image(systemName: icon).frame(height: 24).help(description).accessibilityLabel(description)
    }
}

private struct HomeShowcaseTags: View {
    let tags: [TagDisplaySummary]
    @Binding var showingAll: Bool
    @FocusState private var moreFocused: Bool
    @State private var width: CGFloat = 0
    private let gap: CGFloat = 5
    private let fontSize: CGFloat = 11

    private func chipWidth(_ text: String) -> CGFloat {
        ceil((text as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: fontSize)]).width) + 12
    }

    var body: some View {
        let layout = HomeTagPreviewLayout(widths: tags.map { chipWidth($0.displayText) }, available: width,
                                          gap: gap, moreWidth: { chipWidth("+\($0)") })
        VStack(alignment: .leading, spacing: 4) {
            ForEach(layout.rows.indices, id: \.self) { row in
                HStack(spacing: gap) {
                    ForEach(layout.rows[row], id: \.self) { index in
                        chip(tags[index].displayText)
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
                                            Text(tag.displayText).font(.callout)
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
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
    }

    private func chip(_ text: String) -> some View {
        Text(text).font(.system(size: fontSize))
            .lineLimit(1).foregroundStyle(.secondary)
            .padding(.horizontal, 6).frame(height: 19)
            .background(.secondary.opacity(0.10), in: RoundedRectangle(cornerRadius: 4))
            .frame(maxWidth: min(width, chipWidth(text)), alignment: .leading)
            .help(text)
    }
}
