// 本文件提供导入页面的 Liquid Glass 仪表盘、收件箱工具栏、紧凑书籍行与重试表单。

import SwiftUI

struct ImportWorkflowCard: View {
    let presentation: ImportWorkflowPresentation
    let batch: ImportPipelineBatch?
    let pipelineMessage: String?
    let localizer: AppLocalizer
    let onPrimaryAction: (ImportPipelinePrimaryAction) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            header
            phaseStrip
            ProgressView(value: presentation.progressFraction)
                .accessibilityLabel(localizer.string(.importProgress))

            if let batch {
                batchMetrics(batch)
            }

            if let message = pipelineMessage, !message.isEmpty {
                Label(message, systemImage: "info.circle")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
            }

            primaryAction
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .importGlassPanel(cornerRadius: 22)
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            Label(localizer.string(.importWorkflow), systemImage: "point.3.connected.trianglepath.dotted")
                .font(.title3.weight(.semibold))
            Spacer()
            if let batch {
                Text(String(format: localizer.string(.importBatchNumberFormat), batch.id))
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var phaseStrip: some View {
        HStack(alignment: .top, spacing: 8) {
            ForEach(Array(ImportWorkflowPhase.allCases.enumerated()), id: \.element.id) { index, phase in
                ImportWorkflowPhaseView(
                    phase: phase,
                    state: presentation[phase],
                    localizer: localizer
                )
                if index < ImportWorkflowPhase.allCases.count - 1 {
                    Capsule()
                        .fill(connectorColor(after: phase))
                        .frame(maxWidth: .infinity)
                        .frame(height: 2)
                        .padding(.top, 15)
                }
            }
        }
    }

    private func connectorColor(after phase: ImportWorkflowPhase) -> Color {
        presentation[phase] == .completed ? .green.opacity(0.7) : .secondary.opacity(0.22)
    }

    private func batchMetrics(_ batch: ImportPipelineBatch) -> some View {
        Grid(horizontalSpacing: 18, verticalSpacing: 8) {
            GridRow {
                metric(localizer.string(.importReady), value: batch.readyCount, color: .green)
                metric(localizer.string(.importDeferred), value: batch.deferredCount, color: .orange)
                metric(localizer.string(.importWaitingReview), value: batch.reviewCount, color: .yellow)
                metric(localizer.string(.importFailedCount), value: batch.failedCount, color: .red)
                metric(localizer.string(.importDeletedCount), value: batch.deletedCount, color: .secondary)
            }
        }
        .frame(maxWidth: .infinity)
    }

    private func metric(_ title: String, value: Int, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value.formatted())
                .font(.title3.monospacedDigit().weight(.semibold))
                .foregroundStyle(value > 0 ? color : .primary)
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var primaryAction: some View {
        switch presentation.primaryAction {
        case .continueIncomplete:
            Button {
                onPrimaryAction(.continueIncomplete)
            } label: {
                Label(localizer.string(.importContinueIncomplete), systemImage: "play.fill")
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
        case .pause:
            Button(role: .cancel) {
                onPrimaryAction(.pause)
            } label: {
                Label(localizer.string(.metadataBatchPause), systemImage: "pause.fill")
            }
            .controlSize(.large)
        case .openVersionReview:
            Button {
                onPrimaryAction(.openVersionReview)
            } label: {
                Label(localizer.string(.importReviewVersionRecommendations), systemImage: "person.crop.circle.badge.questionmark")
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
        case .openCollectionReview:
            Button {
                onPrimaryAction(.openCollectionReview)
            } label: {
                Label(localizer.string(.importReviewSeriesRecommendations), systemImage: "person.crop.circle.badge.questionmark")
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
        case .none:
            Label(localizer.string(.importWorkflowCompleted), systemImage: "checkmark.circle.fill")
                .font(.headline)
                .foregroundStyle(.green)
        }
    }
}

private struct ImportWorkflowPhaseView: View {
    let phase: ImportWorkflowPhase
    let state: ImportWorkflowPhaseState
    let localizer: AppLocalizer

    var body: some View {
        VStack(spacing: 6) {
            ZStack {
                Circle()
                    .fill(color.opacity(0.13))
                Image(systemName: symbol)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(color)
            }
            .frame(width: 32, height: 32)

            Text(localizer.string(phase.titleKey))
                .font(.caption.weight(.semibold))
                .lineLimit(1)
            Text(localizer.string(state.titleKey))
                .font(.caption2)
                .foregroundStyle(color)
                .lineLimit(1)
        }
        .frame(minWidth: 72)
        .accessibilityElement(children: .combine)
    }

    private var symbol: String {
        switch state {
        case .pending: phase.systemImage
        case .running: "arrow.triangle.2.circlepath"
        case .waitingForReview: "person.crop.circle.badge.questionmark"
        case .paused: "pause.fill"
        case .needsAttention: "exclamationmark.triangle.fill"
        case .completed: "checkmark"
        }
    }

    private var color: Color {
        switch state {
        case .pending: .secondary
        case .running: .accentColor
        case .waitingForReview: .orange
        case .paused: .orange
        case .needsAttention: .red
        case .completed: .green
        }
    }
}

struct ImportSettingsCard: View {
    let libraryRootPath: String?
    let lastScanText: String
    let scanSummary: String?
    let isScanning: Bool
    @Binding var gallerySearchSite: GallerySearchSite
    let localizer: AppLocalizer
    let onSelectLibrary: () -> Void
    let onScan: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label(localizer.string(.importLibraryManagement), systemImage: "books.vertical")
                .font(.title3.weight(.semibold))

            LabeledContent(localizer.string(.libraryLocation)) {
                Text(libraryRootPath ?? localizer.string(.libraryNotSelected))
                    .foregroundStyle(libraryRootPath == nil ? .secondary : .primary)
                    .lineLimit(2)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
            }

            LabeledContent(localizer.string(.lastLibraryScan), value: lastScanText)

            HStack(spacing: 10) {
                Button(action: onSelectLibrary) {
                    Label(localizer.string(.selectLibrary), systemImage: "folder")
                }
                Button(action: onScan) {
                    Label(localizer.string(.scanLibrary), systemImage: "arrow.triangle.2.circlepath")
                }
                .disabled(libraryRootPath == nil || isScanning)

                if isScanning {
                    ProgressView()
                        .controlSize(.small)
                        .accessibilityLabel(localizer.string(.scanning))
                }
            }

            if let scanSummary, !scanSummary.isEmpty {
                Label(scanSummary, systemImage: "checkmark.circle")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
            }

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                Label(localizer.string(.importMetadataManagement), systemImage: "network")
                    .font(.headline)
                Picker(localizer.string(.gallerySearchSite), selection: $gallerySearchSite) {
                    ForEach(GallerySearchSite.allCases) { site in
                        Text(site.displayName).tag(site)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .importGlassPanel(cornerRadius: 22)
    }
}

struct ImportInboxToolbar: View {
    @Binding var searchText: String
    @Binding var filter: ImportInboxFilter
    let filteredCount: Int
    let totalCount: Int
    let localizer: AppLocalizer

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) {
                title
                Spacer(minLength: 8)
                searchField
                filterPicker
                count
            }
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    title
                    Spacer()
                    count
                }
                HStack(spacing: 10) {
                    searchField
                    filterPicker
                }
            }
        }
        .padding(12)
        .importGlassPanel(cornerRadius: 18)
        .zIndex(2)
    }

