import SwiftUI

// 每个系列只提供原生浮窗的锚点；唯一的展示/返回状态由搜索页持有。
struct SearchCollectionPopoverAnchor<Content: View>: View {
    let source: SearchDisplayItem
    let state: SearchCollectionPopoverState
    let isSearchActive: Bool
    let viewport: CGSize
    let topInset: CGFloat
    let titleDisplayMode: BookTitleDisplayMode
    let cardMetrics: BookCardMetrics
    let localizer: AppLocalizer
    let selectedBookIDs: Set<LibraryBook.ID>
    let onToggleMemberSelection: (LibraryBook) -> Void
    let onMember: (UUID, LibraryBook, SearchCollectionBrowsePosition) -> Void
    let onDetails: (UUID, LibraryDisplayItem) -> Void
    let onAnchorVisibility: (BookCollection.ID, Bool) -> Void
    @ViewBuilder let content: () -> Content
    @State private var isAnchorVisible = false

    var body: some View {
        content()
            .popover(item: presentationBinding, arrowEdge: nil) { session in
                SearchCollectionMembersPopover(
                    source: source,
                    session: session,
                    viewport: viewport,
                    titleDisplayMode: titleDisplayMode,
                    cardMetrics: cardMetrics,
                    localizer: localizer,
                    selectedBookIDs: selectedBookIDs,
                    onToggleMemberSelection: onToggleMemberSelection,
                    onMember: { book, position in onMember(session.id, book, position) },
                    onDetails: { onDetails(session.id, source.item) },
                    onClose: { state.dismiss(presentationID: session.id) }
                )
                .editionDeckHost()
                .id(session.id)
            }
            .onGeometryChange(for: Bool.self) { [viewport, topInset] geometry in
                SearchCollectionPopoverMetrics.isAnchorVisible(
                    geometry.frame(in: .named("SearchResultsViewport")),
                    viewport: viewport,
                    topInset: topInset
                )
            } action: { isVisible in
                guard case .collection(let item) = source.item else { return }
                isAnchorVisible = isVisible
                onAnchorVisibility(item.id, isVisible)
            }
            .task(id: visibleRestoreRequestID) {
                guard let requestID = visibleRestoreRequestID,
                      !Task.isCancelled,
                      requestID == state.restoreRequestID,
                      case .collection(let item) = source.item else { return }
                state.restoreAtAnchor(collectionID: item.id)
            }
            .onDisappear {
                isAnchorVisible = false
                if case .collection(let item) = source.item { onAnchorVisibility(item.id, false) }
            }
    }

    private var visibleRestoreRequestID: UUID? {
        guard isSearchActive, isAnchorVisible,
              state.returnSession?.anchorID == "entity.\(source.id)" else { return nil }
        return state.restoreRequestID
    }

    private var presentationBinding: Binding<SearchCollectionPopoverSession?> {
        // 捕获本次展示的身份，忽略系统迟到的关闭回调。
        let presentationID = matchingPresentation?.id
        return Binding(
            get: { isSearchActive ? matchingPresentation : nil },
            set: { value in
                if value == nil, let presentationID { state.dismiss(presentationID: presentationID) }
            }
        )
    }

    private var matchingPresentation: SearchCollectionPopoverSession? {
        guard let presentation = state.presentation, source.id == "collection.\(presentation.collectionID)" else { return nil }
        return presentation
    }

}

private struct SearchCollectionMembersPopover: View {
    let source: SearchDisplayItem
    let session: SearchCollectionPopoverSession
    let viewport: CGSize
    let titleDisplayMode: BookTitleDisplayMode
    let cardMetrics: BookCardMetrics
    let localizer: AppLocalizer
    let selectedBookIDs: Set<LibraryBook.ID>
    let onToggleMemberSelection: (LibraryBook) -> Void
    let onMember: (LibraryBook, SearchCollectionBrowsePosition) -> Void
    let onDetails: () -> Void
    let onClose: () -> Void

