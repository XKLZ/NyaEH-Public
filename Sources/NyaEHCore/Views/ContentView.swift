// 本文件是主窗口导航组合层，维护侧边栏目的地、详情路由栈和全局工具栏动作。

import SwiftUI

enum TagCategoryToolbarVisibility {
    static func isVisible(baseDestination: LibraryDestination, detailPath: [LibraryRoute]) -> Bool {
        guard detailPath.isEmpty else { return false }
        if case .tagCategory = baseDestination { return true }
        return false
    }
}

struct ContentView: View {
    let appModel: NyaEHAppModel
    @Bindable var preferences: AppPreferences
    let developmentConfiguration: NyaEHDevelopmentConfiguration?
    @State private var cardActions: BookCardActions
    @State private var initialSidebarWidth: CGFloat
    // 主导航拆成“侧边栏 base + 详情 overlay path”。这样从作品/合集进入书籍时，
    // 返回动画可以保留中间页面，不会闪回侧边栏基础页。
    @State private var baseDestination: LibraryDestination = SearchScrollBenchmarkConfiguration.isEnabled
        ? .search
        : .home
    @State private var detailPath: [LibraryRoute] = []
    @State private var advancedSearchFocusRequest = 0
    @State private var isSearchSyntaxHelpPresented = false
    @State private var routeStateResetToken = 0
    @State private var isTaskCenterPresented = false

    init(
        appModel: NyaEHAppModel,
        preferences: AppPreferences,
        developmentConfiguration: NyaEHDevelopmentConfiguration?
    ) {
        _cardActions = State(initialValue: BookCardActions(store: appModel.catalog, preferences: preferences))
        self.appModel = appModel
        self.preferences = preferences
        self.developmentConfiguration = developmentConfiguration
        // A window takes its initial width once. AppKit owns the divider after that.
        _initialSidebarWidth = State(
            initialValue: preferences.savedMainSidebarWidth() ?? MainWindowGeometry.defaultSidebarWidth
        )
    }

    private var localizer: AppLocalizer {
        preferences.localizer
    }

    private var store: CatalogStore {
        appModel.catalog
    }

    var body: some View {
        MainWindowSplitView {
            LibrarySidebarView(
                selection: sidebarSelection,
                localizer: localizer,
                showsDevelopmentTools: developmentConfiguration != nil,
                navigationRequest: routeStateResetToken
            )
            .background { MainSidebarWidthObserver(preferences: preferences).allowsHitTesting(false) }
            .navigationSplitViewColumnWidth(
                min: MainWindowGeometry.minimumSidebarWidth,
                ideal: initialSidebarWidth,
                max: MainWindowGeometry.maximumSidebarWidth
            )
        } detail: {
            LibraryContentView(
                baseDestination: $baseDestination,
                detailPath: $detailPath,
                appModel: appModel,
                preferences: preferences,
                metadataConfiguration: preferences.galleryMetadataFetchConfiguration,
                metadataBatchConfiguration: preferences.metadataBatchConfiguration,
                isTagTranslationEnabled: preferences.isTagTranslationEnabled,
                isCoverSimilarityVersionRecommendationEnabled: preferences.isCoverSimilarityVersionRecommendationEnabled,
                coverSimilarityMaximumDistance: preferences.coverSimilarityMaximumDistance,
                titleDisplayMode: preferences.bookTitleDisplayMode,
                advancedSearchPageSize: $preferences.advancedSearchPageSize,
                isAdvancedSearchFacetPanelExpanded: $preferences.isAdvancedSearchFacetPanelExpanded,
                isAdvancedSearchHeaderPinned: $preferences.isAdvancedSearchHeaderPinned,
                libraryCollectionPageSize: $preferences.libraryCollectionPageSize,
                tagCategoryPageSize: $preferences.tagCategoryPageSize,
                homeCardWidth: $preferences.homeCardWidth,
                advancedSearchCardWidth: $preferences.advancedSearchCardWidth,
                libraryShelfCardWidth: $preferences.libraryShelfCardWidth,
                collectionCandidatePageSize: $preferences.collectionCandidatePageSize,
                versionCandidatePageSize: $preferences.versionCandidatePageSize,
                readerInitialLoadLimit: preferences.readerInitialLoadLimit,
                readerHoverPreviewDelayMilliseconds: preferences.readerHoverPreviewDelayMilliseconds,
                advancedSearchFocusRequest: advancedSearchFocusRequest,
                routeStateResetToken: routeStateResetToken,
                isTaskCenterPresented: $isTaskCenterPresented,
                localizer: localizer,
                developmentConfiguration: developmentConfiguration,
                resolveLibraryRootURL: {
                    try preferences.resolvedLibraryRootURL()
                }
            )
        } actions: {
            mainWindowActions
        }
        .environment(\.bookCardActions, cardActions)
        .overlay(alignment: .bottom) {
            if let message = cardActions.notice {
                Text(message).padding(10).background(.regularMaterial, in: Capsule()).padding()
            }
        }
        .task(id: cardActions.noticeID) {
            guard cardActions.notice != nil else { return }
            try? await Task.sleep(for: .seconds(4))
            if !Task.isCancelled { cardActions.notice = nil }
        }
        .onChange(of: store.deletingBookIDs) { _, ids in
            if let id = cardActions.readerBookID, ids.contains(id) { cardActions.closeReader() }
        }
        .onDisappear { cardActions.closeReader() }
        .environment(\.bookCardCatalog, store)
        .environment(\.bookCardFields, preferences.bookCardFields)
        .toolbar(removing: usesImmersiveToolbar || showsTagCategoryToolbar ? .title : nil)
        .toolbarBackgroundVisibility(usesImmersiveToolbar ? .hidden : .automatic, for: .windowToolbar)
        .focusedSceneValue(\.nyaehAppCommands, appCommandContext)
        .onExitCommand {
            guard !detailPath.isEmpty else {
                return
            }
            navigateBack()
        }
    }