    private var title: some View {
        Label(localizer.string(.importInbox), systemImage: "tray.full")
            .font(.headline)
    }

    private var searchField: some View {
        TextField(localizer.string(.importInboxSearchPlaceholder), text: $searchText)
            .textFieldStyle(.roundedBorder)
            .frame(minWidth: 180, idealWidth: 260, maxWidth: 320)
            .accessibilityLabel(localizer.string(.importInboxSearchPlaceholder))
    }

    private var filterPicker: some View {
        Picker(localizer.string(.importInbox), selection: $filter) {
            ForEach(ImportInboxFilter.allCases) { filter in
                Text(localizer.string(filter.titleKey)).tag(filter)
            }
        }
        .labelsHidden()
        .frame(width: 132)
    }

    private var count: some View {
        Text(String(format: localizer.string(.importInboxCountFormat), filteredCount, totalCount))
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
            .fixedSize()
    }
}

struct ImportInboxBookRow: View {
    let book: LibraryBook
    let item: ImportPipelineItem?
    let titleDisplayMode: BookTitleDisplayMode
    let localizer: AppLocalizer
    let isSavingOrganization: Bool
    let onOpen: () -> Void
    let onRetry: (ImportPipelineItem) -> Void
    let onCopyTitle: () -> Void
    let onRetryFromPasteboard: (ImportPipelineItem) -> Void
    let onSkipMetadata: (ImportPipelineItem) -> Void
    let onResetRecommendations: () -> Void
    let onOpenVersionReview: () -> Void
    let onOpenCollectionReview: () -> Void
    let onRemoveVersionMembership: () -> Void
    let onRemoveCollectionMembership: () -> Void

    @State private var isTitleCopied = false
    @State private var titleCopyFeedbackGeneration = 0

