// 本文件是书库用例服务聚合层，统一协调 repository、扫描、元数据、标签、合集、版本组和维护动作。

import Foundation

struct BookLibraryService: @unchecked Sendable {
    // 这个类型有意保持为“用例门面”：Store 不直接碰 repository 组合，也不自己决定文件、
    // 网络、缓存和数据库写入顺序。可选依赖让单元测试和降级运行可以只装配局部能力。
    private let bookRepository: LibraryBookRepository
    private let metadataRepository: GalleryMetadataRepository
    private let tagRepository: TagRepository?
    private let searchRepository: LibrarySearchRepository?
    private let collectionRepository: CollectionRepository?
    private let collectionRecommendationMutationRepository: CollectionRecommendationMutationRepository?
    private let versionGroupRepository: VersionGroupRepository?
    private let versionGroupMutationRepository: VersionGroupMutationRepository?
    private let versionLabelSuggestionRepository: VersionLabelSuggestionRepository?
    private let bookVersionLabelRepository: BookVersionLabelRepository?
    private let readingStateRepository: BookReadingStateRepository?
    private let versionRecommendationRepository: VersionRecommendationRepository?
    private let versionRecommendationService: VersionRecommendationService?
    private let collectionRecommendationRepository: CollectionRecommendationRepository?
    private let collectionRecommendationService: CollectionRecommendationService?
    private let importPipelineRepository: ImportPipelineRepository?
    private let workCharacterRepository: WorkCharacterRepository?
    private let workDetailRepository: WorkDetailRepository?
    private let tagVisualProfileRepository: TagVisualProfileRepository?
    private let tagVisualAssetService: TagVisualAssetService?
    private let coverVectorRepository: CoverVectorRepository?
    private let coverVectorIndexService: CoverVectorIndexService?
    private let semanticTitleVectorRepository: SemanticTitleVectorRepository?
    private let semanticTitleVectorIndexService: SemanticTitleVectorIndexService?
    private let coverFeatureQueryGenerator: CoverFeatureQueryGenerating
    private let databaseManager: DatabaseManager?
    let backupService: LibraryBackupService?
    private let fileStatusService: BookFileStatusService
    private let scannerService: LibraryScannerService
    private let metadataFetchService: GalleryMetadataFetchService
    private let tagTranslationUpdateService: EhTagTranslationUpdateService?
    private let externalImportService: ExternalLibraryImportService?
    private let coverCache: (any CoverCaching)?
    private let sourceTrash: any LibrarySourceTrashing
    private let fileManager: FileManager

    init(
        bookRepository: LibraryBookRepository,
        metadataRepository: GalleryMetadataRepository,
        tagRepository: TagRepository? = nil,
        searchRepository: LibrarySearchRepository? = nil,
        collectionRepository: CollectionRepository? = nil,
        versionGroupRepository: VersionGroupRepository? = nil,
        versionGroupMutationRepository: VersionGroupMutationRepository? = nil,
        versionLabelSuggestionRepository: VersionLabelSuggestionRepository? = nil,
        bookVersionLabelRepository: BookVersionLabelRepository? = nil,
        readingStateRepository: BookReadingStateRepository? = nil,
        versionRecommendationRepository: VersionRecommendationRepository? = nil,
        collectionRecommendationRepository: CollectionRecommendationRepository? = nil,
        importPipelineRepository: ImportPipelineRepository? = nil,
        workCharacterRepository: WorkCharacterRepository? = nil,
        workDetailRepository: WorkDetailRepository? = nil,
        tagVisualProfileRepository: TagVisualProfileRepository? = nil,
        tagVisualAssetService: TagVisualAssetService? = try? .appDefault(),
        coverVectorRepository: CoverVectorRepository? = nil,
        semanticTitleVectorRepository: SemanticTitleVectorRepository? = nil,
        contextualTitleEmbeddingGenerator: ContextualTitleEmbeddingGenerating = ContextualTitleEmbeddingService(),
        coverFeaturePrintGenerator: CoverFeaturePrintGenerating = CoverFeaturePrintService(),
        coverFeatureQueryGenerator: CoverFeatureQueryGenerating = CoverFeaturePrintService(),
        databaseManager: DatabaseManager? = nil,
        backupService: LibraryBackupService? = nil,
        fileStatusService: BookFileStatusService = BookFileStatusService(),
        metadataFetchService: GalleryMetadataFetchService = GalleryMetadataFetchService(),
        tagTranslationUpdateService: EhTagTranslationUpdateService? = try? .appDefault(),
        externalImportService: ExternalLibraryImportService? = nil,
        coverCache: (any CoverCaching)? = try? CoverCacheService.appDefault(),
        sourceTrash: any LibrarySourceTrashing = LibrarySourceTrash(),
        fileManager: FileManager = .default
    ) {
        self.bookRepository = bookRepository
        self.metadataRepository = metadataRepository
        self.tagRepository = tagRepository
        self.searchRepository = searchRepository
        self.collectionRepository = collectionRepository
        self.collectionRecommendationMutationRepository = collectionRepository as? CollectionRecommendationMutationRepository
        self.versionGroupRepository = versionGroupRepository
        self.versionGroupMutationRepository = versionGroupMutationRepository
            ?? (versionGroupRepository as? VersionGroupMutationRepository)
        self.versionLabelSuggestionRepository = versionLabelSuggestionRepository
        self.bookVersionLabelRepository = bookVersionLabelRepository
        self.readingStateRepository = readingStateRepository
        self.versionRecommendationRepository = versionRecommendationRepository
        self.collectionRecommendationRepository = collectionRecommendationRepository
        self.importPipelineRepository = importPipelineRepository
        self.workCharacterRepository = workCharacterRepository
        self.workDetailRepository = workDetailRepository
        self.tagVisualProfileRepository = tagVisualProfileRepository
        self.tagVisualAssetService = tagVisualAssetService
        self.coverVectorRepository = coverVectorRepository
        self.semanticTitleVectorRepository = semanticTitleVectorRepository
        self.coverFeatureQueryGenerator = coverFeatureQueryGenerator
        coverVectorIndexService = coverVectorRepository.map {
            CoverVectorIndexService(repository: $0, featureGenerator: coverFeaturePrintGenerator)
        }
        semanticTitleVectorIndexService = semanticTitleVectorRepository.map {
            SemanticTitleVectorIndexService(
                repository: $0,
                generator: contextualTitleEmbeddingGenerator
            )
        }
        self.databaseManager = databaseManager
        self.backupService = backupService
        versionRecommendationService = versionRecommendationRepository.map {
            VersionRecommendationService(
                bookRepository: bookRepository,
                recommendationRepository: $0,
                coverVectorSearch: coverVectorRepository
            )
        }
        collectionRecommendationService = collectionRecommendationRepository.map {
            CollectionRecommendationService(
                bookRepository: bookRepository,
                recommendationRepository: $0,
                semanticVectorSearch: semanticTitleVectorRepository
            )
        }
        self.fileStatusService = fileStatusService
        self.metadataFetchService = metadataFetchService
        self.tagTranslationUpdateService = tagTranslationUpdateService
        self.externalImportService = externalImportService
        self.coverCache = coverCache
        self.fileManager = fileManager
        self.sourceTrash = sourceTrash
        scannerService = LibraryScannerService(repository: bookRepository, coverCache: coverCache)
    }

    func loadBooks() throws -> [LibraryBook] {
        try bookRepository.fetchAll()
    }

    func loadBook(id: LibraryBook.DatabaseID) throws -> LibraryBook? {
        try bookRepository.fetch(id: id)
    }

    func loadBooks(collectionID: BookCollection.DatabaseID) throws -> [LibraryBook] {
        try bookRepository.fetchByCollectionID(collectionID)
    }

    func loadBooks(versionGroupID: BookVersionGroup.DatabaseID) throws -> [LibraryBook] {
        try bookRepository.fetchByVersionGroupID(versionGroupID)
    }

    func loadCollections() throws -> [BookCollection] {
        try collectionRepository?.fetchAll() ?? []
    }

    func loadVersionGroups() throws -> [BookVersionGroup] {
        try versionGroupRepository?.fetchAll() ?? []
    }

    func loadVersionLabelSuggestions() throws -> [VersionLabelSuggestion] {
        try versionLabelSuggestionRepository?.fetchAll() ?? []
    }

    func loadReadingStates() throws -> [BookReadingState] {
        try readingStateRepository?.fetchAll() ?? []
    }