    @State private var scrollPosition: ScrollPosition
    @State private var scrollOffset: CGFloat
    @State private var hasRestoredScroll = false
    @State private var requestedFocus: SearchCollectionPopoverFocus?
    @FocusState private var focusedTarget: SearchCollectionPopoverFocus?

    // 一次性的种子属于 session 身份；关闭重开后以新的 session 创建视图。
    init(
        source: SearchDisplayItem,
        session: SearchCollectionPopoverSession,
        viewport: CGSize,
        titleDisplayMode: BookTitleDisplayMode,
        cardMetrics: BookCardMetrics,
        localizer: AppLocalizer,
        selectedBookIDs: Set<LibraryBook.ID>,
        onToggleMemberSelection: @escaping (LibraryBook) -> Void,
        onMember: @escaping (LibraryBook, SearchCollectionBrowsePosition) -> Void,
        onDetails: @escaping () -> Void,
        onClose: @escaping () -> Void
    ) {
        self.source = source
        self.session = session
        self.viewport = viewport
        self.titleDisplayMode = titleDisplayMode
        self.cardMetrics = cardMetrics
        self.localizer = localizer
        self.selectedBookIDs = selectedBookIDs
        self.onToggleMemberSelection = onToggleMemberSelection
        self.onMember = onMember
        self.onDetails = onDetails
        self.onClose = onClose
        _scrollPosition = State(initialValue: ScrollPosition(y: session.position.scrollOffset))
        _scrollOffset = State(initialValue: session.position.scrollOffset)
        _requestedFocus = State(initialValue: (session.position.focusedMemberID ?? source.books.first?.id).map(SearchCollectionPopoverFocus.member))
    }

    @Environment(\.bookCardFields) private var cardFields
    @Environment(\.bookCardCatalog) private var catalog
    @Environment(\.bookCardsShowUserHidden) private var showsUserHidden

    @Environment(\.bookCardAggregatesVersions) private var aggregatesVersions

    private var metadataMemberIDs: Set<LibraryBook.ID> {
        guard let catalog, aggregatesVersions, !cardFields.isDisjoint(with: .metadata) else { return [] }
        return Set(source.books.compactMap { member in
            let book = catalog.bookForCard(member)
            return catalog.cardVersionAlternatives(to: book, showsUserHidden: showsUserHidden).isEmpty ? nil : book.id
        })
    }

    private var metrics: SearchCollectionPopoverMetrics {
        SearchCollectionPopoverMetrics(viewport: viewport, memberCount: source.books.count, cardMetrics: cardMetrics, fields: cardFields)
    }

    private var initialFocus: SearchCollectionPopoverFocus {
        if let bookID = session.position.focusedMemberID ?? source.books.first?.id { return .member(bookID) }
        return .details
    }