    @ToolbarContentBuilder
    private var mainWindowActions: some ToolbarContent {
        if !showsTagCategoryToolbar {
            ToolbarSpacer(.flexible, placement: MainWindowToolbarLayout.actionPlacement)
        }
        if isSearchBaseVisible {
            if !appModel.search.catalog.isCoverImageSearchActive {
                ToolbarItem(id: "search-sorting", placement: MainWindowToolbarLayout.actionPlacement) {
                    ControlGroup {
                        SearchResultSortToolbarMenu(store: appModel.search, localizer: localizer)
                        SearchResultDirectionToolbarButton(store: appModel.search, localizer: localizer)
                    } label: {
                        Label(localizer.string(.viewSortStrategy), systemImage: "arrow.up.arrow.down")
                    }
                    .controlGroupStyle(SearchToolbarGlassControlGroupStyle())
                }
                .sharedBackgroundVisibility(.hidden)

                ToolbarSpacer(.fixed, placement: MainWindowToolbarLayout.actionPlacement)
            }

            ToolbarItem(id: "search-display", placement: MainWindowToolbarLayout.actionPlacement) {
                searchDisplayControls
            }
            .sharedBackgroundVisibility(.hidden)

            ToolbarSpacer(.fixed, placement: MainWindowToolbarLayout.actionPlacement)

            ToolbarItem(id: "search-tools", placement: MainWindowToolbarLayout.actionPlacement) {
                searchToolControls
            }
            .sharedBackgroundVisibility(.hidden)

        } else if !showsTagCategoryToolbar {
            ToolbarItem(id: "global-actions", placement: MainWindowToolbarLayout.actionPlacement) {
                ControlGroup {
                    SettingsToolbarButton(localizer: localizer)
                        .buttonStyle(SearchToolbarButtonStyle())
                    TaskCenterToolbarButton(
                        store: appModel.taskCenter,
                        isPresented: $isTaskCenterPresented,
                        localizer: localizer
                    )
                    .buttonStyle(SearchToolbarButtonStyle())
                } label: {
                    Label(localizer.string(.toolbarGlobalActions), systemImage: "ellipsis")
                }
                .controlGroupStyle(SearchToolbarGlassControlGroupStyle())
            }
            .sharedBackgroundVisibility(.hidden)
        }
    }

    private var searchToolControls: some View {
        ControlGroup {
            Button {
                isSearchSyntaxHelpPresented.toggle()
            } label: {
                Label(localizer.string(.advancedSearchSyntaxHelp), systemImage: "questionmark.circle")
            }
            .buttonStyle(SearchToolbarButtonStyle())
            .help(localizer.string(.advancedSearchSyntaxHelp))
            .popover(isPresented: $isSearchSyntaxHelpPresented, arrowEdge: .bottom) {
                SearchSyntaxHelpPopover(localizer: localizer)
                    .buttonStyle(.automatic)
            }

            TaskCenterToolbarButton(
                store: appModel.taskCenter,
                isPresented: $isTaskCenterPresented,
                localizer: localizer
            )
            .buttonStyle(SearchToolbarButtonStyle())

            SettingsToolbarButton(localizer: localizer)
                .buttonStyle(SearchToolbarButtonStyle())
        } label: {
            Label(localizer.string(.searchToolbarTools), systemImage: "ellipsis")
        }
        .controlGroupStyle(SearchToolbarGlassControlGroupStyle())
    }

    private var searchDisplayControls: some View {
        ControlGroup {
            SearchResultLayoutToolbarMenu(store: appModel.search, localizer: localizer)

            Toggle(isOn: Binding(
                get: { preferences.isAdvancedSearchHeaderPinned },
                set: { isPinned in
                    withAnimation(.snappy(duration: 0.24)) {
                        preferences.isAdvancedSearchHeaderPinned = isPinned
                    }
                }
            )) {
                Label(
                    localizer.string(preferences.isAdvancedSearchHeaderPinned ? .advancedSearchUnpinHeader : .advancedSearchPinHeader),
                    systemImage: preferences.isAdvancedSearchHeaderPinned ? "pin.fill" : "pin.slash"
                )
            }
            .toggleStyle(SearchToolbarToggleStyle())
            .help(localizer.string(preferences.isAdvancedSearchHeaderPinned ? .advancedSearchUnpinHeader : .advancedSearchPinHeader))

            Toggle(isOn: Binding(
                get: { appModel.catalog.advancedSearchShowsIndividualBooks },
                set: { showsIndividualBooks in
                    appModel.catalog.advancedSearchShowsIndividualBooks = showsIndividualBooks
                    preferences.isAdvancedSearchCollectionMembersExpanded = showsIndividualBooks
                }
            )) {
                Label(
                    localizer.string(
                        appModel.catalog.advancedSearchShowsIndividualBooks
                            ? .advancedSearchHideCollectionMembers
                            : .advancedSearchShowCollectionMembers
                    ),
                    systemImage: appModel.catalog.advancedSearchShowsIndividualBooks
                        ? "rectangle.stack.fill"
                        : "rectangle.stack"
                )
            }
            .toggleStyle(SearchToolbarToggleStyle())
            .help(localizer.string(
                appModel.catalog.advancedSearchShowsIndividualBooks
                    ? .advancedSearchHideCollectionMembers
                    : .advancedSearchShowCollectionMembers
            ))
        } label: {
            Label(localizer.string(.searchToolbarDisplay), systemImage: "square.grid.3x3")
        }
        .controlGroupStyle(SearchToolbarGlassControlGroupStyle())
    }

