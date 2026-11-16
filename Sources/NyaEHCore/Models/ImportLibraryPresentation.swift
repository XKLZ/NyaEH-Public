// 本文件定义导入页面的纯展示状态，统一收件箱筛选、搜索和四阶段流程映射。

import Foundation

enum ImportInboxFilter: String, CaseIterable, Identifiable, Sendable {
    case pending
    case review
    case attention
    case all

    var id: String { rawValue }

    var titleKey: L10nKey {
        switch self {
        case .pending: .importInboxFilterPending
        case .review: .importInboxFilterReview
        case .attention: .importInboxFilterAttention
        case .all: .importInboxFilterAll
        }
    }
}

enum ImportWorkflowPhase: CaseIterable, Identifiable, Sendable {
    case scan
    case metadata
    case version
    case collection

    var id: Self { self }

    var titleKey: L10nKey {
        switch self {
        case .scan: .importWorkflowScan
        case .metadata: .importWorkflowMetadata
        case .version: .importWorkflowVersion
        case .collection: .importWorkflowCollection
        }
    }

    var systemImage: String {
        switch self {
        case .scan: "doc.viewfinder"
        case .metadata: "tag"
        case .version: "square.stack.3d.up"
        case .collection: "rectangle.stack"
        }
    }
}

enum ImportWorkflowPhaseState: Equatable, Sendable {
    case pending
    case running
    case waitingForReview
    case paused
    case needsAttention
    case completed

    var titleKey: L10nKey {
        switch self {
        case .pending: .importWorkflowNotStarted
        case .running: .running
        case .waitingForReview: .importWorkflowWaitingReview
        case .paused: .importWorkflowPaused
        case .needsAttention: .importWorkflowNeedsAttention
        case .completed: .importWorkflowCompleted
        }
    }
}

enum ImportPipelinePrimaryAction: Equatable, Sendable {
    case continueIncomplete
    case pause
    case openVersionReview
    case openCollectionReview
    case none
}

struct ImportWorkflowPresentation: Equatable, Sendable {
    var states: [ImportWorkflowPhase: ImportWorkflowPhaseState]
    var primaryAction: ImportPipelinePrimaryAction
    var progressFraction: Double

    subscript(_ phase: ImportWorkflowPhase) -> ImportWorkflowPhaseState {
        states[phase] ?? .pending
    }

    static func make(
        hasLibraryRoot: Bool,
        hasCompletedScan: Bool,
        isScanning: Bool,
        batch: ImportPipelineBatch?,
        isProcessing: Bool,
        inboxIsEmpty: Bool
    ) -> ImportWorkflowPresentation {
        var states: [ImportWorkflowPhase: ImportWorkflowPhaseState] = [
            .scan: scanState(
                hasLibraryRoot: hasLibraryRoot,
                hasCompletedScan: hasCompletedScan,
                isScanning: isScanning
            ),
            .metadata: inboxIsEmpty ? .completed : .pending,
            .version: inboxIsEmpty ? .completed : .pending,
            .collection: inboxIsEmpty ? .completed : .pending
        ]

        if let batch {
            apply(batch: batch, to: &states)
        }

        let action = primaryAction(
            batch: batch,
            isProcessing: isProcessing,
            inboxIsEmpty: inboxIsEmpty
        )
        let completed = ImportWorkflowPhase.allCases.count(where: { states[$0] == .completed })
        let activeFraction = states.values.contains(.running) ? 0.5 : 0

        return ImportWorkflowPresentation(
            states: states,
            primaryAction: action,
            progressFraction: min(1, (Double(completed) + activeFraction) / Double(ImportWorkflowPhase.allCases.count))
        )
    }

    private static func scanState(
        hasLibraryRoot: Bool,
        hasCompletedScan: Bool,
        isScanning: Bool
    ) -> ImportWorkflowPhaseState {
        if isScanning { return .running }
        if hasCompletedScan { return .completed }
        return hasLibraryRoot ? .pending : .needsAttention
    }