    var body: some View {
        let metadataIDs = metadataMemberIDs
        ScrollViewReader { proxy in
            VStack(spacing: 0) {
                header
                Divider()
                    .frame(height: SearchCollectionPopoverMetrics.dividerHeight)
                ScrollView {
                    LazyVGrid(
                        columns: Array(repeating: GridItem(.fixed(metrics.cardWidth), spacing: SearchCollectionPopoverMetrics.horizontalSpacing, alignment: .top), count: metrics.columns),
                        alignment: .leading,
                        spacing: SearchCollectionPopoverMetrics.verticalSpacing
                    ) {
                        ForEach(source.books) { book in
                            memberButton(book)
                                .id(book.id)
                        }
                    }
                    .padding(metrics.gridPadding)
                    .scrollTargetLayout()
                }
                .scrollBounceBehavior(.basedOnSize, axes: .vertical)
                .scrollPosition($scrollPosition)
                .onScrollGeometryChange(for: MemberScrollGeometry.self) { geometry in
                    MemberScrollGeometry(
                        offset: max(0, geometry.contentOffset.y + geometry.contentInsets.top),
                        contentHeight: geometry.contentSize.height,
                        viewportHeight: geometry.containerSize.height
                    )
                } action: { _, geometry in
                    if !hasRestoredScroll {
                        guard geometry.viewportHeight > 0, geometry.contentHeight > 0 else { return }
                        hasRestoredScroll = true
                        let restoredOffset = SearchCollectionPopoverMetrics.clampedOffset(
                            session.position.scrollOffset,
                            contentHeight: geometry.contentHeight,
                            viewportHeight: geometry.viewportHeight
                        )
                        scrollOffset = restoredOffset
                        scrollPosition.scrollTo(y: restoredOffset)
                    } else {
                        scrollOffset = geometry.offset
                    }
                }
            }
            .onChange(of: requestedFocus) { _, target in
                if let bookID = target?.memberID { proxy.scrollTo(bookID) }
            }
            .onChange(of: hasRestoredScroll) { _, restored in
                // 成员顺序变化时，旧偏移可能不再包含焦点成员；等首轮布局后再定位它。
                if restored, let bookID = requestedFocus?.memberID { proxy.scrollTo(bookID) }
            }

        }
        .frame(width: metrics.size.width, height: metrics.size.height)
        .defaultFocus($focusedTarget, initialFocus)
        .onChange(of: source.books.map(\.id)) { _, memberIDs in
            let needsFallback: Bool
            if let bookID = focusedTarget?.memberID { needsFallback = !memberIDs.contains(bookID) }
            else { needsFallback = focusedTarget == nil }
            if needsFallback {
                requestedFocus = memberIDs.first.map(SearchCollectionPopoverFocus.member)
                if memberIDs.isEmpty { focusedTarget = .details }
            }
        }
        .onChange(of: metadataIDs) { _, updated in
            if case .metadata(let id) = focusedTarget, !updated.contains(id) {
                requestedFocus = .member(id)
            }
        }
        .onKeyPress(.return) {
            switch focusedTarget {
            case .member(let bookID):
                guard let book = source.books.first(where: { $0.id == bookID }) else { return .ignored }
                activate(book)
            case .details: onDetails()
            case .metadata, .reader, nil: return .ignored
            }
            return .handled
        }
        .onExitCommand(perform: onClose)
    }

    private var header: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                if case .collection(let item) = source.item {
                    Text(item.collection.name)
                        .font(.headline)
                        .lineLimit(2)
                        .help(item.collection.name)
                }
                Text(localizer.collectionBookCount(source.books.count))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Button(action: onDetails) {
                Label(localizer.string(.searchSeriesDetails), systemImage: "info.circle")
            }
            .focused($focusedTarget, equals: .details)
        }
        .padding(16)
        .frame(height: SearchCollectionPopoverMetrics.headerHeight)
    }

    private func memberButton(_ book: LibraryBook) -> some View {
        BookCardButton(
            book: book,
            titleDisplayMode: titleDisplayMode,
            localizer: localizer,
            metrics: metrics.bookCardMetrics,
            showsUnobstructedCover: true,
            selection: BookCardSelection(isSelected: selectedBookIDs.contains(book.id), toggle: {
                onToggleMemberSelection(book)
            }),
            collectionFocus: $focusedTarget,
            beforeGroupNavigation: onClose,
            action: activate
        )
        .onChange(of: requestedFocus, initial: true) { _, target in
            if let target, target.memberID == book.id {
                focusedTarget = target
                requestedFocus = nil
            }
        }
    }

    private func activate(_ book: LibraryBook) {
        onMember(book, SearchCollectionBrowsePosition(scrollOffset: scrollOffset, focusedMemberID: book.id))
    }

    private struct MemberScrollGeometry: Equatable {
        var offset: CGFloat
        var contentHeight: CGFloat
        var viewportHeight: CGFloat
    }
}
