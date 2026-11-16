import Foundation
import Testing
@testable import NyaEHCore

@Suite("Import library presentation")
struct ImportLibraryPresentationTests {
    @Test("raw inbox preserves collection members, secondary versions, and hidden records")
    func rawInboxPreservesEveryUnderlyingRecord() {
        var seriesMember = book(id: 1, title: "Series", status: .unscanned)
        seriesMember.collectionID = 9
        seriesMember.hiddenBook = true

        var secondaryVersion = book(id: 2, title: "Version", status: .unscanned)
        secondaryVersion.versionGroupID = 8
        secondaryVersion.isPrimaryVersion = false
        secondaryVersion.hiddenBook = true

        let correct = book(id: 3, title: "Correct", status: .correct)
        let broken = book(id: 4, title: "Broken", status: .broken)
        let missing = book(id: 5, title: "Missing", status: .correct, exist: false)

        let result = ImportLibraryPresentation.inboxBooks(
            books: [seriesMember, secondaryVersion, correct, broken, missing],
            itemsByBookID: [:]
        )

        #expect(result.map(\.databaseID) == [1, 2])
    }

    @Test("incomplete pipeline items remain visible after metadata changes book status")
    func incompletePipelineItemRemainsVisible() {
        let scanned = book(id: 1, title: "Scanned", status: .correct)
        let item = pipelineItem(id: 1, bookID: 1, stage: .versionAnalysisPending)

        let result = ImportLibraryPresentation.inboxBooks(
            books: [scanned],
            itemsByBookID: [1: item]
        )

        #expect(result == [scanned])
    }

    @Test("search matches title, Japanese title, path, and SHA1 without case sensitivity")
    func searchMatchesAllDocumentedFields() {
        var sample = book(id: 1, title: "English TITLE", status: .unscanned)
        sample.titleJpn = "日本語作品"
        sample.filepath = "/Library/Circle/Archive.CBZ"
        sample.hash = "ABCDEF123456"

        #expect(ImportLibraryPresentation.matchesSearch(sample, query: "title"))
        #expect(ImportLibraryPresentation.matchesSearch(sample, query: "日本語"))
        #expect(ImportLibraryPresentation.matchesSearch(sample, query: "circle/archive"))
        #expect(ImportLibraryPresentation.matchesSearch(sample, query: "abcdef"))
        #expect(!ImportLibraryPresentation.matchesSearch(sample, query: "missing"))
    }

    @Test("status filters separate pending, review, and attention records")
    func statusFiltersUsePipelineStages() {
        let sample = book(id: 1, title: "Sample", status: .unscanned)
        let pending = pipelineItem(id: 1, bookID: 1, stage: .metadataPending)
        let review = pipelineItem(id: 2, bookID: 1, stage: .versionReviewPending)
        let deferred = pipelineItem(id: 3, bookID: 1, stage: .metadataDeferred)
        var errored = pipelineItem(id: 4, bookID: 1, stage: .metadataPending)
        errored.lastErrorMessage = "network"

        #expect(ImportLibraryPresentation.matchesFilter(sample, item: pending, filter: .pending))
        #expect(!ImportLibraryPresentation.matchesFilter(sample, item: pending, filter: .review))
        #expect(ImportLibraryPresentation.matchesFilter(sample, item: review, filter: .review))
        #expect(ImportLibraryPresentation.matchesFilter(sample, item: deferred, filter: .attention))
        #expect(ImportLibraryPresentation.matchesFilter(sample, item: errored, filter: .attention))
        #expect(ImportLibraryPresentation.matchesFilter(sample, item: nil, filter: .pending))
    }

    @Test("search and status filtering happen before pagination")
    func filteringProducesThePaginationInput() {
        let books = (1...12).map { id in
            book(id: Int64(id), title: id.isMultiple(of: 2) ? "Match \(id)" : "Other \(id)", status: .unscanned)
        }
        let filtered = ImportLibraryPresentation.filteredBooks(
            books,
            itemsByBookID: [:],
            query: "match",
            filter: .pending
        )
        let page = Pagination.pageItems(filtered, page: 2, pageSize: 4)

        #expect(filtered.count == 6)
        #expect(page.map(\.title) == ["Match 10", "Match 12"])
        #expect(Pagination.clampedPage(4, itemCount: filtered.count, pageSize: 4) == 2)
    }

    @Test("pagination footer is visible only for nonempty successful results")
    func paginationFooterVisibility() {
        #expect(ImportLibraryPresentation.showsPaginationFooter(loadError: nil, filteredCount: 1))
        #expect(!ImportLibraryPresentation.showsPaginationFooter(loadError: nil, filteredCount: 0))
        #expect(!ImportLibraryPresentation.showsPaginationFooter(loadError: "load failed", filteredCount: 10))
    }

