// 本文件实现强搜索界面，协调搜索草稿、facet、建议、分页结果和悬停封面预览。

import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct AdvancedSearchView: View {
    @Environment(\.undoManager) private var undoManager
    @Environment(\.accessibilityReduceMotion) private var accessibilityReduceMotion

    let store: SearchStore
    @Bindable var preferences: AppPreferences
    let metadataBatchConfiguration: MetadataBatchConfiguration
    let isTagTranslationEnabled: Bool
    let titleDisplayMode: BookTitleDisplayMode
    @Binding var page: Int
    @Binding var pageSize: Int
    @Binding var isFacetPanelExpanded: Bool
    @Binding var isHeaderPinned: Bool
    let isCollectionMembersExpanded: Bool
    @Binding var cardWidth: Int
    let focusRequest: Int
    let isActive: Bool
    let localizer: AppLocalizer
    let onFeedback: (String) -> Void
    let onSelect: (LibraryDisplayItem) -> Void

    // 搜索页只保存交互状态；查询结果、facet 和建议都在 Store 中统一刷新，
    // 这样命令菜单、标签跳转和页面按钮能共享同一份搜索上下文。
    @State private var selectedNamespace = "female"
    @State private var seriesConflictConfirmation: SeriesConflictConfirmation?
    @State private var selectionState = SearchResultSelectionState()
    @State private var previewTarget: SearchPreviewTarget?
    @State private var isPreviewPresented = false
    @State private var previewFocusOnDismiss: SearchPreviewTarget?
    @State private var collectionPopoverState = SearchCollectionPopoverState()
    @State private var pinnedHeaderHeight: CGFloat?
    @State private var isSavedSearchPopoverPresented = false
    @State private var expandedTagBookIDs: Set<LibraryBook.ID> = []
    @State private var expandedCollectionIDs: Set<BookCollection.ID> = []
    @State private var resultPresentationSnapshot = SearchResultPresentationSnapshot.empty
    @State private var bottomOverlayHeight = SearchFooterMetrics.defaultOverlayHeight
    @State private var isCoverImageImporterPresented = false
    @State private var isCoverImageDropTargeted = false
    @State private var suggestionSelection = SearchSuggestionSelection()
    @State private var areSuggestionsDismissed = false
    @State private var isSuggestionHovered = false
    @State private var scopeMenuSelection = SearchScopeMenuSelection()
    @FocusState private var isSearchFocused: Bool
    @FocusState private var focusedCompactRow: SearchPreviewTarget?

    private var activeFacets: [SearchTagFacet] {
        store.catalog.advancedSearchFacetsByNamespace[selectedNamespace] ?? []
    }

    private var searchItems: [SearchDisplayItem] {
        store.catalog.advancedSearchDisplayItems
    }

    private var pageItems: [SearchDisplayItem] {
        if store.catalog.isCoverImageSearchActive && isCollectionMembersExpanded {
            return Pagination.pageItems(searchItems, page: page, pageSize: pageSize)
        }
        return searchItems
    }

    private var resultPresentationInput: SearchResultPresentationInput {
        SearchResultPresentationInput(
            items: pageItems,
            layout: store.catalog.advancedSearchResultLayout
        )
    }

    private var currentResultPresentationSnapshot: SearchResultPresentationSnapshot {
        guard resultPresentationSnapshot.input == resultPresentationInput else {
            return SearchResultPresentationSnapshot(input: resultPresentationInput)
        }
        return resultPresentationSnapshot
    }

    private var cardMetrics: BookCardMetrics {
        BookCardMetrics(width: cardWidth)
    }

    private var selectedBooks: [LibraryBook] {
        var seen: Set<LibraryBook.ID> = []
        let pageBooks = pageItems.flatMap(\.books)
        return pageBooks.filter {
            selectionState.selectedBookIDs.contains($0.id) && seen.insert($0.id).inserted
        }
    }

    private var previewItem: LibraryDisplayItem? {
        previewTarget?.resolve(in: pageDisplayItems, expandedCollections: expandedCollectionIDs)
    }

    private var pageBookIDs: Set<LibraryBook.ID> {
        Set(pageItems.flatMap(\.books).map(\.id))
    }

    private var pageDisplayItems: [LibraryDisplayItem] {
        pageItems.map(\.item)
    }

    private var isSearchResultLoading: Bool {
        store.catalog.isAdvancedSearchLoading || store.catalog.isCoverImageSearchLoading
    }

    private var collectionPopoverContext: SearchCollectionPopoverContext {
        SearchCollectionPopoverContext(
            request: LibrarySearchRequest(
                rawQuery: store.catalog.advancedSearchText,
                isRegexEnabled: store.catalog.isAdvancedSearchRegexEnabled,
                mode: store.catalog.advancedSearchMode,
                isTagTranslationEnabled: isTagTranslationEnabled,
                scope: store.catalog.advancedSearchScope,
                page: page,
                pageSize: pageSize,
                sortKey: store.catalog.advancedSearchSortKey,
                sortDirection: store.catalog.advancedSearchSortDirection
            ),
            layout: store.catalog.advancedSearchResultLayout,
            showsCollectionMembers: isCollectionMembersExpanded,
            coverImageFileName: store.catalog.coverImageSearchFileName,
            isCoverImageSearchActive: store.catalog.isCoverImageSearchActive
        )
    }

    private func catalogBinding<Value>(
        _ keyPath: ReferenceWritableKeyPath<CatalogStore, Value>
    ) -> Binding<Value> {
        Binding(
            get: { store.catalog[keyPath: keyPath] },
            set: { store.catalog[keyPath: keyPath] = $0 }
        )
    }

    var body: some View {
        searchLifecycleView
            .environment(\.bookCardAggregatesVersions, !isCollectionMembersExpanded)
            .environment(\.bookCardsShowUserHidden, !store.catalog.isCoverImageSearchActive && store.catalog.advancedSearchScope == .hidden)
            .confirmSeriesConflict($seriesConflictConfirmation, localizer: localizer)
            .overlay(alignment: .topTrailing) {
                OrganizationSaveStatusView(store: store.catalog, localizer: localizer)
                    .padding(12)
            }
    }

    private var searchKeyboardView: some View {
        searchWorkspace
            .navigationTitle(localizer.string(.advancedSearch))
            .focusedSceneValue(\.nyaehViewCommands, viewCommandContext)
            .background {
                Button(action: openSelectedBook) { EmptyView() }
                    .keyboardShortcut(.return, modifiers: [])
                    .disabled(!isActive || isSearchFocused || focusedCompactRow != nil
                        || collectionPopoverState.presentation != nil || isPreviewPresented
                        || (previewItem == nil && selectedBooks.isEmpty))
                    .opacity(0)
                    .allowsHitTesting(false)
            }
    }

    private var searchQueryObservationView: some View {
        searchKeyboardView
        .onChange(of: store.catalog.advancedSearchText) { _, _ in
            // 输入只更新草稿和建议；完整搜索由 Return/按钮/facet 动作提交，避免每个按键都跑全量查询。
            store.catalog.updateAdvancedSearchDraft()
            store.catalog.refreshAdvancedSearchSuggestionsAsync(isTagTranslationEnabled: isTagTranslationEnabled)
            suggestionSelection.clear()
            if isSearchFocused { areSuggestionsDismissed = false }
        }
        .onChange(of: store.catalog.advancedSearchActiveTokenRange) { _, _ in
            store.catalog.refreshAdvancedSearchSuggestionsAsync(isTagTranslationEnabled: isTagTranslationEnabled)
            suggestionSelection.clear()
            if isSearchFocused { areSuggestionsDismissed = false }
        }
        .onChange(of: store.catalog.advancedSearchSuggestions) { _, suggestions in
            suggestionSelection.reconcile(with: suggestions.map(\.id))
        }
        .onChange(of: isSearchFocused) { _, focused in
            if focused {
                areSuggestionsDismissed = false
            } else if !isSuggestionHovered {
                areSuggestionsDismissed = true
                suggestionSelection.clear()
            }
        }
        .onChange(of: store.catalog.isAdvancedSearchRegexEnabled) { _, _ in
            store.catalog.updateAdvancedSearchDraft()
        }
        .onChange(of: store.catalog.advancedSearchScope) { _, _ in
            page = 1
            store.catalog.advancedSearchPage = 1
            guard AdvancedSearchInteractionPolicy.shouldSubmitOrdinarySearch(
                isCoverImageSearchActive: store.catalog.isCoverImageSearchActive
            ) else { return }
            submitSearch()
        }
        .onChange(of: store.catalog.advancedSearchResultLayout) { _, _ in
            expandedCollectionIDs.removeAll()
            expandedTagBookIDs.removeAll()
            clearPreview()
        }
        .onChange(of: isCollectionMembersExpanded) { _, showsIndividualBooks in
            store.catalog.advancedSearchShowsIndividualBooks = showsIndividualBooks
            if store.catalog.isCoverImageSearchActive {
                resetResultInteractions()
                page = 1
                store.catalog.advancedSearchPage = 1
                store.catalog.reprojectCoverImageSearchResults()
            } else {
                submitSearch()
            }
        }
    }

    private var searchPaginationObservationView: some View {
        searchQueryObservationView
        .onChange(of: store.catalog.advancedSearchSortKey) { _, _ in
            applyAdvancedSearchSortChange()
        }
        .onChange(of: store.catalog.advancedSearchSortDirection) { _, _ in
            applyAdvancedSearchSortChange()
        }
        .onChange(of: isHeaderPinned) { _, _ in
            pinnedHeaderHeight = nil
        }
        .onChange(of: pageSize) { _, newPageSize in
            resetResultInteractions()
            page = 1
            store.catalog.advancedSearchPage = 1
            store.catalog.advancedSearchPageSize = newPageSize
            guard AdvancedSearchInteractionPolicy.shouldSubmitOrdinarySearch(
                isCoverImageSearchActive: store.catalog.isCoverImageSearchActive
            ) else { return }
            submitSearch(resetPage: false)
        }
        .onChange(of: page) { _, _ in
            // 页大小与页码在分页控件中可能同时改变；页大小回调负责这次提交。
            guard pageSize == store.catalog.advancedSearchPageSize else { return }
            guard page != store.catalog.advancedSearchPage else { return }
            store.catalog.advancedSearchPage = page
            resetResultInteractions()
            guard AdvancedSearchInteractionPolicy.shouldSubmitOrdinarySearch(
                isCoverImageSearchActive: store.catalog.isCoverImageSearchActive
            ) else { return }
            submitSearch(resetPage: false)
        }
        .onChange(of: store.catalog.advancedSearchTotalCount) { _, _ in
            page = Pagination.clampedPage(page, itemCount: store.catalog.advancedSearchTotalCount, pageSize: pageSize)
        }
        .onChange(of: pageBookIDs) { _, availableBookIDs in
            selectionState.retainAvailableBookIDs(availableBookIDs)
        }
        .onChange(of: pageItems) { _, items in
            collectionPopoverState.retainAvailableItems(items, isLoading: isSearchResultLoading)
            if !isSearchResultLoading { reconcileResultInteractions(in: items) }
        }
        .onChange(of: isSearchResultLoading) { _, isLoading in
            collectionPopoverState.retainAvailableItems(pageItems, isLoading: isLoading)
            if !isLoading { reconcileResultInteractions(in: pageItems) }
            if isActive {
                collectionPopoverState.requestReturn(context: collectionPopoverContext, items: pageItems, isLoading: isLoading)
            }
        }
        .onChange(of: collectionPopoverContext) { _, context in
            collectionPopoverState.invalidate(ifContextChanged: context)
        }
    }

    private var searchLifecycleView: some View {
        searchPaginationObservationView
        .onAppear(perform: handleSearchAppear)
        .onDisappear {
            clearPreview()
            scopeMenuSelection.cancel()
            collectionPopoverState.clear()
        }
        .onChange(of: isActive) { _, isActive in
            if isActive {
                collectionPopoverState.requestReturn(context: collectionPopoverContext, items: pageItems, isLoading: isSearchResultLoading)
            } else {
                previewFocusOnDismiss = nil
                isPreviewPresented = false
                scopeMenuSelection.cancel()
                collectionPopoverState.searchBecameInactive()
            }
        }
        .overlay {
            if isCoverImageDropTargeted {
                CoverImageSearchDropHighlight(
                    title: localizer.string(.coverImageSearchDropPrompt)
                )
                .allowsHitTesting(false)
            }
        }
        .onDrop(
            of: CoverImageSearchDropLoader.typeIdentifiers,
            isTargeted: $isCoverImageDropTargeted,
            perform: handleCoverImageDrop(providers:)
        )
        .fileImporter(
            isPresented: $isCoverImageImporterPresented,
            allowedContentTypes: [.image],
            allowsMultipleSelection: false,
            onCompletion: handleCoverImageImport
        )
        .modifier(
            SearchFocusRequestModifier(
                focusRequest: focusRequest,
                isActive: isActive,
                isSearchFocused: $isSearchFocused,
                isSavedSearchPopoverPresented: $isSavedSearchPopoverPresented
            )
        )
    }

    private var searchWorkspace: some View {
        GeometryReader { geometry in
            let isCompactList = store.catalog.advancedSearchResultLayout == .row
            let showsFixedPreview = isCompactList && geometry.size.width >= SearchCompactRowMetrics.fixedPreviewThreshold

            HStack(spacing: 0) {
                searchContent(showsPreviewButton: isCompactList && !showsFixedPreview)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                if showsFixedPreview {
                    Divider()
                    previewPane
                        .frame(width: SearchCompactRowMetrics.previewWidth)
                }
            }
            .popover(isPresented: $isPreviewPresented, arrowEdge: .trailing) {
                previewPane
                    .frame(width: SearchCompactRowMetrics.previewWidth, height: min(520, geometry.size.height))
            }
            .onChange(of: showsFixedPreview) { _, showsPreview in
                if showsPreview { isPreviewPresented = false }
            }
            .task(id: isPreviewPresented) {
                guard !isPreviewPresented, let target = previewFocusOnDismiss else { return }
                previewFocusOnDismiss = nil
                guard isActive, previewTarget == target, previewItem != nil else { return }
                focusedCompactRow = target
            }
            .background {
                if isCompactList && !showsFixedPreview {
                    Button {
                        guard isActive, !isSearchFocused, let item = previewItem else { return }
                        showPreview(item)
                    } label: { EmptyView() }
                    .keyboardShortcut(.space, modifiers: [])
                    .disabled(!isActive || isSearchFocused || focusedCompactRow != nil
                        || previewItem == nil || isPreviewPresented)
                    .opacity(0)
                    .allowsHitTesting(false)
                }
            }
        }
    }

    private var previewPane: some View {
        SearchResultPreviewView(
            store: store,
            item: previewItem,
            isTagTranslationEnabled: isTagTranslationEnabled,
            titleDisplayMode: titleDisplayMode,
            localizer: localizer,
            onOpen: openFullDetail
        )
    }

    private func searchContent(showsPreviewButton: Bool) -> some View {
        GeometryReader { proxy in
            let topContentClearance = SearchPinnedHeaderLayout.topContentClearance(
                isPinned: isHeaderPinned,
                measuredHeight: pinnedHeaderHeight
            )
            let isResultContentReady = SearchPinnedHeaderLayout.isResultContentReady(
                isPinned: isHeaderPinned,
                measuredHeight: pinnedHeaderHeight
            )

            ZStack(alignment: .top) {
                SearchResultsView(
                    store: store,
                    snapshot: currentResultPresentationSnapshot,
                    topContentClearance: topContentClearance,
                    bottomContentInset: bottomOverlayHeight + SearchFooterMetrics.contentGap,
                    isTagTranslationEnabled: isTagTranslationEnabled,
                    titleDisplayMode: titleDisplayMode,
                    cardMetrics: cardMetrics,
                    showsMatchContext: store.catalog.isCoverImageSearchActive
                        || !store.catalog.advancedSearchText
                        .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        || store.catalog.advancedSearchScope != .all,
                    selectedBookIDs: selectionState.selectedBookIDs,
                    collectionPopoverState: collectionPopoverState,
                    isSearchActive: isActive,
                    localizer: localizer,
                    onPrimaryActivate: activateItem,
                    onCollectionMember: activateCollectionMember,
                    onCollectionDetails: { presentationID, item in
                        guard store.catalog.advancedSearchResultLayout == .card,
                              collectionPopoverState.presentation?.id == presentationID else { return }
                        openFullDetail(item)
                    },
                    expandedCollectionIDs: expandedCollectionIDs,
                    expandedTagBookIDs: $expandedTagBookIDs,
                    onToggleCollection: toggleCollectionExpansion,
                    onOpenCollectionDetails: openFullDetail,
                    onToggleSelection: toggleSelection,
                    onClearSelection: clearSelection,
                    onToggleMarked: { book in
                        store.catalog.toggleAdvancedSearchMarked(
                            for: book,
                            isTagTranslationEnabled: isTagTranslationEnabled
                        )
                    },
                    showsPreviewButton: showsPreviewButton,
                    focusedCompactRow: $focusedCompactRow,
                    onPreview: updatePreview,
                    onShowPreview: showPreview,
                    onUserScroll: { collectionPopoverState.clear() },
                    onScrollActivity: {
                        if !isHeaderPinned {
                            areSuggestionsDismissed = true
                            isSuggestionHovered = false
                            suggestionSelection.clear()
                        }
                    }
                ) {
                    if !isHeaderPinned {
                        searchHeader
                            .padding(.horizontal, 16)
                            .padding(.top, 12)
                            .padding(.bottom, 12)
                            .zIndex(20)
                    }
                }
                .opacity(isResultContentReady ? 1 : 0)
                .allowsHitTesting(isResultContentReady)
                .zIndex(0)

                if isHeaderPinned {
                    searchHeader
                        .padding(.horizontal, 16)
                        .padding(.top, 12)
                        .padding(.bottom, 12)
                        .background {
                            GeometryReader { headerProxy in
                                Color.clear.preference(
                                    key: SearchPinnedHeaderHeightPreferenceKey.self,
                                    value: headerProxy.size.height
                                )
                            }
                        }
                        .zIndex(20)
                }

                VStack(spacing: 0) {
                    Spacer(minLength: 0)
                    VStack(spacing: 12) {
                        if !selectionState.selectedBookIDs.isEmpty {
                            batchActionBar
                        }

                        searchFooter
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 12)
                    .readSearchBottomOverlayHeight()
                }
                .zIndex(45)

            }
            .overlayPreferenceValue(SearchInputRowAnchorPreferenceKey.self) { inputAnchor in
                GeometryReader { overlayProxy in
                    if shouldShowSuggestions,
                       let inputAnchor,
                       let placement = SearchSuggestionPlacement.make(
                           inputFrame: overlayProxy[inputAnchor],
                           containerSize: overlayProxy.size,
                           footerHeight: bottomOverlayHeight,
                           suggestionCount: store.catalog.advancedSearchSuggestions.count
                       ) {
                        SearchSuggestionList(
                            suggestions: store.catalog.advancedSearchSuggestions,
                            selectedID: suggestionSelection.selectedID,
                            isTagTranslationEnabled: isTagTranslationEnabled,
                            localizer: localizer,
                            maxHeight: placement.height,
                            onSelect: insertSuggestion
                        )
                        .frame(width: placement.width)
                        .onHover { hovering in
                            isSuggestionHovered = hovering
                            if !hovering && !isSearchFocused {
                                areSuggestionsDismissed = true
                                suggestionSelection.clear()
                            }
                        }
                        .position(x: placement.center.x, y: placement.center.y)
                    }
                }
            }
            .onPreferenceChange(SearchPinnedHeaderHeightPreferenceKey.self) { height in
                updatePinnedHeaderHeight(height)
            }
            .onPreferenceChange(SearchBottomOverlayHeightPreferenceKey.self) { height in
                guard height > 0 else { return }
                bottomOverlayHeight = height
            }
        }
        .onChange(of: resultPresentationInput, initial: true) { _, input in
            resultPresentationSnapshot.updateIfNeeded(input: input)
        }
    }

    private func handleSearchAppear() {
        store.catalog.advancedSearchPage = page
        store.catalog.advancedSearchPageSize = pageSize
        if store.catalog.isAdvancedSearchRegexEnabled {
            store.catalog.isAdvancedSearchRegexEnabled = false
        }
        if store.catalog.advancedSearchResults.isEmpty && !store.catalog.isCoverImageSearchActive {
            submitSearch()
        }
    }

    private func updatePinnedHeaderHeight(_ height: CGFloat) {
        guard isHeaderPinned,
              let normalizedHeight = SearchPinnedHeaderLayout.normalizedMeasuredHeight(height) else { return }
        guard pinnedHeaderHeight.map({ abs($0 - normalizedHeight) > 0.5 }) ?? true else { return }
        pinnedHeaderHeight = normalizedHeight
    }

    private var batchActionBar: some View {
        HStack(spacing: 8) {
            Text(localizer.selectedBookCount(selectedBooks.count))
                .font(.caption.weight(.semibold))
                .monospacedDigit()

            Divider().frame(height: 22)

            Button {
                setSelectedMarked(!selectedBooks.allSatisfy { $0.mark })
            } label: {
                let shouldUnmark = selectedBooks.allSatisfy { $0.mark }
                Label(
                    localizer.string(shouldUnmark ? .batchUnmark : .batchMark),
                    systemImage: shouldUnmark ? "heart.slash" : "heart.fill"
                )
            }

            Button {
                setSelectedHidden(!selectedBooks.allSatisfy { $0.isUserHidden })
            } label: {
                let shouldUnhide = selectedBooks.allSatisfy { $0.isUserHidden }
                Label(
                    localizer.string(shouldUnhide ? .batchUnhide : .batchHide),
                    systemImage: shouldUnhide ? "eye" : "eye.slash"
                )
            }

            Button {
                store.catalog.rescanBooks(selectedBooks, localizer: localizer)
            } label: {
                Label(localizer.string(.rescanCover), systemImage: "arrow.triangle.2.circlepath")
            }

            Button {
                store.catalog.startMetadataBatch(
                    books: selectedBooks,
                    configuration: metadataBatchConfiguration,
                    titleDisplayMode: titleDisplayMode,
                    localizer: localizer
                )
            } label: {
                Label(localizer.string(.metadataBatchFetch), systemImage: "arrow.down.doc")
            }
            .disabled(store.catalog.metadataBatchProgress.isActive)

            Menu {
                ForEach(store.catalog.collections) { collection in
                    Button(collection.name) {
                        addSelectedBooks(to: collection)
                    }
                }
            } label: {
                Label(localizer.string(.addToCollection), systemImage: "rectangle.stack.badge.plus")
            }
            .disabled(store.catalog.collections.isEmpty)

            Menu {
                ForEach(store.catalog.versionGroups) { group in
                    Button(store.catalog.books(inVersionGroup: group).first.map { BookTitleFormatter.displayTitle(for: $0, mode: titleDisplayMode) } ?? "\(localizer.string(.versions)) \(group.id)") {
                        addSelectedBooks(toVersionGroup: group)
                    }
                }
            } label: {
                Label(localizer.string(.addToVersionGroup), systemImage: "square.2.layers.3d")
            }
            .disabled(store.catalog.versionGroups.isEmpty)

            Button {
                clearSelection()
            } label: {
                Label(localizer.string(.advancedSearchClear), systemImage: "xmark")
                    .labelStyle(.iconOnly)
            }
        }
        .controlSize(.small)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .searchGlassCapsule()
    }

    private func setSelectedMarked(_ isMarked: Bool) {
        let books = selectedBooks
        let previous = Dictionary(uniqueKeysWithValues: books.map { ($0.id, $0.mark) })
        store.catalog.setMarked(isMarked, for: books)
        undoManager?.registerUndo(withTarget: store.catalog) { target in
            for group in Dictionary(grouping: books, by: { previous[$0.id] ?? false }) {
                target.setMarked(group.key, for: group.value)
            }
        }
        clearSelection()
        if !store.catalog.isCoverImageSearchActive {
            submitSearch(resetPage: false)
        }
    }

    private func setSelectedHidden(_ isHidden: Bool) {
        let books = selectedBooks
        let previous = Dictionary(uniqueKeysWithValues: books.map { ($0.id, $0.isUserHidden) })
        store.catalog.setUserHidden(isHidden, for: books)
        undoManager?.registerUndo(withTarget: store.catalog) { target in
            for group in Dictionary(grouping: books, by: { previous[$0.id] ?? false }) {
                target.setUserHidden(group.key, for: group.value)
            }
        }
        clearSelection()
        if !store.catalog.isCoverImageSearchActive {
            submitSearch(resetPage: false)
        }
    }

    private func addSelectedBooks(to collection: BookCollection) {
        let books = selectedBooks
        if books.contains(where: { store.catalog.seriesIDs(for: $0).count > 1 }) {
            seriesConflictConfirmation = SeriesConflictConfirmation(collectionName: collection.name) {
                applySeriesMove(books, to: collection)
            }
        } else {
            applySeriesMove(books, to: collection)
        }
    }

    private func applySeriesMove(_ books: [LibraryBook], to collection: BookCollection) {
        var seenGroups = Set<Int64>()
        let previous = books.compactMap { book -> (book: LibraryBook, collectionID: Int64?)? in
            let current = store.catalog.book(id: book.id) ?? book
            if let groupID = current.versionGroupID, !seenGroups.insert(groupID).inserted { return nil }
            let series = store.catalog.seriesIDs(for: current)
            guard series.count <= 1, series.first != collection.databaseID else { return nil }
            return (current, series.first)
        }
        store.catalog.addBooks(books, to: collection)
        if !previous.isEmpty {
            undoManager?.registerUndo(withTarget: store.catalog) { target in
                for entry in previous {
                    let current = target.book(id: entry.book.id) ?? entry.book
                    if let collectionID = entry.collectionID,
                       let oldCollection = target.collection(id: String(collectionID)) {
                        target.addBook(current, to: oldCollection)
                    } else if let currentCollection = target.collection(id: collection.id) {
                        target.removeBook(current, from: currentCollection)
                    }
                }
            }
        }
        clearSelection()
    }

    private func addSelectedBooks(toVersionGroup group: BookVersionGroup) {
        let books = selectedBooks
        let previous = books.map { book in
            (book: book, versionGroupID: book.versionGroupID, wasPrimary: book.isPrimaryVersion)
        }
        store.catalog.addBooks(books, toVersionGroup: group)
        undoManager?.registerUndo(withTarget: store.catalog) { target in
            for entry in previous {
                let current = target.book(id: entry.book.id) ?? entry.book
                target.removeBookFromVersionGroup(current)
                if let versionGroupID = entry.versionGroupID,
                   let oldGroup = target.versionGroup(id: String(versionGroupID)) {
                    target.addBook(current, toVersionGroup: oldGroup)
                    if entry.wasPrimary, let restored = target.book(id: entry.book.id) {
                        target.setPrimaryVersion(restored)
                    }
                }
            }
        }
        clearSelection()
    }

    private func activateItem(_ item: LibraryDisplayItem) {
        dismissSearchInteractions()
        if SearchPrimaryActivationPolicy.opensCollectionPopover(for: item, layout: store.catalog.advancedSearchResultLayout),
           case .collection(let collection) = item {
            collectionPopoverState.open(collectionID: collection.id, context: collectionPopoverContext)
            return
        }
        if store.catalog.advancedSearchResultLayout == .row {
            updatePreview(item)
        }
        openFullDetail(item)
    }

    private func activateCollectionMember(
        presentationID: UUID,
        book: LibraryBook,
        position: SearchCollectionBrowsePosition
    ) {
        let memberID = position.focusedMemberID ?? book.id
        guard store.catalog.advancedSearchResultLayout == .card,
              let collectionID = collectionPopoverState.presentation?.collectionID,
              let member = pageItems.first(where: { $0.id == "collection.\(collectionID)" })?
                .books.first(where: { $0.id == memberID }) else { return }
        guard member.id == book.id, let target = store.catalog.book(id: book.id),
              collectionPopoverState.activateMember(presentationID: presentationID, bookID: memberID, position: position)
        else { return }
        onSelect(.book(target))
    }

    private func toggleCollectionExpansion(_ id: BookCollection.ID) {
        if !expandedCollectionIDs.insert(id).inserted {
            expandedCollectionIDs.remove(id)
            if previewTarget != nil && previewItem == nil { clearPreview() }
        }
    }

    private func reconcileResultInteractions(in items: [SearchDisplayItem]) {
        expandedCollectionIDs.formIntersection(items.compactMap {
            if case .collection(let collection) = $0.item { return collection.id }
            return nil
        })
        expandedTagBookIDs.formIntersection(items.compactMap {
            if case .book(let book) = $0.item { return book.id }
            return nil
        })
        if previewTarget != nil && previewItem == nil { clearPreview() }
    }

    private func toggleSelection(_ item: LibraryDisplayItem) {
        selectionState.toggleSelection(item)
    }

    private func clearSelection() {
        selectionState.clear()
    }

    private func openSelectedBook() {
        guard isActive, !isSearchFocused, collectionPopoverState.presentation == nil else { return }
        if let previewItem {
            openFullDetail(previewItem)
        } else if let book = selectedBooks.first {
            openFullDetail(.book(book))
        }
    }

    private func updatePreview(_ item: LibraryDisplayItem) {
        guard isActive, store.catalog.advancedSearchResultLayout == .row, !isPreviewPresented else { return }
        previewTarget = SearchPreviewTarget(item: item)
    }

    private func showPreview(_ item: LibraryDisplayItem) {
        updatePreview(item)
        guard previewItem != nil else { return }
        previewFocusOnDismiss = previewTarget
        isPreviewPresented = true
    }

    private func clearPreview() {
        previewFocusOnDismiss = nil
        isPreviewPresented = false
        previewTarget = nil
        focusedCompactRow = nil
    }

    private func openFullDetail(_ item: LibraryDisplayItem) {
        previewFocusOnDismiss = nil
        isPreviewPresented = false
        dismissSearchInteractions()
        onSelect(item)
    }

    private var searchHeader: some View {
        Group {
            if #available(macOS 26.0, *) {
                GlassEffectContainer(spacing: 12) {
                    searchHeaderContent
                }
            } else {
                searchHeaderContent
            }
        }
    }

    private var searchHeaderContent: some View {
        VStack(spacing: 12) {
            searchSurface
                .zIndex(1)
            if isFacetPanelExpanded {
                facetSurface
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .zIndex(0)
            }
        }
    }

    private var searchSurface: some View {
        VStack(alignment: .leading, spacing: 10) {
            searchInputRow
            searchToolbarRow
        }
        .padding(14)
        .searchHeaderGlassPanel(cornerRadius: 22)
    }

    private var searchInputRow: some View {
        HStack(alignment: .center, spacing: 10) {
            savedSearchSplitButton

            NativeSearchField(
                text: catalogBinding(\.advancedSearchText),
                placeholder: localizer.string(.advancedSearchPlaceholder),
                activeTokenRange: catalogBinding(\.advancedSearchActiveTokenRange),
                isActive: isActive,
                onCommit: commitSearchOrSuggestion,
                onMoveSuggestion: moveSuggestionSelection,
                onDismissSuggestions: dismissSuggestions
            )
            .focused($isSearchFocused)
            .frame(minWidth: 0, maxWidth: .infinity)
            .frame(height: SearchInputMetrics.controlSize)
            .anchorPreference(key: SearchInputRowAnchorPreferenceKey.self, value: .bounds) { $0 }

            Button(action: { submitSearch() }) {
                Label(localizer.string(.advancedSearch), systemImage: "magnifyingglass")
                    .labelStyle(.titleAndIcon)
                    .padding(.horizontal, 14)
                    .frame(height: SearchInputMetrics.controlSize)
            }
            .buttonStyle(SearchSplitSegmentButtonStyle(height: SearchInputMetrics.controlSize))
            .searchGlassCapsule()
            .accessibilityLabel(localizer.string(.advancedSearch))

            Button {
                isCoverImageImporterPresented = true
            } label: {
                Label(localizer.string(.coverImageSearch), systemImage: "photo.badge.magnifyingglass")
                    .labelStyle(.iconOnly)
                    .frame(width: SearchInputMetrics.controlSize, height: SearchInputMetrics.controlSize)
            }
            .buttonStyle(SearchSplitSegmentButtonStyle(height: SearchInputMetrics.controlSize))
            .searchGlassCapsule()
            .help(localizer.string(.coverImageSearchChoose))
            .accessibilityLabel(localizer.string(.coverImageSearchChoose))
        }
    }

    private var coverImageSearchStatusRow: some View {
        HStack(spacing: 10) {
            Image(systemName: "photo.badge.magnifyingglass")
                .foregroundStyle(Color.accentColor)

            Text(store.catalog.coverImageSearchFileName ?? localizer.string(.coverImageSearch))
                .font(.caption.weight(.semibold))
                .lineLimit(1)
                .truncationMode(.middle)

            if store.catalog.isCoverImageSearchLoading || store.catalog.isUpdatingCoverVectors {
                ProgressView()
                    .controlSize(.small)
            }

            if let message = store.catalog.coverImageSearchMessage {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(store.catalog.coverImageSearchNeedsIndexUpdate ? .orange : .secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }

            Spacer(minLength: 8)

            if store.catalog.coverImageSearchNeedsIndexUpdate
                || store.catalog.coverVectorStats.missingCount > 0
                || store.catalog.coverVectorStats.staleCount > 0 {
                Button(localizer.string(.coverVectorsUpdate)) {
                    store.catalog.updateCoverImageSearchIndex(localizer: localizer)
                }
                .disabled(store.catalog.isUpdatingCoverVectors)
            }

            Button(localizer.string(.coverImageSearchReselect)) {
                isCoverImageImporterPresented = true
            }

            Button {
                clearSelection()
                store.catalog.clearCoverImageSearch(
                    isTagTranslationEnabled: isTagTranslationEnabled
                )
            } label: {
                Label(localizer.string(.coverImageSearchClear), systemImage: "xmark.circle.fill")
                    .labelStyle(.iconOnly)
            }
            .help(localizer.string(.coverImageSearchClear))
            .accessibilityLabel(localizer.string(.coverImageSearchClear))
        }
        .controlSize(.small)
        .frame(height: 28)
    }

    private var searchFooter: some View {
        FloatingPaginationDock(
            page: $page,
            pageSize: $pageSize,
            itemCount: store.catalog.advancedSearchTotalCount,
            showsPagination: FloatingPaginationPresentation.showsPagination(
                itemCount: store.catalog.advancedSearchTotalCount
            ) && (!store.catalog.isCoverImageSearchActive || isCollectionMembersExpanded),
            showsTrailingPanel: store.catalog.advancedSearchResultLayout == .card,
            localizer: localizer,
            resetsPageOnPageSizeChange: false
        ) {
            searchFooterStatus
        } trailingContent: {
            CardSizeSliderControl(cardWidth: $cardWidth)
        } compactActions: {
            searchFooterCompactActions
        }
    }

    private var searchFooterStatus: some View {
        HStack(spacing: 8) {
            Text(localizer.searchResultCount(store.catalog.advancedSearchTotalCount))
                .font(.callout)
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .lineLimit(1)

            if store.catalog.isAdvancedSearchLoading || store.catalog.isCoverImageSearchLoading {
                ProgressView()
                    .controlSize(.small)
                    .help(localizer.string(.advancedSearch))
            }
        }
    }

    @ViewBuilder
    private var searchFooterCompactActions: some View {
        Text(localizer.searchResultCount(store.catalog.advancedSearchTotalCount))

        if store.catalog.isAdvancedSearchLoading || store.catalog.isCoverImageSearchLoading {
            ProgressView()
                .controlSize(.small)
                .accessibilityLabel(localizer.string(.advancedSearch))
        }

        if store.catalog.advancedSearchResultLayout == .card {
            Divider()

            Button {
                adjustCardWidth(by: BookCardMetrics.step)
            } label: {
                Label(localizer.string(.increaseCardSize), systemImage: "plus.magnifyingglass")
            }
            .disabled(cardWidth >= BookCardMetrics.maximumWidth)

            Button {
                adjustCardWidth(by: -BookCardMetrics.step)
            } label: {
                Label(localizer.string(.decreaseCardSize), systemImage: "minus.magnifyingglass")
            }
            .disabled(cardWidth <= BookCardMetrics.minimumWidth)
        }
    }

    private func adjustCardWidth(by delta: Int) {
        cardWidth = BookCardMetrics.normalizedWidth(cardWidth + delta)
    }

    private var viewCommandContext: NyaEHViewCommandContext {
        NyaEHViewCommandContext(
            canIncreaseCardSize: store.catalog.advancedSearchResultLayout == .card && cardWidth < BookCardMetrics.maximumWidth,
            increaseCardSize: { cardWidth = BookCardMetrics.normalizedWidth(cardWidth + BookCardMetrics.step) },
            canDecreaseCardSize: store.catalog.advancedSearchResultLayout == .card && cardWidth > BookCardMetrics.minimumWidth,
            decreaseCardSize: { cardWidth = BookCardMetrics.normalizedWidth(cardWidth - BookCardMetrics.step) },
            layout: store.catalog.advancedSearchResultLayout,
            setLayout: { store.catalog.advancedSearchResultLayout = $0 },
            sortStrategy: nil,
            setSortStrategy: { _ in },
            searchResultSortKey: store.catalog.advancedSearchSortKey,
            setSearchResultSortKey: { store.catalog.advancedSearchSortKey = $0 },
            sortDirection: store.catalog.advancedSearchSortDirection,
            setSortDirection: { store.catalog.advancedSearchSortDirection = $0 }
        )
    }

    private var searchToolbarRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            if store.catalog.isCoverImageSearchActive {
                coverImageSearchStatusRow
            } else {
                HStack(spacing: 8) {
                    searchScopeMenu

                    SearchModeControl(
                        selection: catalogBinding(\.advancedSearchMode),
                        localizer: localizer,
                        height: SearchHeaderMenuMetrics.height
                    )
                    .layoutPriority(1)

                    SearchTokenStrip(
                        tokens: store.catalog.advancedSearchParsedQuery.tokenHighlights
                    ) { token in
                        prepareFacetSearch()
                        store.catalog.cycleAdvancedSearchToken(
                            token,
                            isTagTranslationEnabled: isTagTranslationEnabled
                        )
                    }
                    .frame(minWidth: 0, maxWidth: .infinity)

                    facetPanelToggleButton
                }
            }

            if let error = store.catalog.advancedSearchError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        }
    }

    private var searchScopeMenu: some View {
        NativeSearchScopeMenu(
            selection: catalogBinding(\.advancedSearchScope),
            isActive: isActive,
            localizer: localizer,
            selectionAction: scopeMenuSelection
        )
        .layoutPriority(1)
    }

    private var savedSearchSplitButton: some View {
        HStack(spacing: 0) {
            Button(action: saveCurrentSearch) {
                Image(systemName: "bookmark.fill")
                    .frame(width: SearchInputMetrics.savedSearchPrimaryWidth)
            }
            .buttonStyle(SearchSplitSegmentButtonStyle(height: SearchInputMetrics.controlSize))
            .help(localizer.string(.saveSearch))
            .accessibilityLabel(localizer.string(.saveSearch))

            Rectangle()
                .fill(.primary.opacity(0.12))
                .frame(width: 1, height: 28)

            Button {
                isSavedSearchPopoverPresented.toggle()
            } label: {
                Image(systemName: "chevron.down")
                    .font(.caption.weight(.semibold))
                    .rotationEffect(.degrees(isSavedSearchPopoverPresented ? 180 : 0))
                    .frame(width: SearchInputMetrics.savedSearchMenuWidth)
            }
            .buttonStyle(SearchSplitSegmentButtonStyle(height: SearchInputMetrics.controlSize))
            .help(localizer.string(.savedSearches))
            .accessibilityLabel(localizer.string(.savedSearches))
        }
        .frame(height: SearchInputMetrics.controlSize)
        .clipShape(Capsule())
        .searchGlassCapsule()
        .fixedSize()
        .popover(isPresented: $isSavedSearchPopoverPresented, arrowEdge: .bottom) {
            SavedSearchPopoverView(
                savedSearches: preferences.savedSearches,
                localizer: localizer,
                onApply: { saved in
                    isSavedSearchPopoverPresented = false
                    applySavedSearch(saved)
                },
                onRemove: { saved in
                    preferences.removeSavedSearch(id: saved.id)
                }
            )
        }
    }

    private func saveCurrentSearch() {
        let trimmed = store.catalog.advancedSearchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = trimmed.isEmpty
            ? localizer.string(store.catalog.advancedSearchScope.titleKey)
            : String(trimmed.prefix(42))
        let saved = SavedBookSearch(
            name: name,
            query: store.catalog.advancedSearchText,
            scope: store.catalog.advancedSearchScope,
            mode: store.catalog.advancedSearchMode,
            isRegexEnabled: store.catalog.isAdvancedSearchRegexEnabled,
            sortKey: store.catalog.advancedSearchSortKey,
            sortDirection: store.catalog.advancedSearchSortDirection,
            layout: store.catalog.advancedSearchResultLayout
        )
        preferences.saveSearch(saved)
        onFeedback(localizer.savedSearchConfirmation(name: saved.name))
    }

    private func applySavedSearch(_ saved: SavedBookSearch) {
        scopeMenuSelection.cancel()
        store.catalog.advancedSearchText = saved.query
        store.catalog.advancedSearchScope = saved.scope
        store.catalog.advancedSearchMode = saved.mode
        store.catalog.isAdvancedSearchRegexEnabled = saved.isRegexEnabled
        store.catalog.advancedSearchSortKey = saved.sortKey
        store.catalog.advancedSearchSortDirection = saved.sortDirection
        store.catalog.advancedSearchResultLayout = saved.layout
        submitSearch()
    }

    private var facetPanelToggleButton: some View {
        Button {
            toggleFacetPanel()
        } label: {
            Image(systemName: isFacetPanelExpanded ? "chevron.up" : "chevron.down")
                .font(.caption.weight(.medium))
                .frame(width: SearchHeaderMenuMetrics.height, height: SearchHeaderMenuMetrics.height)
        }
        .buttonStyle(SearchSplitSegmentButtonStyle(height: SearchHeaderMenuMetrics.height))
        .searchGlassCapsule()
        .help(localizer.string(isFacetPanelExpanded ? .advancedSearchCollapseTags : .advancedSearchExpandTags))
        .accessibilityLabel(localizer.string(isFacetPanelExpanded ? .advancedSearchCollapseTags : .advancedSearchExpandTags))
    }

    private var facetSurface: some View {
        VStack(spacing: 10) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(SearchNamespace.facetNamespaces, id: \.self) { namespace in
                        NamespaceTab(
                            title: searchTagNamespaceTitle(namespace, localizer: localizer),
                            count: store.catalog.advancedSearchFacetsByNamespace[namespace]?.count ?? 0,
                            isSelected: namespace == selectedNamespace
                        )
                        .onHover { hovering in
                            if hovering {
                                selectedNamespace = namespace
                            }
                        }
                        .onTapGesture {
                            selectedNamespace = namespace
                        }
                    }
                }
                .padding(.horizontal, 4)
                .padding(.top, 2)
            }

            ScrollView {
                LazyVGrid(
                    columns: [
                        GridItem(.adaptive(minimum: 168, maximum: 260), spacing: 8, alignment: .leading)
                    ],
                    alignment: .leading,
                    spacing: 8
                ) {
                    ForEach(activeFacets) { facet in
                        SearchTagPill(facet: facet)
                            .onTapGesture {
                                prepareFacetSearch()
                                store.catalog.cycleAdvancedSearchTag(
                                    facet,
                                    isTagTranslationEnabled: isTagTranslationEnabled
                                )
                            }
                            .contextMenu {
                                Button(localizer.string(facet.tag.isFollowed ? .tagUnfollow : .tagFollow)) {
                                    store.catalog.setFollowed(
                                        !facet.tag.isFollowed,
                                        for: facet.tag,
                                        isTagTranslationEnabled: isTagTranslationEnabled
                                    )
                                }

                                Divider()

                                Button(localizer.string(.advancedSearchInclude)) {
                                    prepareFacetSearch()
                                    store.catalog.setAdvancedSearchTag(
                                        facet,
                                        state: .selected,
                                        isTagTranslationEnabled: isTagTranslationEnabled
                                    )
                                }
                                .disabled(!facet.isEnabled && facet.state != .selected)

                                Button(localizer.string(.advancedSearchExclude)) {
                                    prepareFacetSearch()
                                    store.catalog.setAdvancedSearchTag(
                                        facet,
                                        state: .excluded,
                                        isTagTranslationEnabled: isTagTranslationEnabled
                                    )
                                }

                                Button(localizer.string(.advancedSearchClear)) {
                                    prepareFacetSearch()
                                    store.catalog.setAdvancedSearchTag(
                                        facet,
                                        state: .unselected,
                                        isTagTranslationEnabled: isTagTranslationEnabled
                                    )
                                }
                            }
                            .disabled(!facet.isEnabled && facet.state == .unselected)
                    }
                }
                .padding(.bottom, 4)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(height: 188)
        }
        .padding(12)
        .searchHeaderGlassPanel(cornerRadius: 22)
    }

    private var shouldShowSuggestions: Bool {
        isActive
            && (isSearchFocused || isSuggestionHovered)
            && !areSuggestionsDismissed
            && !store.catalog.advancedSearchSuggestions.isEmpty
            && !store.catalog.advancedSearchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func insertSuggestion(_ suggestion: SearchTagSuggestion) {
        store.catalog.insertAdvancedSearchSuggestion(
            suggestion,
            activeRange: store.catalog.advancedSearchActiveTokenRange
        )
        suggestionSelection.clear()
        areSuggestionsDismissed = true
        isSearchFocused = true
    }

    private func moveSuggestionSelection(_ direction: SearchSuggestionSelection.Direction) -> Bool {
        guard shouldShowSuggestions else { return false }
        suggestionSelection.move(direction, among: store.catalog.advancedSearchSuggestions.map(\.id))
        return true
    }

    private func dismissSuggestions() -> Bool {
        guard shouldShowSuggestions else { return false }
        areSuggestionsDismissed = true
        suggestionSelection.clear()
        return true
    }

    private func commitSearchOrSuggestion() {
        if shouldShowSuggestions,
           let selectedID = suggestionSelection.selectedID,
           let suggestion = store.catalog.advancedSearchSuggestions.first(where: { $0.id == selectedID }) {
            insertSuggestion(suggestion)
        } else {
            submitSearch()
        }
    }

    private func handleCoverImageImport(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            guard let imageURL = urls.first else { return }
            beginCoverImageSearch(at: imageURL)
        case .failure(let error):
            store.catalog.advancedSearchError = error.localizedDescription
        }
    }

    private func handleCoverImageDrop(providers: [NSItemProvider]) -> Bool {
        guard !providers.isEmpty else { return false }
        let fileName = providers.lazy.compactMap(\.suggestedName).first
            ?? localizer.string(.coverImageSearch)

        Task { @MainActor in
            do {
                let data = try await CoverImageSearchDropLoader.imageData(from: providers)
                beginCoverImageSearch(data: data, fileName: fileName)
            } catch {
                store.catalog.advancedSearchError = String(
                    format: localizer.string(.coverImageSearchDropFailed),
                    error.localizedDescription
                )
            }
        }
        return true
    }

    private func beginCoverImageSearch(at imageURL: URL) {
        resetResultInteractions()
        store.catalog.searchByCoverImage(at: imageURL, localizer: localizer)
        page = 1
    }

    private func beginCoverImageSearch(data: Data, fileName: String) {
        resetResultInteractions()
        store.catalog.searchByCoverImage(
            data: data,
            fileName: fileName,
            localizer: localizer
        )
        page = 1
    }

    private func resetResultInteractions() {
        clearPreview()
        collectionPopoverState.clear()
        expandedCollectionIDs.removeAll()
        expandedTagBookIDs.removeAll()
        clearSelection()
    }

    private func submitSearch(resetPage: Bool = true) {
        resetResultInteractions()
        areSuggestionsDismissed = true
        suggestionSelection.clear()
        if resetPage {
            page = 1
        }
        store.catalog.advancedSearchPage = page
        store.catalog.advancedSearchPageSize = pageSize
        store.catalog.submitAdvancedSearch(isTagTranslationEnabled: isTagTranslationEnabled)
    }

    private func prepareFacetSearch() {
        resetResultInteractions()
        page = 1
        store.catalog.advancedSearchPage = 1
        areSuggestionsDismissed = true
        suggestionSelection.clear()
    }

    private func dismissSearchInteractions() {
        collectionPopoverState.clear()
        scopeMenuSelection.cancel()
        isSearchFocused = false
        areSuggestionsDismissed = true
        suggestionSelection.clear()
        isSavedSearchPopoverPresented = false
    }

    private func applyAdvancedSearchSortChange() {
        page = 1
        store.catalog.advancedSearchPage = 1
        guard AdvancedSearchInteractionPolicy.shouldSubmitOrdinarySearch(
            isCoverImageSearchActive: store.catalog.isCoverImageSearchActive
        ) else { return }
        submitSearch()
    }

    private func toggleFacetPanel() {
        if accessibilityReduceMotion {
            isFacetPanelExpanded.toggle()
        } else {
            withAnimation(.snappy(duration: 0.24)) {
                isFacetPanelExpanded.toggle()
            }
        }
    }


}