    private static func apply(
        batch: ImportPipelineBatch,
        to states: inout [ImportWorkflowPhase: ImportWorkflowPhaseState]
    ) {
        if batch.status == .completed || batch.stage == .completed {
            states[.metadata] = .completed
            states[.version] = .completed
            states[.collection] = .completed
            return
        }

        let currentPhase: ImportWorkflowPhase
        switch batch.stage {
        case .metadata:
            currentPhase = .metadata
        case .versionAnalysis, .versionReview:
            states[.metadata] = .completed
            currentPhase = .version
        case .collectionAnalysis, .collectionReview:
            states[.metadata] = .completed
            states[.version] = .completed
            currentPhase = .collection
        case .completed:
            return
        }

        if batch.status == .paused {
            states[currentPhase] = batch.failedCount > 0 ? .needsAttention : .paused
        } else if batch.status == .waitingForReview
            || batch.stage == .versionReview
            || batch.stage == .collectionReview {
            states[currentPhase] = .waitingForReview
        } else {
            states[currentPhase] = .running
        }
    }

    private static func primaryAction(
        batch: ImportPipelineBatch?,
        isProcessing: Bool,
        inboxIsEmpty: Bool
    ) -> ImportPipelinePrimaryAction {
        if isProcessing { return .pause }
        if let batch {
            if batch.stage == .versionReview { return .openVersionReview }
            if batch.stage == .collectionReview { return .openCollectionReview }
            if batch.status == .waitingForReview {
                return batch.stage == .versionAnalysis ? .openVersionReview : .openCollectionReview
            }
            if batch.status == .completed && inboxIsEmpty { return .none }
        }
        return inboxIsEmpty ? .none : .continueIncomplete
    }
}

enum ImportLibraryPresentation {
    static func showsMetadataRecoveryActions(for item: ImportPipelineItem?) -> Bool {
        guard let item else { return false }
        if item.stage == .metadataDeferred {
            return true
        }
        return item.stage == .metadataPending
            && item.lastErrorMessage?.isEmpty == false
    }

    static func showsPaginationFooter(loadError: String?, filteredCount: Int) -> Bool {
        loadError == nil && filteredCount > 0
    }

    static func inboxBooks(
        books: [LibraryBook],
        itemsByBookID: [LibraryBook.DatabaseID: ImportPipelineItem]
    ) -> [LibraryBook] {
        books.filter { book in
            guard let bookID = book.databaseID else {
                return book.status == .unscanned
            }
            if let item = itemsByBookID[bookID] {
                return item.stage.isIncomplete
            }
            return book.status == .unscanned
        }
    }

    static func filteredBooks(
        _ books: [LibraryBook],
        itemsByBookID: [LibraryBook.DatabaseID: ImportPipelineItem],
        query: String,
        filter: ImportInboxFilter
    ) -> [LibraryBook] {
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return books.filter { book in
            matchesSearch(book, query: trimmedQuery)
                && matchesFilter(book, item: item(for: book, in: itemsByBookID), filter: filter)
        }
    }

    static func matchesSearch(_ book: LibraryBook, query: String) -> Bool {
        guard !query.isEmpty else { return true }
        return book.title.localizedCaseInsensitiveContains(query)
            || (book.titleJpn?.localizedCaseInsensitiveContains(query) ?? false)
            || book.filepath.localizedCaseInsensitiveContains(query)
            || book.hash.localizedCaseInsensitiveContains(query)
    }

    static func matchesFilter(
        _ book: LibraryBook,
        item: ImportPipelineItem?,
        filter: ImportInboxFilter
    ) -> Bool {
        switch filter {
        case .all:
            return true
        case .pending:
            guard let item else { return book.status == .unscanned }
            switch item.stage {
            case .metadataPending, .metadataRunning, .versionAnalysisPending, .collectionAnalysisPending:
                return true
            default:
                return false
            }
        case .review:
            return item?.stage == .versionReviewPending || item?.stage == .collectionReviewPending
        case .attention:
            return item?.stage == .metadataDeferred
                || item?.stage == .sourceNeedsAttention
                || item?.lastErrorMessage?.isEmpty == false
        }
    }

    private static func item(
        for book: LibraryBook,
        in itemsByBookID: [LibraryBook.DatabaseID: ImportPipelineItem]
    ) -> ImportPipelineItem? {
        guard let bookID = book.databaseID else { return nil }
        return itemsByBookID[bookID]
    }
}
