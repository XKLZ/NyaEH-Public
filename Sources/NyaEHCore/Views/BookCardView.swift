// 本文件实现书籍卡片的封面、标题和状态摘要，是多个列表页面共用的展示单元。

import SwiftUI

struct BookCardSelection {
    let isSelected: Bool
    let toggle: () -> Void
}

@MainActor protocol BookCardLibrary: AnyObject, Sendable {
    func book(id: LibraryBook.ID) -> LibraryBook?
    func setCardCompleted(_ completed: Bool, book: LibraryBook)
    func bookForCard(_ book: LibraryBook) -> LibraryBook
    func cardVersionAlternatives(to book: LibraryBook, showsUserHidden: Bool) -> [LibraryBook]
    func readingState(for book: LibraryBook) -> BookReadingState?
    func setCardMarked(_ marked: Bool, book: LibraryBook)
    func setPrimaryVersion(_ book: LibraryBook, completion: ((String?) -> Void)?)
}

@MainActor protocol BookCardInteraction: AnyObject, Sendable {
    func read(_ book: LibraryBook)
    func showNotice(_ message: String)
}

extension EnvironmentValues {
    @Entry var bookCardActions: (any BookCardInteraction)? = nil
    @Entry var bookCardCatalog: (any BookCardLibrary)? = nil
    @Entry var bookCardFields: BookCardFields = .all
    @Entry var bookCardsShowUserHidden = false
    @Entry var bookCardAggregatesVersions = true
}

enum BookCardControl: Hashable {
    case book, favorite, reader, metadata
}

struct BookCardView: View {
    let book: LibraryBook
    let titleDisplayMode: BookTitleDisplayMode
    let localizer: AppLocalizer
    var metrics: BookCardMetrics = .default
    var showsUnobstructedCover = false
    var selection: BookCardSelection?
    var collectionFocus: FocusState<SearchCollectionPopoverFocus?>.Binding?
    var beforeGroupNavigation: (() -> Void)?
    let action: (LibraryBook) -> Void

    @Environment(\.bookCardCatalog) private var catalog
    @Environment(\.bookCardFields) private var fields
    @Environment(\.bookCardsShowUserHidden) private var showsUserHidden
    @Environment(\.bookCardActions) private var actions
    @Environment(\.bookCardAggregatesVersions) private var aggregatesVersions
    @Environment(\.isBookCardHovered) private var isHovered
    @State private var deckOpenRequest = 0
    @FocusState private var focus: BookCardControl?

    private var revealsActions: Bool {
        isHovered || focus != nil || collectionFocus?.wrappedValue?.memberID == book.id
    }

    var body: some View {
        let current = catalog?.bookForCard(book) ?? book
        let metadata = BookCardMetadata(book: current)
        let reading = BookCardReadingStatus(state: catalog?.readingState(for: current), openCount: current.readCount)
        let alternatives = catalog?.cardVersionAlternatives(to: current, showsUserHidden: showsUserHidden) ?? []
        let stack = BookCardEditionStack(current: current, visibleAlternatives: alternatives, aggregatesVersions: aggregatesVersions)
        let showsStack = stack.depth > 1 && !fields.isDisjoint(with: .metadata)
        let bestRating = fields.contains(.rating) ? stack.highestRating : nil
        let ratingSource = bestRating.flatMap { source -> String? in
            guard stack.depth > 1 else { return nil }
            return stack.versionDescription(at: stack.index(for: source.id), titleDisplayMode: titleDisplayMode)
        }
        let button = Button { action(current) } label: {
            BookCardFace(
                book: current, titleDisplayMode: titleDisplayMode, language: localizer.language,
                metadata: metadata, reading: reading, metrics: metrics, fields: fields,
                showsUnobstructedCover: showsUnobstructedCover, showsStack: showsStack,
                rating: bestRating?.rating, ratingSource: ratingSource
            )
            .equatable()
        }
        .buttonStyle(.plain)
        .onKeyPress(.tab, phases: .down) { press in
            guard showsStack, press.modifiers.isEmpty else { return .ignored }
            guard collectionFocus == nil else { return .ignored }
            focus = .metadata
            return .handled
        }
        .onKeyPress("v") {
            guard showsStack else { return .ignored }
            deckOpenRequest += 1
            return .handled
        }
        .contentShape(Rectangle())
        let face = Group {
            if let collectionFocus {
                button.focused(collectionFocus, equals: .member(book.id))
            } else {
                button.focused($focus, equals: .book)
            }
        }

        return ZStack(alignment: .top) {
            if let selection {
                face.searchBatchSelection(
                    isSelected: selection.isSelected, localizer: localizer,
                    commandClickHeight: metrics.coverHeight + metrics.contentSpacing + metrics.regularTitleHeight, onToggle: selection.toggle
                )
            } else {
                face
            }
            if current.mark || (catalog != nil && revealsActions) {
                favoriteButton(for: current)
                    .frame(width: metrics.cardWidth, alignment: .trailing)
            }
            if showsStack {
                BookCardMetadataStack(stack: stack, fields: fields, metrics: metrics,
                                      titleDisplayMode: titleDisplayMode, localizer: localizer,
                                      focus: $focus, collectionFocus: collectionFocus, openRequest: deckOpenRequest)
                    .id(current.id)
                    .offset(y: metrics.metadataTop)
            }
            if fields.contains(.directRead) {
                let reader = Button { actions?.read(current) } label: {
                    CardReadButtonLabel(width: metrics.readButtonWidth, height: metrics.footerHeight(for: fields),
                                        focused: focus == .reader || collectionFocus?.wrappedValue == .reader(current.id))
                }
                .buttonStyle(.plain)
                .help(localizer.string(.cardDirectRead))
                .accessibilityLabel(localizer.string(.cardDirectRead))
                .onKeyPress(.return) { actions?.read(current); return .handled }
                Group {
                    if let collectionFocus { reader.focused(collectionFocus, equals: .reader(current.id)) }
                    else { reader.focused($focus, equals: .reader) }
                }
                .frame(width: metrics.contentWidth, alignment: .trailing)
                .offset(y: metrics.cardHeight(for: fields) - metrics.bottomInset - metrics.footerHeight(for: fields))
            }
        }
        .contextMenu {
            BookCardMenu(book: current, titleDisplayMode: titleDisplayMode, localizer: localizer,
                         selection: selection, beforeNavigation: beforeGroupNavigation, showDetail: action)
        }
    }