    var body: some View {
        HStack(spacing: 14) {
            BookCoverThumbnail(book: book, width: 48, height: 68, cornerRadius: 7)

            VStack(alignment: .leading, spacing: 5) {
                Text(BookTitleFormatter.displayTitle(for: book, mode: titleDisplayMode))
                    .font(.headline)
                    .lineLimit(1)
                Text(book.filepath)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                statusLine
                if let error = item?.lastErrorMessage, !error.isEmpty {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 12)
            if isSavingOrganization {
                ProgressView()
                    .controlSize(.small)
                    .help(localizer.string(.saving))
            }
            primaryAction
            if ImportLibraryPresentation.showsMetadataRecoveryActions(for: item) {
                metadataRecoveryActions
            }
            if hasMenuActions {
                actionMenu
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .onTapGesture(perform: onOpen)
        .accessibilityElement(children: .contain)
        .accessibilityAction(named: localizer.string(.details), onOpen)
        .importGlassPanel(cornerRadius: 16, interactive: true)
    }

    private var metadataRecoveryActions: some View {
        HStack(spacing: 4) {
            Button(action: copyTitle) {
                Image(systemName: isTitleCopied ? "checkmark" : "doc.on.doc")
                    .frame(width: 12)
            }
            .accessibilityLabel(localizer.string(isTitleCopied ? .titleCopied : .copyTitle))
            .help(localizer.string(isTitleCopied ? .titleCopied : .copyTitle))

            if let item {
                Button {
                    onRetryFromPasteboard(item)
                } label: {
                    Image(systemName: "link.badge.plus")
                        .frame(width: 12)
                }
                .accessibilityLabel(localizer.string(.importRetryFromClipboard))
                .help(localizer.string(.importRetryFromClipboard))
            }
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .fixedSize()
    }

    @ViewBuilder
    private var statusLine: some View {
        HStack(spacing: 8) {
            if let item {
                Label(localizer.string(item.stage.titleKey), systemImage: item.stage.systemImage)
                    .foregroundStyle(item.statusColor)
                if let source = item.metadataSource {
                    Text(localizer.string(source.titleKey))
                        .foregroundStyle(.tertiary)
                }
            } else {
                Label(localizer.string(.unscanned), systemImage: "clock")
                    .foregroundStyle(.secondary)
            }
        }
        .font(.caption)
        .lineLimit(1)
    }

    @ViewBuilder
    private var primaryAction: some View {
        if let item {
            switch item.stage {
            case .metadataDeferred, .sourceNeedsAttention:
                Button {
                    onRetry(item)
                } label: {
                    Text(localizer.string(
                        item.lastErrorKind == "groupingNeedsConfirmation"
                            ? .importKeepGroupsAndRetry
                            : .importRetry
                    ))
                }
                .controlSize(.small)
            case .versionReviewPending:
                Button(localizer.string(.importReviewVersionRecommendations), action: onOpenVersionReview)
                    .controlSize(.small)
            case .collectionReviewPending:
                Button(localizer.string(.importReviewSeriesRecommendations), action: onOpenCollectionReview)
                    .controlSize(.small)
            default:
                EmptyView()
            }
        }
    }

    private var hasMenuActions: Bool {
        item != nil || book.versionGroupID != nil || book.collectionID != nil || book.status == .correct
    }

    private var actionMenu: some View {
        Menu {
            if let item, item.stage.supportsMetadataIntervention {
                Button {
                    onRetry(item)
                } label: {
                    Label(localizer.string(.importRetryMetadata), systemImage: "link")
                }
                Button {
                    onSkipMetadata(item)
                } label: {
                    Label(localizer.string(.importSkipMetadata), systemImage: "forward.end")
                }
            }

            if book.versionGroupID != nil {
                Divider()
                Button(action: onOpenVersionReview) {
                    Label(localizer.string(.importReviewVersionMembership), systemImage: "square.stack.3d.up")
                }
                Button(role: .destructive, action: onRemoveVersionMembership) {
                    Label(localizer.string(.importRemoveVersionMembership), systemImage: "square.stack.3d.up.slash")
                }
            }

            if book.collectionID != nil {
                Divider()
                Button(action: onOpenCollectionReview) {
                    Label(localizer.string(.importReviewSeriesMembership), systemImage: "rectangle.stack")
                }
                Button(role: .destructive, action: onRemoveCollectionMembership) {
                    Label(localizer.string(.importRemoveSeriesMembership), systemImage: "rectangle.stack.badge.minus")
                }
            }

            if book.status == .correct {
                Divider()
                Button(action: onResetRecommendations) {
                    Label(localizer.string(.importResetIgnoredRecommendations), systemImage: "arrow.counterclockwise")
                }
            }
        } label: {
            Label(localizer.string(.details), systemImage: "ellipsis.circle")
                .labelStyle(.iconOnly)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }

    private func copyTitle() {
        onCopyTitle()
        titleCopyFeedbackGeneration += 1
        let generation = titleCopyFeedbackGeneration
        withAnimation(.easeOut(duration: 0.12)) {
            isTitleCopied = true
        }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.2))
            guard titleCopyFeedbackGeneration == generation else { return }
            withAnimation(.easeOut(duration: 0.12)) {
                isTitleCopied = false
            }
        }
    }
}

struct ImportInboxEmptyState: View {
    let title: String
    let description: String
    let systemImage: String

    var body: some View {
        ContentUnavailableView(
            title,
            systemImage: systemImage,
            description: Text(description)
        )
        .frame(maxWidth: .infinity, minHeight: 230)
        .importGlassPanel(cornerRadius: 18)
    }
}

struct ImportPipelineRetrySheet: View {
    @Binding var galleryURL: String
    let localizer: AppLocalizer
    let onCancel: () -> Void
    let onSubmit: () -> Void

    @FocusState private var isURLFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(localizer.string(.importRetryMetadata))
                .font(.title2.weight(.semibold))
            Text(localizer.string(.importRetryMetadataDescription))
                .foregroundStyle(.secondary)

            Form {
                TextField(localizer.string(.importGalleryURLOptional), text: $galleryURL)
                    .focused($isURLFocused)
            }
            .formStyle(.grouped)

            HStack {
                Spacer()
                Button(localizer.string(.cancel), action: onCancel)
                Button(localizer.string(.importAddToNextBatch), action: onSubmit)
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(24)
        .frame(width: 560)
        .onAppear { isURLFocused = true }
    }
}

extension ImportPipelineItemStage {
    var titleKey: L10nKey {
        switch self {
        case .metadataPending: .importItemMetadataWaiting
        case .metadataRunning: .importItemMetadataFetching
        case .metadataDeferred: .importItemMetadataDeferred
        case .versionAnalysisPending: .importItemVersionAnalysisWaiting
        case .versionReviewPending: .importItemVersionReviewWaiting
        case .collectionAnalysisPending: .importItemSeriesAnalysisWaiting
        case .collectionReviewPending: .importItemSeriesReviewWaiting
        case .completed: .importItemCompleted
        case .completedMetadataSkipped: .importItemMetadataSkipped
        case .sourceNeedsAttention: .importItemSourceAttention
        }
    }

    var systemImage: String {
        switch self {
        case .metadataRunning: "arrow.triangle.2.circlepath"
        case .metadataDeferred, .sourceNeedsAttention: "exclamationmark.triangle"
        case .completed, .completedMetadataSkipped: "checkmark.circle"
        case .versionReviewPending, .collectionReviewPending: "person.crop.circle.badge.questionmark"
        default: "clock"
        }
    }

    var supportsMetadataIntervention: Bool {
        switch self {
        case .metadataPending, .metadataDeferred, .sourceNeedsAttention:
            true
        default:
            false
        }
    }
}

extension ImportPipelineItem {
    var statusColor: Color {
        if lastErrorMessage?.isEmpty == false { return .orange }
        switch stage {
        case .metadataRunning: return Color.accentColor
        case .metadataDeferred, .sourceNeedsAttention: return Color.orange
        case .versionReviewPending, .collectionReviewPending: return Color.orange
        case .completed, .completedMetadataSkipped: return Color.green
        default: return Color.secondary
        }
    }
}

extension ImportMetadataSource {
    var titleKey: L10nKey {
        switch self {
        case .galleryURL: .importMetadataSourceURL
        case .localCache: .importMetadataSourceLocalCache
        case .hashSearch: .importMetadataSourceHashSearch
        case .manual: .importMetadataSourceExisting
        case .skipped: .importMetadataSourceSkipped
        }
    }
}

extension View {
    func importGlassPanel(cornerRadius: CGFloat, interactive: Bool = false) -> some View {
        modifier(ImportGlassPanelModifier(cornerRadius: cornerRadius, interactive: interactive))
    }
}

private struct ImportGlassPanelModifier: ViewModifier {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    let cornerRadius: CGFloat
    let interactive: Bool

    @ViewBuilder
    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        if #available(macOS 26.0, *) {
            content.glassEffect(interactive ? .regular.interactive() : .regular, in: shape)
        } else if reduceTransparency {
            content
                .background(Color(nsColor: .controlBackgroundColor), in: shape)
                .overlay { shape.stroke(.separator.opacity(0.65), lineWidth: 1) }
        } else {
            content
                .background(.regularMaterial, in: shape)
                .overlay { shape.stroke(.white.opacity(0.17), lineWidth: 1) }
                .shadow(color: .black.opacity(0.05), radius: 12, x: 0, y: 5)
        }
    }
}
