import SwiftUI

@MainActor @Observable
final class BookReaderLauncher {
    private var readerWindowPresenter = ModernBookReaderWindowPresenter()
    private var readerLaunchTask: Task<Void, Never>?
    private(set) var launchingReaderBookID: LibraryBook.ID?
    private var readerLaunchID: UUID?

    func openReader(
        for book: LibraryBook,
        title: String,
        initialPageID: Int,
        seedPages: [BookReaderLoadedPage],
        catalog: CatalogStore,
        localizer: AppLocalizer,
        resolveLibraryRootURL: @escaping @MainActor () throws -> URL?,
        readerDisplayPreferences: ReaderDisplayPreferences,
        onReaderDisplayPreferencesChange: @escaping (ReaderDisplayPreferences) -> Void,
        savedReaderWindowFrame: CGRect?,
        onReaderWindowFrameChange: @escaping (CGRect) -> Void,
        onFailure: ((String) -> Void)? = nil
    ) {
        readerLaunchTask?.cancel()
        let expectedBookID = book.id
        let launchID = UUID()
        let archiveURL = URL(fileURLWithPath: book.filepath)
        launchingReaderBookID = expectedBookID
        readerLaunchID = launchID
        readerLaunchTask = Task { @MainActor [self] in
            defer {
                if readerLaunchID == launchID {
                    launchingReaderBookID = nil
                    readerLaunchID = nil
                    readerLaunchTask = nil
                }
            }
            do {
                guard let libraryRootURL = try resolveLibraryRootURL() else {
                    throw NyaEHError.libraryFolderPermissionRequired
                }
                let session = try await Task.detached(priority: .userInitiated) {
                    try ReaderArchiveSession(
                        archiveURL: archiveURL,
                        securityScopedRootURL: libraryRootURL
                    )
                }.value
                guard !Task.isCancelled, readerLaunchID == launchID, launchingReaderBookID == expectedBookID else {
                    return
                }
                let totalPages = await session.pageCount()
                guard !Task.isCancelled, readerLaunchID == launchID else { return }
                let resolvedPageID = min(max(initialPageID, 0), max(totalPages - 1, 0))
                catalog.recordRead(for: book)
                readerWindowPresenter.show(
                    title: title,
                    pages: seedPages,
                    initialPageID: resolvedPageID,
                    totalPages: totalPages,
                    localizer: localizer,
                    archiveSession: session,
                    displayPreferences: readerDisplayPreferences,
                    onDisplayPreferencesChange: onReaderDisplayPreferencesChange,
                    savedWindowFrame: savedReaderWindowFrame,
                    onWindowFrameChange: onReaderWindowFrameChange,
                    onProgress: { pageIndex, totalPages, completed in
                        catalog.saveReadingProgress(
                            for: book,
                            currentPageIndex: pageIndex,
                            totalPages: totalPages,
                            forceCompleted: completed
                        )
                    },
                    onFlushProgress: {
                        catalog.flushReadingProgress(for: book)
                    }
                )
                catalog.loadError = nil
            } catch {
                guard !Task.isCancelled, readerLaunchID == launchID, launchingReaderBookID == expectedBookID else {
                    return
                }
                catalog.loadError = error.localizedDescription
                onFailure?(error.localizedDescription)
            }
        }
    }

    func cancelReaderLaunchAndCloseWindow() {
        readerLaunchTask?.cancel()
        readerLaunchTask = nil
        launchingReaderBookID = nil
        readerLaunchID = nil
        readerWindowPresenter.close()
    }
}

/// Window-owned actions survive grid recycling and do not capture a card's stale book.
@MainActor @Observable
final class BookCardActions: BookCardInteraction, BookCardFileRevealing {
    private let store: CatalogStore
    private let preferences: AppPreferences
    private let launcher = BookReaderLauncher()
    private(set) var readerBookID: LibraryBook.DatabaseID?
    var notice: String?
    private(set) var noticeID = UUID()

    init(store: CatalogStore, preferences: AppPreferences) {
        self.store = store
        self.preferences = preferences
    }

    func showNotice(_ message: String) {
        notice = message
        noticeID = UUID()
    }

    func read(_ book: LibraryBook) {
        readerBookID = book.databaseID
        launcher.openReader(
            for: book, title: BookTitleFormatter.displayTitle(for: book, mode: preferences.bookTitleDisplayMode),
            initialPageID: BookDetailReadingActionPolicy.initialPage(for: store.readingState(for: book)),
            seedPages: [], catalog: store, localizer: preferences.localizer,
            resolveLibraryRootURL: { [preferences] in try preferences.resolvedLibraryRootURL() },
            readerDisplayPreferences: preferences.readerDisplayPreferences,
            onReaderDisplayPreferencesChange: { [preferences] in preferences.readerDisplayPreferences = $0 },
            savedReaderWindowFrame: preferences.savedReaderWindowFrame(),
            onReaderWindowFrameChange: preferences.saveReaderWindowFrame,
            onFailure: { [weak self] in self?.showNotice($0) }
        )
    }

    func revealFile(_ book: LibraryBook) {
        do {
            let root = try preferences.resolvedLibraryRootURL()
            let scoped = root?.startAccessingSecurityScopedResource() == true
            defer { if scoped { root?.stopAccessingSecurityScopedResource() } }
            guard let url = CollectionMemberFinderReveal.fileURL(for: book.filepath, fileExists: {
                FileManager.default.isReadableFile(atPath: $0)
            }) else {
                showNotice(preferences.localizer.string(.managementFinderUnavailable))
                return
            }
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } catch {
            showNotice(error.localizedDescription)
        }
    }

    func closeReader() {
        launcher.cancelReaderLaunchAndCloseWindow()
        readerBookID = nil
    }
}