    func recoverImportPipeline() throws {
        try importPipelineRepository?.recoverInterruptedWork()
    }

    func reconcileImportPipeline(books: [LibraryBook]) throws {
        try importPipelineRepository?.reconcile(books: books)
    }

    func loadImportPipelineSnapshot() throws -> ImportPipelineSnapshot {
        guard let importPipelineRepository else { return .empty }
        return ImportPipelineSnapshot(
            activeBatch: try importPipelineRepository.fetchActiveBatch(),
            items: try importPipelineRepository.fetchAllItems()
        )
    }

    func createImportPipelineBatch() throws -> ImportPipelineBatch? {
        try importPipelineRepository?.createBatchFromPendingItems()
    }

    func importPipelineItems(batchID: ImportPipelineBatch.ID) throws -> [ImportPipelineItem] {
        try importPipelineRepository?.fetchItems(batchID: batchID) ?? []
    }

    func updateImportPipelineBatch(_ batch: ImportPipelineBatch) throws {
        try importPipelineRepository?.updateBatch(batch)
    }

    func updateImportPipelineItem(_ item: ImportPipelineItem) throws {
        try importPipelineRepository?.updateItem(item)
    }

    func importPipelineItem(bookID: LibraryBook.DatabaseID) throws -> ImportPipelineItem? {
        try importPipelineRepository?.fetchItem(bookID: bookID)
    }

    func readingState(for book: LibraryBook) throws -> BookReadingState? {
        guard let bookID = book.databaseID else { return nil }
        return try readingStateRepository?.fetch(bookID: bookID)
    }

    func saveReadingProgress(
        for book: LibraryBook,
        currentPageIndex: Int,
        totalPages: Int,
        forceCompleted: Bool? = nil
    ) throws -> BookReadingState {
        guard let bookID = book.databaseID, let readingStateRepository else {
            throw NyaEHError.bookHasNoID
        }
        let now = Timestamp.nowMilliseconds()
        let normalizedTotal = max(totalPages, 0)
        let normalizedIndex = normalizedTotal > 0
            ? min(max(currentPageIndex, 0), normalizedTotal - 1)
            : max(currentPageIndex, 0)
        let shouldComplete = forceCompleted ?? (
            normalizedTotal > 0 && Double(normalizedIndex + 1) / Double(normalizedTotal) >= 0.95
        )
        let existing = try readingStateRepository.fetch(bookID: bookID)
        let state = BookReadingState(
            bookID: bookID,
            currentPageIndex: normalizedIndex,
            totalPages: normalizedTotal,
            updatedAt: now,
            completedAt: shouldComplete ? (existing?.completedAt ?? now) : nil
        )
        return try readingStateRepository.save(state)
    }

    func resetReadingProgress(for book: LibraryBook) throws {
        guard let bookID = book.databaseID else { throw NyaEHError.bookHasNoID }
        try readingStateRepository?.reset(bookID: bookID)
    }

    func databaseIntegrityCheck() throws -> [String] {
        guard let databaseManager else {
            throw NyaEHError.databaseMaintenanceUnavailable
        }
        return try databaseManager.integrityCheck()
    }

    func databaseForeignKeyCheck() throws -> [DatabaseForeignKeyViolation] {
        guard let databaseManager else {
            throw NyaEHError.databaseMaintenanceUnavailable
        }
        return try databaseManager.foreignKeyCheck()
    }

    func vacuumDatabase() throws {
        guard let databaseManager else {
            throw NyaEHError.databaseMaintenanceUnavailable
        }
        try databaseManager.vacuum()
    }

    func dataHealthCheck() throws -> DataHealthReport {
        guard let backupService else { throw NyaEHError.databaseMaintenanceUnavailable }
        return try backupService.healthCheck()
    }

    func repairDerivedData() throws -> DataHealthReport {
        guard let backupService else { throw NyaEHError.databaseMaintenanceUnavailable }
        let before = try backupService.healthCheck()
        _ = try backupService.repairDerivedData(
            books: bookRepository.fetchAll(),
            tagRepository: tagRepository,
            labelRepository: bookVersionLabelRepository
        )
        try recoverLibraryDeletions()
        var report = try backupService.healthCheck()
        let remainingIDs = Set(report.issues.map(\.id))
        report.repairedIssueCount = before.issues.filter { !remainingIDs.contains($0.id) }.count
        return report
    }

    func loadVersionLabels(for book: LibraryBook) throws -> [String] {
        guard let bookID = book.databaseID else {
            return VersionLabelFormatter.labels(from: book.versionLabel)
        }
        if let labels = try bookVersionLabelRepository?.fetchLabels(bookID: bookID), !labels.isEmpty {
            return labels
        }
        return VersionLabelFormatter.labels(from: book.versionLabel)
    }

    func refreshVersionRecommendations(
        useCoverSimilarity: Bool = false,
        maximumCoverDistance: Double = VersionRecommendationService.defaultCoverSimilarityMaximumDistance,
        focusBookIDs: Set<LibraryBook.DatabaseID> = [],
        progress: (@Sendable (VersionRecommendationRefreshProgress) -> Void)? = nil,
        progressPhases: VersionRecommendationRefreshProgressPhases = .default
    ) throws {
        guard let versionRecommendationService else {
            throw NyaEHError.groupingRepositoryUnavailable
        }
        try versionRecommendationService.refreshRecommendations(
            useCoverSimilarity: useCoverSimilarity,
            maximumCoverDistance: maximumCoverDistance,
            focusBookIDs: focusBookIDs,
            progress: progress,
            progressPhases: progressPhases
        )
    }

    @discardableResult
    func updateVersionRecommendationsIncrementally(
        useCoverSimilarity: Bool = false,
        maximumCoverDistance: Double = VersionRecommendationService.defaultCoverSimilarityMaximumDistance,
        focusBookIDs: Set<LibraryBook.DatabaseID> = [],
        progress: (@Sendable (VersionRecommendationRefreshProgress) -> Void)? = nil,
        progressPhases: VersionRecommendationRefreshProgressPhases = .default
    ) throws -> Bool {
        guard let versionRecommendationService else {
            throw NyaEHError.groupingRepositoryUnavailable
        }
        return try versionRecommendationService.updateRecommendationsIncrementally(
            useCoverSimilarity: useCoverSimilarity,
            maximumCoverDistance: maximumCoverDistance,
            focusBookIDs: focusBookIDs,
            progress: progress,
            progressPhases: progressPhases
        )
    }

    func loadCreateVersionGroupRecommendations() throws -> [VersionRecommendationDisplayItem] {
        try versionRecommendationService?.pendingCreateGroupRecommendations() ?? []
    }

    func loadAddToVersionGroupRecommendations(
        groupID: BookVersionGroup.DatabaseID
    ) throws -> [VersionRecommendationDisplayItem] {
        try versionRecommendationService?.pendingAddToGroupRecommendations(groupID: groupID) ?? []
    }

    func loadAddToVersionGroupRecommendationCounts() throws -> [BookVersionGroup.DatabaseID: Int] {
        try versionRecommendationService?.pendingAddToGroupCounts() ?? [:]
    }

    func latestVersionRecommendationRefreshCompletedAt() throws -> Int64? {
        try versionRecommendationService?.latestRefreshCompletedAt()
    }

    func pendingVersionRecommendationCount(involving bookIDs: Set<LibraryBook.DatabaseID>) throws -> Int {
        try versionRecommendationRepository?.pendingCount(involving: bookIDs) ?? 0
    }

    func acceptVersionRecommendation(_ recommendation: VersionRecommendation) throws {
        guard let versionRecommendationService else {
            throw NyaEHError.groupingRepositoryUnavailable
        }
        try versionRecommendationService.markAccepted(recommendation)
    }

    func dismissVersionRecommendation(_ recommendation: VersionRecommendation) throws {
        guard let versionRecommendationService else {
            throw NyaEHError.groupingRepositoryUnavailable
        }
        try versionRecommendationService.dismiss(recommendation)
    }

    func refreshCollectionRecommendations(
        focusBookIDs: Set<LibraryBook.DatabaseID> = [],
        semanticConfiguration: SemanticSeriesConfiguration = .disabled,
        progress: (@Sendable (CollectionRecommendationRefreshProgress) -> Void)? = nil,
        progressPhases: CollectionRecommendationRefreshProgressPhases = .default
    ) throws {
        guard let collectionRecommendationService else {
            throw NyaEHError.groupingRepositoryUnavailable
        }
        try collectionRecommendationService.refreshRecommendations(
            focusBookIDs: focusBookIDs,
            semanticConfiguration: semanticConfiguration,
            progress: progress,
            progressPhases: progressPhases
        )
    }

