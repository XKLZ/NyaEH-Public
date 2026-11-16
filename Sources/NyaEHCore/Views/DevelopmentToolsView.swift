// 本文件集中承载仅由 NyaEHDevRunner 启用的调试工具，避免测试入口散落到正式功能页面。

import SwiftUI

struct DevelopmentToolsView: View {
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

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                VStack(alignment: .leading, spacing: 6) {
                    Label(localizer.string(.developmentTools), systemImage: "hammer")
                        .font(.largeTitle.bold())

                    Text(localizer.string(.developmentToolsDescription))
                        .foregroundStyle(.secondary)
                }

                readerTestCard
            }
            .frame(maxWidth: 760, alignment: .leading)
            .padding(28)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .onDisappear {
            cancelReaderLaunchAndCloseWindow()
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

            Button(action: openReader) {
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

    private func openReader() {
        readerLaunchTask?.cancel()
        let launchID = UUID()
        let archiveURL = configuration.readerTestArchiveURL
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
                let session = try await Task.detached(priority: .userInitiated) {
                    try ReaderArchiveSession(
                        archiveURL: archiveURL,
                        securityScopedRootURL: nil
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
                    title: archiveURL.deletingPathExtension().lastPathComponent,
                    pages: [],
                    initialPageID: 0,
                    totalPages: pageCount,
                    localizer: localizer,
                    archiveSession: session,
                    displayPreferences: readerDisplayPreferences,
                    onDisplayPreferencesChange: onReaderDisplayPreferencesChange,
                    savedWindowFrame: savedReaderWindowFrame,
                    onWindowFrameChange: onReaderWindowFrameChange,
                    onProgress: { _, _, _ in },
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