    private func favoriteButton(for book: LibraryBook) -> some View {
        Button {
            catalog?.setCardMarked(!book.mark, book: book)
        } label: {
            Image(systemName: book.mark ? "heart.fill" : "heart")
                .foregroundStyle(book.mark ? Color.red : Color.primary)
                .font(.system(size: 13, weight: .semibold))
                .frame(width: 27, height: 26)
                .background(.regularMaterial, in: UnevenRoundedRectangle(
                    bottomLeadingRadius: 10, topTrailingRadius: showsUnobstructedCover ? 0 : 8
                ))
        }
        .buttonStyle(.plain)
        .allowsHitTesting(catalog != nil)
        .disabled(catalog == nil)
        .focused($focus, equals: .favorite)
        .help(localizer.string(book.mark ? .markedStatus : .toggleMarked))
        .accessibilityLabel(localizer.string(.toggleMarked))
        .accessibilityValue(book.mark ? localizer.string(.markedStatus) : "")
    }

}

struct CardReadButtonLabel: View {
    let width: CGFloat
    let height: CGFloat
    let focused: Bool
    @Environment(\.nyaehAccentColor) private var accent
    @State private var hovered = false

    var body: some View {
        let highlighted = hovered || focused
        let border = RoundedRectangle(cornerRadius: BookCardMetrics.detailCornerRadius)
        Image(systemName: "book")
            .font(.system(size: 14, weight: .medium))
            .foregroundStyle(highlighted ? accent : .primary)
            .frame(width: width, height: height)
            .background(highlighted ? accent.opacity(0.12) : .clear, in: border)
            .overlay { border.strokeBorder(highlighted ? accent : .secondary.opacity(0.48)) }
            .contentShape(Rectangle())
            .onHover { hovered = $0 }
    }
}

private struct BookCardFace: View, Equatable {
    let book: LibraryBook
    let titleDisplayMode: BookTitleDisplayMode
    let language: AppLanguage
    let metadata: BookCardMetadata
    let reading: BookCardReadingStatus
    let metrics: BookCardMetrics
    let fields: BookCardFields
    let showsUnobstructedCover: Bool
    let showsStack: Bool
    let rating: Double?
    let ratingSource: String?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.isBookCardHovered) private var isHovered

    @Environment(\.colorScheme) private var colorScheme

    private var localizer: AppLocalizer { AppLocalizer(language: language) }

    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.book == rhs.book && lhs.titleDisplayMode == rhs.titleDisplayMode && lhs.language == rhs.language
            && lhs.metadata == rhs.metadata && lhs.reading == rhs.reading && lhs.metrics == rhs.metrics
            && lhs.fields == rhs.fields && lhs.showsUnobstructedCover == rhs.showsUnobstructedCover
            && lhs.showsStack == rhs.showsStack && lhs.rating == rhs.rating && lhs.ratingSource == rhs.ratingSource
    }

    var body: some View {
        if metrics.appearance == .unified {
            let outline = RoundedRectangle(cornerRadius: 8)
            content
                .background(Color.primary.opacity(colorScheme == .dark ? 0.07 : 0.035))
                .clipShape(outline)
                .overlay { outline.strokeBorder(.primary.opacity(0.13), lineWidth: 0.75).allowsHitTesting(false) }
        } else {
            content
        }
    }

    private var content: some View {
        VStack(spacing: metrics.contentSpacing) {
            BookCoverThumbnail(book: book, width: metrics.cardWidth, height: metrics.coverHeight,
                               cornerRadius: metrics.appearance == .unified ? 0 : 8,
                               fitsEntireImage: showsUnobstructedCover)
                .scaleEffect(showsUnobstructedCover ? 1 :
                    BookCardHoverVisualState.resolve(isHovered: isHovered, reduceMotion: reduceMotion).coverScale)
                .frame(width: metrics.cardWidth, height: metrics.coverHeight)
                .clipShape(RoundedRectangle(cornerRadius: showsUnobstructedCover || metrics.appearance == .unified ? 0 : 8))

            BookCardTitleView(title: BookTitleFormatter.displayTitle(for: book, mode: titleDisplayMode), metrics: metrics)

            if !fields.isEmpty {
                VStack(spacing: metrics.infoSpacing) {
                    if !fields.isDisjoint(with: .metadata) {
                        Group {
                            if showsStack { Color.clear }
                            else { BookCardMetadataRow(metadata: metadata, fields: fields, localizer: localizer, metrics: metrics) }
                        }
                        .frame(height: metrics.metadataHeight)
                    }
                    if metrics.showsRatingRow(for: fields) {
                        Group {
                            if let rating {
                                BookCardRating(rating: rating, localizer: localizer, sourceTitle: ratingSource)
                            } else { Color.clear }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .frame(height: metrics.ratingHeight)
                    }
                    if !fields.isDisjoint(with: .reading) {
                        BookCardReadingRow(reading: reading, fields: fields, localizer: localizer)
                            .padding(.trailing, fields.contains(.directRead) ? metrics.readButtonWidth + metrics.readButtonGap : 0)
                            .frame(maxWidth: .infinity)
                            .frame(height: metrics.infoRowHeight)
                    }
                }
                .frame(width: metrics.contentWidth)
            }
        }
        .frame(width: metrics.cardWidth, height: metrics.cardHeight(for: fields), alignment: .top)
        .contentShape(Rectangle())
    }
}