    private var isSearchBaseVisible: Bool {
        guard detailPath.isEmpty else {
            return false
        }
        if case .search = baseDestination {
            return true
        }
        return false
    }

    private var usesImmersiveToolbar: Bool {
        guard let route = detailPath.last else {
            return baseDestination == .home
        }
        switch route {
        case .workDetail, .characterDetail, .bookDetail:
            return true
        case .collectionDetail:
            return false
        }
    }

    private var showsTagCategoryToolbar: Bool {
        TagCategoryToolbarVisibility.isVisible(baseDestination: baseDestination, detailPath: detailPath)
    }

    private var sidebarSelection: Binding<LibraryDestination?> {
        Binding {
            baseDestination
        } set: { newValue in
            guard let newValue else {
                return
            }

            // 切换侧边栏目的地会清空详情路径并重置子页面局部状态，避免旧路由缓存泄漏到新页面。
            baseDestination = newValue
            detailPath = LibraryNavigationPathReducer.pathAfterSelectingBaseDestination()
            routeStateResetToken += 1
            if case .collection(let filter) = newValue {
                store.filter = filter
            }
        }
    }

    private var appCommandContext: NyaEHAppCommandContext {
        NyaEHAppCommandContext(
            canGoBack: !detailPath.isEmpty,
            goBack: navigateBack,
            navigate: navigate,
            refreshLibrary: { store.refresh() },
            focusSearch: focusAdvancedSearch
        )
    }

    private func navigate(_ nextDestination: LibraryDestination) {
        withAnimation(.snappy(duration: 0.28)) {
            baseDestination = nextDestination
            detailPath = LibraryNavigationPathReducer.pathAfterSelectingBaseDestination()
            routeStateResetToken += 1
        }

        if case .collection(let filter) = nextDestination {
            store.filter = filter
        }
    }

    private func navigateBack() {
        guard !detailPath.isEmpty else {
            return
        }

        withAnimation(.snappy(duration: 0.28)) {
            detailPath = LibraryNavigationPathReducer.pathAfterGoingBack(from: detailPath)
        }
    }

    private func focusAdvancedSearch() {
        withAnimation(.snappy(duration: 0.28)) {
            baseDestination = .search
            detailPath = LibraryNavigationPathReducer.pathAfterSelectingBaseDestination()
            routeStateResetToken += 1
        }
        advancedSearchFocusRequest += 1
    }

}

struct SettingsToolbarButton: View {
    @Environment(\.openSettings) private var openSettings
    let localizer: AppLocalizer

    var body: some View {
        Button {
            openSettings()
        } label: {
            Label(localizer.string(.settings), systemImage: "gearshape")
        }
        .help(localizer.string(.openSettingsHelp))
    }
}

struct TaskCenterToolbarButton: View {
    let store: TaskCenterStore
    @Binding var isPresented: Bool
    let localizer: AppLocalizer

    var body: some View {
        Button {
            isPresented.toggle()
        } label: {
            Label(
                localizer.string(.taskCenter),
                systemImage: store.catalog.taskCenterSnapshots(localizer: localizer).isEmpty
                    ? "checkmark.circle" : "progress.indicator"
            )
        }
        .help(localizer.string(.taskCenter))
        .popover(isPresented: $isPresented, arrowEdge: .bottom) {
            TaskCenterView(store: store, localizer: localizer)
                .buttonStyle(.automatic)
        }
    }
}

private struct LibraryContentTransientFeedback: Identifiable, Equatable {
    static let durationMilliseconds = 1_250

    let id = UUID()
    let message: String
}

private struct LibraryContentFeedbackOverlay: View {
    let loadError: String?
    let cleanupWarning: String?
    let transientFeedback: LibraryContentTransientFeedback?

    var body: some View {
        VStack(spacing: 8) {
            if let loadError {
                LibraryContentFeedbackPill(message: loadError, style: .error)
                    .transition(.opacity.combined(with: .scale(scale: 0.98)))
            }

            if let cleanupWarning {
                LibraryContentFeedbackPill(message: cleanupWarning, style: .neutral)
            }
            if let transientFeedback {
                LibraryContentFeedbackPill(message: transientFeedback.message, style: .neutral)
                    .transition(.opacity.combined(with: .scale(scale: 0.98)))
            }
        }
        .animation(.snappy(duration: 0.18), value: loadError)
        .animation(.snappy(duration: 0.18), value: transientFeedback)
    }
}

private struct LibraryContentFeedbackPill: View {
    enum Style {
        case error
        case neutral
    }

    let message: String
    let style: Style

    var body: some View {
        switch style {
        case .error:
            Text(message)
                .font(.caption)
                .foregroundStyle(.red)
                .padding(8)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
        case .neutral:
            Text(message)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.primary)
                .padding(.horizontal, 11)
                .padding(.vertical, 6)
                .background(.regularMaterial, in: Capsule())
                .overlay {
                    Capsule()
                        .stroke(.primary.opacity(0.08), lineWidth: 1)
                }
                .shadow(color: .black.opacity(0.12), radius: 10, x: 0, y: 4)
        }
    }
}

private struct LibraryContentView: View {
    @Binding var baseDestination: LibraryDestination
    @Binding var detailPath: [LibraryRoute]
    let appModel: NyaEHAppModel
    @Bindable var preferences: AppPreferences
    let metadataConfiguration: GalleryMetadataFetchConfiguration
    let metadataBatchConfiguration: MetadataBatchConfiguration
    let isTagTranslationEnabled: Bool
    let isCoverSimilarityVersionRecommendationEnabled: Bool

