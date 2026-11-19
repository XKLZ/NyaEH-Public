// 本文件集中承载仅由 NyaEHDevRunner 启用的调试工具，避免测试入口散落到正式功能页面。

import SwiftUI

struct DevelopmentToolsView: View {
    let catalog: CatalogStore
    let titleDisplayMode: BookTitleDisplayMode
    let initialCardWidth: Int
    let resolveLibraryRootURL: @MainActor () throws -> URL?
    let onOpenRecentSearch: () -> Void
    let configuration: NyaEHDevelopmentConfiguration
    let localizer: AppLocalizer
    let readerDisplayPreferences: ReaderDisplayPreferences
    let onReaderDisplayPreferencesChange: (ReaderDisplayPreferences) -> Void
    let savedReaderWindowFrame: CGRect?
    let onReaderWindowFrameChange: (CGRect) -> Void

    @State private var readerWindowPresenter = ModernBookReaderWindowPresenter()
    @State private var readerLaunchTask: Task<Void, Never>?
    @State private var readerLaunchID: UUID?
    @State private var readerLaunchState: ReaderLaunchState = .idle

    @State private var gallery: DevelopmentCardSamples?

    @State private var shelves: DevelopmentShelfSession?

    var body: some View {
        Group {
            if let gallery {
                VStack(alignment: .leading) {
                    DevelopmentCardGallery(samples: gallery, archive: configuration.readerTestArchiveURL, localizer: localizer) {
                        cancelReaderLaunchAndCloseWindow()
                        self.gallery = nil
                        readerLaunchState = .idle
                    }
                    if case .failed = readerLaunchState { readerStatus.padding(.horizontal) }
                }
            } else if let shelves {
                VStack(alignment: .leading, spacing: 0) {
                    DevelopmentShelfPreview(session: shelves, localizer: localizer, titleMode: titleDisplayMode,
                                            initialWidth: initialCardWidth, onOpenRecentSearch: onOpenRecentSearch, back: closeShelves)
                    if case .failed = readerLaunchState { readerStatus.padding(.horizontal) }
                }
            } else { tools }
        }
        .onDisappear {
            cancelReaderLaunchAndCloseWindow()
            gallery = nil
            shelves = nil
        }
    }

    private var tools: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                VStack(alignment: .leading, spacing: 6) {
                    Label(localizer.string(.developmentTools), systemImage: "hammer")
                        .font(.largeTitle.bold())

                    Text(localizer.string(.developmentToolsDescription))
                        .foregroundStyle(.secondary)
                }