struct BookCardTitleView: View {
    let title: String
    let metrics: BookCardMetrics

    @Environment(\.isBookCardHovered) private var isHovered
    @State private var isTruncated = false

    var body: some View {
        Text(title)
            .font(.callout.weight(.medium))
            .multilineTextAlignment(metrics.appearance == .unified ? .leading : .center)
            .lineLimit(2, reservesSpace: metrics.appearance == .standard)
            .truncationMode(.tail)
            .frame(width: metrics.contentWidth, height: metrics.regularTitleHeight,
                   alignment: metrics.appearance == .unified ? .leading : .top)
            .help(isTruncated ? title : "")
            .overlay {
                if isHovered {
                    Text(title)
                        .font(.callout.weight(.medium))
                        .lineLimit(nil)
                        .frame(width: metrics.contentWidth)
                        .fixedSize(horizontal: false, vertical: true)
                        .onGeometryChange(for: Bool.self) { geometry in
                            geometry.size.height > metrics.regularTitleHeight
                        } action: { isTruncated = $0 }
                        .hidden()
                        .accessibilityHidden(true)
                }
            }
    }
}

private extension BookCardEditionStack {
    func versionDescription(at index: Int, titleDisplayMode: BookTitleDisplayMode) -> String {
        let book = editions[index]
        let title = BookTitleFormatter.displayTitle(for: book, mode: titleDisplayMode)
        let labels = VersionLabelFormatter.labels(from: book.versionLabel)
        let position = (index + 1).formatted() + "/" + editions.count.formatted()
        return ([title] + labels + [position]).joined(separator: " · ")
    }
}

struct BookCardMetadataStack: View {
    let stack: BookCardEditionStack
    let fields: BookCardFields
    let metrics: BookCardMetrics
    let titleDisplayMode: BookTitleDisplayMode
    let localizer: AppLocalizer
    let focus: FocusState<BookCardControl?>.Binding
    let collectionFocus: FocusState<SearchCollectionPopoverFocus?>.Binding?
    let openRequest: Int

    @Environment(\.bookCardCatalog) private var catalog
    @Environment(\.bookCardActions) private var actions
    @Environment(\.searchScrollActivity) private var scrollActivity
    @State private var session: EditionDeckSession?
    @State private var anchorHovered = false