    private var store: CatalogStore { appModel.catalog }
    let coverSimilarityMaximumDistance: Double
    let titleDisplayMode: BookTitleDisplayMode
    @Binding var advancedSearchPageSize: Int
    @Binding var isAdvancedSearchFacetPanelExpanded: Bool
    @Binding var isAdvancedSearchHeaderPinned: Bool
    @Binding var libraryCollectionPageSize: Int
    @Binding var tagCategoryPageSize: Int
    @Binding var homeCardWidth: Int
    @Binding var advancedSearchCardWidth: Int
    @Binding var libraryShelfCardWidth: Int
    @Binding var collectionCandidatePageSize: Int
    @Binding var versionCandidatePageSize: Int
    let readerInitialLoadLimit: Int
    let readerHoverPreviewDelayMilliseconds: Int
    let advancedSearchFocusRequest: Int
    let routeStateResetToken: Int
    @Binding var isTaskCenterPresented: Bool
    let localizer: AppLocalizer
    let developmentConfiguration: NyaEHDevelopmentConfiguration?
    let resolveLibraryRootURL: @MainActor () throws -> URL?
    @State private var requestedGroupID: String?
    @State private var advancedSearchPage = 1
    @State private var transitionBackingRouteIDs: Set<LibraryRoute.ID> = []
    @State private var transitionBackingClearTask: Task<Void, Never>?
    @State private var routeMountDeferralIDs: Set<LibraryRoute.ID> = []
    @State private var routeMountDeferralClearTask: Task<Void, Never>?
    @State private var routeScrollOffsetStore = WorkDetailRouteScrollOffsetStore()
    @State private var transientFeedback: LibraryContentTransientFeedback?
    @State private var transientFeedbackTask: Task<Void, Never>?
    @State private var pendingReaderBookID: LibraryBook.ID?

    private let routeTransitionDuration: TimeInterval = 0.35

    var body: some View {
        ZStack {
            content(for: baseDestination)
                .environment(\.coverPrivacyRule, baseDestination.coverPrivacyPage.map { preferences.coverPrivacy.rule(for: $0) } ?? CoverPrivacyRule())
                .environment(\.coverPrivacyRevealAllowed, detailPath.isEmpty)
                .environment(\.tagVisualDropTargetsEnabled, detailPath.isEmpty)
                .allowsHitTesting(detailPath.isEmpty)
                .zIndex(0)

            ForEach(Array(detailPath.enumerated()), id: \.element.id) { index, route in
                routeLayer(for: route, index: index)
                    .zIndex(Double(index + 1))
            }
        }
        .overlay(alignment: .bottom) {
            LibraryContentFeedbackOverlay(
                loadError: store.loadError,
                cleanupWarning: store.deletionCleanupWarning.map { "\(localizer.string(.deletionCleanupPending)) \($0)" },
                transientFeedback: transientFeedback
            )
            .padding()
        }
        .environment(\.navigateCardGroup, CardGroupNavigation(open: navigateCardGroup))
        .editionDeckHost(page: [baseDestination.id] + detailPath.map(\.id))
        .navigationTitle((try? TestRuntime.current.get()).map { $0.name + " · " + currentNavigationTitle } ?? currentNavigationTitle)
        .onChange(of: detailPath) { oldPath, newPath in
            retainTransitionBackingRoutes(from: oldPath, to: newPath)
            deferRouteMountIfNeeded(from: oldPath, to: newPath)
            pruneRouteScrollOffsets(from: oldPath, to: newPath)
            if let pendingReaderBookID {
                guard case .bookDetail(let visibleBookID) = newPath.last,
                      visibleBookID == pendingReaderBookID else {
                    self.pendingReaderBookID = nil
                    return
                }
            }
        }
        .onChange(of: store.derivedDataRevision) { _, _ in
            if let invalidIndex = detailPath.firstIndex(where: { route in
                switch route {
                case .bookDetail(let id): return store.book(id: id) == nil
                case .collectionDetail(let id): return store.collection(id: id) == nil
                default: return false
                }
            }) {
                updateDetailPath(Array(detailPath.prefix(invalidIndex)))
            }
        }
        .onChange(of: routeStateResetToken) { _, _ in
            routeScrollOffsetStore.clearAfterBaseDestinationChange()
        }
        .onDisappear {
            transitionBackingClearTask?.cancel()
            routeMountDeferralClearTask?.cancel()
            transientFeedbackTask?.cancel()
        }
    }

    private var currentNavigationTitle: String {
        detailPath.last.map { title(for: $0) } ?? title(for: baseDestination)
    }

    private func routeLayer(for route: LibraryRoute, index: Int) -> some View {
        let layerState = LibraryRoutePresentation.layerState(
            routeID: route.id,
            index: index,
            pathCount: detailPath.count,
            transitionBackingRouteIDs: transitionBackingRouteIDs
        )
        let isTopRoute = layerState == .active

        return routeContent(for: route, layerState: layerState)
            .environment(\.coverPrivacyRule, route.coverPrivacyPage.map { preferences.coverPrivacy.rule(for: $0) } ?? CoverPrivacyRule())
            .environment(\.coverPrivacyRevealAllowed, isTopRoute)
            .environment(\.tagVisualDropTargetsEnabled, isTopRoute)
            .allowsHitTesting(LibraryRoutePresentation.allowsHitTesting(layerState: layerState))
            .transition(routeTransition(for: route))
            .toolbar {
                if isTopRoute {
                    ToolbarItem(placement: .navigation) {
                        Button(action: closeTopRoute) {
                            Label(backTitle(forRouteAt: index), systemImage: "chevron.left")
                        }
                    }
                }
            }
    }