private struct SearchFocusRequestModifier: ViewModifier {
    let focusRequest: Int
    let isActive: Bool
    @FocusState.Binding var isSearchFocused: Bool
    @Binding var isSavedSearchPopoverPresented: Bool

    func body(content: Content) -> some View {
        content
            .onChange(of: isActive) { _, isActive in
                guard !isActive else { return }
                isSearchFocused = false
                isSavedSearchPopoverPresented = false
            }
            .task(id: focusRequest) {
                guard isActive, focusRequest > 0 else { return }
                await Task.yield()
                isSearchFocused = true
            }
    }
}

private enum SearchFooterMetrics {
    static let defaultOverlayHeight: CGFloat = 70
    static let contentGap: CGFloat = 8
}

private enum SearchInputMetrics {
    static let controlSize: CGFloat = 44
    static let savedSearchPrimaryWidth: CGFloat = 42
    static let savedSearchMenuWidth: CGFloat = 30
}

private enum SearchHeaderMenuMetrics {
    static let height: CGFloat = 34
}

private struct SearchSplitSegmentButtonStyle: ButtonStyle {
    let height: CGFloat

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .frame(height: height)
            .contentShape(Rectangle())
            .background(.primary.opacity(configuration.isPressed ? 0.10 : 0))
            .foregroundStyle(.primary)
    }
}

