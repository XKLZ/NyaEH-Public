// 本文件实现书籍详情、元数据维护、相关书籍、标签解释和按需阅读器，是最重的单书工作台。

import AppKit
import SwiftUI

struct BookDetailView: View {
    @Bindable var store: ReadingStore
    let book: LibraryBook?
    let metadataConfiguration: GalleryMetadataFetchConfiguration
    let isTagTranslationEnabled: Bool
    let titleDisplayMode: BookTitleDisplayMode
    let readerInitialLoadLimit: Int
    let readerHoverPreviewDelayMilliseconds: Int
    let readerDisplayPreferences: ReaderDisplayPreferences
    let onReaderDisplayPreferencesChange: (ReaderDisplayPreferences) -> Void
    let savedReaderWindowFrame: CGRect?
    let onReaderWindowFrameChange: (CGRect) -> Void
    let usesExternalTransitionShell: Bool
    let readerLaunchRequestBookID: LibraryBook.ID?
    let onReaderLaunchRequestHandled: () -> Void
    let localizer: AppLocalizer
    let resolveLibraryRootURL: @MainActor () throws -> URL?
    let onSelectRelatedBook: (LibraryBook) -> Void
    let onSelectTag: (TagDisplaySummary) -> Void
    let onTitleModeFeedback: (String) -> Void

    @State private var localTitleMode: BookTitleDisplayMode?
    @State private var displayTags: [TagDisplaySummary] = []
    @State private var isURLDialogPresented = false
    @State private var isDeleteBookConfirmationPresented = false
    @State private var deleteBookConfirmationText = ""
    @State private var deleteBookConfirmationCode = DeleteBookConfirmationCode.generate()
    @State private var metadataEditorPresenter = BookMetadataEditorWindowPresenter()
    @State private var activeTagExplanation: ActiveTagExplanation?
    @State private var tagPillFrames: [Tag.DatabaseID: CGRect] = [:]
    @State private var resolvedThemeColors: [LibraryBook.ID: NSColor] = [:]
    @State private var displayedBackgroundThemeColor = BookDetailThemeColorPolicy.safeFallbackColor
    @State private var heroTitleColumnHeight = BookDetailHeroMotionMetrics.defaultExpandedTitleColumnHeight
    @State private var readerLauncher = BookReaderLauncher()
    // 详情页会在导航转场后再挂载重内容；session token 防止旧异步任务在用户切到另一本书后回写状态。
    @State private var deferredSectionsBookID: LibraryBook.ID?
    @State private var detailSession = BookDetailSessionToken.inactive
    @State private var hasConsumedExternalTransitionShell = false

    private var activeTitleMode: BookTitleDisplayMode {
        localTitleMode ?? titleDisplayMode
    }

    private var contentReplacementTransition: AnyTransition {
        shouldSuppressInitialContentReplacementMotion
            ? .identity
            : BookDetailContentReplacementMotion.transition
    }

    private var contentReplacementAnimation: Animation? {
        shouldSuppressInitialContentReplacementMotion
            ? nil
            : BookDetailContentReplacementMotion.animation
    }

    private var shouldSuppressInitialContentReplacementMotion: Bool {
        BookDetailExternalTransitionShellPolicy.shouldSuppressContentReplacementMotion(
            usesExternalTransitionShell: usesExternalTransitionShell,
            hasConsumedExternalTransitionShell: hasConsumedExternalTransitionShell
        )
    }

    var body: some View {
        Group {
            if let book = book ?? store.catalog.selectedBook {
                detailContent(for: book)
            } else {
                ContentUnavailableView(
                    localizer.string(.selectBook),
                    systemImage: "sidebar.right",
                    description: Text(localizer.string(.bookMetadataDescription))
                )
            }
        }
        .navigationTitle(localizer.string(.details))
        .task(id: readerLaunchRequestBookID) {
            guard let requestID = readerLaunchRequestBookID,
                  let currentBook = book ?? store.catalog.selectedBook,
                  currentBook.id == requestID else { return }
            let readingState = store.catalog.readingState(for: currentBook)
            openReader(
                for: currentBook,
                title: BookTitleFormatter.displayTitle(for: currentBook, mode: activeTitleMode),
                initialPageID: BookDetailReadingActionPolicy.initialPage(for: readingState),
                seedPages: []
            )
            onReaderLaunchRequestHandled()
        }
    }

    private func detailContent(for book: LibraryBook) -> some View {
        let themeColor = Color(nsColor: themeColor(for: book))
        let title = BookTitleFormatter.displayTitle(for: book, mode: activeTitleMode)
        let groups = BookDetailTagOrganizer.groups(from: displayTags)
        let readingState = store.catalog.readingState(for: book)
        let readingActionTitleKey = BookDetailReadingActionPolicy.titleKey(for: readingState)

        return BookDetailScrollChrome(
            book: book,
            title: title,
            titleMode: activeTitleMode,
            themeColor: themeColor,
            localizer: localizer,
            titleColumnHeight: heroTitleColumnHeight,
            readingActionTitleKey: readingActionTitleKey,
            isLaunchingReader: readerLauncher.launchingReaderBookID == book.id,
            onCycleTitle: cycleTitleMode,
            onCopyTitle: { copyBookTitle(title) },
            onOpenReader: {
                openReader(
                    for: book,
                    title: title,
                    initialPageID: BookDetailReadingActionPolicy.initialPage(for: readingState),
                    seedPages: []
                )
            },
            overlay: { size in
                tagExplanationOverlay(containerSize: size)
            },
            onTitleColumnHeightChange: updateHeroTitleColumnHeight,
            onTagPillFramesChange: { frames in
                tagPillFrames = frames
            },
            contentReplacementTransition: contentReplacementTransition,
            contentReplacementAnimation: contentReplacementAnimation
        ) {
            mainDetailColumn(
                book: book,
                title: title,
                themeColor: themeColor,
                groups: groups,
                heroTitleColumnHeight: heroTitleColumnHeight,
                showsDeferredSections: BookDetailReplacementPolicy.shouldShowDeferredSections(
                    mountedBookID: deferredSectionsBookID
                )
            )
            .animation(contentReplacementAnimation, value: book.id)
        }
        .focusedSceneValue(\.nyaehBookCommands, bookCommandContext(for: book, title: title))
        .toolbar {
            ToolbarItemGroup {
                Button {
                    editMetadata(for: book)
                } label: {
                    Label(localizer.string(.editMetadata), systemImage: "square.and.pencil")
                }
                .help(localizer.string(.editMetadata))

                Button {
                    fetchMetadata(for: book)
                } label: {
                    Label(localizer.string(.fetchMetadata), systemImage: "arrow.down.doc")
                }
                .disabled(!canFetchMetadataCommand(for: book))
                .help(localizer.string(.fetchMetadata))

                Button {
                    rescanCover(for: book)
                } label: {
                    Label(localizer.string(.rescanCover), systemImage: "photo.badge.arrow.down")
                }
                .disabled(!canRescanCoverCommand)
                .help(localizer.string(.rescanCover))
            }
        }
        .onAppear {
            consumeExternalTransitionShellIfNeeded()
            startDetailSession(for: book.id)
            NavigationPerformanceTracer.bookDetailDidAppear(bookID: book.id)
            NavigationPerformanceTracer.bookDetailMainColumnFirstFrameReady(bookID: book.id)
        }
        .onDisappear {
            endDetailSession(for: book.id)
            NavigationPerformanceTracer.bookDetailDidDisappear(bookID: book.id)
        }
        .task(id: "build-\(book.id)-\(detailSession.revision)") {
            let session = detailSession
            guard isCurrentDetailSession(session, bookID: book.id) else {
                NavigationPerformanceTracer.bookDetailStaleTaskSkipped(bookID: book.id, taskName: "build")
                return
            }
            NavigationPerformanceTracer.bookDetailBuildStarted(bookID: book.id)
        }
        .task(id: "theme-\(book.id)-\(book.coverPath ?? "none")-\(detailSession.revision)") {
            let session = detailSession
            // 封面主题色解析可能触发图片解码，必须在回写前检查 session，避免旧书的颜色闪到新详情页。
            let resolution = await CoverThemeColorCache.shared.resolveColor(coverPath: book.coverPath)
            guard isCurrentDetailSession(session, bookID: book.id) else {
                NavigationPerformanceTracer.bookDetailStaleTaskSkipped(bookID: book.id, taskName: "themeColor")
                return
            }
            let stableColor = BookDetailThemeColorPolicy.stableResolvedColor(
                cachedColor: CoverThemeColorCache.shared.cachedColor(coverPath: book.coverPath)
            )
            withAnimation(BookDetailThemeColorPolicy.backgroundCrossfadeAnimation) {
                resolvedThemeColors[book.id] = stableColor
                displayedBackgroundThemeColor = stableColor
            }
            NavigationPerformanceTracer.themeColorDidResolve(
                bookID: book.id,
                costMilliseconds: resolution.costMilliseconds,
                cacheHit: resolution.cacheHit
            )
            NavigationPerformanceTracer.coverThemeColorSlowResolve(
                bookID: book.id,
                costMilliseconds: resolution.costMilliseconds
            )
        }
        .task(id: "deferred-\(book.id)-\(detailSession.revision)") {
            let session = detailSession
            guard isCurrentDetailSession(session, bookID: book.id) else {
                NavigationPerformanceTracer.bookDetailStaleTaskSkipped(bookID: book.id, taskName: "deferred")
                return
            }
            if deferredSectionsBookID == nil {
                await Task.yield()
            }
            guard !Task.isCancelled, isCurrentDetailSession(session, bookID: book.id) else {
                NavigationPerformanceTracer.bookDetailStaleTaskSkipped(bookID: book.id, taskName: "deferred")
                return
            }
            deferredSectionsBookID = book.id
            NavigationPerformanceTracer.bookDetailDeferredSectionsMounted(bookID: book.id)
        }
        .task(id: "\(book.id)-\(book.updatedAt)-\(isTagTranslationEnabled)-\(store.catalog.tagSummaryRevision)-\(detailSession.revision)") {
            let session = detailSession
            guard isCurrentDetailSession(session, bookID: book.id) else {
                NavigationPerformanceTracer.bookDetailStaleTaskSkipped(bookID: book.id, taskName: "displayTags")
                return
            }
            let tagStart = NavigationPerformanceTracer.displayTagsWillResolve(bookID: book.id)
            let resolvedTags = store.catalog.displayTags(
                for: book,
                isTagTranslationEnabled: isTagTranslationEnabled
            )
            NavigationPerformanceTracer.displayTagsDidResolve(
                bookID: book.id,
                startedAt: tagStart,
                tagCount: resolvedTags.count
            )
            guard isCurrentDetailSession(session, bookID: book.id) else {
                NavigationPerformanceTracer.bookDetailStaleTaskSkipped(bookID: book.id, taskName: "displayTags")
                return
            }
            withAnimation(BookDetailReplacementPolicy.contentCrossfadeAnimation) {
                displayTags = resolvedTags
            }
        }
        .onChange(of: store.catalog.deletingBookIDs) { _, ids in
            if let id = book.databaseID, ids.contains(id) { readerLauncher.cancelReaderLaunchAndCloseWindow() }
        }
        .onChange(of: titleDisplayMode) { _, _ in
            localTitleMode = nil
        }
        .onChange(of: book.id) { _, _ in
            startBookReplacementSession(for: book.id)
        }
        .confirmationDialog(
            book.url ?? localizer.string(.url),
            isPresented: $isURLDialogPresented,
            titleVisibility: .visible
        ) {
            if let urlString = book.url, let url = URL(string: urlString) {
                Button(localizer.string(.openInBrowser)) {
                    NSWorkspace.shared.open(url)
                }
                Button(localizer.string(.copyLink)) {
                    copyToPasteboard(urlString)
                }
            }
            Button(localizer.string(.cancel), role: .cancel) {}
        }
        .sheet(isPresented: $isDeleteBookConfirmationPresented) {
            DeleteBookConfirmationSheet(
                book: book,
                confirmationCode: deleteBookConfirmationCode,
                confirmationText: $deleteBookConfirmationText,
                isDeleting: store.catalog.isDeletingBook,
                localizer: localizer,
                onCancel: { isDeleteBookConfirmationPresented = false },
                onDelete: {
                    readerLauncher.cancelReaderLaunchAndCloseWindow()
                    Task { @MainActor in
                        do {
                            let root = try resolveLibraryRootURL()
                            await store.catalog.deleteBookAndSourceFile(book, securityScopedRootURL: root)
                            if store.catalog.loadError == nil {
                                isDeleteBookConfirmationPresented = false
                                deleteBookConfirmationText = ""
                                deleteBookConfirmationCode = DeleteBookConfirmationCode.generate()
                            }
                        } catch { store.catalog.loadError = error.localizedDescription }
                    }
                }
            )
        }
    }

    private func startDetailSession(for bookID: LibraryBook.ID) {
        resetEphemeralDetailState()
        detailSession = detailSession.next(bookID: bookID)
        NavigationPerformanceTracer.bookDetailSessionStarted(bookID: bookID, revision: detailSession.revision)
    }

    private func startBookReplacementSession(for bookID: LibraryBook.ID) {
        resetEphemeralDetailStateForBookReplacement(nextBookID: bookID)
        detailSession = detailSession.next(bookID: bookID)
        NavigationPerformanceTracer.bookDetailSessionStarted(bookID: bookID, revision: detailSession.revision)
    }