    @ViewBuilder
    private func content(for destination: LibraryDestination) -> some View {
        switch destination {
        case .home:
            LibraryHomeView(
                store: appModel.home,
                pageIsActive: detailPath.isEmpty,
                isTagTranslationEnabled: isTagTranslationEnabled,
                titleDisplayMode: titleDisplayMode,
                localizer: localizer,
                onSelect: { book in openBook(book, source: .home) },
                onOpenFavorites: {
                    withAnimation(.snappy(duration: 0.28)) {
                        baseDestination = .favoriteManagement
                        updateDetailPath(LibraryNavigationPathReducer.pathAfterSelectingBaseDestination())
                    }
                },
                onOpenRecentSearch: openRecentSearch,
                onImport: {
                    baseDestination = .importLibrary
                    updateDetailPath(LibraryNavigationPathReducer.pathAfterSelectingBaseDestination())
                }
            )
        case .search:
            AdvancedSearchView(
                store: appModel.search,
                preferences: preferences,
                metadataBatchConfiguration: metadataBatchConfiguration,
                isTagTranslationEnabled: isTagTranslationEnabled,
                titleDisplayMode: titleDisplayMode,
                page: $advancedSearchPage,
                pageSize: $advancedSearchPageSize,
                isFacetPanelExpanded: $isAdvancedSearchFacetPanelExpanded,
                isHeaderPinned: $isAdvancedSearchHeaderPinned,
                isCollectionMembersExpanded: store.advancedSearchShowsIndividualBooks,
                cardWidth: $advancedSearchCardWidth,
                focusRequest: advancedSearchFocusRequest,
                isActive: detailPath.isEmpty,
                localizer: localizer,
                onFeedback: showTransientFeedback,
                onSelect: { item in openDisplayItem(item, source: .search) }
            )
        case .library:
            LibraryShelfView(
                store: store,
                titleDisplayMode: titleDisplayMode,
                pageSize: $libraryCollectionPageSize,
                cardWidth: $libraryShelfCardWidth,
                localizer: localizer,
                onSelect: { item in openDisplayItem(item, source: .library) }
            )
        case .tagCategory(let category):
            TagCategoryView(
                store: appModel.tagDiscovery,
                taskCenterStore: appModel.taskCenter,
                category: category,
                isActive: detailPath.isEmpty,
                isTagTranslationEnabled: isTagTranslationEnabled,
                pageSize: $tagCategoryPageSize,
                isTaskCenterPresented: $isTaskCenterPresented,
                localizer: localizer,
                onSelectTag: { tag in openTag(tag) }
            )
        case .collection(let filter):
            BookCollectionView(
                store: store,
                filter: filter,
                metadataBatchConfiguration: metadataBatchConfiguration,
                titleDisplayMode: titleDisplayMode,
                pageSize: $libraryCollectionPageSize,
                localizer: localizer,
                onSelect: { item in openDisplayItem(item, source: .library) }
            )
        case .collectionManagement:
            CollectionManagementView(
                requestedGroupID: $requestedGroupID,
                store: appModel.organization,
                titleDisplayMode: titleDisplayMode,
                isTagTranslationEnabled: isTagTranslationEnabled,
                isSemanticSeriesRecommendationEnabled: preferences.isSemanticSeriesRecommendationEnabled,
                candidatePageSize: $collectionCandidatePageSize,
                isCandidateAreaVisible: $preferences.isCollectionCandidateAreaVisible,
                showsManagementToolbar: detailPath.isEmpty,
                localizer: localizer,
                onSelect: { book in openBook(book, source: .management) }
            )
        case .favoriteManagement:
            FavoriteManagementView(
                store: store,
                titleDisplayMode: titleDisplayMode,
                localizer: localizer,
                onSelect: { book in openBook(book, source: .management) }
            )
        case .versionManagement:
            VersionManagementView(
                requestedGroupID: $requestedGroupID,
                store: appModel.organization,
                titleDisplayMode: titleDisplayMode,
                isTagTranslationEnabled: isTagTranslationEnabled,
                isCoverSimilarityVersionRecommendationEnabled: isCoverSimilarityVersionRecommendationEnabled,
                coverSimilarityMaximumDistance: coverSimilarityMaximumDistance,
                candidatePageSize: $versionCandidatePageSize,
                isCandidateAreaVisible: $preferences.isVersionCandidateAreaVisible,
                showsManagementToolbar: detailPath.isEmpty,
                localizer: localizer,
                onSelect: { book in openBook(book, source: .management) },
                onOpenReader: { book in
                    pendingReaderBookID = book.id
                    openBook(book, source: .management)
                }
            )
        case .importLibrary:
            ImportLibraryView(
                store: appModel.taskCenter,
                preferences: preferences,
                metadataBatchConfiguration: metadataBatchConfiguration,
                titleDisplayMode: titleDisplayMode,
                pageSize: $libraryCollectionPageSize,
                localizer: localizer,
                onSelect: { item in openDisplayItem(item, source: .library) },
                onOpenVersionReview: {
                    withAnimation(.snappy(duration: 0.28)) {
                        baseDestination = .versionManagement
                        updateDetailPath(LibraryNavigationPathReducer.pathAfterSelectingBaseDestination())
                    }
                },
                onOpenCollectionReview: {
                    withAnimation(.snappy(duration: 0.28)) {
                        baseDestination = .collectionManagement
                        updateDetailPath(LibraryNavigationPathReducer.pathAfterSelectingBaseDestination())
                    }
                }
            )
        case .developmentTools:
            if let developmentConfiguration {
                DevelopmentToolsView(
                    catalog: store, titleDisplayMode: titleDisplayMode, initialCardWidth: homeCardWidth,
                    resolveLibraryRootURL: resolveLibraryRootURL,
                    onOpenRecentSearch: openRecentSearch,
                    configuration: developmentConfiguration,
                    localizer: localizer,
                    readerDisplayPreferences: preferences.readerDisplayPreferences,
                    onReaderDisplayPreferencesChange: {
                        preferences.readerDisplayPreferences = $0
                    },
                    savedReaderWindowFrame: preferences.savedReaderWindowFrame(),
                    onReaderWindowFrameChange: preferences.saveReaderWindowFrame
                )
            } else {
                ContentUnavailableView(
                    localizer.string(.developmentToolsUnavailable),
                    systemImage: "hammer"
                )
            }
        }
    }