private struct SavedSearchPopoverView: View {
    let savedSearches: [SavedBookSearch]
    let localizer: AppLocalizer
    let onApply: (SavedBookSearch) -> Void
    let onRemove: (SavedBookSearch) -> Void

    @State private var hoveredSearchID: SavedBookSearch.ID?

    var body: some View {
        Group {
            if savedSearches.isEmpty {
                Label(localizer.string(.noSavedSearches), systemImage: "bookmark")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 52)
            } else {
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(savedSearches) { saved in
                            savedSearchRow(saved)
                        }
                    }
                }
                .frame(height: min(max(CGFloat(savedSearches.count) * 40, 44), 320))
            }
        }
        .padding(8)
        .frame(width: 300)
    }

    private func savedSearchRow(_ saved: SavedBookSearch) -> some View {
        let isHovered = hoveredSearchID == saved.id

        return HStack(spacing: 4) {
            Button {
                onApply(saved)
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "bookmark")
                        .foregroundStyle(.secondary)
                        .frame(width: 16)

                    Text(saved.name)
                        .lineLimit(1)
                        .truncationMode(.tail)

                    Spacer(minLength: 8)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(saved.name)

            Button(role: .destructive) {
                hoveredSearchID = nil
                onRemove(saved)
            } label: {
                Image(systemName: "trash")
                    .frame(width: 26, height: 26)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.red)
            .opacity(isHovered ? 1 : 0)
            .allowsHitTesting(isHovered)
            .help(localizer.string(.remove))
            .accessibilityHidden(!isHovered)
        }
        .padding(.leading, 8)
        .padding(.trailing, 5)
        .frame(height: 38)
        .background(
            .primary.opacity(isHovered ? 0.07 : 0),
            in: RoundedRectangle(cornerRadius: 8, style: .continuous)
        )
        .contentShape(Rectangle())
        .onHover { isInside in
            if isInside {
                hoveredSearchID = saved.id
            } else if hoveredSearchID == saved.id {
                hoveredSearchID = nil
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityAction(named: Text(localizer.string(.remove))) {
            onRemove(saved)
        }
    }
}

private struct SearchPinnedHeaderHeightPreferenceKey: PreferenceKey {
    static let defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

private struct SearchInputRowAnchorPreferenceKey: PreferenceKey {
    static let defaultValue: Anchor<CGRect>? = nil

    static func reduce(value: inout Anchor<CGRect>?, nextValue: () -> Anchor<CGRect>?) {
        value = nextValue() ?? value
    }
}

private struct SearchBottomOverlayHeightPreferenceKey: PreferenceKey {
    static let defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

struct SearchSuggestionPlacement: Equatable {
    let left: CGFloat
    let top: CGFloat
    let width: CGFloat
    let height: CGFloat

    var center: CGPoint {
        CGPoint(x: left + width / 2, y: top + height / 2)
    }

    static func make(
        inputFrame: CGRect,
        containerSize: CGSize,
        footerHeight: CGFloat,
        suggestionCount: Int
    ) -> Self? {
        guard inputFrame.minX.isFinite,
              inputFrame.maxY.isFinite,
              inputFrame.width > 0,
              containerSize.width.isFinite,
              containerSize.height.isFinite,
              containerSize.width > 32,
              suggestionCount > 0 else {
            return nil
        }

        let margin: CGFloat = 16
        let gap: CGFloat = 8
        let top = inputFrame.maxY + gap
        let width = min(560, inputFrame.width, containerSize.width - margin * 2)
        let left = min(max(inputFrame.minX, margin), containerSize.width - margin - width)
        let bottom = containerSize.height - max(margin, footerHeight + margin)
        let height = min(CGFloat(suggestionCount) * 38 + 12, 260, bottom - top)
        guard height >= 38 else { return nil }
        return Self(left: left, top: top, width: width, height: height)
    }
}

enum SearchPinnedHeaderLayout {
    static func normalizedMeasuredHeight(_ height: CGFloat) -> CGFloat? {
        guard height.isFinite, height > 0 else { return nil }
        return ceil(height)
    }

    static func topContentClearance(isPinned: Bool, measuredHeight: CGFloat?) -> CGFloat {
        guard isPinned, let measuredHeight else { return 0 }
        return measuredHeight
    }

    static func isResultContentReady(isPinned: Bool, measuredHeight: CGFloat?) -> Bool {
        !isPinned || measuredHeight != nil
    }
}

struct SearchSuggestionSelection {
    enum Direction {
        case previous
        case next
    }

    private(set) var selectedID: SearchTagSuggestion.ID?

    mutating func clear() {
        selectedID = nil
    }

    mutating func reconcile(with ids: [SearchTagSuggestion.ID]) {
        if let selectedID, !ids.contains(selectedID) {
            clear()
        }
    }

    mutating func move(_ direction: Direction, among ids: [SearchTagSuggestion.ID]) {
        guard !ids.isEmpty else {
            clear()
            return
        }
        guard let selectedID, let index = ids.firstIndex(of: selectedID) else {
            self.selectedID = direction == .next ? ids[0] : ids[ids.count - 1]
            return
        }
        let delta = direction == .next ? 1 : -1
        self.selectedID = ids[(index + delta + ids.count) % ids.count]
    }
}

struct SearchResultPresentationInput: Equatable {
    var items: [SearchDisplayItem]
    var layout: SearchResultLayout
}

struct SearchResultPresentationSnapshot: Equatable {
    static let empty = SearchResultPresentationSnapshot(
        input: SearchResultPresentationInput(items: [], layout: .card)
    )

    var input: SearchResultPresentationInput
    var entries: [SearchResultPresentationEntry]
    var generation: UUID

    init(input: SearchResultPresentationInput) {
        self.input = input
        entries = input.items.enumerated().map { index, item in
            SearchResultPresentationEntry(index: index, source: item)
        }
        generation = UUID()
    }

    @discardableResult
    mutating func updateIfNeeded(input: SearchResultPresentationInput) -> Bool {
        guard self.input != input else { return false }
        self = SearchResultPresentationSnapshot(input: input)
        return true
    }
}

struct SearchResultPresentationEntry: Identifiable, Equatable {
    let index: Int
    let source: SearchDisplayItem

    var id: String { "entity.\(source.id)" }
}

private struct SearchResultsView<TopContent: View>: View {
    let store: SearchStore
    let snapshot: SearchResultPresentationSnapshot
    let topContentClearance: CGFloat
    let bottomContentInset: CGFloat
    let isTagTranslationEnabled: Bool
    let titleDisplayMode: BookTitleDisplayMode
    let cardMetrics: BookCardMetrics
    let showsMatchContext: Bool
    let selectedBookIDs: Set<LibraryBook.ID>
    let collectionPopoverState: SearchCollectionPopoverState
    let isSearchActive: Bool
    let localizer: AppLocalizer
    let onPrimaryActivate: (LibraryDisplayItem) -> Void
    let onCollectionMember: (UUID, LibraryBook, SearchCollectionBrowsePosition) -> Void
    let onCollectionDetails: (UUID, LibraryDisplayItem) -> Void
    let expandedCollectionIDs: Set<BookCollection.ID>
    @Binding var expandedTagBookIDs: Set<LibraryBook.ID>
    let onToggleCollection: (BookCollection.ID) -> Void
    let onOpenCollectionDetails: (LibraryDisplayItem) -> Void
    let onToggleSelection: (LibraryDisplayItem) -> Void
    let onClearSelection: () -> Void
    let onToggleMarked: (LibraryBook) -> Void
    let showsPreviewButton: Bool
    let focusedCompactRow: FocusState<SearchPreviewTarget?>.Binding
    let onPreview: (LibraryDisplayItem) -> Void
    let onShowPreview: (LibraryDisplayItem) -> Void
    let onUserScroll: () -> Void
    let onScrollActivity: () -> Void
    @ViewBuilder let topContent: () -> TopContent

    @State private var scrollActivityState = SearchScrollActivityState()
    @State private var coverPrefetchSessionID = UUID()
    @State private var visibleCollectionIDs: Set<BookCollection.ID> = []

    private var layout: SearchResultLayout { snapshot.input.layout }

    private var coverPrefetchGeneration: SearchCoverPrefetchGeneration {
        SearchCoverPrefetchGeneration(
            resultGeneration: snapshot.generation,
            layout: layout.rawValue,
            cardWidth: cardMetrics.width
        )
    }

    private var coverPrefetchRequestsByItem: [[CoverPrefetchRequest]] {
        let pixelBucket: Int
        switch layout {
        case .card:
            let scale = CGFloat(NSScreen.main?.backingScaleFactor ?? 2)
            pixelBucket = CoverImageLoader.pixelBucket(for: cardMetrics.coverHeight * scale)
        case .row:
            pixelBucket = 128
        case .expandedRow:
            pixelBucket = 512
        }

        return snapshot.entries.map { entry in
            let books: [LibraryBook]
            switch entry.source.item {
            case .book(let book):
                books = [book]
            case .collection(let collectionItem):
                books = layout == .card ? Array(collectionItem.books.prefix(3)) : []
            }
            var seenPaths: Set<String> = []
            return books.compactMap { book in
                guard let path = book.coverPath,
                      seenPaths.insert(path).inserted else {
                    return nil
                }
                return CoverPrefetchRequest(path: path, pixelBucket: pixelBucket)
            }
        }
    }

    var body: some View {
        GeometryReader { proxy in
            ScrollViewReader { scrollProxy in
                resultsScrollView(containerSize: proxy.size)
                    .coordinateSpace(name: "SearchResultsViewport")
                    .onChange(of: collectionPopoverState.restoreRequestID) { _, requestID in
                        guard requestID != nil,
                              let session = collectionPopoverState.returnSession,
                              !visibleCollectionIDs.contains(session.collectionID) else { return }
                        // 原锚点因窗口缩放移出可见区时才定位；程序滚动不会取消这次恢复。
                        scrollProxy.scrollTo(session.anchorID, anchor: .center)
                    }
                    .task(id: coverPrefetchGeneration) {
                        if SearchScrollBenchmarkConfiguration.isEnabled {
                            await runScrollBenchmark(using: scrollProxy)
                        }
                    }
            }
        }
    }

    private func resultsScrollView(containerSize: CGSize) -> some View {
        ScrollView {
                if topContentClearance > 0 {
                    Color.clear
                        .frame(height: topContentClearance)
                }

                topContent()
                    .zIndex(20)

                ZStack(alignment: .top) {
                    Color.clear
                        .contentShape(Rectangle())
                        .onTapGesture(perform: onClearSelection)

                    if snapshot.input.items.isEmpty {
                        ContentUnavailableView(
                            localizer.string(.advancedSearchNoResults),
                            systemImage: "magnifyingglass",
                            description: Text(localizer.string(.advancedSearchNoResultsDescription))
                        )
                        .frame(maxWidth: .infinity, minHeight: 360)
                        .padding(24)
                    } else {
                        content(viewport: containerSize)
                    }
                }
                .frame(maxWidth: .infinity, minHeight: containerSize.height, alignment: .top)
                .zIndex(0)

                if bottomContentInset > 0 {
                    Color.clear
                        .frame(height: bottomContentInset)
                }
        }
        .onScrollPhaseChange { _, phase in
            if phase == .tracking || phase == .interacting || phase == .decelerating {
                onUserScroll()
            }
            let isScrolling = phase != .idle
            guard scrollActivityState.update(isScrolling: isScrolling) else {
                return
            }
            if isScrolling {
                onScrollActivity()
            }
        }
        .environment(\.searchScrollActivity, scrollActivityState)
        .task(id: coverPrefetchGeneration) {
            await SearchCoverPrefetcher.shared.configure(
                sessionID: coverPrefetchSessionID,
                generation: coverPrefetchGeneration,
                requestsByItem: coverPrefetchRequestsByItem
            )
        }
        .onDisappear {
            let sessionID = coverPrefetchSessionID
            Task {
                await SearchCoverPrefetcher.shared.cancel(sessionID: sessionID)
            }
        }
    }

    @MainActor
    private func runScrollBenchmark(using proxy: ScrollViewProxy) async {
        guard snapshot.entries.count > 1,
              let firstID = snapshot.entries.first?.id,
              let lastID = snapshot.entries.last?.id else {
            return
        }

        do {
            try await Task.sleep(for: .seconds(1))
            try Task.checkCancellation()
        } catch {
            return
        }

        let interval = SearchScrollBenchmarkTracer.begin(
            itemCount: snapshot.entries.count,
            layout: layout
        )
        defer { SearchScrollBenchmarkTracer.end(interval) }
        let halfDuration = SearchScrollBenchmarkConfiguration.defaultDurationSeconds / 2

        withAnimation(.linear(duration: halfDuration)) {
            proxy.scrollTo(lastID, anchor: .bottom)
        }
        do {
            try await Task.sleep(for: .seconds(halfDuration))
            try Task.checkCancellation()
        } catch {
            return
        }

        withAnimation(.linear(duration: halfDuration)) {
            proxy.scrollTo(firstID, anchor: .top)
        }
        try? await Task.sleep(for: .seconds(halfDuration))
    }

    @ViewBuilder
    private func content(viewport: CGSize) -> some View {
        switch layout {
        case .card:
            LazyVGrid(
                columns: [
                    GridItem(.adaptive(minimum: cardMetrics.gridMinimumWidth, maximum: cardMetrics.gridMaximumWidth), spacing: 22, alignment: .top)
                ],
                alignment: .leading,
                spacing: 24
            ) {
                ForEach(snapshot.entries) { entry in
                    let item = entry.source.item
                    collectionAnchor(for: entry.source, viewport: viewport) {
                        LibraryDisplayItemCardButton(
                            item: item, titleDisplayMode: titleDisplayMode, localizer: localizer,
                            metrics: cardMetrics, showsUnobstructedCover: true,
                            selection: BookCardSelection(isSelected: isSelected(item), toggle: { onToggleSelection(item) }),
                            action: onPrimaryActivate
                        )
                    }
                    .id(entry.id)
                    .onAppear {
                        updatePrefetchVisibility(index: entry.index, isVisible: true)
                    }
                    .onDisappear {
                        updatePrefetchVisibility(index: entry.index, isVisible: false)
                    }
                }
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        case .row, .expandedRow:
            LazyVStack(spacing: 0) {
                ForEach(snapshot.entries) { entry in
                    row(for: entry.source, width: viewport.width - 36)
                        .id(entry.id)
                        .onAppear {
                            updatePrefetchVisibility(index: entry.index, isVisible: true)
                        }
                        .onDisappear {
                            updatePrefetchVisibility(index: entry.index, isVisible: false)
                        }
                }
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 10)
        }
    }

    @ViewBuilder
    private func row(for source: SearchDisplayItem, width: CGFloat) -> some View {
        switch source.item {
        case .collection(let collection):
            collectionRow(collection, source: source, width: width)
        case .book(let book):
            bookRow(book, isMatched: source.hasMatch(for: book.id), width: width)
        }
        rowSeparator
    }

    private var rowSeparator: some View {
        Divider()
            .opacity(layout == .row ? 0.55 : 1)
            .padding(.horizontal, layout == .row ? SearchCompactRowMetrics.inset : 0)
    }

    @ViewBuilder
    private func bookRow(_ book: LibraryBook, isMatched: Bool, width: CGFloat) -> some View {
        let item = LibraryDisplayItem.book(book)
        let title = BookTitleFormatter.displayTitle(for: book, mode: titleDisplayMode)
        Group {
            if layout == .row {
                SearchCompactResultRow(
                    target: .book(book.id),
                    focus: focusedCompactRow,
                    title: title,
                    isMatched: showsMatchContext && isMatched,
                    onActivate: { onPrimaryActivate(item) },
                    onPreview: { onPreview(item) },
                    onPreviewShortcut: showsPreviewButton ? { onShowPreview(item) } : nil
                ) {
                    SearchResultBookMetadataStrip(
                        book: book,
                        showsDateAndRating: width >= SearchCompactRowMetrics.fullMetadataWidth,
                        localizer: localizer,
                        onToggleMarked: { onToggleMarked(book) }
                    )
                    if showsPreviewButton { previewButton(for: item) }
                }
            } else {
                SearchExpandedBookRow(
                    book: book,
                    isMatched: showsMatchContext && isMatched,
                    store: store,
                    isTagTranslationEnabled: isTagTranslationEnabled,
                    title: title,
                    localizer: localizer,
                    showsAllTags: expandedTagBookIDs.contains(book.id),
                    onSelect: { onPrimaryActivate(item) },
                    onToggleMarked: { onToggleMarked(book) },
                    onToggleTags: {
                        if !expandedTagBookIDs.insert(book.id).inserted { expandedTagBookIDs.remove(book.id) }
                    }
                )
            }
        }
        .searchBatchSelection(isSelected: isSelected(item), localizer: localizer, outlineInset: 0) {
            onToggleSelection(item)
        }
    }

    @ViewBuilder
    private func collectionRow(_ collection: BookCollectionDisplayItem, source: SearchDisplayItem, width: CGFloat) -> some View {
        if layout == .expandedRow {
            expandedCollectionRow(collection, source: source)
        } else {
            let isExpanded = expandedCollectionIDs.contains(collection.id)
            VStack(alignment: .leading, spacing: 0) {
                SearchCompactResultRow(
                    target: .collection(collection.id),
                    focus: focusedCompactRow,
                    title: collection.collection.name,
                    subtitle: localizer.collectionBookCount(collection.books.count),
                    disclosure: isExpanded,
                    disclosureHelp: localizer.string(isExpanded ? .collapseSection : .expandSection),
                    isMatched: false,
                    onActivate: { onToggleCollection(collection.id) },
                    onReturn: { onOpenCollectionDetails(source.item) },
                    onPreview: { onPreview(source.item) },
                    onPreviewShortcut: showsPreviewButton ? { onShowPreview(source.item) } : nil
                ) {
                    if showsPreviewButton { previewButton(for: source.item) }
                    collectionDetailsButton(for: source.item)
                }
                .searchBatchSelection(isSelected: isSelected(source.item), localizer: localizer, outlineInset: 0) {
                    onToggleSelection(source.item)
                }

                if isExpanded {
                    LazyVStack(spacing: 0) {
                        ForEach(collection.books) { book in
                            rowSeparator
                            bookRow(
                                book,
                                isMatched: source.hasMatch(for: book.id),
                                width: width - SearchCompactRowMetrics.childIndent
                            )
                        }
                    }
                    .padding(.leading, SearchCompactRowMetrics.childIndent)
                }
            }
        }
    }

    private func expandedCollectionRow(_ collection: BookCollectionDisplayItem, source: SearchDisplayItem) -> some View {
        HStack(spacing: SearchExpandedRowMetrics.columnSpacing) {
            VStack(alignment: .leading, spacing: 8) {
                Text(collection.collection.name)
                    .font(.title3.weight(.semibold))
                    .lineLimit(2)
                    .help(collection.collection.name)

                Text(localizer.collectionBookCount(collection.books.count))
                    .font(.callout)
                    .foregroundStyle(.secondary)

                Button {
                    onOpenCollectionDetails(source.item)
                } label: {
                    Label(localizer.string(.searchSeriesDetails), systemImage: "info.circle")
                }
                .buttonStyle(.bordered)
            }
            .frame(width: SearchExpandedRowMetrics.coverWidth, height: SearchExpandedRowMetrics.coverHeight, alignment: .leading)
            .searchBatchSelection(isSelected: isSelected(source.item), localizer: localizer, outlineInset: 0) {
                onToggleSelection(source.item)
            }

            SearchCollectionCoverStrip(localizer: localizer) {
                ForEach(collection.books) { book in
                    let item = LibraryDisplayItem.book(book)
                    let title = BookTitleFormatter.displayTitle(for: book, mode: titleDisplayMode)
                    SearchExpandedCoverButton(book: book, title: title) {
                        onPrimaryActivate(item)
                    }
                    .searchMatchHighlight(isMatched: showsMatchContext && source.hasMatch(for: book.id))
                    .searchBatchSelection(isSelected: isSelected(item), localizer: localizer) {
                        onToggleSelection(item)
                    }
                }
            }
        }
        .frame(height: SearchExpandedRowMetrics.rowHeight)
    }

    private func previewButton(for item: LibraryDisplayItem) -> some View {
        Button {
            onShowPreview(item)
        } label: {
            Label(localizer.string(.advancedSearchPreview), systemImage: "eye")
                .labelStyle(.iconOnly)
                .frame(width: 24, height: 24)
        }
        .buttonStyle(.borderless)
        .help(localizer.string(.advancedSearchPreview))
    }

    private func collectionDetailsButton(for item: LibraryDisplayItem) -> some View {
        Button {
            onOpenCollectionDetails(item)
        } label: {
            Label(localizer.string(.searchSeriesDetails), systemImage: "info.circle")
                .labelStyle(.iconOnly)
                .frame(width: 24, height: 24)
        }
        .buttonStyle(.borderless)
        .help(localizer.string(.searchSeriesDetails))
    }

    @ViewBuilder
    private func collectionAnchor<Content: View>(
        for item: SearchDisplayItem,
        viewport: CGSize,
        @ViewBuilder content: @escaping () -> Content
    ) -> some View {
        if SearchPrimaryActivationPolicy.opensCollectionPopover(for: item.item, layout: layout) {
            SearchCollectionPopoverAnchor(
                source: item,
                state: collectionPopoverState,
                isSearchActive: isSearchActive,
                viewport: viewport,
                topInset: topContentClearance,
                titleDisplayMode: titleDisplayMode,
                cardMetrics: cardMetrics,
                localizer: localizer,
                selectedBookIDs: selectedBookIDs,
                onToggleMemberSelection: { onToggleSelection(.book($0)) },
                onMember: onCollectionMember,
                onDetails: onCollectionDetails,
                onAnchorVisibility: { collectionID, isVisible in
                    if isVisible { visibleCollectionIDs.insert(collectionID) }
                    else { visibleCollectionIDs.remove(collectionID) }
                },
                content: content
            )
        } else {
            content()
        }
    }

    private func isSelected(_ item: LibraryDisplayItem) -> Bool {
        !item.books.isEmpty && item.books.allSatisfy { selectedBookIDs.contains($0.id) }
    }

    private func updatePrefetchVisibility(index: Int, isVisible: Bool) {
        let sessionID = coverPrefetchSessionID
        let generation = coverPrefetchGeneration
        Task {
            await SearchCoverPrefetcher.shared.visibilityChanged(
                sessionID: sessionID,
                generation: generation,
                index: index,
                isVisible: isVisible
            )
        }
    }

}

enum AdvancedSearchInteractionPolicy {
    static func shouldSubmitOrdinarySearch(isCoverImageSearchActive: Bool) -> Bool {
        !isCoverImageSearchActive
    }
}

@MainActor
enum CoverImageSearchDropLoader {
    static let typeIdentifiers = [
        UTType.fileURL.identifier,
        UTType.image.identifier
    ]

    static func imageData(from providers: [NSItemProvider]) async throws -> Data {
        try await TagDropImageLoader.imageData(from: providers)
    }
}

private struct CoverImageSearchDropHighlight: View {
    let title: String

    var body: some View {
        ZStack {
            Color.accentColor.opacity(0.08)

            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .stroke(
                    Color.accentColor.opacity(0.9),
                    style: StrokeStyle(lineWidth: 2, dash: [8, 6])
                )
                .padding(12)

            Label(title, systemImage: "photo.badge.magnifyingglass")
                .font(.title3.weight(.semibold))
                .foregroundStyle(Color.accentColor)
                .padding(.horizontal, 20)
                .padding(.vertical, 14)
                .background(.regularMaterial, in: Capsule())
        }
        .transition(.opacity)
    }
}

private extension View {
    func searchMatchHighlight(isMatched: Bool) -> some View {
        background {
            if isMatched {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(Color.accentColor.opacity(0.09))
            }
        }
    }
}

private enum SearchCompactRowMetrics {
    static let height: CGFloat = 36
    static let inset: CGFloat = 10
    static let childIndent: CGFloat = 22
    static let fixedPreviewThreshold: CGFloat = 840
    static let previewWidth: CGFloat = 300
    static let fullMetadataWidth: CGFloat = 520
}

private struct SearchCompactResultRow<Actions: View>: View {
    let target: SearchPreviewTarget
    let focus: FocusState<SearchPreviewTarget?>.Binding
    let title: String
    var subtitle: String?
    var disclosure: Bool?
    var disclosureHelp: String?
    let isMatched: Bool
    let onActivate: () -> Void
    var onReturn: (() -> Void)?
    let onPreview: () -> Void
    var onPreviewShortcut: (() -> Void)?
    @ViewBuilder let actions: () -> Actions

    @Environment(\.searchScrollActivity) private var scrollActivity
    @State private var isHovered = false
    @State private var hoverGate = SearchScrollHoverGate()

    var body: some View {
        HStack(spacing: 8) {
            Button(action: onActivate) {
                HStack(spacing: 6) {
                    if let disclosure {
                        Image(systemName: disclosure ? "chevron.down" : "chevron.right")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .accessibilityHidden(true)
                    }
                    Text(title)
                        .font(.callout.weight(disclosure == nil ? .medium : .semibold))
                        .lineLimit(1)
                    if let subtitle {
                        Text(subtitle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize()
                    }
                }
                .frame(maxWidth: .infinity, minHeight: SearchCompactRowMetrics.height, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .focusable()
            .focused(focus, equals: target)
            .onChange(of: focus.wrappedValue == target) { _, focused in
                if focused { onPreview() }
            }
            .onKeyPress(.return) {
                (onReturn ?? onActivate)()
                return .handled
            }
            .onKeyPress(.space) {
                guard let onPreviewShortcut else { return .ignored }
                onPreviewShortcut()
                return .handled
            }
            .accessibilityValue(disclosureHelp ?? "")
            .help(title)

            actions()
        }
        .padding(.horizontal, SearchCompactRowMetrics.inset)
        .frame(height: SearchCompactRowMetrics.height)
        .background {
            if isHovered {
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.primary.opacity(0.055))
            }
        }
        .searchMatchHighlight(isMatched: isMatched)
        .contentShape(Rectangle())
        .onContinuousHover { phase in
            switch phase {
            case .active(let location):
                guard hoverGate.pointerBecameActive(at: location, isScrolling: scrollActivity.isScrolling),
                      !isHovered else { return }
                isHovered = true
                onPreview()
            case .ended:
                hoverGate.pointerEnded()
                isHovered = false
            }
        }
        .onChange(of: scrollActivity.isScrolling) { _, isScrolling in
            hoverGate.scrollActivityChanged(isScrolling: isScrolling)
            if isScrolling { isHovered = false }
        }
    }
}

struct SearchFavoriteButton: View {
    let isMarked: Bool
    let isExpanded: Bool
    let localizer: AppLocalizer
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(
                localizer.string(isMarked ? .markedStatus : .marked),
                systemImage: isMarked ? "heart.fill" : "heart"
            )
            .labelStyle(.iconOnly)
            .font(isExpanded ? .title2.weight(.semibold) : .callout)
            .frame(width: isExpanded ? 44 : 24, height: isExpanded ? 44 : 24)
        }
        .buttonStyle(SearchFavoriteButtonStyle(isMarked: isMarked, showsBackground: isExpanded))
        .help(localizer.string(isMarked ? .markedStatus : .marked))
        .accessibilityAddTraits(isMarked ? .isSelected : [])
    }
}

private struct SearchFavoriteButtonStyle: ButtonStyle {
    let isMarked: Bool
    let showsBackground: Bool

    func makeBody(configuration: Configuration) -> some View {
        Surface(configuration: configuration, isMarked: isMarked, showsBackground: showsBackground)
    }

    private struct Surface: View {
        let configuration: Configuration
        let isMarked: Bool
        let showsBackground: Bool

        @Environment(\.accessibilityReduceMotion) private var reduceMotion
        @State private var isHovered = false

        var body: some View {
            let shape = RoundedRectangle(cornerRadius: showsBackground ? 10 : 6, style: .continuous)
            let color: Color = isMarked ? .red : .secondary
            let opacity = configuration.isPressed ? 0.28 : isHovered ? 0.20 : showsBackground ? 0.10 : 0
            configuration.label
                .foregroundStyle(color)
                .background(color.opacity(opacity), in: shape)
                .contentShape(shape)
                .onHover { isHovered = $0 }
                .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: isHovered)
        }
    }
}

private struct SearchResultBookMetadataStrip: View {
    let book: LibraryBook
    let showsDateAndRating: Bool
    let localizer: AppLocalizer
    let onToggleMarked: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            HStack(spacing: 7) {
                if showsDateAndRating {
                    BookRatingStarsView(rating: book.rating, localizer: localizer)
                }

                Text(languageFlag(for: book.languageCode))
                    .help(languageText(for: book.languageCode))

                Text(pageText)
                    .monospacedDigit()
                    .frame(minWidth: 25, alignment: .trailing)
            }
            .padding(.horizontal, 7)
            .frame(height: 24)
            .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))

            if showsDateAndRating {
                Text(formattedPosted)
                    .monospacedDigit()
                    .frame(width: 110, alignment: .trailing)
            }

            SearchFavoriteButton(isMarked: book.mark, isExpanded: false, localizer: localizer, action: onToggleMarked)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .lineLimit(1)
    }

    private var formattedPosted: String {
        guard let posted = book.posted else {
            return "-"
        }
        return Date(timeIntervalSince1970: TimeInterval(posted))
            .formatted(date: .numeric, time: .shortened)
    }

    private var pageText: String {
        guard let pages = book.pages ?? book.fileCount else {
            return "-"
        }
        return "\(pages)p"
    }

    private func languageText(for code: String) -> String {
        code == "unknown" ? localizer.string(.unknown) : code.capitalized
    }

    private func languageFlag(for code: String) -> String {
        switch code.lowercased() {
        case "chinese":
            return "🇨🇳"
        case "japanese":
            return "🇯🇵"
        case "english":
            return "🇬🇧"
        case "korean":
            return "🇰🇷"
        case "spanish":
            return "🇪🇸"
        case "french":
            return "🇫🇷"
        case "german":
            return "🇩🇪"
        case "italian":
            return "🇮🇹"
        default:
            return "🏳️"
        }
    }
}