    private func consumeExternalTransitionShellIfNeeded() {
        guard usesExternalTransitionShell, !hasConsumedExternalTransitionShell else {
            return
        }

        var transaction = Transaction(animation: nil)
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            hasConsumedExternalTransitionShell = true
        }
    }

    private func endDetailSession(for bookID: LibraryBook.ID) {
        resetEphemeralDetailState()
        detailSession = detailSession.nextInactive()
        NavigationPerformanceTracer.bookDetailSessionEnded(bookID: bookID, revision: detailSession.revision)
    }

    private func resetEphemeralDetailState() {
        readerLauncher.cancelReaderLaunchAndCloseWindow()
        localTitleMode = nil
        displayTags = []
        clearActiveTagExplanation()
        tagPillFrames = [:]
        deferredSectionsBookID = nil
        isURLDialogPresented = false
        isDeleteBookConfirmationPresented = false
        deleteBookConfirmationText = ""
    }

    private func resetEphemeralDetailStateForBookReplacement(nextBookID: LibraryBook.ID) {
        readerLauncher.cancelReaderLaunchAndCloseWindow()
        localTitleMode = nil
        clearActiveTagExplanation()
        tagPillFrames = [:]
        deferredSectionsBookID = BookDetailReplacementPolicy.deferredSectionsBookIDAfterBookChange(
            mountedBookID: deferredSectionsBookID,
            nextBookID: nextBookID
        )
        isURLDialogPresented = false
        isDeleteBookConfirmationPresented = false
        deleteBookConfirmationText = ""
    }

    private func isCurrentDetailSession(_ session: BookDetailSessionToken, bookID: LibraryBook.ID) -> Bool {
        detailSession == session && detailSession.matches(bookID: bookID)
    }

    private func cycleTitleMode() {
        let nextMode = activeTitleMode.next
        withAnimation(BookDetailTitleModeMotion.animation) {
            localTitleMode = nextMode
        }
        onTitleModeFeedback(localizer.string(nextMode.titleKey))
    }

    private func updateHeroTitleColumnHeight(_ height: CGFloat) {
        guard height.isFinite, height > 0 else {
            return
        }
        let normalizedHeight = ceil(height)
        guard abs(heroTitleColumnHeight - normalizedHeight) > 0.5 else {
            return
        }
        withAnimation(BookDetailTitleModeMotion.animation) {
            heroTitleColumnHeight = normalizedHeight
        }
    }

    private func openReader(
        for book: LibraryBook,
        title: String,
        initialPageID: Int,
        seedPages: [BookReaderLoadedPage]
    ) {
        readerLauncher.openReader(
            for: book, title: title, initialPageID: initialPageID, seedPages: seedPages,
            catalog: store.catalog, localizer: localizer, resolveLibraryRootURL: resolveLibraryRootURL,
            readerDisplayPreferences: readerDisplayPreferences, onReaderDisplayPreferencesChange: onReaderDisplayPreferencesChange,
            savedReaderWindowFrame: savedReaderWindowFrame, onReaderWindowFrameChange: onReaderWindowFrameChange
        )
    }

    @ViewBuilder
    private func tagExplanationOverlay(containerSize: CGSize) -> some View {
        Color.clear
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .overlay(alignment: .topLeading) {
                if let activeTagExplanation,
                   let anchorFrame = tagPillFrames[activeTagExplanation.id] {
                    BookDetailTagExplanationOverlay(
                        explanation: activeTagExplanation,
                        anchorFrame: anchorFrame,
                        containerSize: containerSize,
                        localizer: localizer
                    )
                    .allowsHitTesting(false)
                    .transition(.opacity.combined(with: .scale(scale: 0.98)))
                    .animation(.snappy(duration: 0.16), value: activeTagExplanation.id)
                }
            }
            .allowsHitTesting(false)
            .animation(.snappy(duration: 0.16), value: activeTagExplanation?.id)
    }

    private func showTagExplanation(_ tag: TagDisplaySummary) {
        withAnimation(.snappy(duration: 0.16)) {
            activeTagExplanation = ActiveTagExplanation(tag: tag)
        }
    }

    private func clearTagExplanation(_ tag: TagDisplaySummary) {
        guard activeTagExplanation?.id == tag.id else {
            return
        }
        clearActiveTagExplanation()
    }

    private func clearActiveTagExplanation() {
        withAnimation(.snappy(duration: 0.16)) {
            activeTagExplanation = nil
        }
    }

    private func mainDetailColumn(
        book: LibraryBook,
        title: String,
        themeColor: Color,
        groups: BookDetailTagGroups,
        heroTitleColumnHeight: CGFloat,
        showsDeferredSections: Bool
    ) -> some View {
        VStack(alignment: .leading, spacing: 20) {
            BookDetailHeroView(
                book: book,
                title: title,
                titleColumnHeight: heroTitleColumnHeight,
                themeColor: themeColor,
                localizer: localizer,
                onCopyTitle: { copyBookTitle(title) }
            )

            if showsDeferredSections {
                relatedBooksSections(for: book, themeColor: themeColor)
            }

            BookDetailTopCardGrid {
                BasicInfoPanel(book: book, localizer: localizer)
                StatusInfoPanel(book: book, themeColor: themeColor, localizer: localizer)
                RatingFavoritePanel(
                    book: book,
                    themeColor: themeColor,
                    localizer: localizer,
                    onToggleMarked: { toggleMarked(for: book) }
                )
                if !groups.creatorTags.isEmpty {
                    BookDetailSection(title: localizer.string(.detailAuthors), systemImage: "person.crop.square") {
                        GroupedTagSections(
                            groups: groups.creatorGroups,
                            themeColor: themeColor,
                            localizer: localizer,
                            isCompact: false,
                            onSelectTag: onSelectTag,
                            onToggleFollowed: toggleFollowedTag,
                            onRequestExplanation: showTagExplanation,
                            onClearExplanation: clearTagExplanation,
                            claimableWorks: [],
                            onConfirmWork: { _, _ in }
                        )
                    }
                }

                if !groups.workTags.isEmpty {
                    BookDetailSection(title: localizer.string(.detailWorks), systemImage: "rectangle.stack") {
                        GroupedTagSections(
                            groups: groups.workGroups,
                            themeColor: themeColor,
                            localizer: localizer,
                            isCompact: false,
                            onSelectTag: onSelectTag,
                            onToggleFollowed: toggleFollowedTag,
                            onRequestExplanation: showTagExplanation,
                            onClearExplanation: clearTagExplanation,
                            claimableWorks: groups.workTags.filter { $0.namespace == "parody" && TagOpenDestinationResolver.destination(for: $0) == .workDetail },
                            onConfirmWork: confirmWorkForCharacter
                        )
                    }
                }

                BookDetailSection(title: localizer.string(.detailFunctions), systemImage: "hammer") {
                    metadataFetchControls(for: book)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }

            BookDetailSection(title: localizer.string(.tags), systemImage: "tag") {
                if groups.otherTags.isEmpty {
                    Text(localizer.string(.tagNoTags))
                        .foregroundStyle(.secondary)
                } else {
                    GroupedTagSections(
                        groups: groups.otherGroups,
                        themeColor: themeColor,
                        localizer: localizer,
                        isCompact: true,
                        onSelectTag: onSelectTag,
                        onToggleFollowed: toggleFollowedTag,
                        onRequestExplanation: showTagExplanation,
                        onClearExplanation: clearTagExplanation,
                        claimableWorks: [],
                        onConfirmWork: { _, _ in }
                    )
                }
            }

            if showsDeferredSections {
                BookReaderSection(
                    book: book,
                    readingState: store.catalog.readingState(for: book),
                    initialLoadLimit: readerInitialLoadLimit,
                    hoverPreviewDelayMilliseconds: readerHoverPreviewDelayMilliseconds,
                    localizer: localizer,
                    resolveLibraryRootURL: resolveLibraryRootURL,
                    onRecordRead: { store.catalog.recordRead(for: book) },
                    onProgress: { pageIndex, totalPages, completed in
                        store.catalog.saveReadingProgress(
                            for: book,
                            currentPageIndex: pageIndex,
                            totalPages: totalPages,
                            forceCompleted: completed
                        )
                    },
                    onResetProgress: { store.catalog.resetReadingProgress(for: book) },
                    onOpenReader: { pageID, seedPages in
                        openReader(for: book, title: title, initialPageID: pageID, seedPages: seedPages)
                    }
                )
            }

            BookDetailSection(title: localizer.string(.detailOtherInfo), systemImage: "info.circle") {
                OtherInfoGrid(
                    book: book,
                    localizer: localizer,
                    onURL: { isURLDialogPresented = true },
                    onCopyFolder: { copyToPasteboard(URL(fileURLWithPath: book.filepath).deletingLastPathComponent().path) }
                )
            }
            .frame(maxWidth: 360, alignment: .trailing)
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
    }

    @ViewBuilder
    private func relatedBooksSections(for book: LibraryBook, themeColor: Color) -> some View {
        let collectionRelatedBooks = store.catalog.detailCollectionRelatedBooks(for: book)
        if collectionRelatedBooks.contains(where: { $0.id != book.id }) {
            BookDetailSection(title: localizer.string(.sameCollection), systemImage: "rectangle.stack") {
                RelatedBooksRow(
                    books: collectionRelatedBooks,
                    displayMode: .collection,
                    currentBookID: book.id,
                    themeColor: themeColor,
                    titleDisplayMode: titleDisplayMode,
                    localizer: localizer,
                    onSelect: onSelectRelatedBook
                )
            }
        }

        let versionRelatedBooks = store.catalog.detailVersionRelatedBooks(for: book)
        if versionRelatedBooks.contains(where: { $0.id != book.id }) {
            BookDetailSection(title: localizer.string(.otherVersions), systemImage: "square.2.layers.3d") {
                RelatedBooksRow(
                    books: versionRelatedBooks,
                    displayMode: .versionLabels,
                    currentBookID: book.id,
                    themeColor: themeColor,
                    titleDisplayMode: titleDisplayMode,
                    localizer: localizer,
                    onSelect: onSelectRelatedBook
                )
            }
        }
    }

    private func themeColor(for book: LibraryBook) -> NSColor {
        BookDetailThemeColorPolicy.displayColor(
            resolvedColor: resolvedThemeColors[book.id],
            cachedColor: CoverThemeColorCache.shared.cachedColor(coverPath: book.coverPath),
            currentStableColor: displayedBackgroundThemeColor
        )
    }

    private func metadataFetchControls(for book: LibraryBook) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Button {
                editMetadata(for: book)
            } label: {
                Label(localizer.string(.editMetadata), systemImage: "square.and.pencil")
            }

            Button {
                fetchMetadata(for: book)
            } label: {
                Label(localizer.string(.fetchMetadata), systemImage: "arrow.down.doc")
            }
            .disabled(!canFetchMetadataCommand(for: book))

            Button {
                rescanCover(for: book)
            } label: {
                Label(localizer.string(.rescanCover), systemImage: "photo.badge.arrow.down")
            }
            .disabled(!canRescanCoverCommand)

            Divider()

            Button(role: .destructive) {
                deleteBookConfirmationText = ""
                deleteBookConfirmationCode = DeleteBookConfirmationCode.generate()
                isDeleteBookConfirmationPresented = true
            } label: {
                Label(localizer.string(.trashBookTitle), systemImage: "trash")
            }
            .disabled(store.catalog.isDeletingBook)

            HStack(spacing: 8) {
                if store.catalog.isFetchingMetadata {
                    ProgressView()
                        .controlSize(.small)
                }

                if store.catalog.isRescanningCover {
                    ProgressView()
                        .controlSize(.small)
                }

                if let message = store.catalog.metadataFetchMessage {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(metadataMessageColor(for: message))
                }

                if let message = store.catalog.coverRescanMessage {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(coverRescanMessageColor(for: message))
                }
            }
        }
    }

    private func canFetchMetadata(for book: LibraryBook) -> Bool {
        book.hash.range(of: #"^[A-Fa-f0-9]{40}$"#, options: .regularExpression) != nil
    }

    private func canFetchMetadataCommand(for book: LibraryBook) -> Bool {
        !store.catalog.isFetchingMetadata
            && !store.catalog.metadataBatchProgress.isActive
            && canFetchMetadata(for: book)
    }

    private var canRescanCoverCommand: Bool {
        !store.catalog.isRescanningCover
    }

    private func bookCommandContext(for book: LibraryBook, title: String) -> NyaEHBookCommandContext {
        NyaEHBookCommandContext(
            canToggleFavorite: true,
            toggleFavorite: { toggleMarked(for: book) },
            canCopyTitle: !title.isEmpty,
            copyTitle: { copyBookTitle(title) },
            canFetchMetadata: canFetchMetadataCommand(for: book),
            fetchMetadata: { fetchMetadata(for: book) },
            canEditMetadata: true,
            editMetadata: { editMetadata(for: book) },
            canRescanCover: canRescanCoverCommand,
            rescanCover: { rescanCover(for: book) }
        )
    }

    private func toggleMarked(for book: LibraryBook) {
        store.catalog.toggleMarked(for: book)
    }

    private func copyBookTitle(_ title: String) {
        copyToPasteboard(title)
    }

    private func fetchMetadata(for book: LibraryBook) {
        store.catalog.selectedBookID = book.id
        Task {
            await store.catalog.fetchMetadataForSelectedBook(
                configuration: metadataConfiguration,
                localizer: localizer
            )
        }
    }

    private func editMetadata(for book: LibraryBook) {
        metadataEditorPresenter.show(
            book: book,
            store: store.catalog,
            metadataConfiguration: metadataConfiguration,
            localizer: localizer
        )
    }

    private func rescanCover(for book: LibraryBook) {
        store.catalog.rescanCover(for: book, localizer: localizer)
    }

    private func toggleFollowedTag(_ tag: TagDisplaySummary) {
        store.catalog.setFollowed(
            !tag.isFollowed,
            for: tag,
            isTagTranslationEnabled: isTagTranslationEnabled
        )
    }

    private func confirmWorkForCharacter(_ work: TagDisplaySummary, _ character: TagDisplaySummary) {
        Task {
            do {
                try await store.catalog.setWorkCharacterDecision(
                    .confirmed,
                    pair: WorkCharacterPair(workID: work.id, characterID: character.id)
                )
            } catch {
                store.catalog.loadError = error.localizedDescription
            }
        }
    }

    private func metadataMessageColor(for message: String) -> Color {
        if message == localizer.string(.metadataFetchSucceeded) || message == localizer.string(.fetchingMetadata) {
            return .secondary
        }
        return .red
    }

    private func coverRescanMessageColor(for message: String) -> Color {
        if message == localizer.string(.coverRescanSucceeded) || message == localizer.string(.rescanningCover) {
            return .secondary
        }
        return .red
    }

    private func copyToPasteboard(_ value: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
    }
}

private struct RelatedBooksRow: View {
    enum DisplayMode: Equatable {
        case collection
        case versionLabels
    }

    let books: [LibraryBook]
    let displayMode: DisplayMode
    let currentBookID: LibraryBook.ID
    let themeColor: Color
    let titleDisplayMode: BookTitleDisplayMode
    let localizer: AppLocalizer
    let onSelect: (LibraryBook) -> Void

    @State private var scrollPosition = ScrollPosition()
    @State private var scrollState = RelatedBooksScrollState()
    @State private var isHoveringCarousel = false

    private let metrics = BookCardMetrics(width: 128, appearance: .standard)

    private var rowHeight: CGFloat {
        let labelHeight: CGFloat = displayMode == .versionLabels ? 20 + metrics.contentSpacing : 0
        return metrics.coverHeight
            + metrics.titleHeight
            + labelHeight
            + metrics.contentSpacing
            + 12
            + 12
    }

    private var scrollPageDistance: CGFloat {
        (metrics.cardWidth + 12 + 18) * 3
    }

    private var showsBackwardArrow: Bool {
        isHoveringCarousel && scrollState.canScrollBackward
    }

    private var showsForwardArrow: Bool {
        isHoveringCarousel && scrollState.canScrollForward
    }

    var body: some View {
        ZStack {
            scrollLayer

            controlsOverlay
                .zIndex(1)
        }
        .frame(height: rowHeight)
        .contentShape(Rectangle())
        .onHover { isHoveringCarousel = $0 }
        .onChange(of: books.map(\.id)) { _, _ in
            scrollState = .init()
            scrollPosition.scrollTo(edge: .leading)
        }
    }

    private var scrollLayer: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            LazyHStack(alignment: .top, spacing: 18) {
                ForEach(books) { book in
                    let isCurrent = book.id == currentBookID
                    if isCurrent {
                        RelatedBookCard(
                            book: book,
                            displayMode: displayMode,
                            isCurrent: true,
                            themeColor: themeColor,
                            title: BookTitleFormatter.displayTitle(for: book, mode: titleDisplayMode),
                            metrics: metrics
                        )
                    } else {
                        Button {
                            onSelect(book)
                        } label: {
                            RelatedBookCard(
                                book: book,
                                displayMode: displayMode,
                                isCurrent: false,
                                themeColor: themeColor,
                                title: BookTitleFormatter.displayTitle(for: book, mode: titleDisplayMode),
                                metrics: metrics
                            )
                        }
                        .buttonStyle(.plain)
                        .detailHoverSurface(cornerRadius: 10, scale: 1.018)
                    }
                }
            }
            .padding(.horizontal, 2)
            .padding(.vertical, 6)
        }
        .scrollPosition($scrollPosition)
        .onScrollGeometryChange(for: RelatedBooksScrollState.self) { geometry in
            RelatedBooksScrollState(geometry: geometry)
        } action: { _, newState in
            scrollState = newState
        }
        .scrollIndicators(.hidden, axes: .horizontal)
    }

    private var controlsOverlay: some View {
        HStack {
            RelatedBooksArrowButton(
                systemImage: "chevron.left",
                help: localizer.string(.previousPage)
            ) {
                scroll(by: -scrollPageDistance)
            }
            .opacity(showsBackwardArrow ? 1 : 0)
            .scaleEffect(showsBackwardArrow ? 1 : 0.92)
            .allowsHitTesting(showsBackwardArrow)

            Spacer()

            RelatedBooksArrowButton(
                systemImage: "chevron.right",
                help: localizer.string(.nextPage)
            ) {
                scroll(by: scrollPageDistance)
            }
            .opacity(showsForwardArrow ? 1 : 0)
            .scaleEffect(showsForwardArrow ? 1 : 0.92)
            .allowsHitTesting(showsForwardArrow)
        }
        .padding(.horizontal, 8)
        .frame(height: rowHeight, alignment: .center)
        .allowsHitTesting(showsBackwardArrow || showsForwardArrow)
        .animation(.easeInOut(duration: 0.16), value: showsBackwardArrow)
        .animation(.easeInOut(duration: 0.16), value: showsForwardArrow)
    }

    private func scroll(by offset: CGFloat) {
        let targetOffset = min(max(scrollState.offsetX + offset, 0), scrollState.maxOffsetX)
        scrollState = scrollState.updatingOffset(targetOffset)
        withAnimation(.snappy(duration: 0.32)) {
            scrollPosition.scrollTo(x: targetOffset)
        }
    }
}