    @discardableResult
    func updateCollectionRecommendationsIncrementally(
        focusBookIDs: Set<LibraryBook.DatabaseID> = [],
        semanticConfiguration: SemanticSeriesConfiguration = .disabled,
        progress: (@Sendable (CollectionRecommendationRefreshProgress) -> Void)? = nil,
        progressPhases: CollectionRecommendationRefreshProgressPhases = .default
    ) throws -> Bool {
        guard let collectionRecommendationService else {
            throw NyaEHError.groupingRepositoryUnavailable
        }
        return try collectionRecommendationService.updateRecommendationsIncrementally(
            focusBookIDs: focusBookIDs,
            semanticConfiguration: semanticConfiguration,
            progress: progress,
            progressPhases: progressPhases
        )
    }

    func loadCreateCollectionRecommendations() throws -> [CollectionRecommendationDisplayItem] {
        try collectionRecommendationService?.pendingCreateCollectionRecommendations() ?? []
    }

    func loadAddToCollectionRecommendations(
        collectionID: BookCollection.DatabaseID
    ) throws -> [CollectionRecommendationDisplayItem] {
        try collectionRecommendationService?.pendingAddToCollectionRecommendations(collectionID: collectionID) ?? []
    }

    func loadAddToCollectionRecommendationCounts() throws -> [BookCollection.DatabaseID: Int] {
        try collectionRecommendationService?.pendingAddToCollectionCounts() ?? [:]
    }

    func latestCollectionRecommendationRefreshCompletedAt() throws -> Int64? {
        try collectionRecommendationService?.latestRefreshCompletedAt()
    }

    func pendingCollectionRecommendationCount(involving bookIDs: Set<LibraryBook.DatabaseID>) throws -> Int {
        try collectionRecommendationRepository?.pendingCount(involving: bookIDs) ?? 0
    }

    func resetDismissedRecommendations(for book: LibraryBook) throws {
        guard let bookID = book.databaseID else { throw NyaEHError.bookHasNoID }
        try versionRecommendationRepository?.resetDismissed(involving: bookID)
        try collectionRecommendationRepository?.resetDismissed(involving: bookID)
    }

    func rebuildWorkCharacterIndex() throws -> WorkCharacterIndexUpdateResult {
        guard let workCharacterRepository else {
            throw NyaEHError.groupingRepositoryUnavailable
        }
        return try workCharacterRepository.rebuildIndex()
    }

    func updateWorkCharacterIndexIncrementally() throws -> WorkCharacterIndexUpdateResult {
        guard let workCharacterRepository else {
            throw NyaEHError.groupingRepositoryUnavailable
        }
        return try workCharacterRepository.updateIndexIncrementally()
    }

    func updateWorkCharacterIndexIfNeeded() throws -> WorkCharacterIndexUpdateResult {
        guard let workCharacterRepository else {
            return .noChanges
        }
        guard try workCharacterRepository.hasIncrementalChanges() else {
            return .noChanges
        }
        return try workCharacterRepository.updateIndexIncrementally()
    }

    func workCharacterWorks(isTagTranslationEnabled: Bool) throws -> [WorkCharacterWorkSummary] {
        guard let workCharacterRepository else {
            throw NyaEHError.groupingRepositoryUnavailable
        }
        return try workCharacterRepository.fetchWorks(
            languageCode: isTagTranslationEnabled ? EhTagTranslationCache.languageCode : nil
        )
    }

    func workCharacterCharacters(
        parodyTagID: Tag.DatabaseID,
        isTagTranslationEnabled: Bool
    ) throws -> [WorkCharacterCharacterSummary] {
        guard let workCharacterRepository else {
            throw NyaEHError.groupingRepositoryUnavailable
        }
        return try workCharacterRepository.fetchCharacters(
            parodyTagID: parodyTagID,
            languageCode: isTagTranslationEnabled ? EhTagTranslationCache.languageCode : nil
        )
    }

    func workDetail(
        parodyTagID: Tag.DatabaseID,
        isTagTranslationEnabled: Bool
    ) throws -> WorkDetail? {
        guard let workDetailRepository else {
            throw NyaEHError.groupingRepositoryUnavailable
        }
        return try workDetailRepository.fetchWorkDetail(
            parodyTagID: parodyTagID,
            languageCode: isTagTranslationEnabled ? EhTagTranslationCache.languageCode : nil
        )
    }

    func characterDetail(
        characterTagID: Tag.DatabaseID,
        isTagTranslationEnabled: Bool
    ) throws -> CharacterDetail? {
        guard let workDetailRepository else {
            throw NyaEHError.groupingRepositoryUnavailable
        }
        return try workDetailRepository.fetchCharacterDetail(
            characterTagID: characterTagID,
            languageCode: isTagTranslationEnabled ? EhTagTranslationCache.languageCode : nil
        )
    }

    func workCharacterCandidates(parodyTagID: Tag.DatabaseID, isTagTranslationEnabled: Bool) throws -> [WorkCharacterCandidate] {
        guard let workDetailRepository else { throw NyaEHError.groupingRepositoryUnavailable }
        return try workDetailRepository.fetchWorkCharacterCandidates(
            parodyTagID: parodyTagID,
            languageCode: isTagTranslationEnabled ? EhTagTranslationCache.languageCode : nil
        )
    }

    func addCharacterTag(to bookID: LibraryBook.DatabaseID, pair: WorkCharacterPair) throws -> WorkCharacterTagAddition {
        guard let workDetailRepository else { throw NyaEHError.groupingRepositoryUnavailable }
        return try workDetailRepository.addCharacterTag(to: bookID, pair: pair)
    }

    func setWorkCharacterDecision(_ decision: WorkCharacterManualDecision?, pair: WorkCharacterPair) throws {
        guard let workDetailRepository else { throw NyaEHError.groupingRepositoryUnavailable }
        try workDetailRepository.setWorkCharacterDecision(decision, pair: pair)
    }

    func setAutomaticClaimSuppressed(_ isSuppressed: Bool, bookID: LibraryBook.DatabaseID, pair: WorkCharacterPair) throws {
        guard let workDetailRepository else { throw NyaEHError.groupingRepositoryUnavailable }
        try workDetailRepository.setAutomaticClaimSuppressed(isSuppressed, bookID: bookID, pair: pair)
    }

    func dismissCollectionRecommendation(_ recommendation: CollectionRecommendation) throws {
        guard let collectionRecommendationService else {
            throw NyaEHError.groupingRepositoryUnavailable
        }
        try collectionRecommendationService.dismiss(recommendation)
    }

    func coverVectorStats() throws -> CoverVectorIndexStats {
        try coverVectorIndexService?.stats(for: loadBooks()) ?? .empty
    }

    func rebuildCoverVectorIndex(
        phase: String,
        progress: @escaping @Sendable (CoverVectorIndexProgress) -> Void
    ) throws -> CoverVectorIndexStats {
        guard let coverVectorIndexService else {
            throw NyaEHError.coverVectorStorageUnavailable
        }
        return try coverVectorIndexService.rebuild(
            books: loadBooks(),
            phase: phase,
            progress: progress
        )
    }

    func updateMissingCoverVectors(
        phase: String,
        progress: @escaping @Sendable (CoverVectorIndexProgress) -> Void
    ) throws -> CoverVectorIndexStats {
        guard let coverVectorIndexService else {
            throw NyaEHError.coverVectorStorageUnavailable
        }
        return try coverVectorIndexService.updateMissingOrStale(
            books: loadBooks(),
            phase: phase,
            progress: progress
        )
    }

    func clearCoverVectorIndex() throws {
        try coverVectorIndexService?.clear()
    }

    func semanticTitleAssetState() async -> SemanticEmbeddingAssetState {
        await semanticTitleVectorIndexService?.assetState() ?? .unavailable
    }

    func requestSemanticTitleAssets() async throws -> SemanticEmbeddingProfile {
        guard let semanticTitleVectorIndexService else {
            throw NyaEHError.semanticTitleStorageUnavailable
        }
        return try await semanticTitleVectorIndexService.requestAssets()
    }

    func semanticTitleVectorStats() async throws -> SemanticTitleVectorIndexStats {
        guard let semanticTitleVectorIndexService else {
            return .empty
        }
        return try await semanticTitleVectorIndexService.stats(for: loadBooks())
    }