    var body: some View {
        let current = stack.editions[0]
        let button = Button { showFromKeyboard() } label: {
            ZStack(alignment: .bottom) {
                ForEach((1..<stack.depth).reversed(), id: \.self) { layer in
                    RoundedRectangle(cornerRadius: BookCardMetrics.detailCornerRadius)
                        .strokeBorder(.secondary.opacity(0.46))
                        .mask(alignment: .top) { Rectangle().frame(height: 2) }
                        .padding(.horizontal, CGFloat(layer) * 3)
                        .offset(y: CGFloat(-layer) * 2)
                }
                BookCardMetadataRow(metadata: BookCardMetadata(book: current), fields: fields, localizer: localizer, metrics: metrics)
            }
                .opacity(session?.isPresented == true ? 0 : 1)
                .frame(width: metrics.contentWidth, height: metrics.metadataHeight, alignment: .bottom)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onKeyPress(.return) { showFromKeyboard(); return .handled }
        .onKeyPress("v") { showFromKeyboard(); return .handled }
        .onChange(of: openRequest) { showFromKeyboard() }
        .accessibilityLabel(localizer.string(.versions))
        .help(localizer.string(.setPrimaryVersion))
        .onHover { inside in
            anchorHovered = inside
            session?.hover(inside, panel: false)
        }
        .task(id: anchorHovered) {
            guard anchorHovered, session?.isPresented != true, !scrollActivity.isScrolling else { return }
            try? await Task.sleep(for: .milliseconds(180))
            if !Task.isCancelled && !scrollActivity.isScrolling && session?.isPresented != true {
                session = EditionDeckSession(keyboard: false, anchorHovered: true)
            }
        }
        .anchorPreference(key: EditionDeckPreference.self, value: .bounds) { anchor in
            guard let session, session.isPresented else { return nil }
            return EditionDeckRequest(session: session, bounds: anchor, count: stack.editions.count,
                                      cards: { [stack, titleDisplayMode, localizer, catalog, actions, metrics] layout in AnyView(EditionDeckCards(stack: stack, session: session,
                                          layout: layout, metrics: metrics, titleDisplayMode: titleDisplayMode, localizer: localizer,
                                          catalog: catalog, actions: actions)) })
        }
        .onChange(of: session?.isPresented) { _, presented in
            if presented == false { session = nil }
        }
        .background {
            if let session, session.isPresented {
                Color.clear.onScrollVisibilityChange(threshold: 0.01) { visible in
                    if !visible { session.sourceLeft() }
                }
            }
        }
        .onDisappear { session?.sourceLeft() }
        if let collectionFocus {
            button.focused(collectionFocus, equals: .metadata(current.id))
        } else {
            button.focused(focus, equals: .metadata)
        }
    }

    private func showFromKeyboard() {
        if let session, session.isPresented {
            session.openFromKeyboard()
        } else {
            session = EditionDeckSession(keyboard: true, anchorHovered: anchorHovered)
        }
    }
}

private struct EditionDeckCards: View {
    let stack: BookCardEditionStack
    let session: EditionDeckSession
    let layout: EditionDeckPlacement
    let metrics: BookCardMetrics
    @Environment(\.nyaehAccentColor) private var accent
    let titleDisplayMode: BookTitleDisplayMode
    let localizer: AppLocalizer
    let catalog: (any BookCardLibrary)?
    let actions: (any BookCardInteraction)?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @FocusState private var focused: Bool
    @State private var selectedEdition: LibraryBook.ID?
    @State private var scrollTop: CGFloat?
    @State private var spread: CGFloat = 0

    private func editionTitle(_ book: LibraryBook) -> String {
        let labels = VersionLabelFormatter.labels(from: book.versionLabel)
        if !labels.isEmpty && stack.editions.allSatisfy({
            $0.id == book.id || VersionLabelFormatter.labels(from: $0.versionLabel) != labels
        }) { return labels.joined(separator: " · ") }
        return BookTitleFormatter.displayTitle(for: book, mode: titleDisplayMode)
    }

    private func choose(_ book: LibraryBook, title: String) {
        guard session.canSelect else { return }
        guard !book.isPrimaryVersion else { session.dismiss(); return }
        guard let catalog else { return }
        session.beginSave()
        catalog.setPrimaryVersion(book) { error in
            session.finishSave(succeeded: error == nil)
            actions?.showNotice(error ?? String(format: localizer.string(.cardPrimaryChanged), title))
        }
    }

    private func handleKey(_ key: KeyEquivalent) -> KeyPress.Result {
        let index = stack.index(for: selectedEdition)
        switch key {
        case .downArrow, .upArrow:
            guard session.canSelect else { return .handled }
            session.openFromKeyboard()
            let forward = (key == .upArrow) == layout.growsUp
            selectedEdition = stack.editions[min(max(index + (forward ? 1 : -1), 0), stack.editions.count - 1)].id
        case .return:
            let edition = stack.editions[index]
            choose(edition, title: editionTitle(edition))
        case .escape: session.dismiss()
        case .tab: session.dismiss(); return .ignored
        default: return .ignored
        }
        return .handled
    }