private struct RelatedBooksScrollState: Equatable {
    private static let edgeTolerance: CGFloat = 1

    var offsetX: CGFloat = 0
    var maxOffsetX: CGFloat = 0

    var canScrollBackward: Bool {
        offsetX > Self.edgeTolerance
    }

    var canScrollForward: Bool {
        maxOffsetX - offsetX > Self.edgeTolerance
    }

    init(offsetX: CGFloat = 0, maxOffsetX: CGFloat = 0) {
        self.offsetX = max(offsetX, 0)
        self.maxOffsetX = max(maxOffsetX, 0)
    }

    init(geometry: ScrollGeometry) {
        let maxOffsetX = max(geometry.contentSize.width - geometry.containerSize.width, 0)
        self.init(
            offsetX: min(max(geometry.contentOffset.x, 0), maxOffsetX),
            maxOffsetX: maxOffsetX
        )
    }

    func updatingOffset(_ offsetX: CGFloat) -> RelatedBooksScrollState {
        RelatedBooksScrollState(
            offsetX: min(max(offsetX, 0), maxOffsetX),
            maxOffsetX: maxOffsetX
        )
    }
}

private struct RelatedBooksArrowButton: View {
    let systemImage: String
    let help: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.title3.weight(.semibold))
                .foregroundStyle(.primary)
                .frame(width: 34, height: 34)
                .background(.regularMaterial, in: Circle())
                .overlay {
                    Circle()
                        .strokeBorder(.secondary.opacity(0.18))
                }
                .shadow(color: .black.opacity(0.16), radius: 8, x: 0, y: 3)
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

private struct RelatedBookCard: View {
    let book: LibraryBook
    let displayMode: RelatedBooksRow.DisplayMode
    let isCurrent: Bool
    let themeColor: Color
    let title: String
    let metrics: BookCardMetrics

    var body: some View {
        VStack(alignment: .leading, spacing: metrics.contentSpacing) {
            BookCoverThumbnail(
                book: book,
                width: metrics.cardWidth,
                height: metrics.coverHeight,
                cornerRadius: 8
            )

            RelatedBookScrollingTitleView(title: title, width: metrics.cardWidth)

            if displayMode == .versionLabels {
                RelatedBookVersionLabelRow(
                    labels: VersionLabelFormatter.labels(from: book.versionLabel),
                    width: metrics.cardWidth
                )
            }
        }
        .frame(width: metrics.cardWidth, alignment: .topLeading)
        .padding(6)
        .background {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(isCurrent ? themeColor.opacity(0.12) : Color.clear)
        }
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(isCurrent ? themeColor.opacity(0.72) : Color.clear, lineWidth: isCurrent ? 2 : 0)
        }
        .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .help(title)
    }
}

private struct RelatedBookScrollingTitleView: View {
    let title: String
    let width: CGFloat

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovering = false
    @State private var titleWidth: CGFloat = 0
    @State private var scrollOffset: CGFloat = 0
    @State private var scrollTask: Task<Void, Never>?

    private var overflowWidth: CGFloat {
        BookCardTitleScrollMetrics.overflowWidth(titleWidth: titleWidth, cardWidth: width)
    }

    private var canScroll: Bool {
        BookCardTitleScrollMetrics.canStart(
            isHovering: isHovering,
            titleWidth: titleWidth,
            cardWidth: width,
            reduceMotion: reduceMotion
        )
    }

    var body: some View {
        titleContent
            .frame(width: width, height: BookCardMetrics.default.titleHeight, alignment: .leading)
            .clipped()
            .contentShape(Rectangle())
            .help(title)
            .onHover { hovering in
                isHovering = hovering
                updateScrollAnimation()
            }
            .onChange(of: titleWidth) { _, _ in
                updateScrollAnimation()
            }
            .onChange(of: title) { _, _ in
                titleWidth = 0
                updateScrollAnimation()
            }
            .onChange(of: reduceMotion) { _, _ in
                updateScrollAnimation()
            }
            .onDisappear {
                cancelScroll(resetOffset: true)
            }
    }

    @ViewBuilder
    private var titleContent: some View {
        ZStack(alignment: .leading) {
            if canScroll {
                Text(title)
                    .font(.callout.weight(.medium))
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
                    .offset(x: scrollOffset)
            } else {
                Text(title)
                    .font(.callout.weight(.medium))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(width: width, alignment: .leading)
            }

            if isHovering && !reduceMotion {
                titleWidthReader
            }
        }
    }

    private var titleWidthReader: some View {
        Text(title)
            .font(.callout.weight(.medium))
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
            .hidden()
            .background {
                GeometryReader { proxy in
                    Color.clear.preference(key: RelatedBookTitleWidthPreferenceKey.self, value: proxy.size.width)
                }
            }
            .onPreferenceChange(RelatedBookTitleWidthPreferenceKey.self) { width in
                titleWidth = width
            }
    }

    private func updateScrollAnimation() {
        guard canScroll else {
            cancelScroll(resetOffset: true)
            return
        }

        scrollTask?.cancel()
        scrollOffset = 0
        let overflowWidth = overflowWidth
        let duration = BookCardTitleScrollMetrics.duration(forOverflow: overflowWidth)
        scrollTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(260))
            guard !Task.isCancelled, canScroll else {
                return
            }

            withAnimation(.linear(duration: duration)) {
                scrollOffset = -overflowWidth
            }

            try? await Task.sleep(for: .milliseconds(Int(duration * 1_000)))
            guard !Task.isCancelled, canScroll else {
                return
            }

            try? await Task.sleep(for: .milliseconds(520))
            guard !Task.isCancelled else {
                return
            }

            withAnimation(.snappy(duration: 0.22)) {
                scrollOffset = 0
            }
            scrollTask = nil
        }
    }

    private func cancelScroll(resetOffset: Bool) {
        scrollTask?.cancel()
        scrollTask = nil
        guard resetOffset else {
            return
        }
        var transaction = Transaction()
        transaction.animation = nil
        withTransaction(transaction) {
            scrollOffset = 0
        }
    }
}

private struct RelatedBookTitleWidthPreferenceKey: PreferenceKey {
    static let defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

private struct RelatedBookVersionLabelRow: View {
    let labels: [String]
    let width: CGFloat

    var body: some View {
        if !labels.isEmpty {
            HStack(spacing: 5) {
                ForEach(labels, id: \.self) { label in
                    Text(label)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(.secondary.opacity(0.10), in: Capsule())
                        .overlay {
                            Capsule()
                                .stroke(.secondary.opacity(0.16), lineWidth: 1)
                        }
                }
            }
            .frame(width: width, height: 20, alignment: .leading)
            .clipped()
            .help(labels.joined(separator: VersionLabelFormatter.separator))
        }
    }
}

private struct DeleteBookConfirmationSheet: View {
    let book: LibraryBook
    let confirmationCode: String
    @Binding var confirmationText: String
    let isDeleting: Bool
    let localizer: AppLocalizer
    let onCancel: () -> Void
    let onDelete: () -> Void

    private var canDelete: Bool {
        DeleteBookConfirmationCode.matches(input: confirmationText, code: confirmationCode)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(localizer.string(.trashBookTitle))
                .font(.title3)
                .fontWeight(.semibold)
            Text(localizer.string(.trashBookExplanation))
                .foregroundStyle(.red)
            VStack(alignment: .leading, spacing: 6) {
                Text(book.title)
                    .fontWeight(.semibold)
                Text(book.filepath)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .truncationMode(.middle)
            }
            Text("\(localizer.string(.trashBookCodePrompt)) \(confirmationCode)")
                .font(.caption)
                .foregroundStyle(.secondary)
            TextField(localizer.string(.trashBookCodePlaceholder), text: $confirmationText)
                .textFieldStyle(.roundedBorder)

            HStack {
                Spacer()
                Button(localizer.string(.cancel), action: onCancel)
                    .disabled(isDeleting)
                Button(localizer.string(.moveToTrash), role: .destructive, action: onDelete)
                    .disabled(!canDelete || isDeleting)
            }
        }
        .padding(22)
        .frame(width: 560)
        .interactiveDismissDisabled(isDeleting)
    }
}

enum DeleteBookConfirmationCode {
    static func generate(randomNumber: () -> Int = { Int.random(in: 0...9999) }) -> String {
        String(format: "%04d", min(max(randomNumber(), 0), 9999))
    }

    static func matches(input: String, code: String) -> Bool {
        input.trimmingCharacters(in: .whitespacesAndNewlines) == code
    }
}

private struct BookDetailBackground: View {
    let themeColor: Color