struct SearchExpandedInfoIconRow: View {
    let book: LibraryBook
    let localizer: AppLocalizer

    var body: some View {
        HStack(alignment: .center, spacing: 9) {
            Text(languageFlag(for: book.languageCode))
                .font(.title3)
                .help(languageText(for: book.languageCode))

            SearchExpandedStatusIcon(
                systemImage: "paintpalette",
                title: localizer.string(.statusColorShort),
                isActive: book.isFullColor
            )

            SearchExpandedStatusIcon(
                systemImage: "eye",
                title: localizer.string(.statusCensorshipShort),
                isActive: book.censorship == "uncensored"
            )

            HStack(spacing: 4) {
                Image(systemName: "doc.text")
                Text(pageText)
                    .monospacedDigit()
            }
            .font(.callout)
            .foregroundStyle(.secondary)
            .help(localizer.string(.pages))
        }
        .lineLimit(1)
    }

    private var pageText: String {
        guard let pages = book.pages ?? book.fileCount else {
            return "-"
        }
        return "\(pages)p"
    }

    private func languageText(for code: String) -> String {
        code == "unknown" ? localizer.string(.unknown) : code.capitalized
    }

    private func languageFlag(for code: String) -> String {
        switch code.lowercased() {
        case "chinese":
            return "🇨🇳"
        case "japanese":
            return "🇯🇵"
        case "english":
            return "🇬🇧"
        case "korean":
            return "🇰🇷"
        case "spanish":
            return "🇪🇸"
        case "french":
            return "🇫🇷"
        case "german":
            return "🇩🇪"
        case "italian":
            return "🇮🇹"
        default:
            return "🏳️"
        }
    }
}