    func rebuildSemanticTitleVectorIndex(
        phase: String,
        progress: @escaping @Sendable (SemanticTitleVectorIndexProgress) -> Void
    ) async throws -> SemanticTitleVectorIndexStats {
        guard let semanticTitleVectorIndexService else {
            throw NyaEHError.semanticTitleStorageUnavailable
        }
        return try await semanticTitleVectorIndexService.rebuild(
            books: loadBooks(),
            phase: phase,
            progress: progress
        )
    }

    func updateSemanticTitleVectors(
        focusBookIDs: Set<LibraryBook.DatabaseID> = [],
        phase: String,
        progress: @escaping @Sendable (SemanticTitleVectorIndexProgress) -> Void
    ) async throws -> SemanticTitleVectorIndexStats {
        guard let semanticTitleVectorIndexService else {
            throw NyaEHError.semanticTitleStorageUnavailable
        }
        return try await semanticTitleVectorIndexService.updateMissingOrStale(
            books: loadBooks(),
            focusBookIDs: focusBookIDs,
            phase: phase,
            progress: progress
        )
    }

    func clearSemanticTitleVectorIndex() throws {
        try semanticTitleVectorIndexService?.clear()
    }

    func coverDistanceReport(referenceThreshold: Double) throws -> String {
        guard let coverVectorIndexService else {
            throw NyaEHError.coverVectorStorageUnavailable
        }
        return try coverVectorIndexService.distanceReport(
            books: loadBooks(),
            referenceThreshold: referenceThreshold
        )
    }

    func searchByCoverImage(
        data: Data,
        limit: Int = CoverImageSearchConfiguration.maximumResultCount,
        maximumDistance: Double = CoverImageSearchConfiguration.maximumDistance
    ) throws -> [CoverImageSearchMatch] {
        guard let coverVectorRepository else {
            throw NyaEHError.coverVectorStorageUnavailable
        }
        let normalizedLimit = min(
            max(limit, 1),
            CoverImageSearchConfiguration.maximumResultCount
        )
        let query = try coverFeatureQueryGenerator.featureQuery(forImageData: data)
        let candidates = try coverVectorRepository.nearestNeighbors(
            query: query,
            limit: max(normalizedLimit * 4, normalizedLimit)
        )

        var matches: [CoverImageSearchMatch] = []
        matches.reserveCapacity(normalizedLimit)
        for candidate in candidates where candidate.distance <= maximumDistance {
            guard let entry = try coverVectorRepository.fetchEntry(bookID: candidate.bookID),
                  entry.visionRevision == query.visionRevision,
                  entry.elementType == query.elementType,
                  entry.elementCount == query.elementCount,
                  let book = try bookRepository.fetch(id: candidate.bookID),
                  book.exist,
                  !book.isUserHidden else {
                continue
            }
            matches.append(CoverImageSearchMatch(book: book, distance: candidate.distance))
            if matches.count == normalizedLimit {
                break
            }
        }
        return matches
    }

    func metadata(for book: LibraryBook) throws -> GalleryMetadata? {
        try metadataRepository.fetch(hash: book.hash)
    }

    func applyCachedMetadata(for book: LibraryBook) throws -> LibraryBook? {
        guard let metadata = try metadataRepository.fetch(hash: book.hash), metadata.status == .correct else {
            return nil
        }
        return try applyMetadata(metadata, to: book)
    }

    func registerBook(_ book: LibraryBook) throws -> LibraryBook {
        try bookRepository.insert(book)
    }

    func saveMetadata(_ metadata: GalleryMetadata) throws -> GalleryMetadata {
        try metadataRepository.upsert(metadata)
    }

    func saveManualMetadataDraft(_ draft: BookMetadataEditDraft, for book: LibraryBook) throws -> LibraryBook {
        guard let bookID = book.databaseID else {
            throw NyaEHError.bookHasNoID
        }

        let update = try draft.validatedMetadata(for: book)
        var updatedBook = book
        updatedBook.title = update.title
        updatedBook.titleJpn = update.titleJpn
        updatedBook.category = update.category
        updatedBook.languageCode = update.languageCode
        updatedBook.pages = update.pages
        updatedBook.isTranslated = update.isTranslated
        updatedBook.isFullColor = update.isFullColor
        updatedBook.censorship = update.censorship
        updatedBook.hasExtraneousAds = update.hasExtraneousAds
        updatedBook.tags = update.tagsJSON
        updatedBook.status = .correct

        let metadata = GalleryMetadata(
            hash: book.hash,
            galleryID: nil,
            galleryToken: nil,
            title: updatedBook.title,
            titleJpn: updatedBook.titleJpn,
            status: updatedBook.status,
            rating: updatedBook.rating,
            tags: updatedBook.tags,
            pages: updatedBook.pages,
            posted: updatedBook.posted,
            filesize: updatedBook.filesize,
            category: updatedBook.category,
            url: updatedBook.url
        )
        _ = try metadataRepository.upsert(metadata)

        updatedBook.languageCode = update.languageCode
        updatedBook.isTranslated = update.isTranslated
        updatedBook.isFullColor = update.isFullColor
        updatedBook.censorship = update.censorship
        updatedBook.hasExtraneousAds = update.hasExtraneousAds
        let savedBook = try bookRepository.updateMetadata(updatedBook)
        try tagRepository?.rebuildTags(forBookID: bookID, tagsJSON: savedBook.tags)
        try? materializeCachedTagTranslations()
        return try bookRepository.fetch(id: bookID) ?? savedBook
    }

    func clearMetadata(for book: LibraryBook) throws -> LibraryBook {
        guard let bookID = book.databaseID else {
            throw NyaEHError.bookHasNoID
        }

        var cleared = book
        cleared.title = Self.fallbackTitle(for: book)
        cleared.titleJpn = nil
        cleared.rating = nil
        cleared.tags = "[]"
        cleared.pages = nil
        cleared.posted = nil
        cleared.filesize = nil
        cleared.category = nil
        cleared.url = nil
        cleared.status = .unscanned
        cleared.languageCode = "unknown"
        cleared.isTranslated = false
        cleared.isFullColor = false
        cleared.censorship = "unknown"
        cleared.hasExtraneousAds = false

        let saved = try bookRepository.updateMetadata(cleared)
        try metadataRepository.delete(hash: book.hash)
        try tagRepository?.rebuildTags(forBookID: bookID, tagsJSON: saved.tags)
        return try bookRepository.fetch(id: bookID) ?? saved
    }

    @MainActor
    func fetchMetadata(
        for book: LibraryBook,
        configuration: GalleryMetadataFetchConfiguration
    ) async throws -> LibraryBook {
        // 外部 metadata 先独立 upsert 到 gallery_metadata，再复制展示摘要到 library_books；
        // 这样可以保留原始 API 缓存，同时让列表查询无需 join 就能显示常用字段。
        guard book.databaseID != nil else {
            throw NyaEHError.bookHasNoID
        }

        let metadata = try await metadataFetchService.fetchMetadata(
            hash: book.hash,
            configuration: configuration
        )
        guard let id = book.databaseID, let current = try bookRepository.fetch(id: id), current.hash == book.hash, current.mtime == book.mtime,
              try deletionAllowsBookUpdates(id) else { throw LibraryDeletionError.bookUnavailable }
        try Task.checkCancellation()
        let savedMetadata = try metadataRepository.upsert(metadata)
        return try applyMetadata(savedMetadata, to: current)
    }

    @MainActor
    func fetchMetadata(
        for book: LibraryBook,
        galleryURL: URL,
        configuration: GalleryMetadataFetchConfiguration
    ) async throws -> LibraryBook {
        guard book.databaseID != nil else {
            throw NyaEHError.bookHasNoID
        }

        let metadata = try await metadataFetchService.fetchMetadata(
            hash: book.hash,
            galleryURL: galleryURL,
            configuration: configuration
        )
        guard let id = book.databaseID, let current = try bookRepository.fetch(id: id), current.hash == book.hash, current.mtime == book.mtime,
              try deletionAllowsBookUpdates(id) else { throw LibraryDeletionError.bookUnavailable }
        try Task.checkCancellation()
        let savedMetadata = try metadataRepository.upsert(metadata)
        return try applyMetadata(savedMetadata, to: current)
    }