    var body: some View {
        let motion = EditionDeckMotion(layout: layout, count: stack.editions.count, scrollTop: scrollTop)
        let indices = layout.growsUp ? Array(stack.editions.indices.reversed()) : Array(stack.editions.indices)
        let tiles = VStack(spacing: EditionDeckPlacement.gap) {
            ForEach(indices, id: \.self) { index in
                let edition = stack.editions[index]
                let title = editionTitle(edition)
                let highlighted = session.keyboard && (selectedEdition ?? stack.editions[0].id) == edition.id
                EditionDeal(index: index, motion: motion,
                            progress: reduceMotion || !motion.visible.contains(index) ? 1 : spread) { amount in
                    Button { choose(edition, title: title) } label: {
                        VStack(spacing: amount) {
                            BookCardMetadataRow(metadata: BookCardMetadata(book: edition), fields: .metadata,
                                                localizer: localizer, metrics: metrics, bordered: false)
                            HStack(spacing: 2) {
                                Text(title).lineLimit(1)
                                Spacer(minLength: 0)
                                if edition.isPrimaryVersion {
                                    Label(localizer.string(.primaryVersion), systemImage: "checkmark")
                                        .foregroundStyle(.tint).fixedSize()
                                }
                            }
                            .font(.system(size: 10))
                            .padding(.horizontal, 5)
                            .frame(height: 16 * amount)
                            .clipped()
                            .opacity(amount)
                        }
                        .frame(height: motion.restingHeight + (EditionDeckPlacement.tileHeight - motion.restingHeight) * amount)
                        .background {
                            RoundedRectangle(cornerRadius: BookCardMetrics.detailCornerRadius)
                                .fill(.regularMaterial).opacity(amount)
                        }
                        .overlay {
                            RoundedRectangle(cornerRadius: BookCardMetrics.detailCornerRadius)
                                .strokeBorder(highlighted ? accent : .secondary.opacity(0.5))
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .focusable(false)
                    .accessibilityAddTraits(highlighted ? [.isSelected] : [])
                    .accessibilityLabel([stack.versionDescription(at: index, titleDisplayMode: titleDisplayMode),
                                         edition.isPrimaryVersion ? localizer.string(.primaryVersion) : nil]
                                        .compactMap { $0 }.joined(separator: " · "))
                    .accessibilityValue(BookCardMetadataRow(metadata: BookCardMetadata(book: edition), fields: .metadata,
                                                            localizer: localizer).descriptions.joined(separator: ", "))
                    .help(title)
                }
                .id(edition.id)
                .zIndex(Double(stack.editions.count - index))
            }
        }
        return Group {
            if layout.needsScroll {
                ScrollViewReader { proxy in
                    ScrollView { tiles }
                        .scrollIndicators(.hidden)
                        .defaultScrollAnchor(layout.growsUp ? .bottom : .top)
                        .scrollDisabled(session.phase != .open)
                        .onScrollGeometryChange(for: CGFloat.self) { $0.visibleRect.minY } action: { _, top in scrollTop = top }
                        .onChange(of: selectedEdition) { _, id in
                            if let id { proxy.scrollTo(id) }
                        }
                }
            } else { tiles }
        }
        .frame(width: layout.frame.width, height: layout.frame.height)
        .contentShape(Rectangle())
        .onHover { session.hover($0, panel: true) }
        .focusable()
        .focusEffectDisabled()
        .focused($focused)
        .onKeyPress(keys: [.upArrow, .downArrow, .return, .escape, .tab], phases: [.down, .repeat]) {
            handleKey($0.key)
        }
        .onExitCommand { session.dismiss() }
        .onAppear { focused = true }
        .onChange(of: session.phase, initial: true) { _, phase in
            guard phase != .finished else { return }
            let closing = phase == .closing
            let revision = session.revision
            withAnimation(reduceMotion ? nil : .linear(duration: motion.duration), completionCriteria: .removed) {
                spread = closing ? 0 : 1
            } completion: {
                if closing { session.finishRetraction(revision: revision) }
            }
        }
    }
}

private struct EditionDeal<Content: View>: View, Animatable {
    let index: Int
    let motion: EditionDeckMotion
    nonisolated var progress: CGFloat
    @ViewBuilder let tile: (CGFloat) -> Content
    nonisolated var animatableData: CGFloat {
        get { progress }
        set { progress = newValue }
    }

    var body: some View {
        let amount = motion.amount(for: index, progress: progress)
        let remaining = 1 - amount
        let layer = CGFloat(min(index, 2))
        tile(amount)
            .mask(alignment: .top) {
                if index == 0 { Rectangle() }
                else {
                    GeometryReader { proxy in
                        Rectangle().frame(height: 2 + (proxy.size.height - 2) * amount)
                    }
                }
            }
            .padding(.horizontal, 3 * layer * remaining)
            .frame(height: EditionDeckPlacement.tileHeight, alignment: .bottom)
            .offset(y: (motion.returnOffset(for: index) - 2 * layer) * remaining)
    }
}

struct BookCardMetadataRow: View {
    let metadata: BookCardMetadata
    let fields: BookCardFields
    let localizer: AppLocalizer

    var metrics: BookCardMetrics = .default
    var bordered = true

    private var language: BookCardLanguageLabel? {
        metadata.language.map { BookCardLanguageLabel($0, interfaceLanguage: localizer.language) }
    }

    var descriptions: [String] {
        [
            fields.contains(.language) ? language?.fullName : nil,
            fields.contains(.color) && metadata.isFullColor ? localizer.string(.fullColor) : nil,
            fields.contains(.censorship) ? metadata.censorship.map(localizer.versionCensorshipDescription) : nil,
            fields.contains(.pages) ? metadata.pages.map(localizer.bookPageCount) : nil
        ].compactMap { $0 }
    }

    var body: some View {
        HStack(spacing: metrics.metadataOuterSpacing) {
            if !fields.isDisjoint(with: [.language, .color, .censorship]) {
                HStack(spacing: BookCardMetrics.metadataSpacing(width: metrics.cardWidth)) {
                    if fields.contains(.language) {
                        Group {
                            if let language {
                                Text(language.abbreviation)
                                    .fontWeight(.semibold)
                                    .frame(width: 19, height: 15)
                                    .background(.secondary.opacity(0.13), in: RoundedRectangle(cornerRadius: 3))
                                    .help(language.fullName)
                                    .accessibilityLabel(language.fullName)
                            } else { Color.clear }
                        }
                        .frame(width: 19)
                    }
                    if fields.contains(.color) {
                        Group {
                            if metadata.isFullColor {
                                glyph("paintpalette", description: localizer.string(.fullColor))
                            } else { Color.clear }
                        }
                        .frame(width: 12)
                    }
                    if fields.contains(.censorship) {
                        Group {
                            if let censorship = metadata.censorship {
                                glyph(censorship == "uncensored" ? "eye" : "eye.slash",
                                      description: localizer.versionCensorshipDescription(censorship))
                            } else { Color.clear }
                        }
                        .frame(width: 12)
                    }
                }
                .padding(.horizontal, 4)
                .frame(maxHeight: .infinity)
            }
            Spacer(minLength: 0)
            if fields.contains(.pages) {
                Group {
                    if let pages = metadata.pages {
                        Text(localizer.bookPageCount(pages))
                            .monospacedDigit()
                            .minimumScaleFactor(0.6)
                            .help(localizer.bookPageCount(pages))
                    } else { Color.clear }
                }
                .frame(width: 36)
                .frame(maxHeight: .infinity)
            }
        }
        .padding(.horizontal, 2)
        .overlay {
            if bordered { RoundedRectangle(cornerRadius: BookCardMetrics.detailCornerRadius).strokeBorder(.secondary.opacity(0.38)).allowsHitTesting(false) }
        }
        .font(.caption)
        .foregroundStyle(.primary)
        .lineLimit(1)
    }

    private func glyph(_ image: String, description: String) -> some View {
        Image(systemName: image)
            .help(description)
            .accessibilityLabel(description)
    }
}

enum BookCardBadgeSize {
    case ordinary, showcase

    var height: CGFloat { self == .showcase ? 24 : BookCardMetrics.badgeHeight }
    var font: Font { self == .showcase ? .callout.weight(.medium) : .caption2 }
    var iconWidth: CGFloat { self == .showcase ? 26 : BookCardMetrics.scoreIconWidth }
    var padding: CGFloat { self == .showcase ? 6 : BookCardMetrics.scorePadding }
}

struct BookCardRating: View {
    let rating: Double
    let localizer: AppLocalizer
    var sourceTitle: String?
    var size: BookCardBadgeSize = .ordinary

    var body: some View {
        let score = rating.formatted(.number.precision(.fractionLength(1)))
        let label = "\(localizer.string(.rating)) \(score)"
        let description = sourceTitle.map { "\(label) · \($0)" } ?? label
        HStack(spacing: 0) {
            Image(systemName: "star.fill")
                .foregroundStyle(.yellow)
                .frame(width: size.iconWidth)
                .frame(maxHeight: .infinity)
            Text(score)
                .monospacedDigit()
                .foregroundStyle(Color.black)
                .padding(.horizontal, size.padding)
                .frame(maxHeight: .infinity)
                .background(Color.yellow)
        }
        .font(size.font)
        .frame(height: size.height)
        .clipShape(RoundedRectangle(cornerRadius: BookCardMetrics.detailCornerRadius))
        .overlay {
            RoundedRectangle(cornerRadius: BookCardMetrics.detailCornerRadius)
                .strokeBorder(.yellow.opacity(0.55))
                .allowsHitTesting(false)
        }
        .help(description)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(description)
    }
}

struct BookCardReadingRow: View {
    @Environment(\.nyaehAccentColor) private var accent
    let reading: BookCardReadingStatus
    let fields: BookCardFields
    let localizer: AppLocalizer
    var size: BookCardBadgeSize = .ordinary

    var body: some View {
        HStack(spacing: 0) {
            switch reading {
            case .unread:
                if fields.contains(.readingStatus) {
                    badge(localizer.string(.cardUnread), color: .secondary)
                }
            case .completed(let count):
                let hasCount = fields.contains(.readingNumbers) && count > 0
                if fields.contains(.readingStatus) || hasCount {
                    badge(hasCount ? String(format: localizer.string(.cardTimesRead), count.formatted()) : localizer.string(.cardRead),
                          color: accent)
                }
            case .reading(let current, let total):
                if fields.contains(.readingStatus) {
                    CardPageProgress(current: current, total: total, showsNumber: fields.contains(.readingNumbers), size: size)
                        .accessibilityLabel(localizer.string(.readerContinue))
                        .accessibilityValue(BookCardMetrics.progressLabel(page: current))
                } else if fields.contains(.readingNumbers) {
                    Text(BookCardMetrics.progressLabel(page: current)).monospacedDigit()
                }
            }
            Spacer(minLength: 0)
        }.font(size.font).lineLimit(1)
    }

    private func badge(_ text: String, color: Color) -> some View {
        ZStack {
            Text(0.0.formatted(.number.precision(.fractionLength(1))))
                .monospacedDigit()
                .padding(.horizontal, size.padding + size.iconWidth / 2)
                .hidden().accessibilityHidden(true)
            Text(text).minimumScaleFactor(0.7).padding(.horizontal, 6)
        }
        .frame(height: size.height)
        .background(color.opacity(0.17), in: RoundedRectangle(cornerRadius: BookCardMetrics.detailCornerRadius))
    }
}

struct CardPageProgress: View, Animatable {
    let current: Int
    let total: Int?
    let showsNumber: Bool
    let size: BookCardBadgeSize
    @Environment(\.nyaehAccentColor) private var accent
    @Environment(\.self) private var environment
    @State private var numberWidth: CGFloat = 0

    var animatableData: CGFloat

    init(current: Int, total: Int?, showsNumber: Bool, size: BookCardBadgeSize) {
        self.current = current
        self.total = total
        self.showsNumber = showsNumber
        self.size = size
        animatableData = total.map { min(1, max(0, CGFloat(current) / CGFloat(max(1, $0)))) } ?? 0
    }

    private var ink: Color {
        let color = accent.resolve(in: environment)
        return BookCardMetrics.prefersDarkInk(linearRed: color.linearRed, green: color.linearGreen,
                                              blue: color.linearBlue) ? .black : .white
    }

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            let fill = width * animatableData
            let position = BookCardMetrics.pageLabelPosition(width: width, fill: total == nil ? nil : fill, numberWidth: numberWidth)
            ZStack(alignment: .leading) {
                let shape = RoundedRectangle(cornerRadius: BookCardMetrics.detailCornerRadius)
                shape.fill(.secondary.opacity(0.16))
                if total != nil {
                    shape.fill(accent).frame(width: fill)
                } else {
                    accent.mask { ProgressView().progressViewStyle(.linear) }
                        .padding(.leading, showsNumber ? numberWidth + 8 : 3)
                        .padding(.trailing, 3)
                }
                if showsNumber {
                    Text(BookCardMetrics.progressLabel(page: current)).font(size.font.monospacedDigit()).fixedSize()
                        .contentTransition(.opacity)
                        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { numberWidth = $0 }
                        .foregroundStyle(position.onFill ? ink : .primary)
                        .offset(x: position.x)
                }
            }.clipShape(RoundedRectangle(cornerRadius: BookCardMetrics.detailCornerRadius))
        }.frame(height: size.height)
    }
}

enum BookCardTitleScrollMetrics {
    static let minimumOverflowWidth: CGFloat = 1
    static let pointsPerSecond: CGFloat = 18
    static let minimumDuration = 2.4

