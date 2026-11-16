// 本文件组合导入仪表盘与原始记录收件箱，业务操作继续由 CatalogStore 执行。

import AppKit
import SwiftUI

struct ImportLibraryView: View {
    @Bindable var store: TaskCenterStore
    @Bindable var preferences: AppPreferences
    let metadataBatchConfiguration: MetadataBatchConfiguration
    let titleDisplayMode: BookTitleDisplayMode
    @Binding var pageSize: Int
    let localizer: AppLocalizer
    let onSelect: (LibraryDisplayItem) -> Void
    let onOpenVersionReview: () -> Void
    let onOpenCollectionReview: () -> Void

    @SceneStorage("importLibrary.searchText") private var searchText = ""
    @SceneStorage("importLibrary.inboxFilter") private var inboxFilterRawValue = ImportInboxFilter.pending.rawValue
    @State private var page = 1
    @State private var retryItem: ImportPipelineItem?
    @State private var retryGalleryURL = ""
    @State private var showsInvalidClipboardURLAlert = false
    @State private var paginationFooterHeight = ImportLibraryFloatingMetrics.defaultFooterHeight

    private var pipelineItemsByBookID: [LibraryBook.DatabaseID: ImportPipelineItem] {
        store.catalog.importPipelineSnapshot.itemsByBookID
    }

    private var inboxBooks: [LibraryBook] {
        ImportLibraryPresentation.inboxBooks(
            books: store.catalog.books,
            itemsByBookID: pipelineItemsByBookID
        )
    }

    private var inboxFilter: ImportInboxFilter {
        ImportInboxFilter(rawValue: inboxFilterRawValue) ?? .pending
    }

    private var filteredBooks: [LibraryBook] {
        ImportLibraryPresentation.filteredBooks(
            inboxBooks,
            itemsByBookID: pipelineItemsByBookID,
            query: searchText,
            filter: inboxFilter
        )
    }

    private var clampedPage: Int {
        Pagination.clampedPage(page, itemCount: filteredBooks.count, pageSize: pageSize)
    }

    private var pageBooks: [LibraryBook] {
        Pagination.pageItems(filteredBooks, page: clampedPage, pageSize: pageSize)
    }

    private var showsPaginationFooter: Bool {
        ImportLibraryPresentation.showsPaginationFooter(
            loadError: store.catalog.loadError,
            filteredCount: filteredBooks.count
        )
    }

    private var workflowPresentation: ImportWorkflowPresentation {
        ImportWorkflowPresentation.make(
            hasLibraryRoot: preferences.libraryRootPath != nil,
            hasCompletedScan: preferences.lastLibraryScanCompletedAt != nil,
            isScanning: store.catalog.isScanning,
            batch: store.catalog.importPipelineSnapshot.activeBatch,
            isProcessing: store.catalog.isProcessingImportPipeline,
            inboxIsEmpty: inboxBooks.isEmpty
        )
    }

    var body: some View {
        GeometryReader { _ in
            pageLayers
        }
        .navigationTitle(localizer.string(.importLibrary))
        .overlay(alignment: .topTrailing) {
            OrganizationSaveStatusView(store: store.catalog, localizer: localizer)
                .padding(12)
        }
        .onPreferenceChange(ImportPaginationFooterHeightPreferenceKey.self) { height in
            guard height > 0 else { return }
            paginationFooterHeight = height
        }
        .onChange(of: filteredBooks.count) { _, _ in
            page = clampedPage
        }
        .onChange(of: searchText) { _, _ in
            page = 1
        }
        .onChange(of: inboxFilterRawValue) { _, _ in
            page = 1
        }
        .onChange(of: pageSize) { _, _ in
            page = 1
        }
        .task {
            store.catalog.reloadImportPipeline()
        }
        .sheet(item: $retryItem) { item in
            ImportPipelineRetrySheet(
                galleryURL: $retryGalleryURL,
                localizer: localizer,
                onCancel: { retryItem = nil },
                onSubmit: {
                    let url = retryGalleryURL.trimmingCharacters(in: .whitespacesAndNewlines)
                    store.catalog.retryImportPipelineItem(item, preferredGalleryURL: url.isEmpty ? nil : url)
                    retryItem = nil
                }
            )
        }
        .alert(
            localizer.string(.importRetryFromClipboard),
            isPresented: $showsInvalidClipboardURLAlert
        ) {} message: {
            Text(localizer.string(.importClipboardGalleryURLInvalid))
        }
    }