    private func deletionAllowsBookUpdates(_ id: Int64) throws -> Bool {
        guard let operation = try (bookRepository as? any LibraryDeletionRepository)?.deletionOperation(bookID: id) else { return true }
        return operation.stage == "needsAttention"
    }

    @discardableResult
    func deleteBookAndSourceFile(_ book: LibraryBook, securityScopedRootURL: URL? = nil) throws -> LibraryDeletionResult {
        guard let bookID = book.databaseID,
              let deletion = bookRepository as? any LibraryDeletionRepository else { throw LibraryDeletionError.unavailable }
        let access = securityScopedRootURL?.startAccessingSecurityScopedResource() ?? false
        defer { if access { securityScopedRootURL?.stopAccessingSecurityScopedResource() } }
        var operation = try deletion.deletionOperation(bookID: bookID)
        if operation == nil {
            guard let current = try bookRepository.fetch(id: bookID) else { throw LibraryDeletionError.bookUnavailable }
            let identity = try sourceTrash.identity(at: URL(fileURLWithPath: current.filepath))
            operation = try deletion.prepareDeletion(bookID: bookID, identity: identity)
        }
        guard let operation else { throw LibraryDeletionError.unavailable }
        if operation.stage != "sourceHandled" && operation.stage != "cleanupPending" {
            do {
                let url = URL(fileURLWithPath: operation.sourcePath)
                let identity = try sourceTrash.identity(at: url)
                if let identity {
                    guard identity == operation.sourceIdentity else { throw LibraryDeletionError.sourceChanged }
                    try deletion.updateDeletion(bookID: bookID, stage: "moving", error: nil)
                    try sourceTrash.trash(url)
                }
                // Only explicit user retries may resolve an interrupted move with an absent source.
                try deletion.updateDeletion(bookID: bookID, stage: "sourceHandled", error: nil)
            } catch {
                try? deletion.updateDeletion(bookID: bookID, stage: "needsAttention", error: error.localizedDescription)
                throw error
            }
        }
        if operation.stage != "cleanupPending" {
            do { try deletion.commitDeletion(bookID: bookID) }
            catch {
                try? deletion.updateDeletion(bookID: bookID, stage: "sourceHandled", error: error.localizedDescription)
                throw LibraryDeletionError.commitPending
            }
        }
        let result = finishDeletionCleanup(operation, repository: deletion)
        try? backupService?.reconcile()
        return result
    }

    private func finishDeletionCleanup(_ operation: LibraryDeletionOperation, repository: any LibraryDeletionRepository) -> LibraryDeletionResult {
        do {
            try coverVectorRepository?.deleteVector(bookID: operation.bookID)
            if let semanticTitleVectorRepository {
                _ = try semanticTitleVectorRepository.pruneOrphanedVectors(existingBookIDs: Set(bookRepository.fetchAll().compactMap(\.databaseID)))
            }
            if let path = operation.coverPath, try !isCoverPathReferenced(path) {
                try coverCache?.removeCachedCover(path: path)
            }
            try repository.finishDeletion(bookID: operation.bookID)
            return .init(bookID: operation.bookID, cleanupWarning: nil)
        } catch {
            try? repository.updateDeletion(bookID: operation.bookID, stage: "cleanupPending", error: error.localizedDescription)
            return .init(bookID: operation.bookID, cleanupWarning: error.localizedDescription)
        }
    }

    private func isCoverPathReferenced(_ path: String) throws -> Bool {
        try bookRepository.fetchAll().contains { $0.coverPath == path }
    }

    func recoverLibraryDeletions() throws {
        guard let deletion = bookRepository as? any LibraryDeletionRepository else { return }
        for operation in try deletion.deletionOperations() {
            if operation.stage == "sourceHandled" {
                do {
                    try deletion.commitDeletion(bookID: operation.bookID)
                    _ = finishDeletionCleanup(operation, repository: deletion)
                } catch {
                    try deletion.updateDeletion(bookID: operation.bookID, stage: "sourceHandled", error: error.localizedDescription)
                }
            } else if operation.stage == "cleanupPending" {
                _ = finishDeletionCleanup(operation, repository: deletion)
            }
        }
    }

    func refreshFileStatus(for book: LibraryBook) throws {
        guard let id = book.databaseID else {
            throw NyaEHError.bookHasNoID
        }

        let result = fileStatusService.status(forFilepath: book.filepath)
        try bookRepository.updateStatus(bookID: id, status: result.status, exist: result.exist)
    }

    func recordRead(for book: LibraryBook) throws -> LibraryBook {
        guard let bookID = book.databaseID else {
            throw NyaEHError.bookHasNoID
        }

        return try bookRepository.incrementReadCount(bookID: bookID) ?? book
    }

    func setMarked(_ isMarked: Bool, for book: LibraryBook) throws -> LibraryBook {
        guard let bookID = book.databaseID else {
            throw NyaEHError.bookHasNoID
        }

        return try bookRepository.setMarked(isMarked, bookID: bookID)
    }

    func setUserHidden(_ isHidden: Bool, for book: LibraryBook) throws -> LibraryBook {
        guard let bookID = book.databaseID else {
            throw NyaEHError.bookHasNoID
        }
        return try bookRepository.setUserHidden(isHidden, bookID: bookID)
    }

    func createCollection(name: String) throws -> BookCollection {
        guard let collectionRepository else {
            throw NyaEHError.groupingRepositoryUnavailable
        }

        return try collectionRepository.insert(BookCollection(name: normalizedName(name)))
    }

    func renameCollection(_ collection: BookCollection, name: String) throws -> BookCollection {
        guard let collectionRepository else {
            throw NyaEHError.groupingRepositoryUnavailable
        }

        var updated = collection
        updated.name = normalizedName(name)
        return try collectionRepository.update(updated)
    }

    func deleteCollection(_ collection: BookCollection) throws {
        guard let collectionRepository, let collectionID = collection.databaseID else {
            throw NyaEHError.groupingRepositoryUnavailable
        }
        try collectionRepository.deleteAndDissolve(id: collectionID)
    }

    func addBook(_ book: LibraryBook, to collection: BookCollection) throws {
        guard let collectionID = collection.databaseID, let bookID = book.databaseID,
              let collectionRepository else {
            throw NyaEHError.groupingRepositoryUnavailable
        }
        try collectionRepository.addBookAndVersions(bookID: bookID, to: collectionID)
    }

    func acceptCreateCollectionRecommendation(
        _ recommendation: CollectionRecommendation,
        books: [LibraryBook],
        fallbackName: String
    ) throws -> BookCollection {
        // 合集推荐接受后才会修改 library_books.collection_id；
        // 推荐缓存本身只是辅助建议，不能在刷新阶段改变用户组织状态。
        guard let recommendationID = recommendation.databaseID,
              let collectionRecommendationMutationRepository else {
            throw NyaEHError.groupingRepositoryUnavailable
        }
        let targets = try books.flatMap(collectionTargets(for:))
        var seenTargetIDs = Set<LibraryBook.DatabaseID>()
        let targetIDs = try databaseIDs(for: targets).filter {
            seenTargetIDs.insert($0).inserted
        }
        let primaryBooks = books.filter(\.isPrimaryVersion)
        let orderedPrimaryBookIDs = automaticSeriesOrder(for: primaryBooks)
        return try collectionRecommendationMutationRepository.acceptCreateCollectionRecommendation(
            recommendationID: recommendationID,
            bookIDs: targetIDs,
            orderedPrimaryBookIDs: orderedPrimaryBookIDs,
            name: inferredCollectionName(for: books) ?? fallbackName
        )
    }

    func acceptAddToCollectionRecommendation(
        _ recommendation: CollectionRecommendation,
        book: LibraryBook,
        collection: BookCollection
    ) throws {
        guard let recommendationID = recommendation.databaseID,
              let collectionID = collection.databaseID,
              let collectionRecommendationMutationRepository else {
            throw NyaEHError.groupingRepositoryUnavailable
        }
        let targets = try collectionTargets(for: book)
        let existingPrimaryMembers = try bookRepository.fetchByCollectionID(collectionID)
            .filter(\.isPrimaryVersion)
            .sorted(by: collectionSort)
        let logicalMembers = existingPrimaryMembers.filter { $0.id != book.id } + [book]
        let insertAtStart = recommendation.reasons.contains("implicitFirstVolume")
            && SeriesTitleAnalysis(title: book.titleJpn ?? book.title)?.isCleanUnnumbered == true
        let fallbackOrder = insertAtStart
            ? [book] + existingPrimaryMembers.filter { $0.id != book.id }
            : logicalMembers
        try collectionRecommendationMutationRepository.acceptAddToCollectionRecommendation(
            recommendationID: recommendationID,
            bookIDs: try databaseIDs(for: targets),
            orderedPrimaryBookIDs: automaticSeriesOrder(
                for: logicalMembers,
                fallback: fallbackOrder
            ),
            collectionID: collectionID,
            insertAtStart: insertAtStart
        )
    }