    static func canStart(
        isHovering: Bool,
        titleWidth: CGFloat,
        cardWidth: CGFloat,
        reduceMotion: Bool
    ) -> Bool {
        isHovering && !reduceMotion && overflowWidth(titleWidth: titleWidth, cardWidth: cardWidth) > minimumOverflowWidth
    }

    static func overflowWidth(titleWidth: CGFloat, cardWidth: CGFloat) -> CGFloat {
        max(titleWidth - cardWidth, 0)
    }

    static func duration(forOverflow overflowWidth: CGFloat) -> Double {
        max(Double(overflowWidth / pointsPerSecond), minimumDuration)
    }
}

struct BookRatingStarsView: View {
    let rating: Double?
    let localizer: AppLocalizer
    var starFont: Font = .caption
    var spacing: CGFloat = 2
    var height: CGFloat = 18

    var body: some View {
        Canvas { context, size in
            let symbols = BookRatingStarsModel(rating: rating).symbols
            let symbolSize = max(height * 0.72, 10)
            let contentWidth = symbolSize * CGFloat(symbols.count)
                + spacing * CGFloat(max(symbols.count - 1, 0))
            var x = max((size.width - contentWidth) / 2, 0)
            for symbol in symbols {
                var image = context.resolve(Image(systemName: symbol))
                image.shading = .color(starColor)
                context.draw(
                    image,
                    in: CGRect(
                        x: x,
                        y: (size.height - symbolSize) / 2,
                        width: symbolSize,
                        height: symbolSize
                    )
                )
                x += symbolSize + spacing
            }
        }
        .frame(width: canvasWidth, height: height, alignment: .center)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
    }