    var body: some View {
        ZStack {
            Rectangle()
                .fill(.background)

            LinearGradient(
                colors: [
                    themeColor.opacity(0.26),
                    themeColor.opacity(0.08),
                    Color.clear
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()
        }
        .ignoresSafeArea(.container, edges: .top)
    }
}

enum BookDetailStickyHeaderMetrics {
    static let startOffset: CGFloat = 0
    static let collapseDistance: CGFloat = 220
    static let minimumPublishedOffsetDelta: CGFloat = 1.0

    static func progress(for scrollOffset: CGFloat) -> CGFloat {
        guard scrollOffset.isFinite else {
            return 0
        }
        let rawProgress = (scrollOffset - startOffset) / collapseDistance
        return min(max(rawProgress, 0), 1)
    }

    static func presentationOffset(for scrollOffset: CGFloat) -> CGFloat {
        guard scrollOffset.isFinite else {
            return startOffset
        }
        return min(max(scrollOffset, startOffset), startOffset + collapseDistance)
    }

    static func shouldPublishPresentationOffset(_ offset: CGFloat, previous: CGFloat) -> Bool {
        if abs(offset - previous) >= minimumPublishedOffsetDelta {
            return true
        }
        let collapsedOffset = startOffset + collapseDistance
        if offset == startOffset, previous != startOffset {
            return true
        }
        if offset == collapsedOffset, previous != collapsedOffset {
            return true
        }
        return false
    }

    static func phase(for scrollOffset: CGFloat) -> BookDetailScrollHeroPhase {
        guard scrollOffset.isFinite else {
            return .expanded
        }
        if scrollOffset <= startOffset {
            return .expanded
        }
        if scrollOffset >= startOffset + collapseDistance {
            return .collapsed
        }
        return .collapsing
    }
}

enum BookDetailHeroMotionMetrics {
    static let maxContentWidth: CGFloat = 1240
    static let detailHorizontalPadding: CGFloat = 28
    static let detailTopPadding: CGFloat = 24
    static let minimumExpandedCardHeight: CGFloat = 443
    static let collapsedCardHeight: CGFloat = 96
    static let heroInnerPadding: CGFloat = 24
    static let heroContentSpacing: CGFloat = 28
    static let titleCategorySpacing: CGFloat = 18
    static let expandedCategoryHeight: CGFloat = 42
    static let coverAspectRatio: CGFloat = 280 / 395
    static let expandedCoverSize = coverSize(width: 280)
    static let collapsedCoverSize = coverSize(width: 54)
    static let expandedTitleSize: CGFloat = 34
    static let collapsedTitleSize: CGFloat = 17
    static let defaultExpandedTitleColumnHeight: CGFloat = 120
    static let collapsedTitleHeight: CGFloat = 28
    static let stickyHeaderHorizontalPadding: CGFloat = 20
    static let stickyHeaderVerticalPadding: CGFloat = 10
    static let stickyHeaderSpacing: CGFloat = 14
    static let expandedCopyButtonWidth: CGFloat = 128
    static let expandedReadingButtonWidth: CGFloat = 142
    static let expandedActionButtonHeight: CGFloat = 38
    static let collapsedActionButtonWidth: CGFloat = 42
    static let collapsedActionButtonHeight: CGFloat = 32
    static let actionButtonSpacing: CGFloat = 10
    static let expandedTitleTrailingReservedWidth: CGFloat = expandedCopyButtonWidth
        + expandedReadingButtonWidth
        + actionButtonSpacing
        + 16
    static let collapsedTitleTrailingReservedWidth: CGFloat = collapsedActionButtonWidth * 2
        + actionButtonSpacing
        + 16

    struct Layout {
        let cardFrame: CGRect
        let coverFrame: CGRect
        let titleFrame: CGRect
        let expandedTitleWidth: CGFloat
        let titleSize: CGFloat
        let titleLineLimit: Int?
        let subtitleSize: CGFloat
        let categoryFrame: CGRect
        let copyButtonFrame: CGRect
        let readingButtonFrame: CGRect
        let secondaryOpacity: CGFloat
        let surfaceOpacity: CGFloat
        let categoryOpacity: CGFloat
        let cornerRadius: CGFloat
        let hoverScale: CGFloat
        let isCategoryProminent: Bool
        let copyButtonIconOnly: Bool
        let readingButtonIconOnly: Bool
    }

    static var expandedCardHeight: CGFloat {
        expandedCardHeight(titleColumnHeight: defaultExpandedTitleColumnHeight)
    }

    static func coverSize(width: CGFloat) -> CGSize {
        CGSize(width: width, height: width / coverAspectRatio)
    }

    static func expandedCardHeight(titleColumnHeight: CGFloat) -> CGFloat {
        let safeTitleHeight = max(titleColumnHeight.isFinite ? titleColumnHeight : 0, 0)
        let titleStackHeight = safeTitleHeight + titleCategorySpacing + expandedCategoryHeight
        return max(
            minimumExpandedCardHeight,
            heroInnerPadding * 2 + max(expandedCoverSize.height, titleStackHeight)
        )
    }

    static func contentWidth(containerWidth: CGFloat) -> CGFloat {
        min(max(containerWidth, 0), maxContentWidth)
    }

    static func contentLeft(containerWidth: CGFloat) -> CGFloat {
        max((containerWidth - contentWidth(containerWidth: containerWidth)) / 2, 0)
    }

    static func contentRight(containerWidth: CGFloat) -> CGFloat {
        contentLeft(containerWidth: containerWidth) + contentWidth(containerWidth: containerWidth)
    }

    static func layout(
        containerWidth: CGFloat,
        scrollOffset: CGFloat,
        progress: CGFloat,
        expandedTitleColumnHeight: CGFloat = defaultExpandedTitleColumnHeight
    ) -> Layout {
        let easedProgress = smoothstep(progress)
        let left = contentLeft(containerWidth: containerWidth)
        let right = contentRight(containerWidth: containerWidth)
        let expandedCardHeight = expandedCardHeight(titleColumnHeight: expandedTitleColumnHeight)
        let expandedCardFrame = CGRect(
            x: left + detailHorizontalPadding,
            y: detailTopPadding,
            width: max(contentWidth(containerWidth: containerWidth) - detailHorizontalPadding * 2, 0),
            height: expandedCardHeight
        )
        let collapsedCardFrame = CGRect(
            x: left + detailHorizontalPadding,
            y: stickyHeaderVerticalPadding,
            width: max(contentWidth(containerWidth: containerWidth) - detailHorizontalPadding * 2, 0),
            height: collapsedCardHeight
        )
        let cardFrame = CGRect(
            x: interpolated(from: expandedCardFrame.minX, to: collapsedCardFrame.minX, progress: easedProgress),
            y: interpolated(from: expandedCardFrame.minY, to: collapsedCardFrame.minY, progress: easedProgress),
            width: interpolated(from: expandedCardFrame.width, to: collapsedCardFrame.width, progress: easedProgress),
            height: interpolated(from: expandedCardFrame.height, to: collapsedCardFrame.height, progress: easedProgress)
        )

        let expandedCoverOrigin = CGPoint(
            x: left + detailHorizontalPadding + heroInnerPadding,
            y: detailTopPadding + heroInnerPadding
        )
        let collapsedCoverOrigin = CGPoint(
            x: left + detailHorizontalPadding + stickyHeaderHorizontalPadding,
            y: stickyHeaderVerticalPadding + (collapsedCardHeight - collapsedCoverSize.height) / 2
        )
        let coverWidth = interpolated(
            from: expandedCoverSize.width,
            to: collapsedCoverSize.width,
            progress: easedProgress
        )
        let coverSize = coverSize(width: coverWidth)
        let coverOrigin = CGPoint(
            x: interpolated(from: expandedCoverOrigin.x, to: collapsedCoverOrigin.x, progress: easedProgress),
            y: interpolated(from: expandedCoverOrigin.y, to: collapsedCoverOrigin.y, progress: easedProgress)
        )

        let expandedTitleOrigin = CGPoint(
            x: expandedCoverOrigin.x + expandedCoverSize.width + heroContentSpacing,
            y: expandedCoverOrigin.y
        )
        let collapsedTitleOrigin = CGPoint(
            x: collapsedCoverOrigin.x + collapsedCoverSize.width + stickyHeaderSpacing,
            y: collapsedCoverOrigin.y + 12
        )
        let expandedTitleRight = right
            - detailHorizontalPadding
            - heroInnerPadding
            - expandedTitleTrailingReservedWidth
        let expandedTitleWidth = max(expandedTitleRight - expandedTitleOrigin.x, 220)
        let collapsedTitleRight = right
            - detailHorizontalPadding
            - stickyHeaderHorizontalPadding
            - collapsedTitleTrailingReservedWidth
        let collapsedTitleWidth = max(
            collapsedTitleRight - collapsedTitleOrigin.x,
            180
        )
        let titleFrame = CGRect(
            x: interpolated(from: expandedTitleOrigin.x, to: collapsedTitleOrigin.x, progress: easedProgress),
            y: interpolated(from: expandedTitleOrigin.y, to: collapsedTitleOrigin.y, progress: easedProgress),
            width: interpolated(from: expandedTitleWidth, to: collapsedTitleWidth, progress: easedProgress),
            height: interpolated(from: expandedTitleColumnHeight, to: collapsedTitleHeight, progress: easedProgress)
        )
        let expandedCategoryFrame = CGRect(
            x: expandedTitleOrigin.x,
            y: detailTopPadding + expandedCardHeight - heroInnerPadding - expandedCategoryHeight,
            width: 156,
            height: expandedCategoryHeight
        )
        let collapsedCategoryFrame = CGRect(
            x: collapsedTitleOrigin.x,
            y: collapsedTitleOrigin.y + collapsedTitleHeight + 8,
            width: 120,
            height: 24
        )
        let categoryFrame = CGRect(
            x: interpolated(from: expandedCategoryFrame.minX, to: collapsedCategoryFrame.minX, progress: easedProgress),
            y: interpolated(from: expandedCategoryFrame.minY, to: collapsedCategoryFrame.minY, progress: easedProgress),
            width: interpolated(from: expandedCategoryFrame.width, to: collapsedCategoryFrame.width, progress: easedProgress),
            height: interpolated(from: expandedCategoryFrame.height, to: collapsedCategoryFrame.height, progress: easedProgress)
        )
        let expandedReadingButtonFrame = CGRect(
            x: right - detailHorizontalPadding - heroInnerPadding - expandedReadingButtonWidth,
            y: detailTopPadding + expandedCardHeight - heroInnerPadding - expandedActionButtonHeight,
            width: expandedReadingButtonWidth,
            height: expandedActionButtonHeight
        )
        let expandedCopyButtonFrame = CGRect(
            x: expandedReadingButtonFrame.minX - actionButtonSpacing - expandedCopyButtonWidth,
            y: expandedReadingButtonFrame.minY,
            width: expandedCopyButtonWidth,
            height: expandedActionButtonHeight
        )
        let collapsedReadingButtonFrame = CGRect(
            x: right - detailHorizontalPadding - stickyHeaderHorizontalPadding - collapsedActionButtonWidth,
            y: stickyHeaderVerticalPadding + (collapsedCardHeight - collapsedActionButtonHeight) / 2,
            width: collapsedActionButtonWidth,
            height: collapsedActionButtonHeight
        )
        let collapsedCopyButtonFrame = CGRect(
            x: collapsedReadingButtonFrame.minX - actionButtonSpacing - collapsedActionButtonWidth,
            y: collapsedReadingButtonFrame.minY,
            width: collapsedActionButtonWidth,
            height: collapsedActionButtonHeight
        )
        let copyButtonFrame = CGRect(
            x: interpolated(from: expandedCopyButtonFrame.minX, to: collapsedCopyButtonFrame.minX, progress: easedProgress),
            y: interpolated(from: expandedCopyButtonFrame.minY, to: collapsedCopyButtonFrame.minY, progress: easedProgress),
            width: interpolated(from: expandedCopyButtonFrame.width, to: collapsedCopyButtonFrame.width, progress: easedProgress),
            height: interpolated(from: expandedCopyButtonFrame.height, to: collapsedCopyButtonFrame.height, progress: easedProgress)
        )
        let readingButtonFrame = CGRect(
            x: interpolated(from: expandedReadingButtonFrame.minX, to: collapsedReadingButtonFrame.minX, progress: easedProgress),
            y: interpolated(from: expandedReadingButtonFrame.minY, to: collapsedReadingButtonFrame.minY, progress: easedProgress),
            width: interpolated(from: expandedReadingButtonFrame.width, to: collapsedReadingButtonFrame.width, progress: easedProgress),
            height: interpolated(from: expandedReadingButtonFrame.height, to: collapsedReadingButtonFrame.height, progress: easedProgress)
        )
        let secondaryOpacity = 1 - smoothstep((progress - 0.42) / 0.38)
        let categoryOpacity = max(secondaryOpacity, progress)

        return Layout(
            cardFrame: cardFrame,
            coverFrame: CGRect(origin: coverOrigin, size: coverSize),
            titleFrame: titleFrame,
            expandedTitleWidth: expandedTitleWidth,
            titleSize: interpolated(from: expandedTitleSize, to: collapsedTitleSize, progress: easedProgress),
            titleLineLimit: progress > 0.7 ? 1 : nil,
            subtitleSize: interpolated(from: 20, to: 11, progress: easedProgress),
            categoryFrame: categoryFrame,
            copyButtonFrame: copyButtonFrame,
            readingButtonFrame: readingButtonFrame,
            secondaryOpacity: secondaryOpacity,
            surfaceOpacity: 1,
            categoryOpacity: categoryOpacity,
            cornerRadius: interpolated(from: 22, to: 18, progress: easedProgress),
            hoverScale: interpolated(from: 1.004, to: 1.002, progress: easedProgress),
            isCategoryProminent: progress < 0.55,
            copyButtonIconOnly: progress > 0.55,
            readingButtonIconOnly: progress > 0.55
        )
    }

    static func interpolated(from start: CGFloat, to end: CGFloat, progress: CGFloat) -> CGFloat {
        start + (end - start) * min(max(progress, 0), 1)
    }

    static func smoothstep(_ value: CGFloat) -> CGFloat {
        let clamped = min(max(value, 0), 1)
        return clamped * clamped * (3 - 2 * clamped)
    }
}

private struct BookDetailScrollOffsetReader: NSViewRepresentable {
    let bookID: LibraryBook.ID
    let onOffsetChange: (CGFloat) -> Void

    func makeNSView(context: Context) -> ObserverView {
        ObserverView(bookID: bookID, onOffsetChange: onOffsetChange)
    }

    func updateNSView(_ nsView: ObserverView, context: Context) {
        nsView.bookID = bookID
        nsView.onOffsetChange = onOffsetChange
        nsView.attachToNearestScrollViewIfNeeded()
    }

    final class ObserverView: NSView {
        var bookID: LibraryBook.ID
        var onOffsetChange: (CGFloat) -> Void
        private weak var observedScrollView: NSScrollView?
        private let boundsObserverToken = NotificationObserverToken()
        private var offsetCoalescerState = BookDetailScrollOffsetCoalescer.State()

        init(bookID: LibraryBook.ID, onOffsetChange: @escaping (CGFloat) -> Void) {
            self.bookID = bookID
            self.onOffsetChange = onOffsetChange
            super.init(frame: .zero)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            DispatchQueue.main.async { [weak self] in
                self?.attachToNearestScrollViewIfNeeded()
            }
        }

        override func removeFromSuperview() {
            stopObserving(reason: "removeFromSuperview")
            super.removeFromSuperview()
        }

        override func viewWillMove(toWindow newWindow: NSWindow?) {
            if newWindow == nil {
                stopObserving(reason: "windowDetach")
            }
            super.viewWillMove(toWindow: newWindow)
        }

        func attachToNearestScrollViewIfNeeded() {
            guard let scrollView = nearestScrollView() else {
                return
            }
            guard scrollView !== observedScrollView else {
                publishOffset(from: scrollView)
                return
            }

            stopObserving(reason: "reattach")
            observedScrollView = scrollView
            scrollView.contentView.postsBoundsChangedNotifications = true
            boundsObserverToken.observer = NotificationCenter.default.addObserver(
                forName: NSView.boundsDidChangeNotification,
                object: scrollView.contentView,
                queue: .main
            ) { [weak self, weak scrollView] _ in
                guard let self, let scrollView else {
                    return
                }
                MainActor.assumeIsolated {
                    self.publishOffset(from: scrollView)
                }
            }
            NavigationPerformanceTracer.bookDetailScrollObserverAttached(bookID: bookID)
            publishOffset(from: scrollView)
        }

        private func nearestScrollView() -> NSScrollView? {
            if let enclosingScrollView {
                return enclosingScrollView
            }

            var view: NSView? = superview
            while let candidate = view {
                if let scrollView = candidate as? NSScrollView {
                    return scrollView
                }
                view = candidate.superview
            }
            return nil
        }

        private func publishOffset(from scrollView: NSScrollView) {
            scheduleOffsetPublish(max(scrollView.contentView.bounds.origin.y, 0))
        }

        private func scheduleOffsetPublish(_ offset: CGFloat) {
            guard BookDetailScrollOffsetCoalescer.record(offset: offset, state: &offsetCoalescerState) == .schedule else {
                return
            }

            DispatchQueue.main.async { [weak self] in
                guard let self else {
                    return
                }
                guard self.observedScrollView != nil,
                      let offset = BookDetailScrollOffsetCoalescer.flush(state: &self.offsetCoalescerState) else {
                    BookDetailScrollOffsetCoalescer.reset(state: &self.offsetCoalescerState)
                    return
                }
                self.onOffsetChange(offset)
            }
        }

        private func stopObserving(reason: String) {
            if boundsObserverToken.isActive {
                boundsObserverToken.clear()
                NavigationPerformanceTracer.bookDetailScrollObserverStopped(bookID: bookID, reason: reason)
            }
            observedScrollView = nil
            BookDetailScrollOffsetCoalescer.reset(state: &offsetCoalescerState)
        }
    }
}

private final class NotificationObserverToken {
    var observer: NSObjectProtocol?

    var isActive: Bool {
        observer != nil
    }

    func clear() {
        if let observer {
            NotificationCenter.default.removeObserver(observer)
            self.observer = nil
        }
    }

    deinit {
        clear()
    }
}

private struct BookDetailHeroView: View {
    let book: LibraryBook
    let title: String
    let titleColumnHeight: CGFloat
    let themeColor: Color
    let localizer: AppLocalizer
    let onCopyTitle: () -> Void

    var body: some View {
        Color.clear
            .frame(maxWidth: .infinity)
            .frame(height: BookDetailHeroMotionMetrics.expandedCardHeight(titleColumnHeight: titleColumnHeight))
    }
}

private struct BookDetailScrollChrome<Content: View, Overlay: View>: View {
    let book: LibraryBook
    let title: String
    let titleMode: BookTitleDisplayMode
    let themeColor: Color
    let localizer: AppLocalizer
    let titleColumnHeight: CGFloat
    let readingActionTitleKey: L10nKey
    let isLaunchingReader: Bool
    let onCycleTitle: () -> Void
    let onCopyTitle: () -> Void
    let onOpenReader: () -> Void
    let overlay: (CGSize) -> Overlay
    let onTitleColumnHeightChange: (CGFloat) -> Void
    let onTagPillFramesChange: ([Tag.DatabaseID: CGRect]) -> Void
    let contentReplacementTransition: AnyTransition
    let contentReplacementAnimation: Animation?
    let content: Content

    @State private var heroScrollOffset: CGFloat = 0
    @State private var scrollFrameState = BookDetailScrollFrameMetrics.State()
    @State private var scrollSummaryTask: Task<Void, Never>?

    init(
        book: LibraryBook,
        title: String,
        titleMode: BookTitleDisplayMode,
        themeColor: Color,
        localizer: AppLocalizer,
        titleColumnHeight: CGFloat,
        readingActionTitleKey: L10nKey,
        isLaunchingReader: Bool,
        onCycleTitle: @escaping () -> Void,
        onCopyTitle: @escaping () -> Void,
        onOpenReader: @escaping () -> Void,
        @ViewBuilder overlay: @escaping (CGSize) -> Overlay,
        onTitleColumnHeightChange: @escaping (CGFloat) -> Void,
        onTagPillFramesChange: @escaping ([Tag.DatabaseID: CGRect]) -> Void,
        contentReplacementTransition: AnyTransition,
        contentReplacementAnimation: Animation?,
        @ViewBuilder content: () -> Content
    ) {
        self.book = book
        self.title = title
        self.titleMode = titleMode
        self.themeColor = themeColor
        self.localizer = localizer
        self.titleColumnHeight = titleColumnHeight
        self.readingActionTitleKey = readingActionTitleKey
        self.isLaunchingReader = isLaunchingReader
        self.onCycleTitle = onCycleTitle
        self.onCopyTitle = onCopyTitle
        self.onOpenReader = onOpenReader
        self.overlay = overlay
        self.onTitleColumnHeightChange = onTitleColumnHeightChange
        self.onTagPillFramesChange = onTagPillFramesChange
        self.contentReplacementTransition = contentReplacementTransition
        self.contentReplacementAnimation = contentReplacementAnimation
        self.content = content()
    }

    var body: some View {
        // ScrollChrome 同时承担可折叠标题、背景色和 tag popover 坐标收集；
        // 这些几何状态集中在这里，避免正文子视图在滚动时各自触发昂贵布局。
        GeometryReader { proxy in
            let collapseProgress = BookDetailStickyHeaderMetrics.progress(for: heroScrollOffset)
            let motion = tracedHeroLayout(
                bookID: book.id,
                containerWidth: proxy.size.width,
                scrollOffset: heroScrollOffset,
                progress: collapseProgress
            )

            ZStack(alignment: .top) {
                ScrollView {
                    VStack(spacing: 0) {
                        BookDetailScrollOffsetReader(bookID: book.id) { offset in
                            handleScrollOffset(offset, bookID: book.id)
                        }
                        .frame(width: 0, height: 0)

                        content
                            .padding(.horizontal, BookDetailHeroMotionMetrics.detailHorizontalPadding)
                            .padding(.top, BookDetailHeroMotionMetrics.detailTopPadding)
                            .padding(.bottom, 36)
                            .frame(maxWidth: BookDetailHeroMotionMetrics.maxContentWidth, alignment: .top)
                            .frame(maxWidth: .infinity, alignment: .top)
                    }
                }

                BookDetailFloatingHeroGroup(
                    book: book,
                    title: title,
                    titleMode: titleMode,
                    themeColor: themeColor,
                    layout: motion,
                    localizer: localizer,
                    readingActionTitleKey: readingActionTitleKey,
                    isLaunchingReader: isLaunchingReader,
                    onCycleTitle: onCycleTitle,
                    onCopyTitle: onCopyTitle,
                    onOpenReader: onOpenReader
                )
                .id(book.id)
                .transition(contentReplacementTransition)
                .animation(contentReplacementAnimation, value: book.id)
                .zIndex(3)

                overlay(proxy.size)
                    .zIndex(20)
            }
            .coordinateSpace(name: BookDetailTagCoordinateSpace.name)
            .onPreferenceChange(BookDetailTagPillFramePreferenceKey.self) { frames in
                onTagPillFramesChange(frames)
            }
            .onPreferenceChange(BookDetailHeroTitleColumnHeightPreferenceKey.self) { height in
                onTitleColumnHeightChange(height)
            }
            .background {
                BookDetailBackground(themeColor: themeColor)
                    .animation(contentReplacementAnimation, value: book.id)
            }
        }
        .onDisappear {
            if BookDetailScrollResetPolicy.shouldResetScrollState(for: .disappear) {
                resetScrollState(bookID: book.id, flushSummary: true)
            }
        }
    }

    private func handleScrollOffset(_ offset: CGFloat, bookID: LibraryBook.ID) {
        let heroPhase = BookDetailStickyHeaderMetrics.phase(for: offset)
        let result = NavigationPerformanceTracer.bookDetailScrollFrame(
            bookID: bookID,
            offset: offset,
            heroPhase: heroPhase,
            state: &scrollFrameState
        )

        updateHeroOffsetIfNeeded(offset)

        if result.shouldScheduleSummary {
            scheduleScrollSummary(bookID: bookID)
        }
    }

    private func updateHeroOffsetIfNeeded(_ offset: CGFloat) {
        let presentationOffset = BookDetailStickyHeaderMetrics.presentationOffset(for: offset)
        guard BookDetailStickyHeaderMetrics.shouldPublishPresentationOffset(
            presentationOffset,
            previous: heroScrollOffset
        ) else {
            return
        }

        var transaction = Transaction()
        transaction.animation = nil
        withTransaction(transaction) {
            heroScrollOffset = presentationOffset
        }
    }

    private func tracedHeroLayout(
        bookID: LibraryBook.ID,
        containerWidth: CGFloat,
        scrollOffset: CGFloat,
        progress: CGFloat
    ) -> BookDetailHeroMotionMetrics.Layout {
        let startedAt = NavigationPerformanceTracer.heroLayoutWillMeasure()
        let layout = BookDetailHeroMotionMetrics.layout(
            containerWidth: containerWidth,
            scrollOffset: scrollOffset,
            progress: progress,
            expandedTitleColumnHeight: titleColumnHeight
        )
        NavigationPerformanceTracer.heroLayoutDidMeasure(bookID: bookID, startedAt: startedAt)
        return layout
    }

    private func scheduleScrollSummary(bookID: LibraryBook.ID) {
        scrollSummaryTask?.cancel()
        scrollSummaryTask = Task {
            try? await Task.sleep(for: .milliseconds(450))
            guard !Task.isCancelled else {
                return
            }
            await MainActor.run {
                NavigationPerformanceTracer.bookDetailScrollDidPause(bookID: bookID, state: &scrollFrameState)
                scrollSummaryTask = nil
            }
        }
    }

    private func resetScrollState(bookID: LibraryBook.ID, flushSummary: Bool) {
        scrollSummaryTask?.cancel()
        scrollSummaryTask = nil
        if flushSummary {
            NavigationPerformanceTracer.bookDetailScrollDidPause(bookID: bookID, state: &scrollFrameState)
        } else {
            scrollFrameState.reset()
        }
        heroScrollOffset = 0
    }
}

enum BookDetailContentReplacementMotion {
    static let duration = 0.18
    static let animation = Animation.easeInOut(duration: duration)

    @MainActor
    static var transition: AnyTransition {
        .opacity.combined(with: .scale(scale: 0.995))
    }
}

enum BookDetailExternalTransitionShellPolicy {
    static let initialContentReplacementAnimationPolicy: LibraryRouteBackingActivationAnimationPolicy = .disabledAnimation
    static let initialContentReplacementTransitionStyle: LibraryRouteTransitionStyle = .identity

    static func shouldSuppressContentReplacementMotion(
        usesExternalTransitionShell: Bool,
        hasConsumedExternalTransitionShell: Bool
    ) -> Bool {
        usesExternalTransitionShell && !hasConsumedExternalTransitionShell
    }
}

enum BookDetailReplacementPolicy {
    static let mainContentTransitionStyle: LibraryRouteTransitionStyle = .identity
    static let contentCrossfadeDuration = BookDetailContentReplacementMotion.duration
    static let contentCrossfadeAnimation = Animation.easeInOut(duration: contentCrossfadeDuration)

    static func shouldClearDisplayTags(for event: BookDetailScrollLifecycleEvent) -> Bool {
        event != .bookChanged
    }

    static func deferredSectionsBookIDAfterBookChange(
        mountedBookID: LibraryBook.ID?,
        nextBookID: LibraryBook.ID
    ) -> LibraryBook.ID? {
        mountedBookID == nil ? nil : nextBookID
    }

    static func shouldShowDeferredSections(mountedBookID: LibraryBook.ID?) -> Bool {
        mountedBookID != nil
    }
}

enum BookDetailThemeColorPolicy {
    static let safeFallbackColor = NSColor(srgbRed: 0.54, green: 0.64, blue: 0.68, alpha: 1)
    static let backgroundCrossfadeDuration = BookDetailContentReplacementMotion.duration
    static let backgroundCrossfadeAnimation = Animation.easeInOut(duration: backgroundCrossfadeDuration)

    static func displayColor(
        resolvedColor: NSColor?,
        cachedColor: NSColor?,
        currentStableColor: NSColor?
    ) -> NSColor {
        resolvedColor ?? cachedColor ?? currentStableColor ?? safeFallbackColor
    }

    static func stableResolvedColor(cachedColor: NSColor?) -> NSColor {
        cachedColor ?? safeFallbackColor
    }
}

enum BookDetailTitleModeMotion {
    static let animation = Animation.easeInOut(duration: 0.18)
}

enum BookDetailTitleModeHint {
    static func titleKey(for mode: BookTitleDisplayMode) -> L10nKey {
        mode.titleKey
    }
}

enum BookDetailReadingActionPolicy {
    static func titleKey(for readingState: BookReadingState?) -> L10nKey {
        guard let readingState, !readingState.isCompleted else {
            return .readerStart
        }
        return .readerContinue
    }

    static func initialPage(for readingState: BookReadingState?) -> Int {
        guard let readingState, !readingState.isCompleted else {
            return 0
        }
        return max(readingState.currentPageIndex, 0)
    }
}

enum BookDetailScrollLifecycleEvent {
    case bookChanged
    case disappear
}

enum BookDetailScrollResetPolicy {
    static func shouldResetScrollState(for event: BookDetailScrollLifecycleEvent) -> Bool {
        event == .disappear
    }
}

private struct BookDetailFloatingHeroGroup: View {
    let book: LibraryBook
    let title: String
    let titleMode: BookTitleDisplayMode
    let themeColor: Color
    let layout: BookDetailHeroMotionMetrics.Layout
    let localizer: AppLocalizer
    let readingActionTitleKey: L10nKey
    let isLaunchingReader: Bool
    let onCycleTitle: () -> Void
    let onCopyTitle: () -> Void
    let onOpenReader: () -> Void

    private var titleModeLabel: String {
        localizer.string(BookDetailTitleModeHint.titleKey(for: titleMode))
    }

    private var subtitle: String? {
        guard let titleJpn = book.titleJpn, !titleJpn.isEmpty, titleJpn != title else {
            return nil
        }
        return titleJpn
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            titleColumnMeasurement

            Color.clear
                .frame(width: layout.cardFrame.width, height: layout.cardFrame.height)
                .detailGlassSurface(cornerRadius: layout.cornerRadius, material: .regularMaterial)
                .detailHoverSurface(cornerRadius: layout.cornerRadius, scale: layout.hoverScale)
                .opacity(layout.surfaceOpacity)
                .position(x: layout.cardFrame.midX, y: layout.cardFrame.midY)
                .allowsHitTesting(false)

            BookCoverThumbnail(
                book: book,
                width: layout.coverFrame.width,
                height: layout.coverFrame.height,
                cornerRadius: max(8, min(18, layout.coverFrame.width * 0.06))
            )
            .shadow(color: .black.opacity(0.18), radius: 16, x: 0, y: 9)
            .frame(width: layout.coverFrame.width, height: layout.coverFrame.height)
            .position(x: layout.coverFrame.midX, y: layout.coverFrame.midY)
            .allowsHitTesting(false)

            Button(action: onCycleTitle) {
                BookDetailHeroTitleColumn(
                    title: title,
                    subtitle: subtitle,
                    modeLabel: titleModeLabel,
                    titleSize: layout.titleSize,
                    subtitleSize: layout.subtitleSize,
                    secondaryOpacity: layout.secondaryOpacity,
                    lineLimit: layout.titleLineLimit,
                    isMeasuring: false
                )
                .frame(width: layout.titleFrame.width, height: layout.titleFrame.height, alignment: .topLeading)
                .modifier(BookDetailHeroTitleColumnClipModifier(isClipped: layout.titleLineLimit != nil))
            }
            .buttonStyle(.plain)
            .help(localizer.string(titleMode.titleKey))
            .position(x: layout.titleFrame.midX, y: layout.titleFrame.midY)
            .animation(BookDetailTitleModeMotion.animation, value: title)
            .animation(BookDetailTitleModeMotion.animation, value: titleMode)

            if let category = book.category, !category.isEmpty {
                CategoryBadge(category: category, themeColor: themeColor, isProminent: layout.isCategoryProminent)
                    .opacity(layout.categoryOpacity)
                    .position(x: layout.categoryFrame.midX, y: layout.categoryFrame.midY)
                    .allowsHitTesting(false)
            }

            Button(action: onCopyTitle) {
                if layout.copyButtonIconOnly {
                    Label(localizer.string(.copyTitle), systemImage: "doc.on.doc")
                        .labelStyle(.iconOnly)
                } else {
                    Label(localizer.string(.copyTitle), systemImage: "doc.on.doc")
                }
            }
            .controlSize(layout.copyButtonIconOnly ? .regular : .large)
            .frame(width: layout.copyButtonFrame.width, height: layout.copyButtonFrame.height)
            .position(x: layout.copyButtonFrame.midX, y: layout.copyButtonFrame.midY)

            Button(action: onOpenReader) {
                if layout.readingButtonIconOnly {
                    Label(localizer.string(readingActionTitleKey), systemImage: "book.pages")
                        .labelStyle(.iconOnly)
                } else {
                    if isLaunchingReader {
                        HStack(spacing: 8) {
                            ProgressView()
                                .controlSize(.small)
                            Text(localizer.string(readingActionTitleKey))
                        }
                    } else {
                        Label(localizer.string(readingActionTitleKey), systemImage: "book.pages")
                    }
                }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(layout.readingButtonIconOnly ? .regular : .large)
            .tint(themeColor)
            .disabled(isLaunchingReader)
            .help(localizer.string(readingActionTitleKey))
            .frame(width: layout.readingButtonFrame.width, height: layout.readingButtonFrame.height)
            .position(x: layout.readingButtonFrame.midX, y: layout.readingButtonFrame.midY)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var titleColumnMeasurement: some View {
        BookDetailHeroTitleColumn(
            title: title,
            subtitle: subtitle,
            modeLabel: titleModeLabel,
            titleSize: BookDetailHeroMotionMetrics.expandedTitleSize,
            subtitleSize: 20,
            secondaryOpacity: 1,
            lineLimit: nil,
            isMeasuring: true
        )
        .frame(width: layout.expandedTitleWidth, alignment: .topLeading)
        .fixedSize(horizontal: false, vertical: true)
        .background {
            GeometryReader { proxy in
                Color.clear.preference(
                    key: BookDetailHeroTitleColumnHeightPreferenceKey.self,
                    value: proxy.size.height
                )
            }
        }
        .opacity(0)
        .accessibilityHidden(true)
        .allowsHitTesting(false)
        .position(x: -10_000, y: -10_000)
    }
}

private struct BookDetailHeroTitleColumn: View {
    let title: String
    let subtitle: String?
    let modeLabel: String
    let titleSize: CGFloat
    let subtitleSize: CGFloat
    let secondaryOpacity: CGFloat
    let lineLimit: Int?
    let isMeasuring: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(title)
                    .font(.system(size: titleSize, weight: .semibold, design: .default))
                    .foregroundStyle(.primary)
                    .multilineTextAlignment(.leading)
                    .lineLimit(lineLimit)
                    .fixedSize(horizontal: false, vertical: lineLimit == nil)

                BookDetailTitleModeBadge(label: modeLabel)
                    .opacity(secondaryOpacity)
                    .fixedSize()
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if let subtitle {
                Text(subtitle)
                    .font(.system(size: subtitleSize, weight: .regular))
                    .foregroundStyle(.secondary)
                    .lineLimit(lineLimit == nil ? nil : 1)
                    .fixedSize(horizontal: false, vertical: lineLimit == nil)
                    .opacity(secondaryOpacity)
                    .accessibilityHidden(secondaryOpacity <= 0.05)
            }
        }
        .animation(isMeasuring ? nil : BookDetailTitleModeMotion.animation, value: title)
        .animation(isMeasuring ? nil : BookDetailTitleModeMotion.animation, value: subtitle)
        .animation(isMeasuring ? nil : BookDetailTitleModeMotion.animation, value: modeLabel)
    }
}

private struct BookDetailHeroTitleColumnClipModifier: ViewModifier {
    let isClipped: Bool

    func body(content: Content) -> some View {
        if isClipped {
            content.clipped()
        } else {
            content
        }
    }
}

private struct BookDetailTitleModeBadge: View {
    let label: String

    var body: some View {
        Text(label)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(.secondary.opacity(0.12), in: Capsule())
            .overlay {
                Capsule()
                    .stroke(.secondary.opacity(0.16), lineWidth: 1)
            }
    }
}

private struct BookDetailHeroTitleColumnHeightPreferenceKey: PreferenceKey {
    static let defaultValue: CGFloat = BookDetailHeroMotionMetrics.defaultExpandedTitleColumnHeight

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

private struct CategoryBadge: View {
    let category: String
    let themeColor: Color
    let isProminent: Bool

    var body: some View {
        Label(category, systemImage: "square.grid.2x2")
            .font(isProminent ? .title3.weight(.semibold) : .caption.weight(.semibold))
            .foregroundStyle(themeColor)
            .padding(.horizontal, isProminent ? 14 : 9)
            .padding(.vertical, isProminent ? 8 : 4)
            .background(themeColor.opacity(isProminent ? 0.16 : 0.12), in: Capsule())
            .overlay {
                Capsule()
                    .stroke(themeColor.opacity(isProminent ? 0.35 : 0.22), lineWidth: 1)
            }
    }
}

private struct BasicInfoPanel: View {
    let book: LibraryBook
    let localizer: AppLocalizer

    var body: some View {
        TopInfoPanel {
            HStack(alignment: .center, spacing: 10) {
                MetricTile(icon: languageFlag(for: book.languageCode), title: localizer.string(.appLanguage), value: languageText(for: book.languageCode))
                MetricTile(systemImage: "doc.text", title: localizer.string(.pages), value: pageText)
                MetricTile(systemImage: "eye", title: localizer.string(.readCount), value: String(book.readCount))
            }
            .frame(maxWidth: .infinity, alignment: .center)
        }
    }

    private var pageText: String {
        let localCount = book.fileCount.map(String.init)
        let remotePages = book.pages.map(String.init)
        switch (localCount, remotePages) {
        case let (localCount?, remotePages?):
            return "\(localCount) / \(remotePages)"
        case let (localCount?, nil):
            return localCount
        case let (nil, remotePages?):
            return remotePages
        case (nil, nil):
            return localizer.string(.unknown)
        }
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

private struct StatusInfoPanel: View {
    let book: LibraryBook
    let themeColor: Color
    let localizer: AppLocalizer

    var body: some View {
        TopInfoPanel {
            HStack(alignment: .center, spacing: 8) {
                StatusIcon(systemImage: "character.book.closed", title: localizer.string(.statusTranslatedShort), isActive: book.isTranslated, themeColor: themeColor)
                StatusIcon(systemImage: "paintpalette", title: localizer.string(.statusColorShort), isActive: book.isFullColor, themeColor: themeColor)
                StatusIcon(systemImage: "eye", title: localizer.string(.statusCensorshipShort), isActive: book.censorship == "uncensored", themeColor: themeColor)
                StatusIcon(systemImage: "rectangle.badge.plus", title: localizer.string(.statusAdsShort), isActive: book.hasExtraneousAds, themeColor: themeColor)
            }
            .frame(maxWidth: .infinity, alignment: .center)
        }
    }
}

private struct RatingFavoritePanel: View {
    let book: LibraryBook
    let themeColor: Color
    let localizer: AppLocalizer
    let onToggleMarked: () -> Void

    var body: some View {
        TopInfoPanel {
            VStack(alignment: .center, spacing: 10) {
                HStack(spacing: 4) {
                    ForEach(0..<5, id: \.self) { index in
                        Image(systemName: starName(at: index))
                            .font(.title2)
                            .foregroundStyle(.yellow)
                    }

                    Text(book.rating.map { String(format: "%.2f", $0) } ?? localizer.string(.unrate))
                        .font(.headline)
                        .foregroundStyle(.secondary)
                        .padding(.leading, 6)
                }

                Divider()
                    .frame(maxWidth: 180)

                Button(action: onToggleMarked) {
                    Label(
                        book.mark ? localizer.string(.markedStatus) : localizer.string(.marked),
                        systemImage: book.mark ? "heart.fill" : "heart"
                    )
                }
                .font(.title3.weight(.semibold))
                .buttonStyle(.borderedProminent)
                .tint(book.mark ? .red : .secondary)
            }
            .frame(maxWidth: .infinity, alignment: .center)
        }
    }

    private func starName(at index: Int) -> String {
        guard let rating = book.rating else {
            return "star"
        }

        let threshold = Double(index) + 1
        if rating >= threshold {
            return "star.fill"
        }
        if rating >= threshold - 0.5 {
            return "star.leadinghalf.filled"
        }
        return "star"
    }
}

private struct StatusIcon: View {
    let systemImage: String
    let title: String
    let isActive: Bool
    let themeColor: Color

    var body: some View {
        VStack(spacing: 7) {
            Image(systemName: systemImage)
                .font(.system(size: 28, weight: .semibold))
                .foregroundStyle(isActive ? themeColor : Color.secondary.opacity(0.45))
                .frame(width: 50, height: 50)
                .background((isActive ? themeColor.opacity(0.14) : Color.secondary.opacity(0.08)), in: Circle())

            Text(title)
                .font(.caption)
                .foregroundStyle(isActive ? .primary : .secondary)
                .lineLimit(1)
        }
        .frame(width: 58)
        .detailHoverSurface(cornerRadius: 12, scale: 1.045)
        .help(title)
    }
}

private struct MetricTile: View {
    var icon: String?
    var systemImage: String?
    let title: String
    let value: String

    var body: some View {
        VStack(spacing: 7) {
            Group {
                if let icon {
                    Text(icon)
                } else if let systemImage {
                    Image(systemName: systemImage)
                        .foregroundStyle(.secondary)
                }
            }
            .font(.title3)
            .frame(height: 26)

            VStack(alignment: .center, spacing: 2) {
                Text(value)
                    .font(.callout)
                    .fontWeight(.medium)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                Text(title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity)
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 8)
        .frame(minHeight: 92)
        .background(Color.secondary.opacity(0.07), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .detailHoverSurface(cornerRadius: 10, scale: 1.025)
    }
}

private struct TopInfoPanel<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(16)
            .frame(maxWidth: .infinity, minHeight: 176, alignment: .center)
            .detailGlassSurface(cornerRadius: 12, material: .regularMaterial)
            .detailHoverSurface(cornerRadius: 12)
    }
}

private struct BookDetailTopCardGrid<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        BookDetailEqualWidthGridLayout(spacing: BookDetailTopCardGridMetrics.defaultSpacing) {
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct BookDetailEqualWidthGridLayout: Layout {
    var spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let availableWidth = proposal.width ?? idealWidth(for: subviews)
        let columns = BookDetailTopCardGridMetrics.columns(for: availableWidth, spacing: spacing)
        let columnWidth = BookDetailTopCardGridMetrics.columnWidth(
            availableWidth: availableWidth,
            columns: columns,
            spacing: spacing
        )
        let rows = rowHeights(for: subviews, columns: columns, columnWidth: columnWidth)
        let height = rows.reduce(0, +) + spacing * CGFloat(max(rows.count - 1, 0))
        return CGSize(width: availableWidth, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let columns = BookDetailTopCardGridMetrics.columns(for: bounds.width, spacing: spacing)
        let columnWidth = BookDetailTopCardGridMetrics.columnWidth(
            availableWidth: bounds.width,
            columns: columns,
            spacing: spacing
        )
        let rowHeights = rowHeights(for: subviews, columns: columns, columnWidth: columnWidth)

        for index in subviews.indices {
            let row = index / columns
            let column = index % columns
            let x = bounds.minX + CGFloat(column) * (columnWidth + spacing)
            let y = bounds.minY + rowHeights.prefix(row).reduce(0, +) + spacing * CGFloat(row)
            subviews[index].place(
                at: CGPoint(x: x, y: y),
                proposal: ProposedViewSize(width: columnWidth, height: rowHeights[row])
            )
        }
    }

    private func rowHeights(for subviews: Subviews, columns: Int, columnWidth: CGFloat) -> [CGFloat] {
        stride(from: 0, to: subviews.count, by: columns).map { rowStart in
            let rowEnd = Swift.min(rowStart + columns, subviews.count)
            return subviews[rowStart..<rowEnd].map { subview in
                subview.sizeThatFits(ProposedViewSize(width: columnWidth, height: nil)).height
            }.max() ?? 0
        }
    }

    private func idealWidth(for subviews: Subviews) -> CGFloat {
        let idealItemWidth = subviews.map { subview in
            subview.sizeThatFits(.unspecified).width
        }.max() ?? BookDetailTopCardGridMetrics.defaultMinimumColumnWidth
        let columns = Swift.min(Swift.max(subviews.count, 1), BookDetailTopCardGridMetrics.defaultMaximumColumns)
        return idealItemWidth * CGFloat(columns) + spacing * CGFloat(max(columns - 1, 0))
    }
}

enum BookDetailTopCardGridMetrics {
    static let defaultSpacing: CGFloat = 14
    static let defaultMinimumColumnWidth: CGFloat = 280
    static let defaultMaximumColumns = 3

    static func columns(
        for availableWidth: CGFloat,
        minimumColumnWidth: CGFloat = defaultMinimumColumnWidth,
        maximumColumns: Int = defaultMaximumColumns,
        spacing: CGFloat = defaultSpacing
    ) -> Int {
        guard availableWidth.isFinite, availableWidth > 0, maximumColumns > 1 else {
            return 1
        }

        let rawColumns = Int(floor((availableWidth + spacing) / (minimumColumnWidth + spacing)))
        return Swift.min(Swift.max(rawColumns, 1), maximumColumns)
    }

    static func columnWidth(availableWidth: CGFloat, columns: Int, spacing: CGFloat = defaultSpacing) -> CGFloat {
        let safeColumns = Swift.max(columns, 1)
        let totalSpacing = spacing * CGFloat(safeColumns - 1)
        return Swift.max((availableWidth - totalSpacing) / CGFloat(safeColumns), 0)
    }
}

private struct BookDetailSection<Content: View>: View {
    let title: String
    let systemImage: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(title, systemImage: systemImage)
                .font(.headline)

            content
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(16)
        .detailGlassSurface(cornerRadius: 12, material: .regularMaterial)
        .detailHoverSurface(cornerRadius: 12)
    }
}

private struct TagPillCloud: View {
    let tags: [TagDisplaySummary]
    let themeColor: Color
    let isCompact: Bool
    let localizer: AppLocalizer
    let onSelectTag: (TagDisplaySummary) -> Void
    let onToggleFollowed: (TagDisplaySummary) -> Void
    let onRequestExplanation: (TagDisplaySummary) -> Void
    let onClearExplanation: (TagDisplaySummary) -> Void
    let claimableWorks: [TagDisplaySummary]
    let onConfirmWork: (TagDisplaySummary, TagDisplaySummary) -> Void

    var body: some View {
        BookDetailTagFlowLayout(spacing: isCompact ? 6 : 8, lineSpacing: isCompact ? 6 : 8) {
            ForEach(tags) { tag in
                BookDetailTagPill(
                    tag: tag,
                    themeColor: themeColor,
                    isCompact: isCompact,
                    localizer: localizer,
                    onSelect: { onSelectTag(tag) },
                    onToggleFollowed: { onToggleFollowed(tag) },
                    onRequestExplanation: { onRequestExplanation(tag) },
                    onClearExplanation: { onClearExplanation(tag) },
                    claimableWorks: claimableWorks,
                    onConfirmWork: { work in onConfirmWork(work, tag) }
                )
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct BookDetailTagFlowLayout: Layout {
    var spacing: CGFloat
    var lineSpacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let proposedWidth = proposal.width ?? .infinity
        let rows = rows(for: subviews, proposedWidth: proposedWidth)
        let width = proposal.width ?? rows.map(\.width).max() ?? 0
        let height = rows.map(\.height).reduce(0, +) + lineSpacing * CGFloat(max(rows.count - 1, 0))
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let rows = rows(for: subviews, proposedWidth: bounds.width)
        var y = bounds.minY

        for row in rows {
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

    private func rows(for subviews: Subviews, proposedWidth: CGFloat) -> [BookDetailTagFlowMetrics.Row] {
        let items = subviews.indices.map { index in
            BookDetailTagFlowMetrics.Item(index: index, size: subviews[index].sizeThatFits(.unspecified))
        }
        return BookDetailTagFlowMetrics.rows(
            for: items,
            availableWidth: proposedWidth,
            spacing: spacing
        )
    }
}

enum BookDetailTagFlowMetrics {
    struct Item {
        let index: Int
        let size: CGSize
    }

    struct Row {
        var items: [Item] = []
        var width: CGFloat = 0
        var height: CGFloat = 0

        mutating func append(_ item: Item, spacing: CGFloat) {
            width = items.isEmpty ? item.size.width : width + spacing + item.size.width
            height = max(height, item.size.height)
            items.append(item)
        }
    }

    static func rows(for items: [Item], availableWidth: CGFloat, spacing: CGFloat) -> [Row] {
        let maxWidth = availableWidth.isFinite ? Swift.max(availableWidth, 0) : .infinity
        var rows: [Row] = []
        var current = Row()

        for item in items {
            let proposedWidth = current.items.isEmpty ? item.size.width : current.width + spacing + item.size.width
            if proposedWidth > maxWidth, !current.items.isEmpty {
                rows.append(current)
                current = Row()
            }
            current.append(item, spacing: spacing)
        }

        if !current.items.isEmpty {
            rows.append(current)
        }

        return rows
    }
}

private struct GroupedTagSections: View {
    let groups: [BookDetailTagGroup]
    let themeColor: Color
    let localizer: AppLocalizer
    let isCompact: Bool
    let onSelectTag: (TagDisplaySummary) -> Void
    let onToggleFollowed: (TagDisplaySummary) -> Void
    let onRequestExplanation: (TagDisplaySummary) -> Void
    let onClearExplanation: (TagDisplaySummary) -> Void
    let claimableWorks: [TagDisplaySummary]
    let onConfirmWork: (TagDisplaySummary, TagDisplaySummary) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: isCompact ? 10 : 12) {
            ForEach(Array(groups.enumerated()), id: \.element.id) { index, group in
                if index > 0 {
                    Divider()
                }

                VStack(alignment: .leading, spacing: isCompact ? 7 : 9) {
                    Text(title(for: group.namespace))
                        .font(.caption)
                        .fontWeight(.semibold)
                        .foregroundStyle(.secondary)
                        .textCase(.uppercase)

                    TagPillCloud(
                        tags: group.tags,
                        themeColor: themeColor,
                        isCompact: isCompact,
                        localizer: localizer,
                        onSelectTag: onSelectTag,
                        onToggleFollowed: onToggleFollowed,
                        onRequestExplanation: onRequestExplanation,
                        onClearExplanation: onClearExplanation,
                        claimableWorks: claimableWorks,
                        onConfirmWork: onConfirmWork
                    )
                }
            }
        }
    }

    private func title(for namespace: String) -> String {
        switch namespace {
        case "artist":
            return localizer.string(.tagNamespaceArtist)
        case "group":
            return localizer.string(.tagNamespaceGroup)
        case "parody":
            return localizer.string(.tagNamespaceParody)
        case "character":
            return localizer.string(.tagNamespaceCharacter)
        case "female":
            return localizer.string(.tagNamespaceFemale)
        case "male":
            return localizer.string(.tagNamespaceMale)
        case "mixed":
            return localizer.string(.tagNamespaceMixed)
        case "location":
            return localizer.string(.tagNamespaceLocation)
        case "other":
            return localizer.string(.tagNamespaceOther)
        default:
            return namespace
        }
    }
}

private struct BookReaderSection: View {
    let book: LibraryBook
    let readingState: BookReadingState?
    let initialLoadLimit: Int
    let hoverPreviewDelayMilliseconds: Int
    let localizer: AppLocalizer
    let resolveLibraryRootURL: @MainActor () throws -> URL?
    let onRecordRead: () -> Void
    let onProgress: (Int, Int, Bool?) -> Void
    let onResetProgress: () -> Void
    let onOpenReader: (Int, [BookReaderLoadedPage]) -> Void

    @State private var pages: [BookReaderLoadedPage] = []
    @State private var totalPageCount: Int?
    @State private var loadingState: BookReaderLoadingState = .idle
    @State private var hoverPreviewPresenter = BookReaderHoverPreviewPresenter()
    @State private var hoverPreviewTask: Task<Void, Never>?
    @State private var loadTask: Task<Void, Never>?
    @State private var loadLifecycle = BookReaderLoadLifecycleState()
    @State private var sectionSize: CGSize = .zero
    @State private var hostWindow: NSWindow?
    @State private var hasRecordedRead = false

    var body: some View {
        // 阅读器只在用户点开时读取 archive，并在首次开始加载页面时记录阅读；
        // 不要在详情页出现时预读源文件，沙盒授权和大压缩包 IO 都需要按需发生。
        VStack(alignment: .leading, spacing: 14) {
            readerHeader

            switch loadingState {
            case .idle:
                idleContent
            case .loading where pages.isEmpty:
                loadingContent
            case .loaded, .loading:
                loadedContent
            case .failed(let message):
                failedContent(message: message)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, minHeight: 220, alignment: .topLeading)
        .detailGlassSurface(cornerRadius: 14, material: .ultraThinMaterial, interactive: true)
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(.secondary.opacity(0.16), style: StrokeStyle(lineWidth: 1, dash: [6, 6]))
        }
        .background(
            GeometryReader { proxy in
                Color.clear
                    .onAppear { sectionSize = proxy.size }
                    .onChange(of: proxy.size) { _, newValue in
                        sectionSize = newValue
                        hideHoverPreview()
                    }
            }
        )
        .coordinateSpace(name: "bookReaderSection")
        .background(BookReaderHostWindowReader { window in
            hostWindow = window
        })
        .onChange(of: book.id) { _, _ in
            reset()
        }
        .onDisappear {
            reset()
        }
    }

    private var readerHeader: some View {
        HStack(alignment: .firstTextBaseline) {
            Label(localizer.string(.readerArea), systemImage: "book.pages")
                .font(.headline)

            Spacer()

            if let readingState {
                ProgressView(value: readingState.progress)
                    .frame(width: 90)
                    .help(localizer.string(readingState.isCompleted ? .readerCompleted : .readerContinue))

                Button {
                    onProgress(
                        readingState.currentPageIndex,
                        max(readingState.totalPages, totalPageCount ?? 0),
                        !readingState.isCompleted
                    )
                } label: {
                    Label(
                        localizer.string(readingState.isCompleted ? .readerMarkUnread : .readerMarkCompleted),
                        systemImage: readingState.isCompleted ? "arrow.counterclockwise" : "checkmark.circle"
                    )
                    .labelStyle(.iconOnly)
                }
                .buttonStyle(.borderless)

                Button(role: .destructive, action: onResetProgress) {
                    Label(localizer.string(.readerResetProgress), systemImage: "trash.slash")
                        .labelStyle(.iconOnly)
                }
                .buttonStyle(.borderless)
            }

            if !pages.isEmpty {
                Text("\(localizer.string(.readerLoadedPages)): \(pages.count) / \(totalPageCount ?? pages.count)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var idleContent: some View {
        Button {
            startLoadNextBatch(recordRead: true)
        } label: {
            VStack(spacing: 10) {
                Image(systemName: "book.pages")
                    .font(.largeTitle)
                    .foregroundStyle(.secondary)

                Text(localizer.string(.readerLoad))
                    .font(.headline)

                Text("\(localizer.string(.readerInitialLoadLimit)): \(initialLoadLimit)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, minHeight: 158)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .detailHoverSurface(cornerRadius: 14, scale: 1.012)
        .accessibilityLabel(localizer.string(.readerLoad))
    }

    private var loadingContent: some View {
        VStack(spacing: 10) {
            ProgressView()
                .controlSize(.small)
            Text(localizer.string(.readerLoad))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, minHeight: 158)
    }

    private var loadedContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Button {
                    onOpenReader(readingState?.currentPageIndex ?? pages.first?.index ?? 0, pages)
                } label: {
                    Label(localizer.string(.readerContinue), systemImage: "book.pages")
                }
                Spacer()
            }

            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 118, maximum: 164), spacing: 12)],
                alignment: .leading,
                spacing: 12
            ) {
                ForEach(pages) { page in
                    GeometryReader { proxy in
                        Button {
                            hideHoverPreview()
                            onOpenReader(page.id, pages)
                        } label: {
                            BookReaderPageTile(page: page, localizer: localizer)
                                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                        }
                        .buttonStyle(.plain)
                        .detailHoverSurface(cornerRadius: 10, scale: 1.025)
                        .onContinuousHover { phase in
                            switch phase {
                            case .active(let location):
                                scheduleHoverPreview(
                                    for: page,
                                    tileFrame: proxy.frame(in: .global),
                                    location: location
                                )
                            case .ended:
                                hideHoverPreview()
                            }
                        }
                    }
                    .frame(height: 238)
                }
            }

            if hasMorePages {
                HStack {
                    Button {
                        startLoadNextBatch(recordRead: false)
                    } label: {
                        if case .loading = loadingState {
                            ProgressView()
                                .controlSize(.small)
                            Text(localizer.string(.readerLoadMore))
                        } else {
                            Label(localizer.string(.readerLoadMore), systemImage: "plus")
                        }
                    }
                    .disabled(isLoading)

                    Text("\(localizer.string(.readerInitialLoadLimit)): \(initialLoadLimit)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func failedContent(message: String) -> some View {
        VStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle")
                .font(.largeTitle)
                .foregroundStyle(.red)

            Text(message)
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            Button {
                startLoadNextBatch(recordRead: true)
            } label: {
                Label(localizer.string(.readerLoad), systemImage: "arrow.clockwise")
            }
        }
        .frame(maxWidth: .infinity, minHeight: 158)
    }

    private var hasMorePages: Bool {
        guard let totalPageCount else {
            return false
        }
        return pages.count < totalPageCount
    }

    private var isLoading: Bool {
        if loadLifecycle.isLoading || loadTask != nil {
            return true
        }
        if case .loading = loadingState {
            return true
        }
        return false
    }

    private func startLoadNextBatch(recordRead: Bool) {
        guard loadTask == nil, loadLifecycle.start(bookID: book.id) else {
            return
        }
        if recordRead {
            recordReadIfNeeded()
        }

        let expectedBookID = book.id
        loadTask = Task {
            await loadNextBatch(expectedBookID: expectedBookID)
            guard !Task.isCancelled else {
                return
            }
            loadLifecycle.finish(bookID: expectedBookID)
            loadTask = nil
        }
    }

    private func loadNextBatch(expectedBookID: LibraryBook.ID) async {
        guard expectedBookID == book.id else {
            NavigationPerformanceTracer.bookDetailStaleTaskSkipped(bookID: expectedBookID, taskName: "readerLoad")
            return
        }
        guard loadingState != .loading else {
            return
        }

        loadingState = .loading
        let archiveURL = URL(fileURLWithPath: book.filepath)
        let startIndex = pages.count
        // 详情页只保留一小批缩略图；独立阅读窗口会按当前位置加载并释放页面。
        let limit = initialLoadLimit == 0 ? 24 : min(max(initialLoadLimit, 1), 48)

        do {
            guard let libraryRootURL = try resolveLibraryRootURL() else {
                throw NyaEHError.libraryFolderPermissionRequired
            }

            let batch = try await Task.detached(priority: .userInitiated) {
                try ComicArchivePageLoadingService().loadPages(
                    from: archiveURL,
                    startIndex: startIndex,
                    limit: limit,
                    securityScopedRootURL: libraryRootURL
                )
            }.value
            guard loadLifecycle.acceptsResult(bookID: expectedBookID, isCancelled: Task.isCancelled), expectedBookID == book.id else {
                NavigationPerformanceTracer.bookDetailStaleTaskSkipped(bookID: expectedBookID, taskName: "readerLoad")
                return
            }

            let loadedPages = batch.pages.map(BookReaderLoadedPage.init(pageData:))
            pages.append(contentsOf: loadedPages)
            totalPageCount = batch.totalCount
            loadingState = .loaded
        } catch {
            guard loadLifecycle.acceptsResult(bookID: expectedBookID, isCancelled: Task.isCancelled), expectedBookID == book.id else {
                NavigationPerformanceTracer.bookDetailStaleTaskSkipped(bookID: expectedBookID, taskName: "readerLoad")
                return
            }
            loadingState = .failed(error.localizedDescription)
        }
    }

    private func scheduleHoverPreview(
        for page: BookReaderLoadedPage,
        tileFrame: CGRect,
        location: CGPoint
    ) {
        hoverPreviewTask?.cancel()
        let delay = hoverPreviewDelayMilliseconds
        hoverPreviewTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(delay) * 1_000_000)
            guard !Task.isCancelled else {
                return
            }

            let pointer = CGPoint(x: tileFrame.minX + location.x, y: tileFrame.minY + location.y)
            let size = hoverPreviewSize(for: page)
            hoverPreviewPresenter.show(
                page: page,
                size: size,
                pointerInWindow: pointer,
                tileFrameInWindow: tileFrame,
                hostWindow: hostWindow
            )
        }
    }

    private func hideHoverPreview() {
        hoverPreviewTask?.cancel()
        hoverPreviewTask = nil
        hoverPreviewPresenter.hide()
    }

    private func hoverPreviewSize(for page: BookReaderLoadedPage) -> CGSize {
        let imageSize = page.image?.size ?? CGSize(width: 420, height: 600)
        return BookReaderHoverPreviewSizer.previewSize(
            imageSize: imageSize,
            availableSize: CGSize(
                width: NSScreen.main?.visibleFrame.width ?? sectionSize.width,
                height: NSScreen.main?.visibleFrame.height ?? sectionSize.height
            ),
            visibleScreenHeight: NSScreen.main?.visibleFrame.height ?? 900
        )
    }

    private func reset() {
        hideHoverPreview()
        loadTask?.cancel()
        loadTask = nil
        loadLifecycle.reset()
        pages = []
        totalPageCount = nil
        loadingState = .idle
        hasRecordedRead = false
    }

    private func recordReadIfNeeded() {
        guard !hasRecordedRead else {
            return
        }

        hasRecordedRead = true
        onRecordRead()
    }
}

private enum BookReaderLoadingState: Equatable {
    case idle
    case loading
    case loaded
    case failed(String)
}

struct BookReaderLoadLifecycleState: Equatable {
    private(set) var activeBookID: LibraryBook.ID?

    var isLoading: Bool {
        activeBookID != nil
    }

    mutating func start(bookID: LibraryBook.ID) -> Bool {
        guard activeBookID == nil else {
            return false
        }
        activeBookID = bookID
        return true
    }

    func acceptsResult(bookID: LibraryBook.ID, isCancelled: Bool) -> Bool {
        !isCancelled && activeBookID == bookID
    }

    mutating func finish(bookID: LibraryBook.ID) {
        if activeBookID == bookID {
            activeBookID = nil
        }
    }

    mutating func reset() {
        activeBookID = nil
    }
}

struct BookReaderLoadedPage: Identifiable {
    var index: Int
    var path: String
    var image: NSImage?
    var decodedCost: Int

    var id: Int {
        index
    }

    var displayName: String {
        URL(fileURLWithPath: path).lastPathComponent
    }

    init(pageData: ComicArchivePageData) {
        index = pageData.index
        path = pageData.path
        image = NSImage(data: pageData.data)
        decodedCost = image.map { Int($0.size.width * $0.size.height * 4) } ?? 0
    }

    init(decodedPage: ReaderDecodedPage) {
        index = decodedPage.index
        path = decodedPage.path
        image = decodedPage.image
        decodedCost = decodedPage.decodedCost
    }

}

private struct BookReaderPageTile: View {
    let page: BookReaderLoadedPage
    let localizer: AppLocalizer

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(Color.secondary.opacity(0.08))

                if let image = page.image {
                    Image(nsImage: image)
                        .resizable()
                        .scaledToFit()
                        .padding(6)
                } else {
                    Image(systemName: "photo")
                        .font(.title2)
                        .foregroundStyle(.secondary)
                }
            }
            .aspectRatio(0.72, contentMode: .fit)
            .overlay(alignment: .topLeading) {
                Text("\(page.index + 1)")
                    .font(.caption2.weight(.semibold))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(.regularMaterial, in: Capsule())
                    .padding(6)
            }

            Text(page.displayName)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .accessibilityLabel("\(localizer.string(.readerOpen)) \(page.index + 1)")
    }
}

enum BookReaderHoverPreviewSizer {
    static func previewSize(
        imageSize: CGSize,
        availableSize: CGSize,
        visibleScreenHeight: CGFloat
    ) -> CGSize {
        let margin: CGFloat = 24
        let minimumSize = CGSize(width: 220, height: 260)
        let maxWidth = max(availableSize.width - margin, minimumSize.width)
        let availableHeight = availableSize.height > 0 ? availableSize.height : visibleScreenHeight
        let maxHeight = max(min(availableHeight * 0.85, visibleScreenHeight * 0.85), minimumSize.height)
        let sourceWidth = max(imageSize.width, 1)
        let sourceHeight = max(imageSize.height, 1)
        let scale = min(maxWidth / sourceWidth, maxHeight / sourceHeight)
        return CGSize(
            width: max(sourceWidth * scale, minimumSize.width),
            height: max(sourceHeight * scale, minimumSize.height)
        )
    }
}

private struct BookReaderHoverPreviewView: View {
    let page: BookReaderLoadedPage

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(.regularMaterial)

            if let image = page.image {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
                    .padding(8)
            } else {
                Image(systemName: "photo")
                    .font(.largeTitle)
                    .foregroundStyle(.secondary)
            }
        }
        .overlay(alignment: .topLeading) {
            Text("\(page.index + 1)")
                .font(.caption.weight(.semibold))
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(.thinMaterial, in: Capsule())
                .padding(8)
        }
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(.white.opacity(0.18), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.30), radius: 20, x: 0, y: 10)
    }
}

private struct BookReaderHostWindowReader: NSViewRepresentable {
    var onResolve: (NSWindow?) -> Void

    func makeNSView(context: Context) -> WindowReadingView {
        let view = WindowReadingView()
        view.onWindowChange = onResolve
        return view
    }

    func updateNSView(_ nsView: WindowReadingView, context: Context) {
        nsView.onWindowChange = onResolve
        DispatchQueue.main.async {
            onResolve(nsView.window)
        }
    }

    final class WindowReadingView: NSView {
        var onWindowChange: ((NSWindow?) -> Void)?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            onWindowChange?(window)
        }
    }
}

@MainActor
private final class BookReaderHoverPreviewPresenter {
    private var panel: NSPanel?

    func show(
        page: BookReaderLoadedPage,
        size: CGSize,
        pointerInWindow: CGPoint,
        tileFrameInWindow: CGRect,
        hostWindow: NSWindow?
    ) {
        guard let hostWindow,
              let contentView = hostWindow.contentView,
              let screen = hostWindow.screen ?? NSScreen.main else {
            return
        }

        let contentHeight = contentView.bounds.height
        let pointerInScreen = CGPoint(
            x: hostWindow.frame.minX + pointerInWindow.x,
            y: hostWindow.frame.minY + contentHeight - pointerInWindow.y
        )
        let tileFrameInScreen = CGRect(
            x: hostWindow.frame.minX + tileFrameInWindow.minX,
            y: hostWindow.frame.minY + contentHeight - tileFrameInWindow.maxY,
            width: tileFrameInWindow.width,
            height: tileFrameInWindow.height
        )
        let origin = BookReaderHoverPreviewPlacement.origin(
            previewSize: size,
            pointerInScreen: pointerInScreen,
            tileFrameInScreen: tileFrameInScreen,
            visibleFrame: screen.visibleFrame
        )
        let hostingController = NSHostingController(rootView: BookReaderHoverPreviewView(page: page))

        let panel = panel ?? makePanel()
        panel.contentViewController = hostingController
        panel.setFrame(NSRect(origin: origin, size: size), display: true)
        panel.orderFrontRegardless()
        self.panel = panel
    }

    func hide() {
        panel?.orderOut(nil)
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .none
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.level = .floating
        panel.collectionBehavior = [.transient, .ignoresCycle]
        return panel
    }
}

enum BookReaderHoverPreviewPlacement {
    static func origin(
        previewSize: CGSize,
        pointerInScreen: CGPoint,
        tileFrameInScreen: CGRect,
        visibleFrame: CGRect
    ) -> CGPoint {
        let margin: CGFloat = 12
        let gap: CGFloat = 24
        let preferredX = tileFrameInScreen.maxX + gap
        let fallbackX = tileFrameInScreen.minX - gap - previewSize.width
        let rawX = preferredX + previewSize.width + margin <= visibleFrame.maxX
            ? preferredX
            : fallbackX
        let minX = visibleFrame.minX + margin
        let maxX = visibleFrame.maxX - previewSize.width - margin
        let minY = visibleFrame.minY + margin
        let maxY = visibleFrame.maxY - previewSize.height - margin
        return CGPoint(
            x: min(max(rawX, minX), maxX),
            y: min(max(pointerInScreen.y - previewSize.height / 2, minY), maxY)
        )
    }
}

@MainActor
private final class BookReaderWindowPresenter: NSObject, NSWindowDelegate {
    private var window: NSWindow?

    func show(
        title: String,
        pages: [BookReaderLoadedPage],
        initialPageID: Int,
        totalPages: Int,
        localizer: AppLocalizer
    ) {
        // 独立阅读窗口复用同一个 NSWindow；关闭时清掉 hosting controller，避免页面图片继续被窗口持有。
        let view = BookReaderWindowView(
            title: title,
            pages: pages,
            initialPageID: initialPageID,
            totalPages: totalPages,
            localizer: localizer,
            onClose: { [weak self] in
                self?.close()
            }
        )
        let hostingController = NSHostingController(rootView: view)

        if let window {
            window.contentViewController = hostingController
            window.title = title
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 840, height: 860),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = title
        window.isReleasedWhenClosed = false
        window.animationBehavior = .none
        window.minSize = NSSize(width: 520, height: 460)
        window.contentViewController = hostingController
        window.delegate = self
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        self.window = window
    }

    func close() {
        guard let window else {
            return
        }

        window.close()
    }

    func windowWillClose(_ notification: Notification) {
        guard let closingWindow = notification.object as? NSWindow else {
            return
        }

        DispatchQueue.main.async { [weak self, weak closingWindow] in
            guard let self,
                  let closingWindow,
                  self.window === closingWindow else {
                return
            }

            closingWindow.contentViewController = nil
            closingWindow.delegate = nil
            self.window = nil
        }
    }
}

private struct BookReaderWindowView: View {
    let title: String
    let pages: [BookReaderLoadedPage]
    let initialPageID: Int
    let totalPages: Int
    let localizer: AppLocalizer
    let onClose: () -> Void

    @State private var currentPageID: Int

    init(
        title: String,
        pages: [BookReaderLoadedPage],
        initialPageID: Int,
        totalPages: Int,
        localizer: AppLocalizer,
        onClose: @escaping () -> Void
    ) {
        self.title = title
        self.pages = pages
        self.initialPageID = initialPageID
        self.totalPages = totalPages
        self.localizer = localizer
        self.onClose = onClose
        _currentPageID = State(initialValue: initialPageID)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.headline)
                        .lineLimit(1)
                    Text("\(localizer.pageIndicator(current: currentPage.index + 1, total: totalPages)) - \(currentPage.displayName)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer()

                Button(action: goPrevious) {
                    Label(localizer.string(.previousPage), systemImage: "chevron.left")
                        .labelStyle(.iconOnly)
                }
                .keyboardShortcut(.leftArrow, modifiers: [])
                .disabled(!canGoPrevious)

                Button(action: goNext) {
                    Label(localizer.string(.nextPage), systemImage: "chevron.right")
                        .labelStyle(.iconOnly)
                }
                .keyboardShortcut(.rightArrow, modifiers: [])
                .disabled(!canGoNext)

                Button(action: onClose) {
                    Label(localizer.string(.cancel), systemImage: "xmark")
                        .labelStyle(.iconOnly)
                }
                .keyboardShortcut(.cancelAction)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(.regularMaterial)

            ZStack {
                Color.black.opacity(0.88)

                GeometryReader { proxy in
                    if let image = currentPage.image {
                        Image(nsImage: image)
                            .resizable()
                            .scaledToFit()
                            .frame(width: proxy.size.width, height: proxy.size.height)
                            .padding(18)
                    } else {
                        VStack(spacing: 10) {
                            Image(systemName: "photo")
                                .font(.largeTitle)
                            Text(currentPage.displayName)
                        }
                        .foregroundStyle(.white.opacity(0.78))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
            }
        }
        .frame(minWidth: 520, minHeight: 460)
        .background(Color.black.opacity(0.88))
    }

    private var currentPage: BookReaderLoadedPage {
        pages.first { $0.id == currentPageID } ?? pages.first!
    }

    private var currentIndex: Int {
        pages.firstIndex { $0.id == currentPageID } ?? 0
    }

    private var canGoPrevious: Bool {
        currentIndex > 0
    }

    private var canGoNext: Bool {
        currentIndex < pages.count - 1
    }

    private func goPrevious() {
        guard canGoPrevious else {
            return
        }
        currentPageID = pages[currentIndex - 1].id
    }

    private func goNext() {
        guard canGoNext else {
            return
        }
        currentPageID = pages[currentIndex + 1].id
    }
}

private struct BookDetailTagPill: View {
    let tag: TagDisplaySummary
    let themeColor: Color
    let isCompact: Bool
    let localizer: AppLocalizer
    let onSelect: () -> Void
    let onToggleFollowed: () -> Void
    let onRequestExplanation: () -> Void
    let onClearExplanation: () -> Void
    let claimableWorks: [TagDisplaySummary]
    let onConfirmWork: (TagDisplaySummary) -> Void

    @State private var isHovering = false
    @State private var hoverTask: Task<Void, Never>?

    private var hasExplanation: Bool {
        tag.translationIntro?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
    }

    private var showsStar: Bool {
        tag.isFollowed || isHovering
    }

    private var starWidth: CGFloat {
        if showsStar {
            return isCompact ? 16 : 18
        }
        return 0
    }

    var body: some View {
        HStack(spacing: showsStar ? 5 : 0) {
            Button {
                onToggleFollowed()
            } label: {
                Image(systemName: tag.isFollowed ? "heart.fill" : "heart")
                    .font(isCompact ? .caption2 : .caption)
                    .foregroundStyle(tag.isFollowed ? .red : .secondary)
                    .frame(width: starWidth, height: isCompact ? 14 : 16)
                    .opacity(showsStar ? 1 : 0)
                    .clipped()
            }
            .buttonStyle(.plain)
            .help(localizer.string(tag.isFollowed ? .tagUnfollow : .tagFollow))
            .accessibilityHidden(!showsStar)

            Button {
                onSelect()
            } label: {
                Text(tag.displayText)
                    .font(isCompact ? .caption : .callout)
                    .fontWeight(.medium)
                    .lineLimit(1)
            }
            .buttonStyle(.plain)
            .help("\(localizer.string(.searchBooks)): \(tag.rawValue)")
        }
        .padding(.horizontal, isCompact ? 8 : 10)
        .padding(.vertical, isCompact ? 5 : 7)
        .background(themeColor.opacity(isHovering ? 0.18 : 0.12), in: Capsule())
        .overlay {
            Capsule()
                .stroke(themeColor.opacity(isHovering ? 0.38 : 0.22), lineWidth: 1)
        }
        .contentShape(Capsule())
        .brightness(isHovering ? 0.035 : 0)
        .scaleEffect(isHovering ? 1.045 : 1)
        .shadow(color: themeColor.opacity(isHovering ? 0.16 : 0), radius: isHovering ? 8 : 0, x: 0, y: 4)
        .animation(.snappy(duration: 0.16), value: isHovering)
        .animation(.snappy(duration: 0.16), value: tag.isFollowed)
        .onHover { hovering in
            isHovering = hovering
            hovering ? NSCursor.pointingHand.set() : NSCursor.arrow.set()
            hovering ? scheduleExplanation() : hideExplanation()
        }
        .background {
            GeometryReader { proxy in
                Color.clear.preference(
                    key: BookDetailTagPillFramePreferenceKey.self,
                    value: [tag.id: proxy.frame(in: .named(BookDetailTagCoordinateSpace.name))]
                )
            }
        }
        .contextMenu {
            Button(localizer.string(tag.isFollowed ? .tagUnfollow : .tagFollow)) {
                onToggleFollowed()
            }
            if tag.namespace == "character" && !claimableWorks.isEmpty {
                if claimableWorks.count == 1, let work = claimableWorks.first {
                    Button("\(localizer.string(.workCharacterConfirmForWork)): \(work.displayText)") {
                        onConfirmWork(work)
                    }
                } else {
                    Menu(localizer.string(.workCharacterConfirmForWork)) {
                        ForEach(claimableWorks) { work in
                            Button(work.displayText) { onConfirmWork(work) }
                        }
                    }
                }
            }
        }
        .onDisappear {
            hideExplanation()
        }
    }

    private func scheduleExplanation() {
        guard hasExplanation else {
            return
        }

        hoverTask?.cancel()
        hoverTask = Task {
            try? await Task.sleep(for: .milliseconds(TagHoverExplanationDelay.defaultMilliseconds))
            guard !Task.isCancelled else {
                return
            }

            await MainActor.run {
                if TagHoverExplanationDelay.shouldShow(
                    elapsedMilliseconds: TagHoverExplanationDelay.defaultMilliseconds,
                    isHovering: isHovering,
                    hasIntro: hasExplanation
                ) {
                    onRequestExplanation()
                }
            }
        }
    }

    private func hideExplanation() {
        hoverTask?.cancel()
        hoverTask = nil
        onClearExplanation()
    }
}

private struct ActiveTagExplanation: Identifiable, Equatable {
    let tag: TagDisplaySummary

    var id: Tag.DatabaseID {
        tag.id
    }
}

struct BookDetailSessionToken: Equatable {
    static let inactive = BookDetailSessionToken(bookID: nil, revision: 0)

    let bookID: LibraryBook.ID?
    let revision: Int

    func matches(bookID: LibraryBook.ID) -> Bool {
        self.bookID == bookID
    }

    func next(bookID: LibraryBook.ID) -> BookDetailSessionToken {
        BookDetailSessionToken(bookID: bookID, revision: revision + 1)
    }

    func nextInactive() -> BookDetailSessionToken {
        BookDetailSessionToken(bookID: nil, revision: revision + 1)
    }
}

private enum BookDetailTagCoordinateSpace {
    static let name = "BookDetailTagCoordinateSpace"
}

private struct BookDetailTagPillFramePreferenceKey: PreferenceKey {
    static let defaultValue: [Tag.DatabaseID: CGRect] = [:]

    static func reduce(
        value: inout [Tag.DatabaseID: CGRect],
        nextValue: () -> [Tag.DatabaseID: CGRect]
    ) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}

private struct BookDetailTagExplanationOverlay: View {
    let explanation: ActiveTagExplanation
    let anchorFrame: CGRect
    let containerSize: CGSize
    let localizer: AppLocalizer

    @State private var popoverSize = CGSize(width: 320, height: 180)

    private let gap: CGFloat = 20
    private let margin: CGFloat = 16

    private var availableAboveHeight: CGFloat {
        max(anchorFrame.minY - margin - gap, 0)
    }

    private var availableBelowHeight: CGFloat {
        max(containerSize.height - anchorFrame.maxY - margin - gap, 0)
    }

    private var showsBelow: Bool {
        if availableAboveHeight >= popoverSize.height {
            return false
        }
        if availableBelowHeight >= popoverSize.height {
            return true
        }
        return availableBelowHeight > availableAboveHeight
    }

    private var maxOriginX: CGFloat {
        max(margin, containerSize.width - popoverSize.width - margin)
    }

    private var maxOriginY: CGFloat {
        max(margin, containerSize.height - popoverSize.height - margin)
    }

    private var originX: CGFloat {
        let preferred = anchorFrame.midX - popoverSize.width / 2
        return min(max(preferred, margin), maxOriginX)
    }

    private var originY: CGFloat {
        let preferred = showsBelow
            ? anchorFrame.maxY + gap
            : anchorFrame.minY - popoverSize.height - gap
        return min(max(preferred, margin), maxOriginY)
    }

    var body: some View {
        TagExplanationPopover(tag: explanation.tag, localizer: localizer)
            .allowsHitTesting(false)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(.white.opacity(0.16), lineWidth: 1)
            }
            .shadow(color: .black.opacity(0.18), radius: 14, x: 0, y: 8)
            .background {
                GeometryReader { proxy in
                    Color.clear.preference(
                        key: BookDetailTagExplanationSizePreferenceKey.self,
                        value: proxy.size
                    )
                }
            }
            .onPreferenceChange(BookDetailTagExplanationSizePreferenceKey.self) { size in
                popoverSize = size
            }
            .position(
                x: originX + popoverSize.width / 2,
                y: originY + popoverSize.height / 2
            )
    }
}

private struct BookDetailTagExplanationSizePreferenceKey: PreferenceKey {
    static let defaultValue = CGSize(width: 320, height: 180)

    static func reduce(value: inout CGSize, nextValue: () -> CGSize) {
        value = nextValue()
    }
}

private struct TagExplanationPopover: View {
    let tag: TagDisplaySummary
    let localizer: AppLocalizer

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(localizer.string(.tagExplanation))
                .font(.headline)

            VStack(alignment: .leading, spacing: 4) {
                Text(tag.displayText)
                    .font(.callout)
                    .fontWeight(.semibold)
                Text("\(namespaceTitle): \(tag.namespace)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("\(localizer.string(.tagRawValue)): \(tag.rawValue)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let intro = tag.translationIntro?.trimmingCharacters(in: .whitespacesAndNewlines), !intro.isEmpty {
                Text(intro)
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if !tag.translationLinks.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text(localizer.string(.tagLinks))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    ForEach(tag.translationLinks.prefix(3), id: \.self) { link in
                        Text(link)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .textSelection(.enabled)
                    }
                }
            }
        }
        .padding(14)
        .frame(width: 320, alignment: .leading)
    }

    private var namespaceTitle: String {
        switch tag.namespace {
        case "artist": return localizer.string(.tagNamespaceArtist)
        case "group": return localizer.string(.tagNamespaceGroup)
        case "parody": return localizer.string(.tagNamespaceParody)
        case "character": return localizer.string(.tagNamespaceCharacter)
        case "female": return localizer.string(.tagNamespaceFemale)
        case "male": return localizer.string(.tagNamespaceMale)
        case "mixed": return localizer.string(.tagNamespaceMixed)
        case "location": return localizer.string(.tagNamespaceLocation)
        case "other": return localizer.string(.tagNamespaceOther)
        default: return tag.namespace
        }
    }
}

private struct OtherInfoGrid: View {
    let book: LibraryBook
    let localizer: AppLocalizer
    let onURL: () -> Void
    let onCopyFolder: () -> Void

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 20, verticalSpacing: 10) {
            if let url = book.url, !url.isEmpty {
                GridRow {
                    Text(localizer.string(.url)).foregroundStyle(.secondary)
                    Button(url, action: onURL)
                        .buttonStyle(.link)
                        .lineLimit(1)
                }
            }

            GridRow {
                Text(localizer.string(.fileLocation)).foregroundStyle(.secondary)
                Button(folderPath, action: onCopyFolder)
                    .buttonStyle(.link)
                    .lineLimit(1)
            }

            GridRow {
                Text(localizer.string(.fileSize)).foregroundStyle(.secondary)
                Text(format(bytes: book.filesize ?? book.bundleSize))
            }

            GridRow {
                Text(localizer.string(.hash)).foregroundStyle(.secondary)
                Text(book.hash)
                    .textSelection(.enabled)
                    .lineLimit(1)
            }
        }
        .font(.callout)
    }

    private var folderPath: String {
        URL(fileURLWithPath: book.filepath).deletingLastPathComponent().path
    }

    private func format(bytes: Int64?) -> String {
        guard let bytes else {
            return localizer.string(.unknown)
        }

        return ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}