    func removeBook(_ book: LibraryBook, from collection: BookCollection) throws {
        guard let collectionID = collection.databaseID, let bookID = book.databaseID,
              let collectionRepository else {
            throw NyaEHError.groupingRepositoryUnavailable
        }
        try collectionRepository.removeBookAndVersions(bookID: bookID, from: collectionID)
    }

    func moveBook(
        _ book: LibraryBook,
        in collection: BookCollection,
        direction: CollectionMoveDirection
    ) throws -> [LibraryBook] {
        guard let collectionID = collection.databaseID else {
            throw NyaEHError.groupingRepositoryUnavailable
        }

        var displayMembers = try bookRepository.fetchByCollectionID(collectionID)
            .filter { $0.isPrimaryVersion }
            .sorted(by: collectionSort)
        guard let index = displayMembers.firstIndex(where: { $0.id == book.id }),
              let bookID = book.databaseID else {
            return displayMembers
        }
        let targetIndex: Int
        switch direction {
        case .up:
            targetIndex = index - 1
        case .down:
            targetIndex = index + 1
        }
        guard displayMembers.indices.contains(targetIndex) else {
            return displayMembers
        }

        guard displayMembers.contains(where: { $0.databaseID == bookID }) else {
            return displayMembers
        }
        displayMembers.swapAt(index, targetIndex)
        return try replaceCollectionOrder(with: displayMembers, collectionID: collectionID)
    }

    func reorderBooks(_ orderedBooks: [LibraryBook], in collection: BookCollection) throws -> [LibraryBook] {
        guard let collectionID = collection.databaseID else {
            throw NyaEHError.groupingRepositoryUnavailable
        }

        let currentMembers = try bookRepository.fetchByCollectionID(collectionID)
            .filter { $0.isPrimaryVersion }
            .sorted(by: collectionSort)
        let currentIDs = Set(currentMembers.compactMap(\.databaseID))
        let orderedIDs = Set(orderedBooks.compactMap(\.databaseID))
        guard currentIDs == orderedIDs else {
            return currentMembers
        }
        return try replaceCollectionOrder(with: orderedBooks, collectionID: collectionID)
    }

    func autoSortBooks(in collection: BookCollection) throws -> [LibraryBook] {
        guard let collectionID = collection.databaseID else {
            throw NyaEHError.groupingRepositoryUnavailable
        }

        let currentMembers = try bookRepository.fetchByCollectionID(collectionID)
            .filter { $0.isPrimaryVersion }
            .sorted(by: collectionSort)
        guard let sortPlan = SeriesOrdinalResolver.sortPlan(
            for: currentMembers,
            policy: .confirmedCollection
        ) else {
            return currentMembers
        }
        let membersByID = Dictionary(uniqueKeysWithValues: currentMembers.compactMap { book in
            book.databaseID.map { ($0, book) }
        })
        let sortedMembers = sortPlan.orderedPrimaryBookIDs.compactMap { membersByID[$0] }

        return try replaceCollectionOrder(with: sortedMembers, collectionID: collectionID)
    }

    func createVersionGroup(with books: [LibraryBook]) throws -> BookVersionGroup {
        if let versionGroupMutationRepository {
            return try versionGroupMutationRepository.createVersionGroup(bookIDs: try databaseIDs(for: books))
        }
        guard let versionGroupRepository else {
            throw NyaEHError.groupingRepositoryUnavailable
        }

        let group = try versionGroupRepository.insert(BookVersionGroup())
        for (index, book) in books.enumerated() {
            try addBook(book, toVersionGroup: group, isPrimary: index == 0)
        }
        return group
    }

    func acceptCreateVersionGroupRecommendation(
        _ recommendation: VersionRecommendation,
        books: [LibraryBook]
    ) throws -> BookVersionGroup {
        // 版本组推荐接受必须走 mutation repository 的事务路径：
        // 创建/加入组、自动标签、组级收藏同步和推荐状态要么一起成功，要么一起回滚。
        guard let recommendationID = recommendation.databaseID,
              let versionGroupMutationRepository else {
            throw NyaEHError.groupingRepositoryUnavailable
        }
        let bookIDs = try databaseIDs(for: books)
        let automaticLabels = Dictionary(uniqueKeysWithValues: zip(bookIDs, books).map { bookID, book in
            (bookID, VersionLabelClassifier.labels(for: book))
        })
        return try versionGroupMutationRepository.acceptCreateVersionGroupRecommendation(
            recommendationID: recommendationID,
            bookIDs: bookIDs,
            automaticLabels: automaticLabels
        )
    }

    func acceptAddToVersionGroupRecommendation(
        _ recommendation: VersionRecommendation,
        book: LibraryBook,
        group: BookVersionGroup
    ) throws {
        guard let recommendationID = recommendation.databaseID,
              let bookID = book.databaseID,
              let groupID = group.databaseID,
              let versionGroupMutationRepository else {
            throw NyaEHError.groupingRepositoryUnavailable
        }
        try versionGroupMutationRepository.acceptAddToVersionGroupRecommendation(
            recommendationID: recommendationID,
            bookID: bookID,
            groupID: groupID,
            automaticLabels: VersionLabelClassifier.labels(for: book)
        )
    }

    func deleteVersionGroup(_ group: BookVersionGroup) throws {
        guard let groupID = group.databaseID,
              let versionGroupMutationRepository else {
            throw NyaEHError.groupingRepositoryUnavailable
        }
        try versionGroupMutationRepository.deleteVersionGroup(id: groupID)
    }

    func repairVersionGroupMarkedState() throws -> VersionGroupMarkedRepairResult {
        guard let versionGroupMutationRepository else {
            throw NyaEHError.groupingRepositoryUnavailable
        }
        return try versionGroupMutationRepository.repairVersionGroupMarkedState()
    }

    func addBook(_ book: LibraryBook, toVersionGroup group: BookVersionGroup, isPrimary: Bool = false) throws {
        guard let groupID = group.databaseID, let bookID = book.databaseID,
              let versionGroupMutationRepository else {
            throw NyaEHError.groupingRepositoryUnavailable
        }
        try versionGroupMutationRepository.addBook(bookID: bookID, to: groupID, isPrimary: isPrimary)
    }

    func addBooks(_ books: [LibraryBook], toVersionGroup group: BookVersionGroup) throws {
        guard let groupID = group.databaseID, let versionGroupMutationRepository else {
            throw NyaEHError.groupingRepositoryUnavailable
        }
        try versionGroupMutationRepository.addBooks(bookIDs: databaseIDs(for: books), to: groupID)
    }

    func removeBookFromVersionGroup(_ book: LibraryBook) throws {
        guard let bookID = book.databaseID, let versionGroupMutationRepository else {
            throw NyaEHError.groupingRepositoryUnavailable
        }
        try versionGroupMutationRepository.removeBook(bookID: bookID)
    }

    func setPrimaryVersion(_ book: LibraryBook) throws {
        guard let bookID = book.databaseID, let versionGroupMutationRepository else {
            throw NyaEHError.groupingRepositoryUnavailable
        }
        try versionGroupMutationRepository.setPrimary(bookID: bookID)
    }

    func setVersionLabel(_ label: String, for book: LibraryBook) throws {
        try setVersionLabels([label], for: book)
    }

    func setVersionLabels(_ labels: [String], for book: LibraryBook) throws {
        guard let bookID = book.databaseID, let versionGroupMutationRepository else {
            throw NyaEHError.groupingRepositoryUnavailable
        }
        try versionGroupMutationRepository.setLabels(labels, bookID: bookID)
    }

    func applyAutomaticVersionLabelsIfNeeded(to book: LibraryBook) throws {
        guard try loadVersionLabels(for: book).isEmpty else {
            return
        }
        try setVersionLabels(VersionLabelClassifier.labels(for: book), for: book)
    }