    private var canvasWidth: CGFloat {
        max(height * 0.8, 12) * 5 + spacing * 4
    }

    private var starColor: Color {
        rating == nil ? .secondary.opacity(0.55) : .yellow
    }

    private var accessibilityText: String {
        if let rating {
            return "\(localizer.string(.rating)) \(String(format: "%.2f", rating))"
        }
        return localizer.string(.unrate)
    }

}

struct BookRatingStarsModel: Equatable, Sendable {
    let symbols: [String]

    init(rating: Double?) {
        symbols = (1...5).map { index in
            guard let rating else {
                return "star"
            }
            let threshold = Double(index)
            if rating >= threshold {
                return "star.fill"
            }
            if rating >= threshold - 0.5 {
                return "star.leadinghalf.filled"
            }
            return "star"
        }
    }
}

struct BookCardButton: View {
    let book: LibraryBook
    let titleDisplayMode: BookTitleDisplayMode
    let localizer: AppLocalizer
    var metrics: BookCardMetrics = .default
    var showsUnobstructedCover = false
    var selection: BookCardSelection?
    var collectionFocus: FocusState<SearchCollectionPopoverFocus?>.Binding?
    var beforeGroupNavigation: (() -> Void)?
    let action: (LibraryBook) -> Void

    var body: some View {
        BookCardView(book: book, titleDisplayMode: titleDisplayMode, localizer: localizer, metrics: metrics,
                     showsUnobstructedCover: showsUnobstructedCover, selection: selection, collectionFocus: collectionFocus,
                     beforeGroupNavigation: beforeGroupNavigation, action: action)
            .bookCardHoverSurface()
    }
}

struct LibraryDisplayItemCardButton: View {
    @Environment(\.navigateCardGroup) private var navigate
    let item: LibraryDisplayItem
    let titleDisplayMode: BookTitleDisplayMode
    let localizer: AppLocalizer
    var metrics: BookCardMetrics = .default
    var showsUnobstructedCover = false
    var selection: BookCardSelection?
    let action: (LibraryDisplayItem) -> Void