    @ViewBuilder
    private func routeContent(for route: LibraryRoute, layerState: LibraryRouteLayerState) -> some View {
        switch LibraryRoutePresentation.contentWeight(for: layerState) {
        case .full:
            routeMountedContent(for: route)
        case .frozenPlaceholder:
            frozenRouteContent(for: route)
        }
    }

    @ViewBuilder
    private func routeMountedContent(for route: LibraryRoute) -> some View {
        switch LibraryRouteMountDeferralPolicy.content(for: route, deferredRouteIDs: routeMountDeferralIDs) {
        case .transitionShell:
            switch route {
            case .workDetail(let tagID):
                WorkDetailTransitionShell(
                    detail: store.workDetail(tagID: tagID),
                    fallbackTitle: localizer.string(.detailWorks),
                    localizer: localizer
                )
                .background(.background)
                .task(id: "work-transition-\(tagID)-\(isTagTranslationEnabled)") {
                    store.reloadWorkDetail(
                        tagID: tagID,
                        isTagTranslationEnabled: isTagTranslationEnabled
                    )
                }
            case .characterDetail(let tagID):
                CharacterDetailTransitionShell(
                    detail: store.characterDetail(tagID: tagID),
                    fallbackTitle: localizer.string(.tagNamespaceCharacter),
                    localizer: localizer
                )
                .background(.background)
                .task(id: "character-transition-\(tagID)-\(isTagTranslationEnabled)") {
                    store.reloadCharacterDetail(
                        tagID: tagID,
                        isTagTranslationEnabled: isTagTranslationEnabled
                    )
                }
            case .bookDetail(let bookID):
                BookDetailTransitionShell(
                    book: store.selectedBook ?? store.book(id: bookID),
                    titleDisplayMode: titleDisplayMode,
                    localizer: localizer
                )
                .background(.background)
            case .collectionDetail:
                routeContent(for: route)
            }
        case .full:
            routeContent(for: route)
        }
    }

    @ViewBuilder
    private func routeContent(for route: LibraryRoute) -> some View {
        switch route {
        case .bookDetail(let bookID):
            BookDetailView(
                store: appModel.reading,
                book: store.selectedBook ?? store.book(id: bookID),
                metadataConfiguration: metadataConfiguration,
                isTagTranslationEnabled: isTagTranslationEnabled,
                titleDisplayMode: titleDisplayMode,
                readerInitialLoadLimit: readerInitialLoadLimit,
                readerHoverPreviewDelayMilliseconds: readerHoverPreviewDelayMilliseconds,
                readerDisplayPreferences: preferences.readerDisplayPreferences,
                onReaderDisplayPreferencesChange: {
                    preferences.readerDisplayPreferences = $0
                },
                savedReaderWindowFrame: preferences.savedReaderWindowFrame(),
                onReaderWindowFrameChange: preferences.saveReaderWindowFrame,
                usesExternalTransitionShell: true,
                readerLaunchRequestBookID: pendingReaderBookID == bookID ? bookID : nil,
                onReaderLaunchRequestHandled: { pendingReaderBookID = nil },
                localizer: localizer,
                resolveLibraryRootURL: resolveLibraryRootURL,
                onSelectRelatedBook: { book in openBook(book, source: .bookDetail) },
                onSelectTag: { tag in
                    store.searchBooks(
                        matching: tag,
                        isTagTranslationEnabled: isTagTranslationEnabled
                    )
                    withAnimation(.snappy(duration: 0.28)) {
                        baseDestination = .search
                        updateDetailPath(LibraryNavigationPathReducer.pathAfterSelectingBaseDestination())
                    }
                },
                onTitleModeFeedback: showTransientFeedback
            )
            .background(.background)
        case .collectionDetail(let collectionID):
            CollectionDetailView(
                store: appModel.organization,
                collection: store.collection(id: collectionID),
                titleDisplayMode: titleDisplayMode,
                pageSize: $libraryCollectionPageSize,
                localizer: localizer,
                onSelect: { book in openBook(book, source: .collectionDetail) }
            )
            .background(.background)
        case .workDetail(let tagID):
            WorkDetailView(
                store: appModel.tagDiscovery,
                tagID: tagID,
                isTagTranslationEnabled: isTagTranslationEnabled,
                titleDisplayMode: titleDisplayMode,
                initialScrollOffset: routeScrollOffsetStore.offset(for: route.id),
                usesExternalTransitionShell: true,
                localizer: localizer,
                onScrollOffsetChange: { routeScrollOffsetStore.setOffset($0, for: route.id) },
                onSelectBook: { book in openBook(book, source: .workDetail) },
                onSelectCharacter: { character in openRelatedTopic(.characterDetail(character.id)) },
                onSearchWork: { tag in
                    store.searchBooks(
                        matching: tag,
                        isTagTranslationEnabled: isTagTranslationEnabled
                    )
                    withAnimation(.snappy(duration: 0.28)) {
                        baseDestination = .search
                        updateDetailPath(LibraryNavigationPathReducer.pathAfterSelectingBaseDestination())
                    }
                }
            )
            .background(.background)
        case .characterDetail(let tagID):
            CharacterDetailView(
                store: appModel.tagDiscovery,
                tagID: tagID,
                isTagTranslationEnabled: isTagTranslationEnabled,
                titleDisplayMode: titleDisplayMode,
                initialScrollOffset: routeScrollOffsetStore.offset(for: route.id),
                usesExternalTransitionShell: true,
                localizer: localizer,
                onScrollOffsetChange: { routeScrollOffsetStore.setOffset($0, for: route.id) },
                onSelectBook: { book in openBook(book, source: .characterDetail) },
                onSelectWork: { work in openRelatedTopic(.workDetail(work.id)) },
                onSearchCharacter: { tag in
                    store.searchBooks(
                        matching: tag,
                        isTagTranslationEnabled: isTagTranslationEnabled
                    )
                    withAnimation(.snappy(duration: 0.28)) {
                        baseDestination = .search
                        updateDetailPath(LibraryNavigationPathReducer.pathAfterSelectingBaseDestination())
                    }
                }
            )
            .background(.background)
        }
    }