    func scanLibrary(
        rootURL: URL,
        progress: @escaping @Sendable (LibraryScanProgress) -> Void = { _ in },
        isCancelled: @escaping @Sendable () -> Bool = { false }
    ) throws -> LibraryScanResult {
        try TestRuntime.validateSourceRoot(rootURL)
        let result = try scannerService.scan(rootURL: rootURL, progress: progress, isCancelled: isCancelled)
        try? backupService?.reconcile()
        return result
    }

    func rescanCover(for book: LibraryBook) throws -> LibraryBook {
        // 重扫封面可能替换缓存文件；旧封面只有在没有其他书共用时才会清理。
        guard let bookID = book.databaseID else {
            throw NyaEHError.bookHasNoID
        }

        let oldCoverPath = book.coverPath
        let updatedBook = try scannerService.rescanBook(book)

        if let oldCoverPath,
           oldCoverPath != updatedBook.coverPath,
           try !isCoverPathShared(oldCoverPath, excludingBookID: bookID) {
            try coverCache?.removeCachedCover(path: oldCoverPath)
        }

        return updatedBook
    }

    func importExhentaiMangaManager(
        from folderURL: URL,
        progress: @escaping @Sendable (ExternalLibraryImportProgress) -> Void
    ) throws -> ExternalLibraryImportResult {
        guard let externalImportService else {
            throw NyaEHError.importUnavailable
        }
        return try externalImportService.importExhentaiMangaManager(from: folderURL, progress: progress)
    }

    func ensureTagIndex(for books: [LibraryBook]) throws -> Bool {
        guard let tagRepository else {
            return false
        }

        let expectedCount = books.reduce(0) { partialResult, book in
            guard book.databaseID != nil else {
                return partialResult
            }
            return partialResult + TagParser.parseJSON(book.tags).count
        }
        let indexedCount = try tagRepository.indexedBookTagCount()
        guard indexedCount != expectedCount else {
            return false
        }

        try tagRepository.rebuildAllTags(from: books)
        try? materializeCachedTagTranslations()
        return true
    }

    func tagSummaries(
        namespace: String,
        isTagTranslationEnabled: Bool
    ) throws -> [TagDisplaySummary] {
        guard let tagRepository else {
            throw NyaEHError.tagTranslationRepositoryUnavailable
        }

        let summaries = try tagRepository.summaries(
            namespace: namespace,
            languageCode: isTagTranslationEnabled ? EhTagTranslationCache.languageCode : nil
        )
        return try displaySummaries(from: summaries)
    }

    func topTagSummaries(
        namespaces: [String],
        limit: Int,
        isTagTranslationEnabled: Bool
    ) throws -> [TagDisplaySummary] {
        guard let tagRepository else {
            throw NyaEHError.tagTranslationRepositoryUnavailable
        }

        let summaries = try tagRepository.topSummaries(
            namespaces: namespaces,
            limit: limit,
            languageCode: isTagTranslationEnabled ? EhTagTranslationCache.languageCode : nil
        )
        return try displaySummaries(from: summaries)
    }

    func tagVisualProfile(tagID: Tag.DatabaseID) throws -> TagVisualProfile? {
        guard let tagVisualProfileRepository else {
            throw NyaEHError.tagVisualProfileRepositoryUnavailable
        }
        return try tagVisualProfileRepository.profile(tagID: tagID)
    }

    private func displaySummaries(from summaries: [TagSummary]) throws -> [TagDisplaySummary] {
        let profiles = try tagVisualProfileRepository?.profiles(tagIDs: summaries.map(\.id)) ?? [:]
        return summaries.map { summary in
            TagDisplaySummary(
                id: summary.id,
                namespace: summary.namespace,
                name: summary.name,
                rawValue: summary.rawValue,
                displayName: summary.translatedName ?? summary.name,
                translationIntro: summary.translationIntro,
                translationLinks: summary.translationLinks,
                isFollowed: summary.isFollowed,
                count: summary.count,
                visualProfile: profiles[summary.id]
            )
        }
    }

    func saveTagVisualProfile(_ profile: TagVisualProfile) throws -> TagVisualProfile {
        guard let tagVisualProfileRepository else {
            throw NyaEHError.tagVisualProfileRepositoryUnavailable
        }
        return try tagVisualProfileRepository.upsert(profile)
    }

    func storeTagForegroundImage(
        imageData: Data,
        tag: TagVisualAssetTarget
    ) throws -> StoredTagVisualAsset {
        guard let tagVisualAssetService else {
            throw NyaEHError.tagVisualProfileRepositoryUnavailable
        }
        return try tagVisualAssetService.storeForegroundImage(imageData: imageData, tag: tag)
    }

    func storeTagBackgroundImage(
        imageData: Data,
        tag: TagVisualAssetTarget
    ) throws -> StoredTagVisualAsset {
        guard let tagVisualAssetService else {
            throw NyaEHError.tagVisualProfileRepositoryUnavailable
        }
        return try tagVisualAssetService.storeBackgroundImage(imageData: imageData, tag: tag)
    }

    func tagVisualAssetURL(relativePath: String) throws -> URL {
        guard let tagVisualAssetService else {
            throw NyaEHError.tagVisualProfileRepositoryUnavailable
        }
        return tagVisualAssetService.resolvedURL(relativePath: relativePath)
    }

    func tagVisualHeroBlurAssetURL(relativeBackgroundPath: String) throws -> URL {
        guard let tagVisualAssetService else {
            throw NyaEHError.tagVisualProfileRepositoryUnavailable
        }
        return try tagVisualAssetService.heroBlurBackgroundURL(relativeBackgroundPath: relativeBackgroundPath)
    }

    func tagVisualBackgroundPalette(relativeBackgroundPath: String) throws -> TagVisualBackgroundPalette? {
        guard let tagVisualAssetService else {
            throw NyaEHError.tagVisualProfileRepositoryUnavailable
        }
        return try tagVisualAssetService.backgroundPalette(relativeBackgroundPath: relativeBackgroundPath)
    }

    func setFollowed(_ isFollowed: Bool, for tag: TagDisplaySummary) throws {
        guard let tagRepository else {
            throw NyaEHError.tagTranslationRepositoryUnavailable
        }

        try tagRepository.setFollowed(tagID: tag.id, isFollowed: isFollowed)
    }

    func displayTags(
        for book: LibraryBook,
        isTagTranslationEnabled: Bool
    ) throws -> [TagDisplaySummary] {
        let tags = try detailTags(for: book)
        guard let tagRepository else {
            return tags.enumerated().map { offset, tag in
                TagDisplaySummary(
                    id: Int64(offset + 1) * -1,
                    namespace: tag.namespace,
                    name: tag.name,
                    rawValue: tag.rawValue,
                    displayName: tag.name,
                    count: 1
                )
            }
        }

        let resolver = TagTranslationResolver(repository: tagRepository)
        let followedTagIDs = try tagRepository.followedTagIDs()
        return try tags.enumerated().map { offset, tag in
            let displayName = try resolver.resolvedName(
                for: tag,
                isEnabled: isTagTranslationEnabled
            )
            let translation = try resolver.resolvedTranslation(for: tag)
            return TagDisplaySummary(
                id: tag.id ?? Int64(offset + 1) * -1,
                namespace: tag.namespace,
                name: tag.name,
                rawValue: tag.rawValue,
                displayName: displayName,
                translationIntro: translation?.intro,
                translationLinks: translation?.links ?? [],
                isFollowed: tag.id.map { followedTagIDs.contains($0) } ?? false,
                count: 1
            )
        }
    }

    func candidateDisplayTags(
        for book: LibraryBook,
        isTagTranslationEnabled: Bool
    ) throws -> [TagDisplaySummary] {
        guard let tagRepository else {
            let parsedTags = candidateTags(for: book)
            return parsedTags.enumerated().map { offset, tag in
                candidateSummary(for: tag, offset: offset, displayName: tag.name)
            }
        }

        let tagIndex = Dictionary(
            try tagRepository.fetchAllTags().map { ($0.rawValue.lowercased(), $0) },
            uniquingKeysWith: { first, _ in first }
        )
        let resolver = TagTranslationResolver(repository: tagRepository)
        return try candidateDisplayTags(
            for: book,
            isTagTranslationEnabled: isTagTranslationEnabled,
            tagIndex: tagIndex,
            resolver: resolver
        )
    }