    var body: some View {
        switch item {
        case .book(let book):
            BookCardButton(book: book, titleDisplayMode: titleDisplayMode, localizer: localizer, metrics: metrics,
                           showsUnobstructedCover: showsUnobstructedCover, selection: selection) { action(.book($0)) }
        case .collection(let collection):
            let card = Button { action(item) } label: {
                CollectionCardView(item: collection, titleDisplayMode: titleDisplayMode, language: localizer.language, metrics: metrics,
                                   showsUnobstructedCover: showsUnobstructedCover)
                    .equatable()
            }
            .buttonStyle(.plain)
            Group {
                if let selection {
                    card.searchBatchSelection(isSelected: selection.isSelected, localizer: localizer,
                                              commandClickHeight: metrics.coverHeight + metrics.contentSpacing + metrics.regularTitleHeight,
                                              onToggle: selection.toggle)
                } else {
                    card
                }
            }
            .contextMenu {
                CardMenuItems(sections: CardMenuCommand.seriesSections(selected: selection?.isSelected), localizer: localizer) { command in
                    switch command {
                    case .series: navigate?.open(.series(collection.id))
                    case .manageSeries: navigate?.open(.manageSeries(collection.id))
                    case .select, .deselect: selection?.toggle()
                    default: break
                    }
                }
            }
            .bookCardHoverSurface()
        }
    }
}

private struct CollectionCardView: View, Equatable {
    let item: BookCollectionDisplayItem
    let titleDisplayMode: BookTitleDisplayMode
    let language: AppLanguage
    let metrics: BookCardMetrics
    let showsUnobstructedCover: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.isBookCardHovered) private var isHovered

    private var hoverVisualState: BookCardHoverVisualState {
        BookCardHoverVisualState.resolve(isHovered: isHovered, reduceMotion: reduceMotion)
    }

    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.item == rhs.item && lhs.titleDisplayMode == rhs.titleDisplayMode && lhs.language == rhs.language
            && lhs.metrics == rhs.metrics && lhs.showsUnobstructedCover == rhs.showsUnobstructedCover
    }

    private var localizer: AppLocalizer { AppLocalizer(language: language) }

    var body: some View {
        VStack(alignment: .center, spacing: metrics.contentSpacing) {
            ZStack {
                ForEach(Array(item.books.prefix(3).enumerated()), id: \.element.id) { offset, book in
                    collectionCover(book: book)
                        .offset(x: CGFloat(offset) * 6, y: CGFloat(offset) * -4)
                        .zIndex(showsUnobstructedCover ? -Double(offset) : 0)
                        .shadow(color: .black.opacity(0.14), radius: 5, x: 0, y: 3)
                }
            }
            .frame(width: metrics.cardWidth, height: metrics.coverHeight)
            .scaleEffect(hoverVisualState.collectionCoverScale)
            .overlay(alignment: .topLeading) {
                if !showsUnobstructedCover {
                    Image(systemName: "rectangle.stack.fill")
                        .font(.caption)
                        .foregroundStyle(.white)
                        .padding(5)
                        .background(.black.opacity(0.45), in: Circle())
                        .padding(6)
                }
            }

            BookCardTitleView(title: item.collection.name, metrics: .init(width: metrics.width, appearance: .standard))

            HStack(spacing: 4) {
                if showsUnobstructedCover {
                    Image(systemName: "rectangle.stack.fill")
                        .accessibilityHidden(true)
                }
                Text(localizer.collectionBookCount(item.books.count))
            }
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: metrics.cardWidth, height: metrics.infoRowHeight, alignment: .center)
        }
        .frame(width: metrics.cardWidth, height: collectionCardHeight, alignment: .top)
        .contentShape(RoundedRectangle(cornerRadius: 8))
    }

    private var collectionCardHeight: CGFloat {
        metrics.coverHeight
            + metrics.regularTitleHeight
            + metrics.infoRowHeight
            + metrics.contentSpacing * 2
    }

    @ViewBuilder
    private func collectionCover(book: LibraryBook) -> some View {
        BookCoverThumbnail(
            book: book,
            width: metrics.cardWidth - 10,
            height: metrics.coverHeight - 12,
            cornerRadius: 8,
            fitsEntireImage: showsUnobstructedCover
        )
    }
}

struct CardSizeSliderControl: View {
    @Binding var cardWidth: Int

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "square.grid.2x2")
                .font(.caption)
                .foregroundStyle(.secondary)

            Slider(value: sliderValue, in: Double(BookCardMetrics.minimumWidth)...Double(BookCardMetrics.maximumWidth), step: Double(BookCardMetrics.step))
                .frame(width: 132)

            Image(systemName: "square.grid.3x3.fill")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var sliderValue: Binding<Double> {
        Binding {
            Double(cardWidth)
        } set: { newValue in
            cardWidth = BookCardMetrics.normalizedWidth(Int(newValue.rounded()))
        }
    }
}

extension View {
    func cardControlCapsule() -> some View {
        overlay {
            Capsule()
                .stroke(.secondary.opacity(0.18), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.06), radius: 8, x: 0, y: 3)
    }
}