                VStack(alignment: .leading, spacing: 12) {
                    Label(localizer.string(.cardDisplay), systemImage: "rectangle.grid.2x2").font(.title2.bold())
                    Button(localizer.string(.sampleGallery)) {
                        readerLaunchState = .idle
                        gallery = DevelopmentCardSamples(localizer: localizer) { book in openReader(sample: book) }
                    }
                }
                Button(localizer.string(.shelfPreview)) {
                    readerLaunchState = .idle
                    shelves = DevelopmentShelfSession(catalog: catalog) { owner, book, fixture in
                        openReader(sample: book, owner: owner, useLibraryArchive: !fixture)
                    }
                }
                readerTestCard
            }
            .frame(maxWidth: 760, alignment: .leading)
            .padding(28)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
    }

    private var readerTestCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label(localizer.string(.developmentReaderTest), systemImage: "book.pages")
                .font(.title2.bold())

            Text(localizer.string(.developmentReaderTestDescription))
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 6) {
                Text(localizer.string(.developmentReaderArchivePath))
                    .font(.caption)
                    .fontWeight(.semibold)
                    .foregroundStyle(.secondary)

                Text(configuration.readerTestArchiveURL.path)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                    .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 8))
            }

            readerStatus

            Button(action: { openReader() }) {
                if readerLaunchState.isOpening {
                    ProgressView()
                        .controlSize(.small)
                    Text(localizer.string(.developmentReaderOpening))
                } else {
                    Label(localizer.string(.developmentReaderOpen), systemImage: "book.pages")
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(readerLaunchState.isOpening)
        }
        .padding(20)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(.primary.opacity(0.08))
        }
    }

    @ViewBuilder
    private var readerStatus: some View {
        switch readerLaunchState {
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
                .textSelection(.enabled)
        case .opened(let pageCount):
            Label(
                "\(localizer.string(.developmentReaderOpened)): \(pageCount)",
                systemImage: "checkmark.circle.fill"
            )
            .foregroundStyle(.green)
        case .idle, .opening:
            if FileManager.default.fileExists(atPath: configuration.readerTestArchiveURL.path) {
                Label(
                    localizer.string(.developmentReaderArchiveReady),
                    systemImage: "checkmark.circle"
                )
                .foregroundStyle(.secondary)
            } else {
                Label(
                    localizer.string(.developmentReaderArchiveMissing),
                    systemImage: "exclamationmark.triangle"
                )
                .foregroundStyle(.orange)
            }
        }
    }

    private func closeShelves() {
        cancelReaderLaunchAndCloseWindow()
        shelves = nil
        readerLaunchState = .idle
    }

    private func openReader(sample: LibraryBook? = nil, owner: DevelopmentCardSamples? = nil,
                            useLibraryArchive: Bool = false) {
        let samples = owner ?? gallery
        let page = sample.flatMap { samples?.readingState(for: $0)?.currentPageIndex } ?? 0
        readerLaunchTask?.cancel()
        let launchID = UUID()
        let archiveURL = useLibraryArchive ? sample.map { URL(fileURLWithPath: $0.filepath) } : configuration.readerTestArchiveURL
        guard let archiveURL else { return }
        readerLaunchID = launchID
        readerLaunchState = .opening

        readerLaunchTask = Task { @MainActor in
            defer {
                if readerLaunchID == launchID {
                    readerLaunchID = nil
                    readerLaunchTask = nil
                }
            }

            do {
                let root = useLibraryArchive ? try resolveLibraryRootURL() : nil
                if useLibraryArchive && root == nil { throw NyaEHError.libraryFolderPermissionRequired }
                let session = try await Task.detached(priority: .userInitiated) {
                    try ReaderArchiveSession(
                        archiveURL: archiveURL,
                        securityScopedRootURL: root
                    )
                }.value
                guard !Task.isCancelled, readerLaunchID == launchID else {
                    return
                }

                let pageCount = await session.pageCount()
                guard !Task.isCancelled, readerLaunchID == launchID else {
                    return
                }

                readerWindowPresenter.show(
                    title: sample?.title ?? archiveURL.deletingPathExtension().lastPathComponent,
                    pages: [],
                    initialPageID: min(page, max(0, pageCount - 1)),
                    totalPages: pageCount,
                    localizer: localizer,
                    archiveSession: session,
                    displayPreferences: readerDisplayPreferences,
                    onDisplayPreferencesChange: { value in
                        if owner == nil { onReaderDisplayPreferencesChange(value) }
                    },
                    savedWindowFrame: savedReaderWindowFrame,
                    onWindowFrameChange: { frame in
                        if owner == nil { onReaderWindowFrameChange(frame) }
                    },
                    onProgress: { index, total, completed in
                        if let sample { samples?.updateProgress(book: sample, page: index, total: total, completed: completed) }
                    },
                    onFlushProgress: {}
                )
                readerLaunchState = .opened(pageCount)
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled, readerLaunchID == launchID else {
                    return
                }
                readerLaunchState = .failed(error.localizedDescription)
            }
        }
    }

    private func cancelReaderLaunchAndCloseWindow() {
        readerLaunchTask?.cancel()
        readerLaunchTask = nil
        readerLaunchID = nil
        readerLaunchState = .idle
        readerWindowPresenter.close()
    }
}

private enum ReaderLaunchState: Equatable {
    case idle
    case opening
    case opened(Int)
    case failed(String)

    var isOpening: Bool {
        self == .opening
    }
}