private extension View {
    func detailHoverSurface(
        cornerRadius: CGFloat = 12,
        scale: CGFloat = 1.01
    ) -> some View {
        modifier(BookDetailHoverSurfaceModifier(cornerRadius: cornerRadius, scale: scale))
    }

    @ViewBuilder
    func detailGlassSurface(
        cornerRadius: CGFloat,
        material: Material,
        interactive: Bool = false
    ) -> some View {
        if #available(macOS 26.0, *) {
            glassEffect(
                interactive ? .regular.interactive() : .regular,
                in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            )
        } else {
            background(material, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .stroke(.white.opacity(0.16), lineWidth: 1)
                }
                .shadow(color: .black.opacity(0.05), radius: 14, x: 0, y: 6)
        }
    }
}

private struct BookDetailHoverSurfaceModifier: ViewModifier {
    let cornerRadius: CGFloat
    let scale: CGFloat
    @State private var isHovering = false

    func body(content: Content) -> some View {
        content
            .contentShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .brightness(isHovering ? 0.025 : 0)
            .scaleEffect(isHovering ? scale : 1)
            .shadow(color: .black.opacity(isHovering ? 0.08 : 0), radius: isHovering ? 10 : 0, x: 0, y: 5)
            .animation(.snappy(duration: 0.16), value: isHovering)
            .onHover { hovering in
                isHovering = hovering
            }
    }
}