private struct SearchExpandedStatusIcon: View {
    let systemImage: String
    let title: String
    let isActive: Bool

    var body: some View {
        Image(systemName: systemImage)
            .font(.callout.weight(.semibold))
            .foregroundStyle(isActive ? Color.accentColor : Color.secondary.opacity(0.38))
            .frame(width: 20, height: 20)
            .help(title)
    }
}

struct SearchResultTagCloud: View {
    let tags: [TagDisplaySummary]
    let isExpanded: Bool

    var body: some View {
        SearchResultTagFlowLayout(
            spacing: isExpanded ? 8 : 5,
            lineSpacing: isExpanded ? 8 : 5
        ) {
            ForEach(tags) { tag in
                Text(tag.displayText)
                    .font(isExpanded ? .callout : .caption2)
                    .lineLimit(1)
                    .padding(.horizontal, isExpanded ? 11 : 7)
                    .padding(.vertical, isExpanded ? 6 : 3)
                    .foregroundStyle(.secondary)
                    .background(.secondary.opacity(0.08), in: Capsule())
                    .help(tag.rawValue)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct SearchResultTagFlowLayout: Layout {
    let spacing: CGFloat
    let lineSpacing: CGFloat
    var wrapsLongItems = false

    func sizeThatFits(
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) -> CGSize {
        let width = proposal.width ?? 0
        let rows = rows(in: width, subviews: subviews)
        return CGSize(
            width: width,
            height: rows.reduce(CGFloat.zero) { $0 + $1.height } + CGFloat(max(rows.count - 1, 0)) * lineSpacing
        )
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) {
        var y = bounds.minY
        for row in rows(in: bounds.width, subviews: subviews) {
            var x = bounds.minX
            for item in row.items {
                subviews[item.index].place(
                    at: CGPoint(x: x, y: y),
                    proposal: ProposedViewSize(item.size)
                )
                x += item.size.width + spacing
            }
            y += row.height + lineSpacing
        }
    }

    private func rows(in width: CGFloat, subviews: Subviews) -> [Row] {
        guard width > 0 else {
            return []
        }

        var rows: [Row] = []
        var current = Row()

        for index in subviews.indices {
            let ideal = subviews[index].sizeThatFits(.unspecified)
            let size = wrapsLongItems && ideal.width > width
                ? subviews[index].sizeThatFits(ProposedViewSize(width: width, height: nil))
                : ideal
            let nextWidth = current.width == 0 ? size.width : current.width + spacing + size.width
            if nextWidth > width, !current.items.isEmpty {
                rows.append(current)
                current = Row()
            }
            current.items.append(RowItem(index: index, size: size))
            current.width = current.width == 0 ? size.width : current.width + spacing + size.width
            current.height = max(current.height, size.height)
        }

        if !current.items.isEmpty {
            rows.append(current)
        }
        return rows
    }

    private struct Row {
        var items: [RowItem] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private struct RowItem {
        var index: Int
        var size: CGSize
    }
}

private struct NamespaceTab: View {
    @Environment(\.nyaehAccentColor) private var accentColor

    let title: String
    let count: Int
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 7) {
            Text(title)
                .font(.caption)
                .fontWeight(isSelected ? .semibold : .regular)
            Text("\(count)")
                .font(.caption2)
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 6)
        .background(isSelected ? accentColor.opacity(0.14) : Color.secondary.opacity(0.06), in: Capsule())
        .overlay {
            Capsule()
                .stroke(isSelected ? accentColor.opacity(0.24) : Color.secondary.opacity(0.08), lineWidth: 1)
        }
        .contentShape(Capsule())
    }
}

private struct SearchTagPill: View {
    @Environment(\.nyaehAccentColor) private var accentColor

    let facet: SearchTagFacet

    var body: some View {
        HStack(spacing: 7) {
            if facet.tag.isFollowed {
                Image(systemName: "star.fill")
                    .font(.caption2)
                    .foregroundStyle(.yellow)
            }

            Text(facet.tag.displayText)
                .font(.caption)
                .fontWeight(.medium)
                .lineLimit(1)
            Spacer(minLength: 4)
            Text("\(facet.availableCount)")
                .font(.caption2)
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(background, in: Capsule())
        .overlay {
            Capsule().stroke(border, lineWidth: 1)
        }
        .opacity(facet.isEnabled || facet.state != .unselected ? 1 : 0.42)
        .help(helpText)
    }

    private var background: Color {
        switch facet.state {
        case .selected:
            return accentColor.opacity(0.18)
        case .excluded:
            return .red.opacity(0.16)
        case .unselected:
            return .secondary.opacity(facet.isEnabled ? 0.08 : 0.04)
        }
    }

    private var border: Color {
        switch facet.state {
        case .selected:
            return accentColor.opacity(0.44)
        case .excluded:
            return .red.opacity(0.42)
        case .unselected:
            return .secondary.opacity(facet.isEnabled ? 0.18 : 0.08)
        }
    }

    private var helpText: String {
        [facet.tag.rawValue, facet.intro].compactMap { $0 }.joined(separator: "\n")
    }
}

private struct SearchTokenStrip: View {
    @Environment(\.nyaehAccentColor) private var accentColor

    let tokens: [SearchTokenHighlight]
    let onCycle: (SearchTokenHighlight) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(tokens) { token in
                    Button {
                        onCycle(token)
                    } label: {
                        Text(token.displayText)
                            .font(.caption2)
                            .fontWeight(.medium)
                            .lineLimit(1)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(token.state == .excluded ? .red.opacity(0.16) : accentColor.opacity(0.16), in: Capsule())
                            .overlay {
                                Capsule()
                                    .stroke(token.state == .excluded ? .red.opacity(0.34) : accentColor.opacity(0.34))
                            }
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 2)
        }
        .frame(height: SearchHeaderMenuMetrics.height)
    }
}

private struct SearchSuggestionList: View {
    @State private var hoveredID: SearchTagSuggestion.ID?

    let suggestions: [SearchTagSuggestion]
    let selectedID: SearchTagSuggestion.ID?
    let isTagTranslationEnabled: Bool
    let localizer: AppLocalizer
    let maxHeight: CGFloat
    let onSelect: (SearchTagSuggestion) -> Void

    private var height: CGFloat {
        min(CGFloat(suggestions.count) * 38 + 12, 260, maxHeight)
    }

    var body: some View {
        if !suggestions.isEmpty {
            ScrollViewReader { scrollProxy in
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(suggestions) { suggestion in
                            Button {
                                onSelect(suggestion)
                            } label: {
                                HStack(spacing: 16) {
                                    HStack(spacing: 7) {
                                        if suggestion.tag.isFollowed {
                                            Image(systemName: "star.fill")
                                                .font(.caption)
                                                .foregroundStyle(.yellow)
                                        }

                                        Text(suggestion.exactInsertionText)
                                            .font(.callout)
                                            .fontWeight(.medium)
                                            .lineLimit(1)
                                    }
                                    .frame(maxWidth: .infinity, alignment: .leading)

                                    if isTagTranslationEnabled, suggestion.tag.displayName != suggestion.tag.name {
                                        Text(suggestion.tag.displayText)
                                            .font(.callout)
                                            .foregroundStyle(.secondary)
                                            .lineLimit(1)
                                            .frame(maxWidth: .infinity, alignment: .trailing)
                                    }
                                }
                                .padding(.horizontal, 12)
                                .padding(.vertical, 8)
                                .contentShape(Rectangle())
                                .background {
                                    if selectedID == suggestion.id || hoveredID == suggestion.id {
                                        RoundedRectangle(cornerRadius: 8)
                                            .fill(Color.accentColor.opacity(0.16))
                                    }
                                }
                            }
                            .buttonStyle(.plain)
                            .id(suggestion.id)
                            .onHover { isHovering in
                                if isHovering {
                                    hoveredID = suggestion.id
                                } else if hoveredID == suggestion.id {
                                    hoveredID = nil
                                }
                            }
                            .help([suggestion.tag.rawValue, suggestion.intro].compactMap { $0 }.joined(separator: "\n"))

                            if suggestion.id != suggestions.last?.id {
                                Divider().padding(.leading, 12)
                            }
                        }
                    }
                }
                .onChange(of: selectedID) { _, selectedID in
                    guard let selectedID else { return }
                    scrollProxy.scrollTo(selectedID, anchor: .center)
                }
            }
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity)
            .frame(height: height)
            .glassPanel(cornerRadius: 14, material: .regularMaterial)
            .shadow(color: .black.opacity(0.16), radius: 18, x: 0, y: 8)
            .accessibilityLabel(localizer.string(.advancedSearchSuggestions))
        }
    }
}

