import SwiftUI

enum HomeToolbarTint: PreferenceKey {
    static let defaultValue: Color? = nil

    static func reduce(value: inout Color?, nextValue: () -> Color?) {
        if let next = nextValue() { value = next }
    }
}

struct HomeBookShowcase: View {
    let books: HomeShowcaseBooks
    let catalog: CatalogStore
    let pageIsActive: Bool
    let titleMode: BookTitleDisplayMode
    let localizer: AppLocalizer
    let translatesTags: Bool
    let onSelect: (LibraryBook) -> Void

    @Environment(\.nyaehAccentColor) private var accent
    @Environment(\.appearsActive) private var windowActive
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @FocusState private var focus: HomeShowcaseControl?
    @State private var selected: HomeShowcaseSelection?
    @State private var hovering = false
    @State private var visible = false
    @State private var groupHover = HomeShowcaseHover()
    @State private var tagPreview: LibraryBook.ID?
    @State private var coverColor: HomeShowcaseResult<String, NSColor>?

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
        let path = book.coverPath
        let cached = path.flatMap { CoverThemeColorCache.shared.cachedColor(coverPath: $0) ?? coverColor?.value(for: $0) }
        let tint = cached.map { Color(nsColor: $0) } ?? accent
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
            .contextMenu {
                BookCardMenu(book: book, titleDisplayMode: titleMode, localizer: localizer,
                             selection: nil, beforeNavigation: nil, showDetail: onSelect)
            }

            HomeShowcaseInformation(book: book, title: title, width: width, height: height,
                                    catalog: catalog, translates: translatesTags, localizer: localizer,
                                    progressTint: tint, readIdentifier: "home.feature.read", focus: $focus,
                                    tagPreview: $tagPreview, onSelect: onSelect, navigate: navigate) {
                shelfSelector(selection, width: selectorWidth, height: height)
            }
            .padding(inset)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(width: width, height: height)
        .background {
            HomePanelBackground(tint: tint, symbol: selection.group.backgroundSymbol)
                .animation(reduceMotion ? nil : .easeInOut(duration: 0.22), value: tint)
        }
        .modifier(HomePanelSurface())
        .preference(key: HomeToolbarTint.self, value: tint)
        .task(id: path) {
            guard let path else { coverColor = nil; return }
            let cache = CoverThemeColorCache.shared
            if cache.cachedColor(coverPath: path) == nil { _ = await cache.resolveColor(coverPath: path) }
            guard !Task.isCancelled, let color = cache.cachedColor(coverPath: path) else { return }
            coverColor = .init(key: path, value: color)
        }
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
                            .font(HomeShowcaseTypography.selector)
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

extension View {
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
            .transformEnvironment(\.coverPrivacyRevealAllowed) { $0 = $0 && phase.isIdentity }
            .allowsHitTesting(phase.isIdentity)
            .accessibilityHidden(!phase.isIdentity)
    }
}