    func candidateDisplayTags(
        for books: [LibraryBook],
        isTagTranslationEnabled: Bool
    ) throws -> [LibraryBook.ID: [TagDisplaySummary]] {
        guard let tagRepository else {
            return Dictionary(uniqueKeysWithValues: books.map { book in
                let tags = candidateTags(for: book).enumerated().map { offset, tag in
                    candidateSummary(for: tag, offset: offset, displayName: tag.name)
                }
                return (book.id, tags)
            })
        }

        let tagIndex = Dictionary(
            try tagRepository.fetchAllTags().map { ($0.rawValue.lowercased(), $0) },
            uniquingKeysWith: { first, _ in first }
        )
        let resolver = TagTranslationResolver(repository: tagRepository)
        return try Dictionary(uniqueKeysWithValues: books.map { book in
            let tags = try candidateDisplayTags(
                for: book,
                isTagTranslationEnabled: isTagTranslationEnabled,
                tagIndex: tagIndex,
                resolver: resolver
            )
            return (book.id, tags)
        })
    }

    private func candidateDisplayTags(
        for book: LibraryBook,
        isTagTranslationEnabled: Bool,
        tagIndex: [String: Tag],
        resolver: TagTranslationResolver
    ) throws -> [TagDisplaySummary] {
        try candidateTags(for: book).enumerated().map { offset, parsedTag in
            let indexedTag = tagIndex[parsedTag.rawValue.lowercased()] ?? parsedTag
            let displayName = try resolver.resolvedName(
                for: indexedTag,
                isEnabled: isTagTranslationEnabled
            )
            return candidateSummary(for: indexedTag, offset: offset, displayName: displayName)
        }
    }

    private func candidateTags(for book: LibraryBook) -> [Tag] {
        TagParser.parseJSON(book.tags)
            .filter { Self.candidateTagNamespaces.contains($0.namespace.lowercased()) }
    }

    func cachedTagTranslationManifest() throws -> EhTagTranslationManifest? {
        try tagTranslationUpdateService?.cachedManifest()
    }

    func searchLibrary(_ request: LibrarySearchRequest) throws -> LibrarySearchResponse {
        guard let searchRepository else {
            throw NyaEHError.tagTranslationRepositoryUnavailable
        }
        return try searchRepository.search(request)
    }

    func searchTagFacets(
        _ request: LibrarySearchRequest,
        knownTotalCount: Int? = nil
    ) throws -> [SearchTagFacet] {
        guard let searchRepository else {
            throw NyaEHError.tagTranslationRepositoryUnavailable
        }
        return try searchRepository.tagFacets(request, knownTotalCount: knownTotalCount)
    }

    func searchTagSuggestions(_ request: SearchTagSuggestionRequest) throws -> [SearchTagSuggestion] {
        guard let searchRepository else {
            throw NyaEHError.tagTranslationRepositoryUnavailable
        }
        return try searchRepository.tagSuggestions(request)
    }

    @MainActor
    func updateTagTranslations(proxySettings: NetworkProxySettings = NetworkProxySettings()) async throws -> TagTranslationUpdateResult {
        guard let tagRepository, let tagTranslationUpdateService else {
            throw NyaEHError.tagTranslationRepositoryUnavailable
        }

        return try await tagTranslationUpdateService.update(repository: tagRepository, proxySettings: proxySettings)
    }

    private func materializeCachedTagTranslations() throws {
        guard let tagRepository, let tagTranslationUpdateService else {
            return
        }

        _ = try tagTranslationUpdateService.materializeCachedTranslations(repository: tagRepository)
    }

    private func databaseIDs(for books: [LibraryBook]) throws -> [LibraryBook.DatabaseID] {
        try books.map { book in
            guard let id = book.databaseID else {
                throw NyaEHError.bookHasNoID
            }
            return id
        }
    }

    private func isCoverPathShared(_ coverPath: String, excludingBookID bookID: LibraryBook.DatabaseID) throws -> Bool {
        try bookRepository.fetchAll().contains { book in
            book.databaseID != bookID && book.coverPath == coverPath
        }
    }

    private func applyMetadata(_ metadata: GalleryMetadata, to book: LibraryBook) throws -> LibraryBook {
        var updatedBook = book
        if let title = metadata.title, !title.isEmpty {
            updatedBook.title = title
        }
        updatedBook.titleJpn = metadata.titleJpn
        updatedBook.rating = metadata.rating
        updatedBook.tags = metadata.tags
        updatedBook.pages = metadata.pages
        updatedBook.posted = metadata.posted
        updatedBook.filesize = metadata.filesize
        updatedBook.category = metadata.category
        updatedBook.url = metadata.url
        updatedBook.status = .correct

        let savedBook = try bookRepository.updateMetadata(updatedBook)
        if let bookID = savedBook.databaseID {
            try tagRepository?.rebuildTags(forBookID: bookID, tagsJSON: savedBook.tags)
            try? materializeCachedTagTranslations()
            return try bookRepository.fetch(id: bookID) ?? savedBook
        }

        return savedBook
    }

    private func collectionTargets(for book: LibraryBook) throws -> [LibraryBook] {
        if let groupID = book.versionGroupID {
            return try bookRepository.fetchByVersionGroupID(groupID)
        }
        return [book]
    }

    private func collectionSort(_ lhs: LibraryBook, _ rhs: LibraryBook) -> Bool {
        let leftOrder = lhs.collectionOrder ?? Int.max
        let rightOrder = rhs.collectionOrder ?? Int.max
        if leftOrder == rightOrder {
            return lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
        }
        return leftOrder < rightOrder
    }

    private func replaceCollectionOrder(
        with orderedBooks: [LibraryBook],
        collectionID: BookCollection.DatabaseID
    ) throws -> [LibraryBook] {
        // 排序以主版本为逻辑成员；仓库会同步同版本组次版本的 order。
        let orderedIDs = orderedBooks.compactMap(\.databaseID)
        return try bookRepository.replaceCollectionOrder(bookIDs: orderedIDs, collectionID: collectionID)
            .filter { $0.isPrimaryVersion }
            .sorted(by: collectionSort)
    }

    private func automaticSeriesOrder(
        for primaryBooks: [LibraryBook],
        fallback: [LibraryBook]? = nil
    ) -> [LibraryBook.DatabaseID] {
        if let plan = SeriesOrdinalResolver.sortPlan(
            for: primaryBooks,
            policy: .confirmedCollection
        ) {
            return plan.orderedPrimaryBookIDs
        }
        return (fallback ?? primaryBooks).compactMap(\.databaseID)
    }

    private func normalizedName(_ name: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Untitled Collection" : trimmed
    }

    private func inferredCollectionName(for books: [LibraryBook]) -> String? {
        let titles = books.map { BookTitleFormatter.compactTitle($0.titleJpn ?? $0.title) }
            .filter { !$0.isEmpty }
        guard let first = titles.first else {
            return nil
        }
        let prefix = titles.dropFirst().reduce(first) { partial, title in
            String(partial.commonPrefix(with: title, options: [.caseInsensitive, .widthInsensitive]))
        }
        let cleaned = prefix
            .replacingOccurrences(of: #"[0-9０-９一二三四五六七八九十百零〇]+$"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? nil : cleaned
    }

    private static func fallbackTitle(for book: LibraryBook) -> String {
        let stem = URL(fileURLWithPath: book.filepath).deletingPathExtension().lastPathComponent
        let trimmed = stem.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Untitled Book" : trimmed
    }

    private func detailTags(for book: LibraryBook) throws -> [Tag] {
        let fallbackTags = TagParser.parseJSON(book.tags)
        guard let tagRepository else {
            return fallbackTags
        }

        if let bookID = book.databaseID {
            let indexedTags = try tagRepository.tags(forBookID: bookID)
            if !indexedTags.isEmpty {
                return indexedTags
            }
        }

        let tagIndex = Dictionary(
            try tagRepository.fetchAllTags().map { ($0.rawValue.lowercased(), $0) },
            uniquingKeysWith: { first, _ in first }
        )
        return fallbackTags.map { tagIndex[$0.rawValue.lowercased()] ?? $0 }
    }

    private static let candidateTagNamespaces: Set<String> = [
        "female",
        "male",
        "mixed",
        "location",
        "other"
    ]

    private func candidateSummary(
        for tag: Tag,
        offset: Int,
        displayName: String
    ) -> TagDisplaySummary {
        TagDisplaySummary(
            id: tag.id ?? Int64(offset + 1) * -1,
            namespace: tag.namespace,
            name: tag.name,
            rawValue: tag.rawValue,
            displayName: displayName,
            count: 1
        )
    }
}

enum CollectionMoveDirection: Sendable {
    case up
    case down
}