struct SearchSyntaxHelpPopover: View {
    let localizer: AppLocalizer

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label(localizer.string(.advancedSearchSyntaxHelpTitle), systemImage: "questionmark.circle")
                .font(.headline)

            VStack(alignment: .leading, spacing: 12) {
                helpSection(
                    title: localizer.string(.advancedSearchSyntaxKeywordTitle),
                    rows: [
                        ("alpha", localizer.string(.advancedSearchSyntaxKeywordBody))
                    ]
                )

                helpSection(
                    title: localizer.string(.advancedSearchSyntaxFieldTitle),
                    rows: [
                        ("title:alpha", localizer.string(.advancedSearchSyntaxFieldTitleOnly)),
                        ("file:alpha", localizer.string(.advancedSearchSyntaxFieldFileOnly)),
                        ("filename:alpha", localizer.string(.advancedSearchSyntaxFieldFileOnly)),
                        ("path:alpha", localizer.string(.advancedSearchSyntaxFieldFileOnly))
                    ]
                )

                helpSection(
                    title: localizer.string(.advancedSearchSyntaxTagTitle),
                    rows: [
                        ("f:tag m:tag a:tag c:tag", localizer.string(.advancedSearchSyntaxTagPeople)),
                        ("p:tag g:tag l:tag o:tag x:tag", localizer.string(.advancedSearchSyntaxTagMeta)),
                        ("tag:tag", localizer.string(.advancedSearchSyntaxTagAny))
                    ]
                )

                helpSection(
                    title: localizer.string(.advancedSearchSyntaxOperatorTitle),
                    rows: [
                        (#"f:"multi word"$"#, localizer.string(.advancedSearchSyntaxOperatorQuoteExact)),
                        ("-f:tag", localizer.string(.advancedSearchSyntaxOperatorExclude)),
                        ("~tag:tag", localizer.string(.advancedSearchSyntaxOperatorOptional))
                    ]
                )

                helpSection(
                    title: localizer.string(.advancedSearchSyntaxModeTitle),
                    rows: [
                        (localizer.string(.advancedSearchExact), localizer.string(.advancedSearchSyntaxModeExact)),
                        (localizer.string(.advancedSearchBroad), localizer.string(.advancedSearchSyntaxModeBroad))
                    ]
                )
            }
        }
        .padding(16)
        .frame(width: 380)
    }

    private func helpSection(title: String, rows: [(String, String)]) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title)
                .font(.subheadline.weight(.semibold))
            VStack(alignment: .leading, spacing: 6) {
                ForEach(rows, id: \.0) { example, description in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(verbatim: example)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.primary)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 3)
                            .background(Color.secondary.opacity(0.10), in: RoundedRectangle(cornerRadius: 6))
                            .frame(minWidth: 92, alignment: .leading)

                        Text(description)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }
}