    @Test("metadata recovery shortcuts only appear for metadata failures")
    func metadataRecoveryShortcutVisibility() {
        let deferred = pipelineItem(id: 1, bookID: 1, stage: .metadataDeferred)
        var pausedWithError = pipelineItem(id: 2, bookID: 2, stage: .metadataPending)
        pausedWithError.lastErrorMessage = "authentication failed"
        let ordinaryPending = pipelineItem(id: 3, bookID: 3, stage: .metadataPending)
        let sourceFailure = pipelineItem(id: 4, bookID: 4, stage: .sourceNeedsAttention)

        #expect(ImportLibraryPresentation.showsMetadataRecoveryActions(for: deferred))
        #expect(ImportLibraryPresentation.showsMetadataRecoveryActions(for: pausedWithError))
        #expect(!ImportLibraryPresentation.showsMetadataRecoveryActions(for: ordinaryPending))
        #expect(!ImportLibraryPresentation.showsMetadataRecoveryActions(for: sourceFailure))
        #expect(!ImportLibraryPresentation.showsMetadataRecoveryActions(for: nil))
    }

    @Test("clipboard URL selection accepts only supported gallery URLs")
    func clipboardGalleryURLSelection() {
        let selected = ImportGalleryURLPasteboardReader.firstSupportedURL(in: [
            "https://example.com/g/1/wrong/",
            "  https://exhentai.org/g/12345/tokenabc/ \n"
        ])

        #expect(selected?.absoluteString == "https://exhentai.org/g/12345/tokenabc/")
        #expect(ImportGalleryURLPasteboardReader.firstSupportedURL(in: [
            "",
            "not a URL",
            "https://e-hentai.org/g/12345/"
        ]) == nil)
    }

    @Test("workflow maps running, review, paused failure, and completed batches")
    func workflowStageMapping() {
        let running = presentation(batch: batch(status: .running, stage: .metadata), isProcessing: true)
        #expect(running[.scan] == .completed)
        #expect(running[.metadata] == .running)
        #expect(running.primaryAction == .pause)

        let review = presentation(batch: batch(status: .waitingForReview, stage: .versionReview))
        #expect(review[.metadata] == .completed)
        #expect(review[.version] == .waitingForReview)
        #expect(review.primaryAction == .openVersionReview)

        var failedBatch = batch(status: .paused, stage: .collectionAnalysis)
        failedBatch.failedCount = 1
        let failed = presentation(batch: failedBatch)
        #expect(failed[.version] == .completed)
        #expect(failed[.collection] == .needsAttention)
        #expect(failed.primaryAction == .continueIncomplete)

        let completed = ImportWorkflowPresentation.make(
            hasLibraryRoot: true,
            hasCompletedScan: true,
            isScanning: false,
            batch: batch(status: .completed, stage: .completed),
            isProcessing: false,
            inboxIsEmpty: true
        )
        #expect(completed.primaryAction == .none)
        #expect(completed.progressFraction == 1)
    }

    private func presentation(
        batch: ImportPipelineBatch,
        isProcessing: Bool = false
    ) -> ImportWorkflowPresentation {
        ImportWorkflowPresentation.make(
            hasLibraryRoot: true,
            hasCompletedScan: true,
            isScanning: false,
            batch: batch,
            isProcessing: isProcessing,
            inboxIsEmpty: false
        )
    }

    private func book(
        id: Int64,
        title: String,
        status: BookStatus,
        exist: Bool = true
    ) -> LibraryBook {
        LibraryBook(
            databaseID: id,
            title: title,
            hash: "hash-\(id)",
            filepath: "/tmp/\(id).cbz",
            type: .archive,
            status: status,
            exist: exist
        )
    }

    private func pipelineItem(
        id: Int64,
        bookID: Int64,
        stage: ImportPipelineItemStage
    ) -> ImportPipelineItem {
        ImportPipelineItem(
            id: id,
            batchID: nil,
            bookID: bookID,
            sourceHash: "hash-\(bookID)",
            sourceMtime: nil,
            stage: stage,
            metadataSource: nil,
            preferredGalleryURL: nil,
            attemptCount: 0,
            lastErrorKind: nil,
            lastErrorMessage: nil,
            retryAfter: nil,
            createdAt: 1,
            updatedAt: 1,
            completedAt: nil
        )
    }

    private func batch(
        status: ImportPipelineBatchStatus,
        stage: ImportPipelineBatchStage
    ) -> ImportPipelineBatch {
        ImportPipelineBatch(
            id: 1,
            status: status,
            stage: stage,
            pauseReason: nil,
            totalCount: 3,
            readyCount: 1,
            deferredCount: 0,
            reviewCount: 0,
            failedCount: 0,
            createdAt: 1,
            startedAt: 1,
            completedAt: nil,
            updatedAt: 1
        )
    }
}