    private var pageLayers: some View {
        ZStack(alignment: .top) {
            ScrollView {
                pageContent
            }

            if showsPaginationFooter {
                VStack(spacing: 0) {
                    Spacer(minLength: 0)
                    HStack(spacing: 0) {
                        paginationFooter
                        Spacer(minLength: 0)
                    }
                    .frame(maxWidth: 1_440)
                    .padding(.horizontal, ImportLibraryFloatingMetrics.horizontalPadding)
                    .frame(maxWidth: .infinity)
                    .padding(.bottom, ImportLibraryFloatingMetrics.bottomPadding)
                }
                .zIndex(10)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var pageContent: some View {
        LazyVStack(alignment: .leading, spacing: 18, pinnedViews: [.sectionHeaders]) {
            dashboard

            Section {
                inboxContent
            } header: {
                ImportInboxToolbar(
                    searchText: $searchText,
                    filter: Binding(
                        get: { inboxFilter },
                        set: { inboxFilterRawValue = $0.rawValue }
                    ),
                    filteredCount: filteredBooks.count,
                    totalCount: inboxBooks.count,
                    localizer: localizer
                )
            }

            if showsPaginationFooter {
                Color.clear
                    .frame(height: paginationFooterHeight + ImportLibraryFloatingMetrics.contentGap)
                    .accessibilityHidden(true)
            }
        }
        .frame(maxWidth: 1_440)
        .padding(.horizontal, 24)
        .padding(.vertical, 20)
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private var dashboard: some View {
        if #available(macOS 26.0, *) {
            GlassEffectContainer(spacing: 0) {
                dashboardContent
            }
        } else {
            dashboardContent
        }
    }

    private var dashboardContent: some View {
        ViewThatFits(in: .horizontal) {
            Grid(alignment: .top, horizontalSpacing: 16) {
                GridRow(alignment: .top) {
                    workflowCard
                        .frame(minWidth: 480, maxWidth: .infinity)
                    settingsCard
                        .frame(minWidth: 360, idealWidth: 400, maxWidth: 440)
                }
            }

            VStack(alignment: .leading, spacing: 16) {
                workflowCard
                settingsCard
            }
        }
    }

    private var workflowCard: some View {
        ImportWorkflowCard(
            presentation: workflowPresentation,
            batch: store.catalog.importPipelineSnapshot.activeBatch,
            pipelineMessage: store.catalog.importPipelineMessage,
            localizer: localizer,
            onPrimaryAction: performPrimaryAction
        )
    }

    private var settingsCard: some View {
        ImportSettingsCard(
            libraryRootPath: preferences.libraryRootPath,
            lastScanText: lastScanText,
            scanSummary: store.catalog.scanSummary,
            isScanning: store.catalog.isScanning,
            gallerySearchSite: $preferences.gallerySearchSite,
            localizer: localizer,
            onSelectLibrary: chooseLibraryRoot,
            onScan: scanLibrary
        )
    }

    @ViewBuilder
    private var inboxContent: some View {
        if let loadError = store.catalog.loadError, store.catalog.organizationSaveError == nil {
            ImportInboxEmptyState(
                title: localizer.string(.unknown),
                description: loadError,
                systemImage: "exclamationmark.triangle"
            )
        } else if inboxBooks.isEmpty {
            ImportInboxEmptyState(
                title: localizer.string(.noBooks),
                description: localizer.string(.importInboxEmptyDescription),
                systemImage: "checkmark.circle"
            )
        } else if filteredBooks.isEmpty {
            ImportInboxEmptyState(
                title: localizer.string(.importInboxNoResults),
                description: localizer.string(.importInboxNoResultsDescription),
                systemImage: "line.3.horizontal.decrease.circle"
            )
        } else {
            ForEach(pageBooks) { book in
                ImportInboxBookRow(
                    book: book,
                    item: pipelineItem(for: book),
                    titleDisplayMode: titleDisplayMode,
                    localizer: localizer,
                    isSavingOrganization: book.databaseID.map { store.catalog.savingOrganizationKeys.contains("book:\($0)") } ?? false,
                    onOpen: { open(book) },
                    onRetry: { beginRetry($0) },
                    onCopyTitle: { copyTitle(book) },
                    onRetryFromPasteboard: { retryFromPasteboard($0) },
                    onSkipMetadata: { store.catalog.skipImportPipelineMetadata($0) },
                    onResetRecommendations: { store.catalog.resetDismissedImportRecommendations(for: book) },
                    onOpenVersionReview: { openVersionMembership(book) },
                    onOpenCollectionReview: { openCollectionMembership(book) },
                    onRemoveVersionMembership: { store.catalog.removeBookFromVersionGroup(book) },
                    onRemoveCollectionMembership: { removeCollectionMembership(book) }
                )
            }
        }
    }

    private var paginationFooter: some View {
        FloatingPaginationPanel(
            page: $page,
            pageSize: $pageSize,
            itemCount: filteredBooks.count,
            localizer: localizer
        )
        .background {
            GeometryReader { proxy in
                Color.clear.preference(
                    key: ImportPaginationFooterHeightPreferenceKey.self,
                    value: proxy.size.height
                )
            }
        }
    }

    private func performPrimaryAction(_ action: ImportPipelinePrimaryAction) {
        switch action {
        case .continueIncomplete:
            do {
                guard let rootURL = try preferences.resolvedLibraryRootURL() else {
                    store.catalog.loadError = localizer.string(.libraryNotSelected)
                    return
                }
                store.catalog.startImportPipeline(
                    securityScopedRootURL: rootURL,
                    configuration: metadataBatchConfiguration,
                    useCoverSimilarity: preferences.isCoverSimilarityVersionRecommendationEnabled,
                    useSemanticSeriesSimilarity: preferences.isSemanticSeriesRecommendationEnabled,
                    maximumCoverDistance: preferences.coverSimilarityMaximumDistance,
                    localizer: localizer
                )
            } catch {
                store.catalog.loadError = error.localizedDescription
            }
        case .pause:
            store.catalog.pauseImportPipeline()
        case .openVersionReview:
            onOpenVersionReview()
        case .openCollectionReview:
            onOpenCollectionReview()
        case .none:
            break
        }
    }

    private func open(_ book: LibraryBook) {
        store.catalog.selectedBookID = book.id
        onSelect(.book(book))
    }

    private func beginRetry(_ item: ImportPipelineItem) {
        retryGalleryURL = item.preferredGalleryURL ?? ""
        retryItem = item
    }

    private func copyTitle(_ book: LibraryBook) {
        let title = BookTitleFormatter.displayTitle(for: book, mode: titleDisplayMode)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(title, forType: .string)
    }

    private func retryFromPasteboard(_ item: ImportPipelineItem) {
        guard let galleryURL = ImportGalleryURLPasteboardReader.read() else {
            showsInvalidClipboardURLAlert = true
            return
        }
        store.catalog.retryImportPipelineItem(
            item,
            preferredGalleryURL: galleryURL.absoluteString
        )
    }

    private func pipelineItem(for book: LibraryBook) -> ImportPipelineItem? {
        guard let bookID = book.databaseID else { return nil }
        return pipelineItemsByBookID[bookID]
    }

    private func openVersionMembership(_ book: LibraryBook) {
        if let versionGroupID = book.versionGroupID {
            store.catalog.selectedVersionGroupID = String(versionGroupID)
        }
        onOpenVersionReview()
    }

    private func openCollectionMembership(_ book: LibraryBook) {
        if let collectionID = book.collectionID {
            store.catalog.selectedCollectionID = String(collectionID)
        }
        onOpenCollectionReview()
    }

    private func removeCollectionMembership(_ book: LibraryBook) {
        guard let collectionID = book.collectionID,
              let collection = store.catalog.collection(id: String(collectionID)) else {
            return
        }
        store.catalog.removeBook(book, from: collection)
    }

    private var lastScanText: String {
        guard let milliseconds = preferences.lastLibraryScanCompletedAt else {
            return localizer.string(.neverScanned)
        }
        return Date(timeIntervalSince1970: Double(milliseconds) / 1_000)
            .formatted(date: .abbreviated, time: .shortened)
    }

    private func chooseLibraryRoot() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.prompt = localizer.string(.selectLibrary)

        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try preferences.setLibraryRoot(url: url)
            preferences.lastLibraryScanCompletedAt = nil
            store.catalog.scanSummary = nil
        } catch {
            store.catalog.loadError = error.localizedDescription
        }
    }

    private func scanLibrary() {
        do {
            guard let rootURL = try preferences.resolvedLibraryRootURL() else {
                store.catalog.loadError = localizer.string(.libraryNotSelected)
                return
            }
            store.catalog.scanLibrary(rootURL: rootURL, localizer: localizer) { _ in
                preferences.lastLibraryScanCompletedAt = Timestamp.nowMilliseconds()
            }
        } catch {
            store.catalog.loadError = error.localizedDescription
        }
    }
}

private enum ImportLibraryFloatingMetrics {
    static let horizontalPadding: CGFloat = 24
    static let bottomPadding: CGFloat = 16
    static let contentGap: CGFloat = 8
    static let defaultFooterHeight: CGFloat = 52
}

private struct ImportPaginationFooterHeightPreferenceKey: PreferenceKey {
    static let defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}