private extension View {
    func readSearchBottomOverlayHeight() -> some View {
        background {
            GeometryReader { proxy in
                Color.clear.preference(
                    key: SearchBottomOverlayHeightPreferenceKey.self,
                    value: proxy.size.height
                )
            }
        }
    }

    @ViewBuilder
    func searchHeaderGlassPanel(cornerRadius: CGFloat) -> some View {
        searchGlassSurface(
            in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        )
    }

    @ViewBuilder
    func searchGlassCapsule() -> some View {
        searchGlassSurface(in: Capsule())
    }

    @ViewBuilder
    func searchGlassSurface<SurfaceShape: Shape>(in shape: SurfaceShape) -> some View {
        if #available(macOS 26.0, *) {
            glassEffect(.regular, in: shape)
        } else {
            background(.thinMaterial, in: shape)
                .overlay {
                    shape.stroke(.primary.opacity(0.08), lineWidth: 1)
                }
                .shadow(color: .black.opacity(0.05), radius: 10, x: 0, y: 4)
        }
    }

    func glassPanel(cornerRadius: CGFloat, material: Material) -> some View {
        self
            .background(material, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .stroke(.white.opacity(0.18), lineWidth: 1)
            }
            .shadow(color: .black.opacity(0.04), radius: 10, x: 0, y: 4)
    }
}