    @ViewBuilder
    private func frozenRouteContent(for route: LibraryRoute) -> some View {
        switch route {
        case .bookDetail(let bookID):
            FrozenBookRouteView(
                book: store.selectedBook ?? store.book(id: bookID),
                titleDisplayMode: titleDisplayMode,
                localizer: localizer
            )
        case .collectionDetail(let collectionID):
            let collection = store.collection(id: collectionID)
            FrozenCollectionRouteView(
                collection: collection,
                bookCount: collection.map { store.displayBooks(in: $0).count } ?? 0,
                localizer: localizer
            )
        case .workDetail(let tagID):
            FrozenWorkRouteView(
                detail: store.workDetail(tagID: tagID),
                fallbackTitle: localizer.string(.detailWorks),
                localizer: localizer
            )
        case .characterDetail(let tagID):
            FrozenCharacterRouteView(
                detail: store.characterDetail(tagID: tagID),
                fallbackTitle: localizer.string(.tagNamespaceCharacter),
                localizer: localizer
            )
        }
    }

    private func showTransientFeedback(_ message: String) {
        transientFeedbackTask?.cancel()
        let feedback = LibraryContentTransientFeedback(message: message)
        withAnimation(.snappy(duration: 0.18)) {
            transientFeedback = feedback
        }
        transientFeedbackTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(LibraryContentTransientFeedback.durationMilliseconds))
            guard !Task.isCancelled, transientFeedback?.id == feedback.id else {
                return
            }
            withAnimation(.snappy(duration: 0.18)) {
                transientFeedback = nil
            }
            transientFeedbackTask = nil
        }
    }

    private func retainTransitionBackingRoutes(from oldPath: [LibraryRoute], to newPath: [LibraryRoute]) {
        let backingIDs = LibraryRouteTransitionBackingResolver.backingRouteIDs(from: oldPath, to: newPath)
        guard !backingIDs.isEmpty else {
            return
        }

        var transaction = Transaction(animation: nil)
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            transitionBackingRouteIDs.formUnion(backingIDs)
        }
        transitionBackingClearTask?.cancel()
        transitionBackingClearTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(routeTransitionDuration))
            guard !Task.isCancelled else {
                return
            }
            transitionBackingRouteIDs.subtract(backingIDs)
        }
    }

    private func deferRouteMountIfNeeded(from oldPath: [LibraryRoute], to newPath: [LibraryRoute]) {
        let deferredIDs = LibraryRouteMountDeferralPolicy.deferredRouteIDs(from: oldPath, to: newPath)
        guard !deferredIDs.isEmpty else {
            return
        }

        var transaction = Transaction(animation: nil)
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            routeMountDeferralIDs.formUnion(deferredIDs)
        }
        routeMountDeferralClearTask?.cancel()
        routeMountDeferralClearTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(routeTransitionDuration))
            guard !Task.isCancelled else {
                return
            }
            var transaction = Transaction(animation: nil)
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                routeMountDeferralIDs.subtract(deferredIDs)
            }
        }
    }

    private func pruneRouteScrollOffsets(from oldPath: [LibraryRoute], to newPath: [LibraryRoute]) {
        routeScrollOffsetStore.pruneAfterPathChange(
            oldPath: oldPath,
            newPath: newPath
        )
    }

    private func closeTopRoute() {
        guard !detailPath.isEmpty else {
            return
        }

        withAnimation(.snappy(duration: 0.28)) {
            updateDetailPath(LibraryNavigationPathReducer.pathAfterGoingBack(from: detailPath))
        }
    }

    private func routeTransition(for route: LibraryRoute) -> AnyTransition {
        switch LibraryRoutePresentation.transitionStyle(for: route) {
        case .identity:
            return .identity
        case .trailingMoveOpacity:
            return .move(edge: .trailing).combined(with: .opacity)
        }
    }

    private func backTitle(forRouteAt index: Int) -> String {
        guard index > 0 else {
            return title(for: baseDestination)
        }
        return title(for: detailPath[index - 1])
    }

    private func title(for destination: LibraryDestination) -> String {
        switch destination {
        case .home:
            return localizer.string(.home)
        case .search:
            return localizer.string(.advancedSearch)
        case .library:
            return localizer.string(.libraryShelf)
        case .tagCategory(let category):
            return localizer.string(category.titleKey)
        case .collection(let filter):
            return localizer.string(filter.titleKey)
        case .favoriteManagement:
            return localizer.string(.favoriteManagement)
        case .collectionManagement:
            return localizer.string(.collectionManagement)
        case .versionManagement:
            return localizer.string(.versionManagement)
        case .importLibrary:
            return localizer.string(.importLibrary)
        case .developmentTools:
            return localizer.string(.developmentTools)
        }
    }

    private func title(for route: LibraryRoute) -> String {
        switch route {
        case .bookDetail(let bookID):
            let book = store.selectedBook ?? store.book(id: bookID)
            return book.map { BookTitleFormatter.displayTitle(for: $0, mode: titleDisplayMode) }
                ?? localizer.string(.details)
        case .collectionDetail(let collectionID):
            return store.collection(id: collectionID)?.name ?? localizer.string(.selectCollection)
        case .workDetail(let tagID):
            return store.workDetail(tagID: tagID)?.work.displayText ?? localizer.string(.detailWorks)
        case .characterDetail(let tagID):
            return store.characterDetail(tagID: tagID)?.character.displayText ?? localizer.string(.tagNamespaceCharacter)
        }
    }

    private func openTag(_ tag: TagDisplaySummary) {
        switch TagOpenDestinationResolver.destination(for: tag) {
        case .search:
            openSearch(for: tag)
        case .workDetail:
            openWork(tag)
        case .characterDetail:
            openCharacter(tag)
        }
    }

    private func openRecentSearch() {
        advancedSearchPage = 1
        store.advancedSearchPageSize = advancedSearchPageSize
        store.searchRecentlyAddedBooks(isTagTranslationEnabled: isTagTranslationEnabled)
        withAnimation(.snappy(duration: 0.28)) {
            baseDestination = .search
            updateDetailPath(LibraryNavigationPathReducer.pathAfterSelectingBaseDestination())
        }
    }

    private func openSearch(for tag: TagDisplaySummary) {
        store.searchBooks(
            matching: tag,
            isTagTranslationEnabled: isTagTranslationEnabled
        )
        withAnimation(.snappy(duration: 0.28)) {
            baseDestination = .search
            updateDetailPath(LibraryNavigationPathReducer.pathAfterSelectingBaseDestination())
        }
    }

    private func openWork(_ tag: TagDisplaySummary) {
        withAnimation(.snappy(duration: 0.35)) {
            updateDetailPath([.workDetail(tag.id)])
        }
    }

    private func openCharacter(_ tag: TagDisplaySummary) {
        withAnimation(.snappy(duration: 0.35)) {
            updateDetailPath([.characterDetail(tag.id)])
        }
    }

    private func openRelatedTopic(_ route: LibraryRoute) {
        withAnimation(.snappy(duration: 0.35)) {
            updateDetailPath(LibraryNavigationPathReducer.pathAfterOpeningTopic(route, currentPath: detailPath))
        }
    }

    private func openBook(_ book: LibraryBook, source: BookOpenSource) {
        let nextRoute = LibraryRoute.bookDetail(book.id)
        NavigationPerformanceTracer.openBookStarted(
            source: source,
            bookID: book.id,
            returnDestinationID: navigationReturnID(for: source)
        )
        store.selectedBookID = book.id
        NavigationPerformanceTracer.selectedBookDidSet(bookID: book.id)

        NavigationPerformanceTracer.destinationWillChange(bookID: book.id, destinationID: nextRoute.id)
        applyBookRoute(nextRoute, source: source)
        NavigationPerformanceTracer.destinationDidChange(bookID: book.id, destinationID: nextRoute.id)
    }

    private func applyBookRoute(_ route: LibraryRoute, source: BookOpenSource) {
        var transaction = Transaction(animation: source.usesAnimatedBookDetailTransition ? .snappy(duration: 0.22) : nil)
        transaction.disablesAnimations = !source.usesAnimatedBookDetailTransition
        withTransaction(transaction) {
            if case .bookDetail(let bookID) = route {
                updateDetailPath(LibraryNavigationPathReducer.pathAfterOpeningBook(
                    bookID,
                    source: source,
                    currentPath: detailPath
                ))
            }
        }
    }

    private func navigateCardGroup(_ destination: CardGroupDestination) {
        switch destination {
        case .series(let id):
            guard store.collection(id: id) != nil else { return }
            let route = LibraryRoute.collectionDetail(id)
            if let existing = detailPath.firstIndex(of: route) {
                updateDetailPath(Array(detailPath.prefix(through: existing)))
            } else {
                updateDetailPath(detailPath + [route])
            }
        case .manageSeries(let id):
            guard store.collection(id: id) != nil else { return }
            requestedGroupID = id
            baseDestination = .collectionManagement
            updateDetailPath([])
        case .manageVersions(let id):
            guard store.versionGroup(id: id) != nil else { return }
            requestedGroupID = id
            baseDestination = .versionManagement
            updateDetailPath([])
        }
    }

    private func openDisplayItem(_ item: LibraryDisplayItem, source: BookOpenSource) {
        switch item {
        case .book(let book):
            openBook(book, source: source)
        case .collection(let item):
            withAnimation(.snappy(duration: 0.35)) {
                updateDetailPath([.collectionDetail(item.collection.id)])
            }
        }
    }

    private func updateDetailPath(_ nextPath: [LibraryRoute]) {
        retainTransitionBackingRoutes(from: detailPath, to: nextPath)
        deferRouteMountIfNeeded(from: detailPath, to: nextPath)
        detailPath = nextPath
    }

    private func navigationReturnID(for source: BookOpenSource) -> String {
        switch source {
        case .bookDetail:
            return detailPath.dropLast().last?.id ?? baseDestination.id
        case .workDetail, .characterDetail, .collectionDetail:
            return detailPath.last?.id ?? baseDestination.id
        case .home, .search, .library, .management:
            return baseDestination.id
        }
    }
}
