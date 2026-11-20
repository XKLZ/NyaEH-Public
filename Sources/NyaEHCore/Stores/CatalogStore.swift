// 本文件维护共享书籍实体缓存与现有用例编排；Scene/视图通过 NyaEHAppModel 的领域 Store 依赖它。

import Foundation
import Observation

@MainActor
@Observable
final class CatalogStore: BookCardLibrary {
    // MARK: - 视图可观察状态

    // 这些集合是界面直接消费的快照。所有会改变数据库或文件系统的动作仍要走 service，
    // 然后通过 refresh()/局部重载回灌，避免视图层绕过业务规则直接改持久化状态。
    var books: [LibraryBook] = []
    var collections: [BookCollection] = []
    var versionGroups: [BookVersionGroup] = []
    var versionLabelSuggestions: [VersionLabelSuggestion] = []
    var readingStates: [LibraryBook.DatabaseID: BookReadingState] = [:]
    var createCollectionRecommendations: [CollectionRecommendationDisplayItem] = []
    var addToSelectedCollectionRecommendations: [CollectionRecommendationDisplayItem] = []
    var addToCollectionRecommendationCounts: [BookCollection.DatabaseID: Int] = [:]
    var collectionRecommendationLastUpdatedAt: Int64?
    var createVersionGroupRecommendations: [VersionRecommendationDisplayItem] = []
    var addToSelectedVersionGroupRecommendations: [VersionRecommendationDisplayItem] = []
    var addToVersionGroupRecommendationCounts: [BookVersionGroup.DatabaseID: Int] = [:]
    var versionRecommendationLastUpdatedAt: Int64?
    var isRefreshingVersionRecommendations = false
    var isAcceptingVersionRecommendation = false
    var isRefreshingCollectionRecommendations = false
    var isAcceptingCollectionRecommendation = false
    var collectionRecommendationRefreshProgress = CollectionRecommendationRefreshProgress.idle
    var collectionRecommendationMessage: String?
    var versionRecommendationRefreshProgress = VersionRecommendationRefreshProgress.idle
    var versionRecommendationMessage: String?
    var selectedBookID: LibraryBook.ID?
    var selectedCollectionID: BookCollection.ID?
    var selectedVersionGroupID: BookVersionGroup.ID?
    var searchText = "" {
        didSet {
            rebuildSearchDerivedCaches()
        }
    }
    var filter: LibraryFilter = .all {
        didSet {
            rebuildFilterDerivedCaches()
        }
    }
    var loadError: String?
    var scanSummary: String?
    var scanProgress = LibraryScanProgress(phase: "", completed: 0, total: 1)
    var isScanning = false
    var isFetchingMetadata = false
    var isDeletingBook = false
    var deletionCleanupWarning: String?
    private(set) var deletingBookIDs: Set<LibraryBook.DatabaseID> = []
    var isRescanningCover = false
    var isUpdatingTagTranslations = false
    var isImporting = false
    var isUpdatingCoverVectors = false
    var isUpdatingSemanticTitleVectors = false
    var isDownloadingSemanticTitleAssets = false
    var isGeneratingCoverDistanceReport = false
    var isRepairingVersionGroupMarkedState = false
    var isUpdatingWorkCharacterIndex = false
    var isManagingBackup = false
    var isRunningDataHealthCheck = false
    var metadataFetchMessage: String?
    var coverRescanMessage: String?
    var tagTranslationMessage: String?
    var coverVectorMessage: String?
    var semanticTitleVectorMessage: String?
    var versionGroupMarkedRepairMessage: String?
    var workCharacterIndexMessage: String?
    var backupMessage: String?
    var dataHealthReport: DataHealthReport?
    var lastTaskFailure: LibraryTaskFailure?
    var coverDistanceReport: String?
    var importProgress = ExternalLibraryImportProgress(phase: "", completed: 0, total: 1)
    var coverVectorProgress = CoverVectorIndexProgress.idle
    var coverVectorStats: CoverVectorIndexStats = .empty
    var semanticTitleVectorStats: SemanticTitleVectorIndexStats = .empty
    var semanticTitleVectorProgress = SemanticTitleVectorIndexProgress.idle
    var importSummary: String?
    var importBackupPath: String?
    var tagTranslationManifest: EhTagTranslationManifest?
    var homeInsightCharts = HomeInsightCharts.empty
    var isLoadingHomeInsightCharts = false
    var homeInsightChartError: String?
    var tagSummaryCache: [String: [TagDisplaySummary]] = [:]
    var tagSummaryErrors: [String: String] = [:]
    var loadingTagSummaryKeys: Set<String> = []
    var tagSummaryRevision = 0
    var workDetailCache: [Tag.DatabaseID: WorkDetail] = [:]
    var workDetailTranslationStates: [Tag.DatabaseID: Bool] = [:]
    var loadingWorkDetailIDs: Set<Tag.DatabaseID> = []
    var workDetailErrors: [Tag.DatabaseID: String] = [:]
    var workDetailRevision = 0
    var unconfirmedCharacterAssignmentWorkID: Tag.DatabaseID?
    var characterDetailCache: [Tag.DatabaseID: CharacterDetail] = [:]
    var characterDetailTranslationStates: [Tag.DatabaseID: Bool] = [:]
    var loadingCharacterDetailIDs: Set<Tag.DatabaseID> = []
    var characterDetailErrors: [Tag.DatabaseID: String] = [:]
    var characterDetailRevision = 0
    var metadataBatchProgress = MetadataBatchProgress()
    var importPipelineSnapshot = ImportPipelineSnapshot.empty
    var isProcessingImportPipeline = false
    var importPipelineMessage: String?
    var bootstrapError: String?
    var advancedSearchText = ""
    var advancedSearchMode: SearchMode = .exact
    var advancedSearchScope: BookSearchScope = .all
    var advancedSearchPage = 1
    var advancedSearchPageSize = 30
    var advancedSearchTotalCount = 0
    var advancedSearchShowsIndividualBooks = false
    var advancedSearchResultLayout: SearchResultLayout = .card
    var advancedSearchSortKey: SearchResultSortKey = .posted
    var advancedSearchSortDirection: SortDirection = .descending
    var favoriteManagementLayout: SearchResultLayout = .card
    var isAdvancedSearchRegexEnabled = false
    var isAdvancedSearchLoading = false
    var advancedSearchHits: [LibrarySearchHit] = []
    var advancedSearchResults: [LibraryBook] = []
    var advancedSearchDisplayItems: [SearchDisplayItem] = []
    var advancedSearchFacetsByNamespace: [String: [SearchTagFacet]] = [:]
    var advancedSearchParsedQuery = ParsedSearchQuery()
    var advancedSearchTagFacets: [SearchTagFacet] = []
    var advancedSearchSuggestions: [SearchTagSuggestion] = []
    var advancedSearchError: String?
    @ObservationIgnored private var lastSearchTranslationEnabled: Bool?
    @ObservationIgnored private var coverSearchMatches: [CoverImageSearchMatch] = []
    @ObservationIgnored private var coverSearchProvider: (@Sendable () throws -> Data)?
    @ObservationIgnored private var coverSearchLocalizer: AppLocalizer?
    var advancedSearchActiveTokenRange: NSRange?
    var isCoverImageSearchActive = false
    var isCoverImageSearchLoading = false
    var coverImageSearchFileName: String?
    var coverImageSearchMessage: String?
    var coverImageSearchNeedsIndexUpdate = false
    var derivedDataRevision = 0
    var collectionOrderRevision = 0
    var isSavingOrganization = false
    var savingOrganizationKeys: Set<String> = []
    var organizationSaveError: String?
    private(set) var searchedBooks: [LibraryBook] = []
    private(set) var displayItems: [LibraryDisplayItem] = []
    private(set) var recommendedBooks: [LibraryBook] = []
    private(set) var homeFavoritePreview = HomeFavoritePreview(favorites: [])
    var markedPreviewBooks: [LibraryBook] { Array(homeFavoritePreview.books) }
    private(set) var favoriteManagementBooks: [LibraryBook] = []
    private(set) var continueReadingBooks: [LibraryBook] = []
    private(set) var recentlyViewedBooks: [LibraryBook] = []
    private(set) var recentlyAddedBooks: [LibraryBook] = []
    private(set) var homeArrivalDays: [HomeArrivalDay] = []
    private(set) var filteredDisplayItems: [LibraryDisplayItem] = []
    private(set) var filteredBooks: [LibraryBook] = []

    // MARK: - 非观察任务与派生索引

    // Task、索引和缓存不应触发 SwiftUI 观察；它们只服务于异步取消、快速查找和列表渲染降本。
    private let service: BookLibraryService
    @ObservationIgnored private let organizationWorker: OrganizationMutationWorker
    @ObservationIgnored private var organizationTail: Task<Void, Never>?
    @ObservationIgnored private var organizationQueueRevision = 0
    @ObservationIgnored private var organizationPendingCounts: [String: Int] = [:]
    @ObservationIgnored private var pendingOrganizationMutations: [(UUID, OrganizationMutation, optimistic: Bool)] = []
    @ObservationIgnored private var pendingCollectionOrders: [BookCollection.DatabaseID: [LibraryBook]] = [:]
    @ObservationIgnored private var organizationProjectionTask: Task<Void, Never>?
    @ObservationIgnored private var organizationProjectionRevision = 0
    @ObservationIgnored private let organizationProjectionWorker = OrganizationProjectionWorker()
    @ObservationIgnored private let changeBus: LibraryChangeBus
    @ObservationIgnored private let sleep: @Sendable (UInt64) async throws -> Void
    @ObservationIgnored private var retiredMutationTasks: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored private var mutationTaskGenerations: [String: UUID] = [:]
    @ObservationIgnored private var scanTask: Task<Void, Never>?
    @ObservationIgnored private var importTask: Task<Void, Never>?
    @ObservationIgnored private var lastScanRootURL: URL?
    @ObservationIgnored private var lastImportFolderURL: URL?
    @ObservationIgnored private var manualMetadataTask: Task<LibraryBook, Error>?
    @ObservationIgnored private var metadataBatchTask: Task<Void, Never>?
    @ObservationIgnored private var importPipelineTask: Task<Void, Never>?
    @ObservationIgnored private var importPipelineUsesSemanticSeries = false
    @ObservationIgnored private var didRecoverImportPipeline = false
    @ObservationIgnored private var metadataBatchQueue: [LibraryBook] = []
    @ObservationIgnored private var metadataBatchIndex = 0
    @ObservationIgnored private var metadataBatchConfiguration: MetadataBatchConfiguration?
    @ObservationIgnored private var metadataBatchDidUpdateMetadata = false
    @ObservationIgnored private var metadataBatchLocalizer: AppLocalizer?
    @ObservationIgnored private var metadataBatchTitleDisplayMode: BookTitleDisplayMode = .originalTitle
    @ObservationIgnored private var advancedSearchTask: Task<Void, Never>?
    @ObservationIgnored private var advancedSearchRevision = 0
    @ObservationIgnored private var advancedSearchFacetTask: Task<Void, Never>?
    @ObservationIgnored private var advancedSearchFacetRevision = 0
    @ObservationIgnored private var advancedSearchFacetCache: [SearchFacetCacheKey: [SearchTagFacet]] = [:]
    @ObservationIgnored private var advancedSearchSuggestionTask: Task<Void, Never>?
    @ObservationIgnored private var advancedSearchSuggestionRevision = 0
    @ObservationIgnored private var coverImageSearchTask: Task<Void, Never>?
    @ObservationIgnored private var coverImageSearchRevision = 0
    @ObservationIgnored private var coverImageSearchQueryData: Data?
    @ObservationIgnored private var collectionRecommendationRefreshTask: Task<Void, Never>?
    @ObservationIgnored private var versionRecommendationRefreshTask: Task<Void, Never>?
    @ObservationIgnored private var selectedCollectionRecommendationTask: Task<Void, Never>?
    @ObservationIgnored private var selectedVersionRecommendationTask: Task<Void, Never>?
    @ObservationIgnored private var collectionOrderCommitTasks: [BookCollection.DatabaseID: Task<Void, Never>] = [:]
    @ObservationIgnored private var collectionOrderCommitRevisions: [BookCollection.DatabaseID: Int] = [:]
    @ObservationIgnored private var coverVectorIndexTask: Task<Void, Never>?
    @ObservationIgnored private var semanticTitleVectorIndexTask: Task<Void, Never>?
    @ObservationIgnored private var coverDistanceReportTask: Task<Void, Never>?
    @ObservationIgnored private var workCharacterIndexTask: Task<Void, Never>?
    @ObservationIgnored private var workDetailLoadTasks: [Tag.DatabaseID: Task<Void, Never>] = [:]
    @ObservationIgnored private var characterDetailLoadTasks: [Tag.DatabaseID: Task<Void, Never>] = [:]
    @ObservationIgnored private var readingProgressTasks: [LibraryBook.DatabaseID: Task<Void, Never>] = [:]
    @ObservationIgnored private var pendingReadingProgress: [LibraryBook.DatabaseID: PendingReadingProgress] = [:]
    @ObservationIgnored private var readingProgressRevisions: [LibraryBook.DatabaseID: Int] = [:]
    @ObservationIgnored private var bookIndex: [LibraryBook.ID: LibraryBook] = [:]
    @ObservationIgnored private var bookPositions: [LibraryBook.ID: Int] = [:]
    @ObservationIgnored private var collectionIndex: [BookCollection.ID: BookCollection] = [:]
    @ObservationIgnored private var versionGroupIndex: [BookVersionGroup.ID: BookVersionGroup] = [:]
    @ObservationIgnored private var booksByCollectionID: [BookCollection.DatabaseID: [LibraryBook]] = [:]
    @ObservationIgnored private var displayBooksByCollectionID: [BookCollection.DatabaseID: [LibraryBook]] = [:]
    @ObservationIgnored private var booksByVersionGroupID: [BookVersionGroup.DatabaseID: [LibraryBook]] = [:]
    @ObservationIgnored private var collectionCandidateBaseBooks: [LibraryBook] = []
    @ObservationIgnored private var versionCandidateBaseBooks: [LibraryBook] = []
    @ObservationIgnored private var candidateDisplayTagCache: [CandidateDisplayTagCacheKey: [TagDisplaySummary]] = [:]
    @ObservationIgnored private var homeInsightChartCache: [Bool: HomeInsightCharts] = [:]

    init(
        service: BookLibraryService,
        changeBus: LibraryChangeBus = LibraryChangeBus(),
        organizationBeforeExecute: @escaping @Sendable () async -> Void = {},
        sleep: @escaping @Sendable (UInt64) async throws -> Void = { nanoseconds in
            try await Task.sleep(nanoseconds: nanoseconds)
        }
    ) {
        self.service = service
        organizationWorker = OrganizationMutationWorker(service: service, beforeExecute: organizationBeforeExecute)
        self.changeBus = changeBus
        self.sleep = sleep
    }

    // MARK: - 依赖装配

    // 生产装配集中在这里，测试可直接注入轻量 repository/service，避免把 SQLite 细节扩散到视图。
    static func bootstrap(changeBus: LibraryChangeBus = LibraryChangeBus()) -> CatalogStore {
        do {
            let database = try DatabaseManager.appDefault()
            let bookRepository = SQLiteLibraryBookRepository(dbQueue: database.dbQueue)
            let metadataRepository = SQLiteGalleryMetadataRepository(dbQueue: database.dbQueue)
            let tagRepository = SQLiteTagRepository(dbQueue: database.dbQueue)
            let searchRepository = SQLiteLibrarySearchRepository(dbQueue: database.dbQueue)
            let collectionRepository = SQLiteCollectionRepository(dbQueue: database.dbQueue)
            let versionGroupRepository = SQLiteVersionGroupRepository(dbQueue: database.dbQueue)
            let versionLabelSuggestionRepository = SQLiteVersionLabelSuggestionRepository(dbQueue: database.dbQueue)
            let bookVersionLabelRepository = SQLiteBookVersionLabelRepository(dbQueue: database.dbQueue)
            let readingStateRepository = SQLiteBookReadingStateRepository(dbQueue: database.dbQueue)
            let versionRecommendationRepository = SQLiteVersionRecommendationRepository(dbQueue: database.dbQueue)
            let collectionRecommendationRepository = SQLiteCollectionRecommendationRepository(dbQueue: database.dbQueue)
            let importPipelineRepository = SQLiteImportPipelineRepository(dbQueue: database.dbQueue)
            let workCharacterRepository = SQLiteWorkCharacterRepository(dbQueue: database.dbQueue)
            let workDetailRepository = SQLiteWorkDetailRepository(dbQueue: database.dbQueue)
            let tagVisualProfileRepository = SQLiteTagVisualProfileRepository(dbQueue: database.dbQueue)
            let tagVisualAssetService = try TagVisualAssetService.appDefault()
            let coverVectorRepository = try? SQLiteCoverVectorRepository.appDefault()
            let semanticTitleVectorRepository = try? SQLiteSemanticTitleVectorRepository.appDefault()
            let backupService = LibraryBackupService(
                databaseManager: database,
                appDataURL: try AppDataDirectory.rootURL(),
                coverVectorRepository: coverVectorRepository,
                semanticTitleVectorRepository: semanticTitleVectorRepository
            )
            let externalImportService = ExternalLibraryImportService(dbQueue: database.dbQueue, backups: backupService)
            return CatalogStore(
                service: BookLibraryService(
                    bookRepository: bookRepository,
                    metadataRepository: metadataRepository,
                    tagRepository: tagRepository,
                    searchRepository: searchRepository,
                    collectionRepository: collectionRepository,
                    versionGroupRepository: versionGroupRepository,
                    versionGroupMutationRepository: versionGroupRepository,
                    versionLabelSuggestionRepository: versionLabelSuggestionRepository,
                    bookVersionLabelRepository: bookVersionLabelRepository,
                    readingStateRepository: readingStateRepository,
                    versionRecommendationRepository: versionRecommendationRepository,
                    collectionRecommendationRepository: collectionRecommendationRepository,
                    importPipelineRepository: importPipelineRepository,
                    workCharacterRepository: workCharacterRepository,
                    workDetailRepository: workDetailRepository,
                    tagVisualProfileRepository: tagVisualProfileRepository,
                    tagVisualAssetService: tagVisualAssetService,
                    coverVectorRepository: coverVectorRepository,
                    semanticTitleVectorRepository: semanticTitleVectorRepository,
                    databaseManager: database,
                    backupService: backupService,
                    externalImportService: externalImportService
                ),
                changeBus: changeBus
            )
        } catch {
            let store = CatalogStore(
                service: BookLibraryService(
                    bookRepository: InMemoryLibraryBookRepository(),
                    metadataRepository: InMemoryGalleryMetadataRepository()
                ),
                changeBus: changeBus
            )
            store.bootstrapError = "Database initialization failed: \(error.localizedDescription)"
            store.loadError = store.bootstrapError
            return store
        }
    }

    var selectedBook: LibraryBook? {
        books.first { $0.id == selectedBookID }
    }

    func libraryPageItems(page: Int, pageSize: Int) -> [LibraryDisplayItem] {
        Pagination.pageItems(displayItems, page: page, pageSize: pageSize)
    }

    func libraryPageCount(pageSize: Int) -> Int {
        Pagination.pageCount(itemCount: displayItems.count, pageSize: pageSize)
    }

    func book(id: LibraryBook.ID) -> LibraryBook? {
        bookIndex[id]
    }

    func collection(id: BookCollection.ID) -> BookCollection? {
        collectionIndex[id]
    }

    func versionGroup(id: BookVersionGroup.ID) -> BookVersionGroup? {
        versionGroupIndex[id]
    }

    func books(in collection: BookCollection) -> [LibraryBook] {
        guard let collectionID = collection.databaseID else {
            return []
        }
        return booksByCollectionID[collectionID] ?? []
    }

    func displayBooks(in collection: BookCollection) -> [LibraryBook] {
        guard let collectionID = collection.databaseID else {
            return []
        }
        return displayBooksByCollectionID[collectionID] ?? []
    }

    func books(inVersionGroup group: BookVersionGroup) -> [LibraryBook] {
        guard let groupID = group.databaseID else {
            return []
        }
        return booksByVersionGroupID[groupID] ?? []
    }

    func collectionCompanions(for book: LibraryBook) -> [LibraryBook] {
        guard let collectionID = book.collectionID else {
            return []
        }
        return (displayBooksByCollectionID[collectionID] ?? [])
            .filter { companion in
                if let groupID = book.versionGroupID {
                    return companion.versionGroupID != groupID
                }
                return companion.id != book.id
            }
    }

    func bookForCard(_ book: LibraryBook) -> LibraryBook {
        // Targeted mutations refresh the identity index before this observation is delivered.
        _ = books
        return bookIndex[book.id] ?? book
    }

    func cardVersionAlternatives(to book: LibraryBook, showsUserHidden: Bool) -> [LibraryBook] {
        guard book.versionGroupID != nil else { return [] }
        _ = derivedDataRevision
        _ = books
        let companions = versionCompanions(for: book).compactMap { bookIndex[$0.id] }
        return BookCardVersionChoices.alternatives(to: book, among: companions, showsUserHidden: showsUserHidden)
    }

    func versionCompanions(for book: LibraryBook) -> [LibraryBook] {
        guard let groupID = book.versionGroupID else {
            return []
        }
        return (booksByVersionGroupID[groupID] ?? [])
            .filter { $0.id != book.id }
    }

    func detailCollectionRelatedBooks(for book: LibraryBook) -> [LibraryBook] {
        guard let collectionID = book.collectionID else {
            return []
        }
        let collectionBooks = displayBooksByCollectionID[collectionID] ?? []
        guard let groupID = book.versionGroupID else {
            if collectionBooks.contains(where: { $0.id == book.id }) {
                return collectionBooks
            }
            return [book] + collectionBooks
        }

        var hasInsertedCurrent = false
        var relatedBooks: [LibraryBook] = []
        for candidate in collectionBooks {
            if candidate.id == book.id {
                relatedBooks.append(book)
                hasInsertedCurrent = true
            } else if candidate.versionGroupID == groupID {
                if !hasInsertedCurrent {
                    relatedBooks.append(book)
                    hasInsertedCurrent = true
                }
            } else {
                relatedBooks.append(candidate)
            }
        }

        if !hasInsertedCurrent {
            relatedBooks.insert(book, at: 0)
        }
        return relatedBooks
    }

    func detailVersionRelatedBooks(for book: LibraryBook) -> [LibraryBook] {
        guard let groupID = book.versionGroupID else {
            return []
        }
        let versionBooks = booksByVersionGroupID[groupID] ?? []
        if versionBooks.contains(where: { $0.id == book.id }) {
            return versionBooks
        }
        return [book] + versionBooks
    }

    func displayTags(
        for book: LibraryBook,
        isTagTranslationEnabled: Bool
    ) -> [TagDisplaySummary] {
        do {
            let tags = try service.displayTags(
                for: book,
                isTagTranslationEnabled: isTagTranslationEnabled
            )
            loadError = nil
            return tags
        } catch {
            loadError = error.localizedDescription
            return []
        }
    }

    func candidateDisplayTags(
        for book: LibraryBook,
        isTagTranslationEnabled: Bool
    ) -> [TagDisplaySummary] {
        let cacheKey = CandidateDisplayTagCacheKey(
            bookID: book.id,
            isTagTranslationEnabled: isTagTranslationEnabled,
            revision: tagSummaryRevision
        )
        if let cached = candidateDisplayTagCache[cacheKey] {
            return cached
        }

        do {
            let tags = try service.candidateDisplayTags(
                for: book,
                isTagTranslationEnabled: isTagTranslationEnabled
            )
            candidateDisplayTagCache[cacheKey] = tags
            return tags
        } catch {
            let tags = TagParser.parseJSON(book.tags)
                .enumerated()
                .filter { Self.candidateTagNamespaces.contains($0.element.namespace.lowercased()) }
                .map { offset, tag in
                    TagDisplaySummary(
                        id: tag.id ?? Int64(offset + 1) * -1,
                        namespace: tag.namespace,
                        name: tag.name,
                        rawValue: tag.rawValue,
                        displayName: tag.name,
                        count: 1
                    )
                }
            candidateDisplayTagCache[cacheKey] = tags
            return tags
        }
    }

    func searchResultTags(for book: LibraryBook, isTagTranslationEnabled: Bool) async -> [TagDisplaySummary] {
        let service = service
        return (try? await Task.detached(priority: .utility) {
            try Task.checkCancellation()
            return try service.displayTags(for: book, isTagTranslationEnabled: isTagTranslationEnabled)
        }.cancellableValue) ?? []
    }

    func prepareCandidateDisplayData(
        for books: [LibraryBook],
        isTagTranslationEnabled: Bool
    ) {
        let missingBooks = books.filter { book in
            let cacheKey = CandidateDisplayTagCacheKey(
                bookID: book.id,
                isTagTranslationEnabled: isTagTranslationEnabled,
                revision: tagSummaryRevision
            )
            return candidateDisplayTagCache[cacheKey] == nil
        }
        guard !missingBooks.isEmpty else {
            return
        }

        do {
            let summaries = try service.candidateDisplayTags(
                for: missingBooks,
                isTagTranslationEnabled: isTagTranslationEnabled
            )
            for book in missingBooks {
                let cacheKey = CandidateDisplayTagCacheKey(
                    bookID: book.id,
                    isTagTranslationEnabled: isTagTranslationEnabled,
                    revision: tagSummaryRevision
                )
                candidateDisplayTagCache[cacheKey] = summaries[book.id] ?? []
            }
        } catch {
            for book in missingBooks {
                let cacheKey = CandidateDisplayTagCacheKey(
                    bookID: book.id,
                    isTagTranslationEnabled: isTagTranslationEnabled,
                    revision: tagSummaryRevision
                )
                candidateDisplayTagCache[cacheKey] = TagParser.parseJSON(book.tags)
                    .enumerated()
                    .filter { Self.candidateTagNamespaces.contains($0.element.namespace.lowercased()) }
                    .map { offset, tag in
                        TagDisplaySummary(
                            id: tag.id ?? Int64(offset + 1) * -1,
                            namespace: tag.namespace,
                            name: tag.name,
                            rawValue: tag.rawValue,
                            displayName: tag.name,
                            count: 1
                        )
                    }
            }
        }
    }

    func tagSummaries(
        for category: TagCategory,
        isTagTranslationEnabled: Bool
    ) -> [TagDisplaySummary] {
        category.namespaces.flatMap { namespace in
            tagSummaries(namespace: namespace, isTagTranslationEnabled: isTagTranslationEnabled)
        }
    }

    func tagSummaries(
        for tab: TagCategoryTab,
        isTagTranslationEnabled: Bool
    ) -> [TagDisplaySummary] {
        tagSummaries(namespace: tab.namespace, isTagTranslationEnabled: isTagTranslationEnabled)
    }

    func tagSummaries(
        for group: TagNamespaceGroup,
        isTagTranslationEnabled: Bool
    ) -> [TagDisplaySummary] {
        tagSummaries(namespace: group.namespace, isTagTranslationEnabled: isTagTranslationEnabled)
    }

    func loadHomeInsightCharts(
        isTagTranslationEnabled: Bool,
        forceReload: Bool = false
    ) {
        if forceReload {
            homeInsightChartCache[isTagTranslationEnabled] = nil
        }

        if let cached = homeInsightChartCache[isTagTranslationEnabled] {
            homeInsightCharts = cached
            homeInsightChartError = nil
            return
        }

        guard !isLoadingHomeInsightCharts else {
            return
        }

        isLoadingHomeInsightCharts = true
        defer {
            isLoadingHomeInsightCharts = false
        }

        do {
            var charts = HomeInsightCharts.empty
            for kind in HomeInsightChartKind.allCases {
                charts[kind] = try service.topTagSummaries(
                    namespaces: kind.namespaces,
                    limit: 20,
                    isTagTranslationEnabled: isTagTranslationEnabled
                )
            }
            homeInsightChartCache[isTagTranslationEnabled] = charts
            homeInsightCharts = charts
            homeInsightChartError = nil
            loadError = nil
        } catch {
            homeInsightChartError = error.localizedDescription
            loadError = error.localizedDescription
        }
    }

    func tagSummaryError(
        for category: TagCategory,
        isTagTranslationEnabled: Bool
    ) -> String? {
        category.namespaces
            .compactMap { namespace in
                tagSummaryErrors[tagSummaryCacheKey(namespace: namespace, isTagTranslationEnabled: isTagTranslationEnabled)]
            }
            .first
    }

    func isLoadingTagSummaries(
        for category: TagCategory,
        isTagTranslationEnabled: Bool
    ) -> Bool {
        category.namespaces.contains { namespace in
            loadingTagSummaryKeys.contains(
                tagSummaryCacheKey(namespace: namespace, isTagTranslationEnabled: isTagTranslationEnabled)
            )
        }
    }

    func loadTagSummaries(
        for category: TagCategory,
        isTagTranslationEnabled: Bool
    ) {
        loadTagSummaries(
            for: category,
            isTagTranslationEnabled: isTagTranslationEnabled,
            forceReload: false
        )
    }

    func reloadTagSummaries(
        for category: TagCategory,
        isTagTranslationEnabled: Bool
    ) {
        loadTagSummaries(
            for: category,
            isTagTranslationEnabled: isTagTranslationEnabled,
            forceReload: true
        )
    }

    func refreshAdvancedSearch(isTagTranslationEnabled: Bool) {
        submitAdvancedSearch(isTagTranslationEnabled: isTagTranslationEnabled)
    }

    // MARK: - 强搜索

    // 草稿解析留在主线程，真正的 SQL 查询和 facet 统计在 detached task 中执行；
    // revision 用来丢弃慢请求，防止旧结果覆盖用户刚提交的新查询。
    func updateAdvancedSearchDraft() {
        advancedSearchParsedQuery = SearchQueryParser.parse(advancedSearchText)
        advancedSearchSuggestions = []
    }

    func refreshAdvancedSearchSuggestionsAsync(isTagTranslationEnabled: Bool) {
        advancedSearchSuggestionTask?.cancel()
        advancedSearchSuggestionRevision += 1
        let revision = advancedSearchSuggestionRevision
        guard let suggestionRequest = advancedSearchSuggestionRequest(isTagTranslationEnabled: isTagTranslationEnabled) else {
            advancedSearchSuggestions = []
            return
        }
        let service = service

        advancedSearchSuggestionTask = Task(priority: .userInitiated) { [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(180))
                let suggestions = try await Task.detached(priority: .userInitiated) {
                    try service.searchTagSuggestions(suggestionRequest)
                }.cancellableValue
                guard !Task.isCancelled else {
                    return
                }
                await MainActor.run {
                    guard let self, revision == self.advancedSearchSuggestionRevision else {
                        return
                    }
                    self.advancedSearchSuggestions = suggestions
                }
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled else {
                    return
                }
                await MainActor.run {
                    guard let self, revision == self.advancedSearchSuggestionRevision else {
                        return
                    }
                    self.advancedSearchSuggestions = []
                }
            }
        }
    }

    func submitAdvancedSearch(isTagTranslationEnabled: Bool) {
        lastSearchTranslationEnabled = isTagTranslationEnabled
        deactivateCoverImageSearch()
        advancedSearchTask?.cancel()
        advancedSearchFacetTask?.cancel()
        advancedSearchRevision += 1
        let revision = advancedSearchRevision
        let request = advancedSearchRequest(isTagTranslationEnabled: isTagTranslationEnabled)
        let suggestionRequest = advancedSearchSuggestionRequest(isTagTranslationEnabled: isTagTranslationEnabled)
        let service = service
        isAdvancedSearchLoading = true

        advancedSearchTask = Task(priority: .userInitiated) { [weak self] in
            do {
                let result = try await Task.detached(priority: .userInitiated) {
                    let response = try service.searchLibrary(request)
                    let suggestions: [SearchTagSuggestion]
                    if let suggestionRequest {
                        suggestions = try service.searchTagSuggestions(suggestionRequest)
                    } else {
                        suggestions = []
                    }
                    return (response, suggestions)
                }.cancellableValue

                guard !Task.isCancelled else {
                    return
                }
                await MainActor.run {
                    guard let self, revision == self.advancedSearchRevision else {
                        return
                    }
                    self.applyAdvancedSearchResult(response: result.0, suggestions: result.1)
                    self.loadAdvancedSearchFacets(
                        request: request,
                        knownTotalCount: result.0.totalCount,
                        searchRevision: revision
                    )
                }
            } catch {
                guard !Task.isCancelled else {
                    return
                }
                await MainActor.run {
                    guard let self, revision == self.advancedSearchRevision else {
                        return
                    }
                    self.isAdvancedSearchLoading = false
                    self.advancedSearchError = error.localizedDescription
                    self.loadError = error.localizedDescription
                }
            }
        }
    }

    func cancelAdvancedSearch() {
        advancedSearchTask?.cancel()
        advancedSearchFacetTask?.cancel()
        advancedSearchSuggestionTask?.cancel()
        advancedSearchTask = nil
        advancedSearchFacetTask = nil
        advancedSearchSuggestionTask = nil
        isAdvancedSearchLoading = false
        coverImageSearchTask?.cancel()
        coverImageSearchTask = nil
        isCoverImageSearchLoading = false
    }

    func searchByCoverImage(at imageURL: URL, localizer: AppLocalizer) {
        runCoverImageSearch(fileName: imageURL.lastPathComponent, localizer: localizer) {
            let didAccess = imageURL.startAccessingSecurityScopedResource()
            defer {
                if didAccess {
                    imageURL.stopAccessingSecurityScopedResource()
                }
            }
            return try Data(contentsOf: imageURL, options: .mappedIfSafe)
        }
    }

    func searchByCoverImage(data: Data, fileName: String, localizer: AppLocalizer) {
        runCoverImageSearch(fileName: fileName, localizer: localizer) {
            data
        }
    }

    func clearCoverImageSearch(isTagTranslationEnabled: Bool) {
        deactivateCoverImageSearch()
        advancedSearchPage = 1
        submitAdvancedSearch(isTagTranslationEnabled: isTagTranslationEnabled)
    }

    func updateCoverImageSearchIndex(localizer: AppLocalizer) {
        updateMissingCoverVectors(localizer: localizer) { [weak self] succeeded in
            guard succeeded, let self,
                  self.isCoverImageSearchActive,
                  let data = self.coverImageSearchQueryData,
                  let fileName = self.coverImageSearchFileName else {
                return
            }
            self.runCoverImageSearch(fileName: fileName, localizer: localizer) {
                data
            }
        }
    }

    private func runCoverImageSearch(
        fileName: String,
        localizer: AppLocalizer,
        dataProvider: @escaping @Sendable () throws -> Data
    ) {
        coverSearchProvider = dataProvider
        coverSearchLocalizer = localizer
        advancedSearchTask?.cancel()
        advancedSearchFacetTask?.cancel()
        advancedSearchSuggestionTask?.cancel()
        coverImageSearchTask?.cancel()
        coverImageSearchRevision += 1
        let revision = coverImageSearchRevision
        let service = service

        coverSearchMatches = []
        isCoverImageSearchActive = true
        isCoverImageSearchLoading = true
        isAdvancedSearchLoading = false
        coverImageSearchFileName = fileName
        coverImageSearchMessage = nil
        coverImageSearchNeedsIndexUpdate = false
        advancedSearchError = nil
        advancedSearchPage = 1
        advancedSearchSuggestions = []

        coverImageSearchTask = Task(priority: .userInitiated) { [weak self] in
            do {
                let result = try await Task.detached(priority: .userInitiated) {
                    let data = try dataProvider()
                    let stats = try service.coverVectorStats()
                    let matches: [CoverImageSearchMatch]
                    if stats.vectorCount == 0 || stats.staleCount > 0 {
                        matches = []
                    } else {
                        matches = try service.searchByCoverImage(data: data)
                    }
                    return (data, stats, matches)
                }.cancellableValue
                guard !Task.isCancelled else {
                    return
                }
                await MainActor.run {
                    guard let self, revision == self.coverImageSearchRevision else {
                        return
                    }
                    self.coverImageSearchQueryData = result.0
                    self.coverVectorStats = result.1
                    self.isCoverImageSearchLoading = false
                    self.coverImageSearchTask = nil

                    if result.1.vectorCount == 0 || result.1.staleCount > 0 {
                        self.coverImageSearchNeedsIndexUpdate = true
                        self.coverImageSearchMessage = localizer.string(.coverImageSearchIndexRequired)
                        self.applyCoverImageSearchMatches([])
                    } else {
                        self.coverImageSearchNeedsIndexUpdate = false
                        self.applyCoverImageSearchMatches(result.2)
                        if result.1.missingCount > 0 || result.1.failureCount > 0 {
                            self.coverImageSearchMessage = String(
                                format: localizer.string(.coverImageSearchPartialIndex),
                                result.1.vectorCount,
                                result.1.totalBooksWithCovers
                            )
                        } else if result.2.isEmpty {
                            self.coverImageSearchMessage = localizer.string(.coverImageSearchNoMatches)
                        } else {
                            self.coverImageSearchMessage = nil
                        }
                    }
                }
            } catch {
                guard !Task.isCancelled else {
                    return
                }
                await MainActor.run {
                    guard let self, revision == self.coverImageSearchRevision else {
                        return
                    }
                    self.isCoverImageSearchLoading = false
                    self.coverImageSearchTask = nil
                    self.coverImageSearchMessage = error.localizedDescription
                    self.applyCoverImageSearchMatches([])
                }
            }
        }
    }

    func reprojectCoverImageSearchResults() {
        applyCoverImageSearchMatches(coverSearchMatches)
    }

    private func applyCoverImageSearchMatches(_ matches: [CoverImageSearchMatch]) {
        coverSearchMatches = matches
        advancedSearchHits = Self.coverImageSearchHits(matches, showsIndividualBooks: advancedSearchShowsIndividualBooks)
        advancedSearchResults = advancedSearchHits.map(\.representativeBook)
        advancedSearchDisplayItems = makeAdvancedSearchDisplayItems(from: advancedSearchHits)
        advancedSearchTotalCount = advancedSearchDisplayItems.count
        advancedSearchParsedQuery = ParsedSearchQuery()
        advancedSearchTagFacets = []
        advancedSearchFacetsByNamespace = [:]
        advancedSearchSuggestions = []
        advancedSearchError = nil
        loadError = nil
    }

    nonisolated static func coverImageSearchHits(
        _ matches: [CoverImageSearchMatch],
        showsIndividualBooks: Bool
    ) -> [LibrarySearchHit] {
        var grouped: [LibrarySearchEntityKey: CoverImageSearchEntityAccumulator] = [:]
        for match in matches {
            let entityKey = LibrarySearchEntityKey(book: match.book, showsIndividualBooks: showsIndividualBooks)
            if var existing = grouped[entityKey] {
                existing.matchedBookIDs.insert(match.book.id)
                if match.distance < existing.distance {
                    existing.representativeBook = match.book
                    existing.distance = match.distance
                }
                grouped[entityKey] = existing
            } else {
                grouped[entityKey] = CoverImageSearchEntityAccumulator(
                    representativeBook: match.book,
                    matchedBookIDs: [match.book.id],
                    distance: match.distance
                )
            }
        }

        return grouped.map { entityKey, accumulator in
            LibrarySearchHit(
                entityKey: entityKey,
                representativeBook: accumulator.representativeBook,
                matchedBookIDs: accumulator.matchedBookIDs,
                similarityDistance: accumulator.distance
            )
        }.sorted {
            if $0.similarityDistance == $1.similarityDistance {
                return $0.entityKey.stableID < $1.entityKey.stableID
            }
            return ($0.similarityDistance ?? .greatestFiniteMagnitude)
                < ($1.similarityDistance ?? .greatestFiniteMagnitude)
        }
    }

    private func deactivateCoverImageSearch() {
        coverSearchProvider = nil
        coverSearchMatches = []
        coverSearchLocalizer = nil
        coverImageSearchTask?.cancel()
        coverImageSearchTask = nil
        coverImageSearchRevision += 1
        coverImageSearchQueryData = nil
        isCoverImageSearchActive = false
        isCoverImageSearchLoading = false
        coverImageSearchFileName = nil
        coverImageSearchMessage = nil
        coverImageSearchNeedsIndexUpdate = false
    }

    func refreshAdvancedSearchSuggestions(isTagTranslationEnabled: Bool) {
        do {
            if let suggestionRequest = advancedSearchSuggestionRequest(isTagTranslationEnabled: isTagTranslationEnabled) {
                advancedSearchSuggestions = try service.searchTagSuggestions(suggestionRequest)
            } else {
                advancedSearchSuggestions = []
            }
            advancedSearchError = nil
            loadError = nil
        } catch {
            advancedSearchSuggestions = []
            advancedSearchError = error.localizedDescription
            loadError = error.localizedDescription
        }
    }

    func searchRecentlyAddedBooks(isTagTranslationEnabled: Bool) {
        advancedSearchText = ""
        advancedSearchMode = .exact
        advancedSearchScope = .all
        advancedSearchPage = 1
        advancedSearchSortKey = .added
        advancedSearchSortDirection = .descending
        advancedSearchShowsIndividualBooks = true
        isAdvancedSearchRegexEnabled = false
        advancedSearchActiveTokenRange = nil
        updateAdvancedSearchDraft()
        refreshAdvancedSearchSuggestionsAsync(isTagTranslationEnabled: isTagTranslationEnabled)
        submitAdvancedSearch(isTagTranslationEnabled: isTagTranslationEnabled)
    }

    func searchBooks(
        matching tag: TagDisplaySummary,
        isTagTranslationEnabled: Bool
    ) {
        advancedSearchText = SearchQueryTextEditor.settingTag(tag, to: .selected, in: "")
        advancedSearchMode = .exact
        advancedSearchScope = .all
        advancedSearchPage = 1
        advancedSearchActiveTokenRange = nil
        advancedSearchSuggestions = []
        submitAdvancedSearch(isTagTranslationEnabled: isTagTranslationEnabled)
    }

    func setFollowed(
        _ isFollowed: Bool,
        for tag: TagDisplaySummary,
        isTagTranslationEnabled: Bool
    ) {
        do {
            try service.setFollowed(isFollowed, for: tag)
            applyFollowedState(isFollowed, tagID: tag.id)
            candidateDisplayTagCache.removeAll()
            tagSummaryRevision += 1
            loadError = nil
            refreshAdvancedSearchSuggestions(isTagTranslationEnabled: isTagTranslationEnabled)
        } catch {
            loadError = error.localizedDescription
        }
    }

    func tagVisualProfile(tagID: Tag.DatabaseID) -> TagVisualProfile? {
        if let cached = tagSummaryCache.values
            .flatMap({ $0 })
            .first(where: { $0.id == tagID })?
            .visualProfile {
            return cached
        }

        return try? service.tagVisualProfile(tagID: tagID)
    }

    func importDroppedTagForegroundImage(
        imageData: Data,
        tag: TagVisualAssetTarget
    ) {
        importDroppedTagImage(kind: .foreground, imageData: imageData, tag: tag)
    }

    func importDroppedTagImage(
        kind: TagVisualDropImportKind,
        imageData: Data,
        tag: TagVisualAssetTarget
    ) {
        do {
            let existingProfile = tagVisualProfile(tagID: tag.tagID)
            let asset: StoredTagVisualAsset
            switch kind {
            case .foreground:
                asset = try service.storeTagForegroundImage(imageData: imageData, tag: tag)
            case .background:
                asset = try service.storeTagBackgroundImage(imageData: imageData, tag: tag)
            }
            let background: (hex: String, source: TagVisualBackgroundColorSource)

            if existingProfile?.backgroundColorSource == .manual,
               let manualHex = existingProfile?.backgroundColorHex {
                background = (manualHex, .manual)
            } else if let themeHex = asset.themeColorHex {
                background = (themeHex, .image)
            } else {
                background = (
                    TagVisualAssetService.generatedBackgroundHex(tagID: tag.tagID, rawValue: tag.rawValue),
                    .generated
                )
            }

            let profile = TagVisualProfile(
                tagID: tag.tagID,
                foregroundAssetPath: kind == .foreground ? asset.relativePath : existingProfile?.foregroundAssetPath,
                foregroundScale: kind == .foreground ? 1 : existingProfile?.foregroundScale ?? 1,
                foregroundOffsetX: kind == .foreground ? 0 : existingProfile?.foregroundOffsetX ?? 0,
                foregroundOffsetY: kind == .foreground ? 0 : existingProfile?.foregroundOffsetY ?? 0,
                backgroundAssetPath: kind == .background ? asset.relativePath : existingProfile?.backgroundAssetPath,
                backgroundScale: existingProfile?.backgroundScale ?? 1,
                backgroundOffsetX: existingProfile?.backgroundOffsetX ?? 0,
                backgroundOffsetY: existingProfile?.backgroundOffsetY ?? 0,
                backgroundColorHex: background.hex,
                backgroundColorSource: background.source
            )
            let saved = try service.saveTagVisualProfile(profile)
            applyTagVisualProfile(saved)
            loadError = nil
        } catch {
            loadError = error.localizedDescription
        }
    }

    func tagVisualAssetURL(relativePath: String) -> URL? {
        try? service.tagVisualAssetURL(relativePath: relativePath)
    }

    func tagVisualHeroBlurAssetURL(relativeBackgroundPath: String) async -> URL? {
        let service = service
        return await Task.detached {
            try? service.tagVisualHeroBlurAssetURL(relativeBackgroundPath: relativeBackgroundPath)
        }.value
    }

    func tagVisualBackgroundPalette(relativeBackgroundPath: String) async -> TagVisualBackgroundPalette? {
        let service = service
        return await Task.detached {
            try? service.tagVisualBackgroundPalette(relativeBackgroundPath: relativeBackgroundPath)
        }.value
    }

    func workDetail(tagID: Tag.DatabaseID) -> WorkDetail? {
        workDetailCache[tagID]
    }

    func characterDetail(tagID: Tag.DatabaseID) -> CharacterDetail? {
        characterDetailCache[tagID]
    }

    func workCharacterCandidates(tagID: Tag.DatabaseID, isTagTranslationEnabled: Bool) async throws -> [WorkCharacterCandidate] {
        let service = service
        return try await Task.detached(priority: .userInitiated) {
            try service.workCharacterCandidates(parodyTagID: tagID, isTagTranslationEnabled: isTagTranslationEnabled)
        }.value
    }

    func searchCharacterTags(_ query: String, isTagTranslationEnabled: Bool) async throws -> [TagDisplaySummary] {
        let service = service
        let request = SearchTagSuggestionRequest(query: query, namespace: "character", isTagTranslationEnabled: isTagTranslationEnabled)
        return try await Task.detached(priority: .userInitiated) {
            try Task.checkCancellation()
            return try service.searchTagSuggestions(request).map(\.tag)
        }.cancellableValue
    }

    func addCharacterTag(to bookID: LibraryBook.DatabaseID, pair: WorkCharacterPair, isTagTranslationEnabled: Bool) async throws {
        guard !isDeletingBook else { throw LibraryDeletionError.bookUnavailable }
        let service = service
        let addition = try await Task.detached(priority: .userInitiated) {
            try service.addCharacterTag(to: bookID, pair: pair)
        }.cancellableValue
        if !addition.isClassified && !Task.isCancelled {
            unconfirmedCharacterAssignmentWorkID = pair.workID
        }
        guard addition.didChange else { return }

        // A concurrent organization edit may already be visible in the UI. Patch only the fields we own.
        if var current = book(id: addition.book.id) {
            current.tags = addition.book.tags
            current.updatedAt = max(current.updatedAt, addition.book.updatedAt)
            applyBookUpdatesIncrementally([current])
        }
        invalidateTagSummaries()
        reloadSearchAfterLibraryChange()
        changeBus.publish(.tagsChanged([bookID]))
        invalidateWorkDetails(keepingVisibleWork: pair.workID)
        reloadWorkDetail(tagID: pair.workID, isTagTranslationEnabled: isTagTranslationEnabled)
    }

    func setWorkCharacterDecision(_ decision: WorkCharacterManualDecision?, pair: WorkCharacterPair) async throws {
        let service = service
        try await Task.detached(priority: .userInitiated) {
            try service.setWorkCharacterDecision(decision, pair: pair)
        }.value
        invalidateWorkDetails()
    }

    func setAutomaticClaimSuppressed(_ isSuppressed: Bool, bookID: LibraryBook.DatabaseID, pair: WorkCharacterPair) async throws {
        let service = service
        try await Task.detached(priority: .userInitiated) {
            try service.setAutomaticClaimSuppressed(isSuppressed, bookID: bookID, pair: pair)
        }.value
        invalidateWorkDetails()
    }

    func isLoadingWorkDetail(tagID: Tag.DatabaseID) -> Bool {
        loadingWorkDetailIDs.contains(tagID)
    }

    func isLoadingCharacterDetail(tagID: Tag.DatabaseID) -> Bool {
        loadingCharacterDetailIDs.contains(tagID)
    }

    func workDetailError(tagID: Tag.DatabaseID) -> String? {
        workDetailErrors[tagID]
    }

    func characterDetailError(tagID: Tag.DatabaseID) -> String? {
        characterDetailErrors[tagID]
    }

    func reloadWorkDetail(
        tagID: Tag.DatabaseID,
        isTagTranslationEnabled: Bool,
        forceReload: Bool = false
    ) {
        let hasMatchingCache = workDetailCache[tagID] != nil
            && workDetailTranslationStates[tagID] == isTagTranslationEnabled
        guard forceReload || !hasMatchingCache else {
            return
        }
        guard !loadingWorkDetailIDs.contains(tagID) else {
            return
        }

        loadingWorkDetailIDs.insert(tagID)
        workDetailErrors[tagID] = nil

        let service = service
        workDetailLoadTasks[tagID]?.cancel()
        workDetailLoadTasks[tagID] = Task { @MainActor in
            let result = await Task.detached(priority: .userInitiated) {
                Result {
                    try service.workDetail(
                        parodyTagID: tagID,
                        isTagTranslationEnabled: isTagTranslationEnabled
                    )
                }
            }.value

            guard !Task.isCancelled else { return }

            switch result {
            case .success(let detail):
                workDetailCache[tagID] = detail
                workDetailTranslationStates[tagID] = isTagTranslationEnabled
                workDetailErrors[tagID] = nil
                loadError = nil
                workDetailRevision += 1
            case .failure(let error):
                workDetailErrors[tagID] = error.localizedDescription
                workDetailRevision += 1
            }

            loadingWorkDetailIDs.remove(tagID)
            workDetailLoadTasks[tagID] = nil
        }
    }

    func reloadCharacterDetail(
        tagID: Tag.DatabaseID,
        isTagTranslationEnabled: Bool,
        forceReload: Bool = false
    ) {
        let hasMatchingCache = characterDetailCache[tagID] != nil
            && characterDetailTranslationStates[tagID] == isTagTranslationEnabled
        guard forceReload || !hasMatchingCache else {
            return
        }
        guard !loadingCharacterDetailIDs.contains(tagID) else {
            return
        }

        loadingCharacterDetailIDs.insert(tagID)
        characterDetailErrors[tagID] = nil

        let service = service
        characterDetailLoadTasks[tagID]?.cancel()
        characterDetailLoadTasks[tagID] = Task { @MainActor in
            let result = await Task.detached(priority: .userInitiated) {
                Result {
                    try service.characterDetail(
                        characterTagID: tagID,
                        isTagTranslationEnabled: isTagTranslationEnabled
                    )
                }
            }.value

            guard !Task.isCancelled else { return }

            switch result {
            case .success(let detail):
                characterDetailCache[tagID] = detail
                characterDetailTranslationStates[tagID] = isTagTranslationEnabled
                characterDetailErrors[tagID] = nil
                loadError = nil
                characterDetailRevision += 1
            case .failure(let error):
                characterDetailErrors[tagID] = error.localizedDescription
                characterDetailRevision += 1
            }

            loadingCharacterDetailIDs.remove(tagID)
            characterDetailLoadTasks[tagID] = nil
        }
    }

    private func invalidateWorkDetails(keepingVisibleWork workID: Tag.DatabaseID? = nil) {
        workDetailLoadTasks.values.forEach { $0.cancel() }
        workDetailLoadTasks.removeAll()
        // Keep the active topic on screen while it refreshes after a single-book assignment.
        if let workID, let current = workDetailCache[workID] {
            workDetailCache = [workID: current]
        } else {
            workDetailCache.removeAll()
        }
        workDetailTranslationStates.removeAll()
        workDetailErrors.removeAll()
        loadingWorkDetailIDs.removeAll()
        workDetailRevision += 1
        characterDetailLoadTasks.values.forEach { $0.cancel() }
        characterDetailLoadTasks.removeAll()
        characterDetailCache.removeAll()
        characterDetailTranslationStates.removeAll()
        characterDetailErrors.removeAll()
        loadingCharacterDetailIDs.removeAll()
        characterDetailRevision += 1
    }

    func cycleAdvancedSearchTag(_ facet: SearchTagFacet, isTagTranslationEnabled: Bool) {
        guard facet.isEnabled else {
            return
        }

        switch facet.state {
        case .unselected:
            advancedSearchText = SearchQueryTextEditor.settingTag(facet.tag, to: .selected, in: advancedSearchText)
        case .selected:
            advancedSearchText = SearchQueryTextEditor.settingTag(facet.tag, to: .excluded, in: advancedSearchText)
        case .excluded:
            advancedSearchText = SearchQueryTextEditor.settingTag(facet.tag, to: .unselected, in: advancedSearchText)
        }

        submitAdvancedSearch(isTagTranslationEnabled: isTagTranslationEnabled)
    }

    func setAdvancedSearchTag(
        _ facet: SearchTagFacet,
        state: SearchTagState,
        isTagTranslationEnabled: Bool
    ) {
        guard state != .selected || facet.isEnabled || facet.state == .selected else {
            return
        }
        advancedSearchText = SearchQueryTextEditor.settingTag(facet.tag, to: state, in: advancedSearchText)
        submitAdvancedSearch(isTagTranslationEnabled: isTagTranslationEnabled)
    }

    func insertAdvancedSearchSuggestion(
        _ suggestion: SearchTagSuggestion,
        activeRange: NSRange?
    ) {
        advancedSearchText = SearchQueryTextEditor.replacingActiveToken(
            in: advancedSearchText,
            activeRange: activeRange,
            with: suggestion.exactInsertionText
        )
        advancedSearchActiveTokenRange = NSRange(location: (advancedSearchText as NSString).length, length: 0)
        advancedSearchSuggestions = []
    }

    func cycleAdvancedSearchToken(
        _ token: SearchTokenHighlight,
        isTagTranslationEnabled: Bool
    ) {
        advancedSearchText = SearchQueryTextEditor.cyclingHighlightedToken(token, in: advancedSearchText)
        advancedSearchActiveTokenRange = nil
        advancedSearchSuggestions = []
        submitAdvancedSearch(isTagTranslationEnabled: isTagTranslationEnabled)
    }

    func resortAdvancedSearchResults() {
        advancedSearchHits.sort {
            advancedSearchBookSort($0.representativeBook, $1.representativeBook)
        }
        advancedSearchResults = advancedSearchHits.map(\.representativeBook)
        advancedSearchDisplayItems = makeAdvancedSearchDisplayItems(from: advancedSearchHits)
    }

    func toggleAdvancedSearchMarked(
        for book: LibraryBook,
        isTagTranslationEnabled: Bool
    ) {
        do {
            let updatedBook = try service.setMarked(!book.mark, for: book)
            applyBookUpdatesIncrementally([updatedBook])
            selectedBookID = updatedBook.id
            if !isCoverImageSearchActive {
                submitAdvancedSearch(isTagTranslationEnabled: isTagTranslationEnabled)
            }
            loadError = nil
        } catch {
            loadError = error.localizedDescription
        }
    }

    private func loadTagSummaries(
        for category: TagCategory,
        isTagTranslationEnabled: Bool,
        forceReload: Bool
    ) {
        category.namespaces.forEach { namespace in
            loadTagSummaries(
                namespace: namespace,
                isTagTranslationEnabled: isTagTranslationEnabled,
                forceReload: forceReload
            )
        }
    }

    private func tagSummaries(
        namespace: String,
        isTagTranslationEnabled: Bool
    ) -> [TagDisplaySummary] {
        tagSummaryCache[tagSummaryCacheKey(namespace: namespace, isTagTranslationEnabled: isTagTranslationEnabled)] ?? []
    }

    private func applyFollowedState(_ isFollowed: Bool, tagID: Tag.DatabaseID) {
        tagSummaryCache = tagSummaryCache.mapValues { summaries in
            summaries.map { summary in
                var updated = summary
                if updated.id == tagID {
                    updated.isFollowed = isFollowed
                }
                return updated
            }
        }
        advancedSearchTagFacets = advancedSearchTagFacets.map { facet in
            followedFacet(facet, tagID: tagID, isFollowed: isFollowed)
        }
        advancedSearchFacetsByNamespace = advancedSearchFacetsByNamespace.mapValues { facets in
            facets.map { followedFacet($0, tagID: tagID, isFollowed: isFollowed) }
        }
        advancedSearchSuggestions = advancedSearchSuggestions.map { suggestion in
            var updated = suggestion
            if updated.tag.id == tagID {
                updated.tag.isFollowed = isFollowed
            }
            return updated
        }
        homeInsightCharts = mapHomeInsightCharts { tag in
            var updated = tag
            if updated.id == tagID {
                updated.isFollowed = isFollowed
            }
            return updated
        }
        homeInsightChartCache = homeInsightChartCache.mapValues { charts in
            mapHomeInsightCharts(charts) { tag in
                var updated = tag
                if updated.id == tagID {
                    updated.isFollowed = isFollowed
                }
                return updated
            }
        }
    }

    private func applyTagVisualProfile(_ profile: TagVisualProfile) {
        tagSummaryCache = tagSummaryCache.mapValues { summaries in
            summaries.map { summary in
                var updated = summary
                if updated.id == profile.tagID {
                    updated.visualProfile = profile
                }
                return updated
            }
        }
        workDetailCache = workDetailCache.mapValues { detail in
            var updated = detail
            if updated.work.id == profile.tagID {
                updated.work.visualProfile = profile
            }
            updated.sections = updated.sections.map { section in
                var updatedSection = section
                if updatedSection.character?.id == profile.tagID {
                    updatedSection.character?.visualProfile = profile
                }
                return updatedSection
            }
            return updated
        }
        characterDetailCache = characterDetailCache.mapValues { detail in
            var updated = detail
            if updated.character.id == profile.tagID {
                updated.character.visualProfile = profile
            }
            updated.sections = updated.sections.map { section in
                var updatedSection = section
                if updatedSection.work?.id == profile.tagID {
                    updatedSection.work?.visualProfile = profile
                }
                return updatedSection
            }
            return updated
        }
        homeInsightCharts = mapHomeInsightCharts { tag in
            var updated = tag
            if updated.id == profile.tagID {
                updated.visualProfile = profile
            }
            return updated
        }
        homeInsightChartCache = homeInsightChartCache.mapValues { charts in
            mapHomeInsightCharts(charts) { tag in
                var updated = tag
                if updated.id == profile.tagID {
                    updated.visualProfile = profile
                }
                return updated
            }
        }
        tagSummaryRevision += 1
        workDetailRevision += 1
        characterDetailRevision += 1
    }

    private func followedFacet(
        _ facet: SearchTagFacet,
        tagID: Tag.DatabaseID,
        isFollowed: Bool
    ) -> SearchTagFacet {
        var updated = facet
        if updated.tag.id == tagID {
            updated.tag.isFollowed = isFollowed
        }
        return updated
    }

    private func loadTagSummaries(
        namespace: String,
        isTagTranslationEnabled: Bool,
        forceReload: Bool
    ) {
        let cacheKey = tagSummaryCacheKey(namespace: namespace, isTagTranslationEnabled: isTagTranslationEnabled)
        if forceReload {
            tagSummaryCache[cacheKey] = nil
            tagSummaryErrors[cacheKey] = nil
        }

        guard tagSummaryCache[cacheKey] == nil, !loadingTagSummaryKeys.contains(cacheKey) else {
            return
        }

        loadingTagSummaryKeys.insert(cacheKey)
        defer {
            loadingTagSummaryKeys.remove(cacheKey)
        }

        do {
            let summaries = try service.tagSummaries(
                namespace: namespace,
                isTagTranslationEnabled: isTagTranslationEnabled
            )
            tagSummaryCache[cacheKey] = summaries
            tagSummaryErrors[cacheKey] = nil
            tagSummaryRevision += 1
            loadError = nil
        } catch {
            tagSummaryErrors[cacheKey] = error.localizedDescription
            tagSummaryRevision += 1
            loadError = error.localizedDescription
        }
    }

    // MARK: - 全量刷新与轻量状态同步

    // refresh 是 Store 的一致性回灌点：重新读取主表、组织表、推荐缓存和封面向量统计，
    // 然后重建所有供视图滚动使用的派生缓存。
    func refresh() {
        organizationProjectionRevision &+= 1
        organizationProjectionTask?.cancel()
        let isInitialLoad = !didRecoverImportPipeline
        if let bootstrapError {
            loadError = bootstrapError
            return
        }

        do {
            if !didRecoverImportPipeline {
                try service.recoverLibraryDeletions()
                try service.recoverImportPipeline()
                didRecoverImportPipeline = true
            }
            books = try service.loadBooks()
            importPipelineSnapshot = try service.loadImportPipelineSnapshot()
            readingStates = Dictionary(uniqueKeysWithValues: try service.loadReadingStates().map { ($0.bookID, $0) })
            collections = try service.loadCollections()
            versionGroups = try service.loadVersionGroups()
            versionLabelSuggestions = mergedVersionLabelSuggestions(try service.loadVersionLabelSuggestions())
            if try service.ensureTagIndex(for: books) {
                invalidateTagSummaries()
                invalidateWorkDetails()
                books = try service.loadBooks()
            }
            rebuildDerivedCaches()
            for (_, mutation, optimistic) in pendingOrganizationMutations where optimistic { applyOptimisticOrganizationMutation(mutation) }
            for (collectionID, orderedBooks) in pendingCollectionOrders {
                let currentBooks = orderedBooks.compactMap { bookIndex[$0.id] }
                applyOptimisticCollectionOrder(currentBooks, collectionID: collectionID, shouldCommit: false)
            }
            createCollectionRecommendations = try service.loadCreateCollectionRecommendations()
            collectionRecommendationLastUpdatedAt = try service.latestCollectionRecommendationRefreshCompletedAt()
            addToCollectionRecommendationCounts = try service.loadAddToCollectionRecommendationCounts()
            createVersionGroupRecommendations = try service.loadCreateVersionGroupRecommendations()
            versionRecommendationLastUpdatedAt = try service.latestVersionRecommendationRefreshCompletedAt()
            addToVersionGroupRecommendationCounts = try service.loadAddToVersionGroupRecommendationCounts()
            coverVectorStats = try service.coverVectorStats()
            reloadAddToSelectedCollectionRecommendations()
            changeBus.publish(.fullReload(reason: "refresh"))
            reloadAddToSelectedVersionGroupRecommendations()
            if !isInitialLoad { reloadSearchAfterLibraryChange() }
            tagTranslationManifest = try? service.cachedTagTranslationManifest()
            if isInitialLoad { reconcileBackups() }
            loadError = nil

            if selectedBookID == nil {
                selectedBookID = books.first?.id
            } else if selectedBook == nil {
                selectedBookID = books.first?.id
            }
            if isInitialLoad { continueImportPipelineReviewIfReady() }
        } catch {
            loadError = error.localizedDescription
        }
    }

    func refreshTagTranslationStatus() {
        tagTranslationManifest = try? service.cachedTagTranslationManifest()
    }

    func updateTagTranslations(
        proxySettings: NetworkProxySettings = NetworkProxySettings(),
        localizer: AppLocalizer
    ) async {
        guard !isUpdatingTagTranslations else {
            return
        }

        isUpdatingTagTranslations = true
        tagTranslationMessage = localizer.string(.tagTranslationsUpdating)
        defer {
            isUpdatingTagTranslations = false
        }

        do {
            let result = try await service.updateTagTranslations(proxySettings: proxySettings)
            tagTranslationManifest = try? service.cachedTagTranslationManifest()
            tagTranslationMessage = localizer.tagTranslationUpdateSummary(result)
            invalidateTagSummaries()
            loadError = nil
        } catch {
            tagTranslationMessage = error.localizedDescription
            loadError = error.localizedDescription
            refreshTagTranslationStatus()
        }
    }

    func refreshSelectedFileStatus() {
        guard let selectedBook else {
            return
        }

        do {
            try service.refreshFileStatus(for: selectedBook)
            refresh()
        } catch {
            refresh()
            loadError = error.localizedDescription
        }
    }

    func recordRead(for book: LibraryBook) {
        do {
            let updatedBook = try service.recordRead(for: book)
            applyBookUpdatesIncrementally([updatedBook])
            selectedBookID = updatedBook.id
            loadError = nil
        } catch {
            loadError = error.localizedDescription
        }
    }

    func readingState(for book: LibraryBook) -> BookReadingState? {
        guard let bookID = book.databaseID else { return nil }
        return readingStates[bookID]
    }

    func taskCenterSnapshots(localizer: AppLocalizer) -> [LibraryTaskSnapshot] {
        var snapshots: [LibraryTaskSnapshot] = []
        if isScanning {
            snapshots.append(.init(
                kind: .scan,
                title: localizer.string(.scanLibrary),
                detail: scanProgress.phase,
                state: .running,
                fractionCompleted: scanProgress.fractionCompleted,
                canCancel: true
            ))
        }
        if metadataBatchProgress.isActive || metadataBatchProgress.state == .completed {
            let total = max(metadataBatchProgress.total, 1)
            snapshots.append(.init(
                kind: .metadata,
                title: localizer.string(.metadataBatch),
                detail: metadataBatchProgress.lastError ?? metadataBatchProgress.currentTitle,
                state: metadataBatchProgress.state == .paused ? .paused : (metadataBatchProgress.state == .completed ? .completed : .running),
                fractionCompleted: Double(metadataBatchProgress.processed) / Double(total),
                canPause: metadataBatchProgress.state == .running,
                canResume: metadataBatchProgress.state == .paused,
                canCancel: metadataBatchProgress.isActive
            ))
        }
        if let batch = importPipelineSnapshot.activeBatch {
            let state: LibraryTaskRunState = switch batch.status {
            case .running: .running
            case .waitingForReview, .paused: .paused
            case .completed: .completed
            }
            let processed = min(batch.readyCount + batch.deferredCount + batch.failedCount, batch.totalCount)
            snapshots.append(.init(
                kind: .importPipeline,
                title: localizer.string(.importLibrary),
                detail: importPipelineMessage ?? batch.pauseReason,
                state: state,
                fractionCompleted: batch.stage == .metadata && batch.totalCount > 0
                    ? Double(processed) / Double(batch.totalCount)
                    : nil,
                canPause: isProcessingImportPipeline,
                canCancel: isProcessingImportPipeline
            ))
        }
        if isImporting {
            snapshots.append(.init(kind: .externalImport, title: localizer.string(.importExternalLibrary), detail: importProgress.phase, state: .running, fractionCompleted: importProgress.fractionCompleted, canCancel: true))
        }
        if isUpdatingWorkCharacterIndex {
            snapshots.append(.init(kind: .workCharacterIndex, title: localizer.string(.workCharacterIndex), detail: workCharacterIndexMessage, state: .running, fractionCompleted: nil, canCancel: true))
        }
        if isRefreshingCollectionRecommendations {
            snapshots.append(.init(kind: .collectionRecommendations, title: localizer.string(.collectionRecommendationsRebuild), detail: collectionRecommendationRefreshProgress.phase, state: .running, fractionCompleted: collectionRecommendationRefreshProgress.fractionCompleted, canCancel: true))
        }
        if isRefreshingVersionRecommendations {
            snapshots.append(.init(kind: .versionRecommendations, title: localizer.string(.versionRecommendationsRebuild), detail: versionRecommendationRefreshProgress.phase, state: .running, fractionCompleted: versionRecommendationRefreshProgress.fractionCompleted, canCancel: true))
        }
        if isUpdatingCoverVectors {
            snapshots.append(.init(kind: .coverVectors, title: localizer.string(.coverVectors), detail: coverVectorProgress.phase, state: .running, fractionCompleted: coverVectorProgress.fractionCompleted, canCancel: true))
        }
        if isUpdatingSemanticTitleVectors {
            snapshots.append(.init(
                kind: .semanticTitleVectors,
                title: localizer.string(.semanticSeriesRecommendations),
                detail: semanticTitleVectorProgress.phase,
                state: .running,
                fractionCompleted: semanticTitleVectorProgress.fractionCompleted,
                canCancel: true
            ))
        }
        if isUpdatingTagTranslations {
            snapshots.append(.init(kind: .tagTranslations, title: localizer.string(.tagTranslations), detail: tagTranslationMessage, state: .running, fractionCompleted: nil))
        }
        if let failure = lastTaskFailure,
           !snapshots.contains(where: { $0.kind == failure.kind }) {
            snapshots.append(.init(
                kind: failure.kind,
                title: failure.title,
                detail: failure.detail,
                state: .failed,
                fractionCompleted: nil,
                canResume: failure.canRetry
            ))
        }
        return snapshots
    }

    var backups: LibraryBackupService? { service.backupService }

    func reconcileBackups() {
        guard let backups else { return }
        Task.detached(priority: .utility) { try? backups.reconcile() }
    }

    func manageBackup(_ command: BackupCommand, localizer: AppLocalizer) {
        guard let backups, !isManagingBackup else { return }
        isManagingBackup = true
        backupMessage = nil
        Task { [weak self] in
            defer { self?.isManagingBackup = false }
            do {
                let output = try await Task.detached(priority: .utility) {
                    try command.perform(using: backups)
                }.value
                guard let self else { return }
                if command.isRestore {
                    invalidateTagSummaries()
                    invalidateWorkDetails()
                    refresh()
                    backupMessage = localizer.string(.backupRestoreSucceeded)
                } else { backupMessage = output }
            } catch { self?.backupMessage = error.localizedDescription }
        }
    }

    func runDataHealthCheck() {
        guard !isRunningDataHealthCheck else { return }
        isRunningDataHealthCheck = true
        let service = service
        Task { @MainActor [weak self] in
            defer { self?.isRunningDataHealthCheck = false }
            do {
                self?.dataHealthReport = try await Task.detached(priority: .utility) {
                    try service.dataHealthCheck()
                }.cancellableValue
                self?.loadError = nil
            } catch {
                self?.loadError = error.localizedDescription
            }
        }
    }

    func repairDerivedData() {
        guard !isDeletingBook else { return }
        guard !isRunningDataHealthCheck else { return }
        isRunningDataHealthCheck = true
        let service = service
        Task { @MainActor [weak self] in
            defer { self?.isRunningDataHealthCheck = false }
            do {
                self?.dataHealthReport = try await Task.detached(priority: .utility) {
                    try service.repairDerivedData()
                }.cancellableValue
                self?.invalidateWorkDetails()
                self?.invalidateTagSummaries()
                self?.refresh()
                self?.continueImportPipelineReviewIfReady()
            } catch {
                self?.loadError = error.localizedDescription
            }
        }
    }

    func vacuumDatabase() {
        guard !isRunningDataHealthCheck else { return }
        isRunningDataHealthCheck = true
        let service = service
        Task { @MainActor [weak self] in
            defer { self?.isRunningDataHealthCheck = false }
            do {
                try await Task.detached(priority: .utility) { try service.vacuumDatabase() }.cancellableValue
                self?.loadError = nil
            } catch {
                self?.loadError = error.localizedDescription
            }
        }
    }

    func saveReadingProgress(
        for book: LibraryBook,
        currentPageIndex: Int,
        totalPages: Int,
        forceCompleted: Bool? = nil
    ) {
        guard !isDeletingBook, books.contains(where: { $0.databaseID == book.databaseID }), let bookID = book.databaseID else { return }
        let pending = PendingReadingProgress(
            book: book,
            currentPageIndex: currentPageIndex,
            totalPages: totalPages,
            forceCompleted: forceCompleted
        )
        pendingReadingProgress[bookID] = pending
        readingProgressRevisions[bookID, default: 0] += 1
        let revision = readingProgressRevisions[bookID] ?? 0

        let optimistic = optimisticReadingState(for: pending)
        readingStates[bookID] = optimistic
        repositionContinueReadingBook(book, state: optimistic)
        changeBus.publish(.readingStateChanged(bookID: bookID, state: optimistic))
        loadError = nil

        readingProgressTasks[bookID]?.cancel()
        if forceCompleted != nil {
            persistReadingProgress(bookID: bookID, revision: revision)
        } else {
            let sleep = sleep
            readingProgressTasks[bookID] = Task { @MainActor [weak self] in
                do {
                    try await sleep(500_000_000)
                    guard !Task.isCancelled else { return }
                    self?.persistReadingProgress(bookID: bookID, revision: revision)
                } catch is CancellationError {
                    return
                } catch {
                    self?.loadError = error.localizedDescription
                }
            }
        }
    }

    func flushReadingProgress(for book: LibraryBook) {
        guard let bookID = book.databaseID,
              pendingReadingProgress[bookID] != nil else { return }
        readingProgressTasks[bookID]?.cancel()
        readingProgressRevisions[bookID, default: 0] += 1
        persistReadingProgress(bookID: bookID, revision: readingProgressRevisions[bookID] ?? 0)
    }

    func resetReadingProgress(for book: LibraryBook) {
        do {
            let bookID = book.databaseID
            if let bookID {
                readingProgressTasks[bookID]?.cancel()
                readingProgressTasks[bookID] = nil
                pendingReadingProgress[bookID] = nil
                readingProgressRevisions[bookID, default: 0] += 1
            }
            try service.resetReadingProgress(for: book)
            if let bookID = book.databaseID {
                readingStates[bookID] = nil
            }
            repositionContinueReadingBook(book, state: nil)
            if let bookID {
                changeBus.publish(.readingStateChanged(bookID: bookID, state: nil))
            }
            loadError = nil
        } catch {
            loadError = error.localizedDescription
        }
    }

    private func optimisticReadingState(for pending: PendingReadingProgress) -> BookReadingState {
        let bookID = pending.book.databaseID ?? -1
        let total = max(pending.totalPages, 0)
        let index = total > 0
            ? min(max(pending.currentPageIndex, 0), total - 1)
            : max(pending.currentPageIndex, 0)
        let completed = pending.forceCompleted ?? (
            total > 0 && Double(index + 1) / Double(total) >= 0.95
        )
        return BookReadingState(
            bookID: bookID,
            currentPageIndex: index,
            totalPages: total,
            updatedAt: Timestamp.nowMilliseconds(),
            completedAt: completed ? (readingStates[bookID]?.completedAt ?? Timestamp.nowMilliseconds()) : nil
        )
    }

    private func persistReadingProgress(bookID: LibraryBook.DatabaseID, revision: Int) {
        guard let pending = pendingReadingProgress[bookID] else { return }
        let service = service
        readingProgressTasks[bookID] = Task { @MainActor [weak self] in
            do {
                let state = try await Task.detached(priority: .utility) {
                    try service.saveReadingProgress(
                        for: pending.book,
                        currentPageIndex: pending.currentPageIndex,
                        totalPages: pending.totalPages,
                        forceCompleted: pending.forceCompleted
                    )
                }.cancellableValue
                guard let self, self.readingProgressRevisions[bookID] == revision else { return }
                self.pendingReadingProgress[bookID] = nil
                self.readingProgressTasks[bookID] = nil
                self.readingStates[bookID] = state
                self.repositionContinueReadingBook(pending.book, state: state)
                self.changeBus.publish(.readingStateChanged(bookID: bookID, state: state))
                self.loadError = nil
            } catch is CancellationError {
                return
            } catch {
                guard let self, self.readingProgressRevisions[bookID] == revision else { return }
                self.readingProgressTasks[bookID] = nil
                self.loadError = error.localizedDescription
            }
        }
    }

    private func repositionContinueReadingBook(_ book: LibraryBook, state: BookReadingState?) {
        continueReadingBooks.removeAll { $0.id == book.id }
        if let state,
           state.currentPageIndex > 0,
           !state.isCompleted,
           !book.isUserHidden,
           isPrimaryDisplayVersion(book) {
            continueReadingBooks.append(book)
        }
        continueReadingBooks.sort { lhs, rhs in
            let left = lhs.databaseID.flatMap { readingStates[$0]?.updatedAt } ?? 0
            let right = rhs.databaseID.flatMap { readingStates[$0]?.updatedAt } ?? 0
            return left == right ? lhs.id < rhs.id : left > right
        }
        if continueReadingBooks.count > 10 {
            continueReadingBooks.removeLast(continueReadingBooks.count - 10)
        }
    }

    func setUserHidden(_ isHidden: Bool, for book: LibraryBook) {
        do {
            let updated = try service.setUserHidden(isHidden, for: book)
            applyBookUpdatesIncrementally([updated])
        } catch {
            loadError = error.localizedDescription
        }
    }

    func toggleMarked(for book: LibraryBook) {
        do {
            let updatedBook = try service.setMarked(!book.mark, for: book)
            applyBookUpdatesIncrementally([updatedBook])
            selectedBookID = updatedBook.id
            loadError = nil
        } catch {
            loadError = error.localizedDescription
        }
    }

    func setCardCompleted(_ completed: Bool, book: LibraryBook) {
        if completed {
            let state = readingState(for: book)
            let pages = BookCardMetadata(book: book).pages ?? 0
            saveReadingProgress(for: book, currentPageIndex: state?.currentPageIndex ?? 0,
                                totalPages: state.flatMap { $0.totalPages > 0 ? $0.totalPages : nil } ?? pages,
                                forceCompleted: true)
        } else {
            resetReadingProgress(for: book)
        }
    }

    func setCardMarked(_ isMarked: Bool, book: LibraryBook) {
        let current = bookIndex[book.id] ?? book
        do {
            let saved = try service.setMarked(isMarked, for: current)
            let companions = versionCompanions(for: saved).compactMap { bookIndex[$0.id] }
            let updates = companions.map { companion in
                var book = companion
                book.mark = saved.mark
                return book
            }
            applyBookUpdatesIncrementally([saved] + updates)
        } catch {
            loadError = error.localizedDescription
        }
    }

    func setMarked(_ isMarked: Bool, for books: [LibraryBook]) {
        var failures: [String] = []
        var updates: [LibraryBook] = []
        for book in books {
            do {
                updates.append(try service.setMarked(isMarked, for: book))
            } catch {
                failures.append("\(book.title): \(error.localizedDescription)")
            }
        }
        applyBookUpdatesIncrementally(updates)
        loadError = failures.isEmpty ? nil : failures.joined(separator: "\n")
    }

    func setUserHidden(_ isHidden: Bool, for books: [LibraryBook]) {
        var failures: [String] = []
        var updates: [LibraryBook] = []
        for book in books {
            do {
                updates.append(try service.setUserHidden(isHidden, for: book))
            } catch {
                failures.append("\(book.title): \(error.localizedDescription)")
            }
        }
        applyBookUpdatesIncrementally(updates)
        loadError = failures.isEmpty ? nil : failures.joined(separator: "\n")
    }

    func seriesIDs(for book: LibraryBook) -> Set<Int64> {
        let current = bookIndex[book.id] ?? book
        let members = current.versionGroupID.flatMap { booksByVersionGroupID[$0] } ?? [current]
        return Set(members.compactMap(\.collectionID))
    }

    func addBooks(_ books: [LibraryBook], to collection: BookCollection) {
        let sourceIDs = books.reduce(into: Set<Int64>()) { $0.formUnion(seriesIDs(for: $1)) }
        for sourceID in sourceIDs.sorted() {
            flushCollectionOrder(for: sourceID)
        }
        flushCollectionOrder(for: collection.databaseID)
        enqueueOrganizationMutation(.addToCollection(books, collection))
    }

    func removeBooks(_ books: [LibraryBook], from collection: BookCollection) {
        guard !books.isEmpty else { return }
        flushCollectionOrder(for: collection.databaseID)
        enqueueOrganizationMutation(.removeFromCollectionBatch(books, collection))
    }

    func addBooks(_ books: [LibraryBook], toVersionGroup group: BookVersionGroup) {
        enqueueOrganizationMutation(.addToVersionGroup(books, group))
    }

    func rescanBooks(_ books: [LibraryBook], localizer: AppLocalizer) {
        guard !isRescanningCover else { return }
        isRescanningCover = true
        let service = service
        Task { @MainActor [weak self] in
            defer { self?.isRescanningCover = false }
            var succeeded = 0
            var failures: [String] = []
            for book in books {
                do {
                    _ = try await Task.detached(priority: .utility) {
                        try service.rescanCover(for: book)
                    }.cancellableValue
                    succeeded += 1
                } catch {
                    failures.append("\(book.title): \(error.localizedDescription)")
                }
            }
            self?.refresh()
            self?.coverRescanMessage = failures.isEmpty
                ? localizer.string(.coverRescanSucceeded)
                : "\(succeeded)/\(books.count) — \(failures.joined(separator: "; "))"
            self?.loadError = failures.isEmpty ? nil : failures.joined(separator: "\n")
        }
    }

    func createCollection(localizer: AppLocalizer) {
        enqueueOrganizationMutation(.createCollection(localizer.string(.untitledCollection)))
    }

    func renameCollection(_ collection: BookCollection, name: String) {
        enqueueOrganizationMutation(.renameCollection(collection, name))
    }

    func deleteCollection(_ collection: BookCollection) {
        flushCollectionOrder(for: collection.databaseID)
        enqueueOrganizationMutation(.deleteCollection(collection))
    }

    func addBook(_ book: LibraryBook, to collection: BookCollection) {
        addBooks([book], to: collection)
    }

    func removeBook(_ book: LibraryBook, from collection: BookCollection) {
        flushCollectionOrder(for: collection.databaseID)
        enqueueOrganizationMutation(.removeFromCollection(book, collection))
    }

    func moveBook(_ book: LibraryBook, in collection: BookCollection, direction: CollectionMoveDirection) {
        guard let collectionID = collection.databaseID else {
            loadError = NyaEHError.groupingRepositoryUnavailable.localizedDescription
            return
        }
        var orderedBooks = displayBooks(in: collection)
        guard let index = orderedBooks.firstIndex(where: { $0.id == book.id }) else {
            return
        }
        let targetIndex: Int
        switch direction {
        case .up:
            targetIndex = index - 1
        case .down:
            targetIndex = index + 1
        }
        guard orderedBooks.indices.contains(targetIndex) else {
            return
        }
        orderedBooks.swapAt(index, targetIndex)
        applyOptimisticCollectionOrder(orderedBooks, collectionID: collectionID, shouldCommit: true)
    }

    func reorderBooks(_ orderedBooks: [LibraryBook], in collection: BookCollection) {
        guard let collectionID = collection.databaseID else {
            loadError = NyaEHError.groupingRepositoryUnavailable.localizedDescription
            return
        }
        applyOptimisticCollectionOrder(orderedBooks, collectionID: collectionID, shouldCommit: true)
    }

    func autoSortBooks(in collection: BookCollection) {
        guard let collectionID = collection.databaseID else {
            loadError = NyaEHError.groupingRepositoryUnavailable.localizedDescription
            return
        }
        let currentMembers = displayBooks(in: collection)
        guard let sortPlan = SeriesOrdinalResolver.sortPlan(
            for: currentMembers,
            policy: .confirmedCollection
        ) else {
            return
        }
        let membersByID = Dictionary(uniqueKeysWithValues: currentMembers.compactMap { book in
            book.databaseID.map { ($0, book) }
        })
        let sortedMembers = sortPlan.orderedPrimaryBookIDs.compactMap { membersByID[$0] }
        applyOptimisticCollectionOrder(sortedMembers, collectionID: collectionID, shouldCommit: true)
    }

    func acceptCreateCollectionRecommendation(
        _ item: CollectionRecommendationDisplayItem,
        useSemanticSimilarity: Bool = false,
        localizer: AppLocalizer
    ) {
        guard !isAcceptingCollectionRecommendation else {
            return
        }
        isAcceptingCollectionRecommendation = true
        enqueueOrganizationMutation(.acceptCreateCollection(item, localizer.string(.untitledCollection)),
                                    useSemanticSimilarity: useSemanticSimilarity)
    }

    func acceptAddToSelectedCollectionRecommendation(
        _ item: CollectionRecommendationDisplayItem,
        useSemanticSimilarity: Bool = false
    ) {
        guard !isAcceptingCollectionRecommendation else {
            return
        }
        isAcceptingCollectionRecommendation = true
        guard let collection = selectedCollectionID.flatMap(collection(id:)),
              let recommendedBook = item.books.first else {
            isAcceptingCollectionRecommendation = false
            return
        }
        flushCollectionOrder(for: collection.databaseID)
        enqueueOrganizationMutation(
            .acceptAddToCollection(item, book(id: recommendedBook.id) ?? recommendedBook, collection),
            useSemanticSimilarity: useSemanticSimilarity
        )
    }

    private func refreshCollectionRecommendationsAfterAcceptance(
        focusBookIDs: Set<LibraryBook.DatabaseID>,
        useSemanticSimilarity: Bool
    ) {
        updateCollectionRecommendationsIncrementally(
            focusBookIDs: focusBookIDs,
            useSemanticSimilarity: useSemanticSimilarity
        )
        Task { @MainActor [weak self] in
            guard let self else { return }
            await waitForCollectionRecommendationRefresh()
            continueImportPipelineReviewIfReady()
        }
    }

    func dismissCollectionRecommendation(_ item: CollectionRecommendationDisplayItem) {
        enqueueOrganizationMutation(.dismissCollection(item))
    }

    func createVersionGroup(with book: LibraryBook?) {
        enqueueOrganizationMutation(.createVersionGroup(book.map { [$0] } ?? []))
    }

    func createVersionGroup(with books: [LibraryBook]) {
        enqueueOrganizationMutation(.createVersionGroup(books))
    }

    func addBook(_ book: LibraryBook, toVersionGroup group: BookVersionGroup) {
        enqueueOrganizationMutation(.addToVersionGroup([book], group))
    }

    func removeBookFromVersionGroup(_ book: LibraryBook) {
        enqueueOrganizationMutation(.removeFromVersionGroup(book))
    }

    func deleteVersionGroup(_ group: BookVersionGroup) {
        enqueueOrganizationMutation(.deleteVersionGroup(group))
    }

    func setPrimaryVersion(_ book: LibraryBook, completion: ((String?) -> Void)? = nil) {
        enqueueOrganizationMutation(.setPrimaryVersion(book), completion: completion)
    }

    func setVersionLabel(_ label: String, for book: LibraryBook) {
        setVersionLabels([label], for: book)
    }

    func setVersionLabels(_ labels: [String], for book: LibraryBook) {
        enqueueOrganizationMutation(.setVersionLabels(labels, book))
    }

    func versionLabels(for book: LibraryBook) -> [String] {
        VersionLabelFormatter.labels(from: book.versionLabel)
    }

    func suggestedAutomaticVersionLabels(for book: LibraryBook) -> [String] {
        VersionLabelClassifier.labels(for: book)
    }

    func reloadVersionRecommendations() {
        do {
            createVersionGroupRecommendations = try service.loadCreateVersionGroupRecommendations()
            versionRecommendationLastUpdatedAt = try service.latestVersionRecommendationRefreshCompletedAt()
            addToVersionGroupRecommendationCounts = try service.loadAddToVersionGroupRecommendationCounts()
            reloadAddToSelectedVersionGroupRecommendations()
            loadError = nil
        } catch {
            loadError = error.localizedDescription
        }
    }

    func reloadAddToSelectedVersionGroupRecommendations() {
        do {
            guard let groupID = selectedVersionGroupID.flatMap(versionGroup(id:))?.databaseID else {
                addToSelectedVersionGroupRecommendations = []
                return
            }
            addToSelectedVersionGroupRecommendations = try service.loadAddToVersionGroupRecommendations(groupID: groupID)
            addToVersionGroupRecommendationCounts = try service.loadAddToVersionGroupRecommendationCounts()
            loadError = nil
        } catch {
            loadError = error.localizedDescription
        }
    }

    func reloadAddToSelectedVersionGroupRecommendationsAsync() {
        selectedVersionRecommendationTask?.cancel()
        guard let groupID = selectedVersionGroupID.flatMap(versionGroup(id:))?.databaseID else {
            addToSelectedVersionGroupRecommendations = []
            return
        }
        let service = service
        selectedVersionRecommendationTask = Task { @MainActor [weak self] in
            do {
                let result = try await Task.detached(priority: .userInitiated) {
                    (
                        try service.loadAddToVersionGroupRecommendations(groupID: groupID),
                        try service.loadAddToVersionGroupRecommendationCounts()
                    )
                }.cancellableValue
                guard let self, !Task.isCancelled,
                      self.selectedVersionGroupID.flatMap(self.versionGroup(id:))?.databaseID == groupID else { return }
                self.addToSelectedVersionGroupRecommendations = result.0
                self.addToVersionGroupRecommendationCounts = result.1
            } catch {
                guard !Task.isCancelled else { return }
                self?.loadError = error.localizedDescription
            }
        }
    }

    func reloadCollectionRecommendations() {
        do {
            createCollectionRecommendations = try service.loadCreateCollectionRecommendations()
            collectionRecommendationLastUpdatedAt = try service.latestCollectionRecommendationRefreshCompletedAt()
            addToCollectionRecommendationCounts = try service.loadAddToCollectionRecommendationCounts()
            reloadAddToSelectedCollectionRecommendations()
            loadError = nil
        } catch {
            loadError = error.localizedDescription
        }
    }

    func reloadAddToSelectedCollectionRecommendations() {
        do {
            guard let collectionID = selectedCollectionID.flatMap(collection(id:))?.databaseID else {
                addToSelectedCollectionRecommendations = []
                return
            }
            addToSelectedCollectionRecommendations = try service.loadAddToCollectionRecommendations(collectionID: collectionID)
            addToCollectionRecommendationCounts = try service.loadAddToCollectionRecommendationCounts()
            loadError = nil
        } catch {
            loadError = error.localizedDescription
        }
    }

    func reloadAddToSelectedCollectionRecommendationsAsync() {
        selectedCollectionRecommendationTask?.cancel()
        guard let collectionID = selectedCollectionID.flatMap(collection(id:))?.databaseID else {
            addToSelectedCollectionRecommendations = []
            return
        }
        let service = service
        selectedCollectionRecommendationTask = Task { @MainActor [weak self] in
            do {
                let result = try await Task.detached(priority: .userInitiated) {
                    (
                        try service.loadAddToCollectionRecommendations(collectionID: collectionID),
                        try service.loadAddToCollectionRecommendationCounts()
                    )
                }.cancellableValue
                guard let self, !Task.isCancelled,
                      self.selectedCollectionID.flatMap(self.collection(id:))?.databaseID == collectionID else { return }
                self.addToSelectedCollectionRecommendations = result.0
                self.addToCollectionRecommendationCounts = result.1
            } catch {
                guard !Task.isCancelled else { return }
                self?.loadError = error.localizedDescription
            }
        }
    }

    // MARK: - 推荐缓存与作品索引任务

    // 合集/版本推荐与作品-角色索引都可能很重；这里统一把计算放到后台，
    // 只把进度和最终快照切回 MainActor，避免管理页拖动或滚动时被同步计算卡住。
    func refreshCollectionRecommendations(
        useSemanticSimilarity: Bool = false,
        localizer: AppLocalizer? = nil
    ) {
        guard !isDeletingBook else { return }
        guard !isRefreshingCollectionRecommendations else {
            return
        }
        isRefreshingCollectionRecommendations = true
        collectionRecommendationMessage = localizer?.string(.collectionRecommendationsRebuilding)
            ?? CollectionRecommendationRefreshProgressPhases.default.computingCandidates
        collectionRecommendationRefreshProgress = CollectionRecommendationRefreshProgress(
            phase: collectionRecommendationMessage ?? "",
            fractionCompleted: 0
        )
        let taskGeneration = UUID()
        mutationTaskGenerations["collectionRecommendationRefreshTask"] = taskGeneration
        let service = service
        let phases = collectionRecommendationRefreshProgressPhases(localizer: localizer)
        retireMutationTask(collectionRecommendationRefreshTask)
        collectionRecommendationRefreshTask = Task { @MainActor in
            do {
                try await Task.detached(priority: .userInitiated) {
                    try service.refreshCollectionRecommendations(
                        semanticConfiguration: useSemanticSimilarity ? .precisionFirst : .disabled,
                        progress: { progress in
                            Task { @MainActor in
                                guard self.mutationTaskGenerations["collectionRecommendationRefreshTask"] == taskGeneration else { return }
                                self.collectionRecommendationRefreshProgress = progress
                            }
                        },
                        progressPhases: phases
                    )
                }.cancellableValue
                guard !Task.isCancelled else {
                    return
                }
                reloadCollectionRecommendations()
                collectionRecommendationMessage = phases.completed
            } catch {
                guard !Task.isCancelled else {
                    return
                }
                loadError = error.localizedDescription
                collectionRecommendationMessage = error.localizedDescription
            }
            isRefreshingCollectionRecommendations = false
        }
    }

    func updateCollectionRecommendationsIncrementally(
        focusBookIDs: Set<LibraryBook.DatabaseID> = [],
        useSemanticSimilarity: Bool = false,
        localizer: AppLocalizer? = nil
    ) {
        guard !isDeletingBook else { return }
        guard !isRefreshingCollectionRecommendations else {
            return
        }
        isRefreshingCollectionRecommendations = true
        collectionRecommendationMessage = localizer?.string(.collectionRecommendationsUpdating)
            ?? CollectionRecommendationRefreshProgressPhases.default.computingCandidates
        collectionRecommendationRefreshProgress = CollectionRecommendationRefreshProgress(
            phase: collectionRecommendationMessage ?? "",
            fractionCompleted: 0
        )
        let taskGeneration = UUID()
        mutationTaskGenerations["collectionRecommendationRefreshTask"] = taskGeneration
        let service = service
        let phases = collectionRecommendationRefreshProgressPhases(localizer: localizer)
        retireMutationTask(collectionRecommendationRefreshTask)
        collectionRecommendationRefreshTask = Task { @MainActor in
            do {
                let didUpdate = try await Task.detached(priority: .userInitiated) {
                    try service.updateCollectionRecommendationsIncrementally(
                        focusBookIDs: focusBookIDs,
                        semanticConfiguration: useSemanticSimilarity ? .precisionFirst : .disabled,
                        progress: { progress in
                            Task { @MainActor in
                                guard self.mutationTaskGenerations["collectionRecommendationRefreshTask"] == taskGeneration else { return }
                                self.collectionRecommendationRefreshProgress = progress
                            }
                        },
                        progressPhases: phases
                    )
                }.cancellableValue
                guard !Task.isCancelled else {
                    return
                }
                reloadCollectionRecommendations()
                collectionRecommendationMessage = didUpdate
                    ? phases.completed
                    : (localizer?.string(.recommendationsNoIncrementalChanges) ?? phases.completed)
            } catch {
                guard !Task.isCancelled else {
                    return
                }
                loadError = error.localizedDescription
                collectionRecommendationMessage = error.localizedDescription
            }
            isRefreshingCollectionRecommendations = false
        }
    }

    func updateWorkCharacterIndexIncrementally(localizer: AppLocalizer) {
        runWorkCharacterIndexTask(
            phase: localizer.string(.workCharacterIndexUpdating),
            localizer: localizer
        ) { service in
            try service.updateWorkCharacterIndexIncrementally()
        }
    }

    func rebuildWorkCharacterIndex(localizer: AppLocalizer) {
        guard !isDeletingBook else { return }
        runWorkCharacterIndexTask(
            phase: localizer.string(.workCharacterIndexRebuilding),
            localizer: localizer
        ) { service in
            try service.rebuildWorkCharacterIndex()
        }
    }

    private func updateWorkCharacterIndexIfNeeded(localizer: AppLocalizer) {
        guard !isDeletingBook else { return }
        invalidateWorkDetails()
        runWorkCharacterIndexTask(
            phase: localizer.string(.workCharacterIndexUpdating),
            localizer: localizer
        ) { service in
            try service.updateWorkCharacterIndexIfNeeded()
        }
    }

    private func runWorkCharacterIndexTask(
        phase: String,
        localizer: AppLocalizer,
        operation: @escaping @Sendable (BookLibraryService) throws -> WorkCharacterIndexUpdateResult
    ) {
        guard !isDeletingBook else { return }
        guard !isUpdatingWorkCharacterIndex else {
            return
        }

        isUpdatingWorkCharacterIndex = true
        workCharacterIndexMessage = phase
        let taskGeneration = UUID()
        mutationTaskGenerations["workCharacterIndexTask"] = taskGeneration
        let service = service
        retireMutationTask(workCharacterIndexTask)
        workCharacterIndexTask = Task { @MainActor in
            defer {
                if self.mutationTaskGenerations["workCharacterIndexTask"] == taskGeneration {
                    isUpdatingWorkCharacterIndex = false
                }
            }
            do {
                let result = try await Task.detached(priority: .utility) {
                    try operation(service)
                }.cancellableValue
                guard !Task.isCancelled else {
                    return
                }
                workCharacterIndexMessage = result.didChange
                    ? localizer.workCharacterIndexUpdateSummary(result)
                    : localizer.string(.workCharacterIndexNoChanges)
                if result.didChange { invalidateWorkDetails() }
                loadError = nil
            } catch {
                guard !Task.isCancelled else {
                    return
                }
                workCharacterIndexMessage = error.localizedDescription
                loadError = error.localizedDescription
            }
        }
    }

    private func collectionRecommendationRefreshProgressPhases(
        localizer: AppLocalizer?
    ) -> CollectionRecommendationRefreshProgressPhases {
        guard let localizer else {
            return .default
        }
        return CollectionRecommendationRefreshProgressPhases(
            readingLibrary: localizer.string(.collectionRecommendationsReadingLibrary),
            parsingTitles: localizer.string(.collectionRecommendationsParsingTitles),
            computingCandidates: localizer.string(.collectionRecommendationsComputing),
            writingCache: localizer.string(.collectionRecommendationsWriting),
            completed: localizer.string(.collectionRecommendationsRefreshFinished)
        )
    }

    func repairVersionGroupMarkedState(localizer: AppLocalizer) {
        guard !isRepairingVersionGroupMarkedState else {
            return
        }
        isRepairingVersionGroupMarkedState = true
        versionGroupMarkedRepairMessage = localizer.string(.versionGroupMarkedRepairing)
        let service = service
        Task { @MainActor in
            do {
                let result = try await Task.detached(priority: .userInitiated) {
                    try service.repairVersionGroupMarkedState()
                }.cancellableValue
                guard !Task.isCancelled else {
                    return
                }
                refresh()
                reloadVersionRecommendations()
                versionGroupMarkedRepairMessage = localizer.versionGroupMarkedRepairSummary(result)
            } catch {
                guard !Task.isCancelled else {
                    return
                }
                loadError = error.localizedDescription
                versionGroupMarkedRepairMessage = error.localizedDescription
            }
            isRepairingVersionGroupMarkedState = false
        }
    }

    func refreshVersionRecommendations(
        useCoverSimilarity: Bool = false,
        maximumCoverDistance: Double = VersionRecommendationService.defaultCoverSimilarityMaximumDistance,
        localizer: AppLocalizer? = nil
    ) {
        guard !isDeletingBook else { return }
        guard !isRefreshingVersionRecommendations else {
            return
        }
        isRefreshingVersionRecommendations = true
        versionRecommendationMessage = localizer?.string(.versionRecommendationsRebuilding)
            ?? VersionRecommendationRefreshProgressPhases.default.computingCandidates
        versionRecommendationRefreshProgress = VersionRecommendationRefreshProgress(
            phase: versionRecommendationMessage ?? "",
            fractionCompleted: 0
        )
        let taskGeneration = UUID()
        mutationTaskGenerations["versionRecommendationRefreshTask"] = taskGeneration
        let service = service
        let phases = versionRecommendationRefreshProgressPhases(localizer: localizer)
        retireMutationTask(versionRecommendationRefreshTask)
        versionRecommendationRefreshTask = Task { @MainActor in
            do {
                try await Task.detached(priority: .userInitiated) {
                    try service.refreshVersionRecommendations(
                        useCoverSimilarity: useCoverSimilarity,
                        maximumCoverDistance: maximumCoverDistance,
                        progress: { progress in
                            Task { @MainActor in
                                guard self.mutationTaskGenerations["versionRecommendationRefreshTask"] == taskGeneration else { return }
                                self.versionRecommendationRefreshProgress = progress
                            }
                        },
                        progressPhases: phases
                    )
                }.cancellableValue
                guard !Task.isCancelled else {
                    return
                }
                reloadVersionRecommendations()
                versionRecommendationMessage = phases.completed
            } catch {
                guard !Task.isCancelled else {
                    return
                }
                loadError = error.localizedDescription
                versionRecommendationMessage = error.localizedDescription
            }
            isRefreshingVersionRecommendations = false
        }
    }

    func updateVersionRecommendationsIncrementally(
        useCoverSimilarity: Bool = false,
        maximumCoverDistance: Double = VersionRecommendationService.defaultCoverSimilarityMaximumDistance,
        localizer: AppLocalizer? = nil
    ) {
        guard !isDeletingBook else { return }
        guard !isRefreshingVersionRecommendations else {
            return
        }
        isRefreshingVersionRecommendations = true
        versionRecommendationMessage = localizer?.string(.versionRecommendationsUpdating)
            ?? VersionRecommendationRefreshProgressPhases.default.computingCandidates
        versionRecommendationRefreshProgress = VersionRecommendationRefreshProgress(
            phase: versionRecommendationMessage ?? "",
            fractionCompleted: 0
        )
        let taskGeneration = UUID()
        mutationTaskGenerations["versionRecommendationRefreshTask"] = taskGeneration
        let service = service
        let phases = versionRecommendationRefreshProgressPhases(localizer: localizer)
        retireMutationTask(versionRecommendationRefreshTask)
        versionRecommendationRefreshTask = Task { @MainActor in
            do {
                let didUpdate = try await Task.detached(priority: .userInitiated) {
                    try service.updateVersionRecommendationsIncrementally(
                        useCoverSimilarity: useCoverSimilarity,
                        maximumCoverDistance: maximumCoverDistance,
                        progress: { progress in
                            Task { @MainActor in
                                guard self.mutationTaskGenerations["versionRecommendationRefreshTask"] == taskGeneration else { return }
                                self.versionRecommendationRefreshProgress = progress
                            }
                        },
                        progressPhases: phases
                    )
                }.cancellableValue
                guard !Task.isCancelled else {
                    return
                }
                reloadVersionRecommendations()
                versionRecommendationMessage = didUpdate
                    ? phases.completed
                    : (localizer?.string(.recommendationsNoIncrementalChanges) ?? phases.completed)
            } catch {
                guard !Task.isCancelled else {
                    return
                }
                loadError = error.localizedDescription
                versionRecommendationMessage = error.localizedDescription
            }
            isRefreshingVersionRecommendations = false
        }
    }

    private func versionRecommendationRefreshProgressPhases(
        localizer: AppLocalizer?
    ) -> VersionRecommendationRefreshProgressPhases {
        guard let localizer else {
            return .default
        }
        return VersionRecommendationRefreshProgressPhases(
            readingLibrary: localizer.string(.versionRecommendationsReadingLibrary),
            readingCoverVectors: localizer.string(.versionRecommendationsReadingCoverVectors),
            computingCandidates: localizer.string(.versionRecommendationsComputing),
            writingCache: localizer.string(.versionRecommendationsWriting),
            completed: localizer.string(.versionRecommendationsRefreshFinished)
        )
    }

    func waitForVersionRecommendationRefresh() async {
        await versionRecommendationRefreshTask?.value
    }

    func waitForCollectionRecommendationRefresh() async {
        await collectionRecommendationRefreshTask?.value
    }

    func waitForCollectionOrderCommit(collectionID: BookCollection.DatabaseID? = nil) async {
        if let collectionID {
            await collectionOrderCommitTasks[collectionID]?.value
            await organizationTail?.value
            return
        }
        let tasks = Array(collectionOrderCommitTasks.values)
        for task in tasks {
            await task.value
        }
        await organizationTail?.value
    }

    func waitForWorkCharacterIndexUpdate() async {
        await workCharacterIndexTask?.value
    }

    func waitForWorkDetailLoad(tagID: Tag.DatabaseID) async {
        await workDetailLoadTasks[tagID]?.value
    }

    func waitForCharacterDetailLoad(tagID: Tag.DatabaseID) async {
        await characterDetailLoadTasks[tagID]?.value
    }

    func refreshCoverVectorStats() {
        do {
            coverVectorStats = try service.coverVectorStats()
            coverVectorMessage = nil
        } catch {
            coverVectorMessage = error.localizedDescription
        }
    }

    func refreshSemanticTitleVectorStats() {
        let service = service
        Task { @MainActor in
            do {
                semanticTitleVectorStats = try await service.semanticTitleVectorStats()
                semanticTitleVectorMessage = nil
            } catch {
                semanticTitleVectorMessage = error.localizedDescription
            }
        }
    }

    func requestSemanticTitleAssets(localizer: AppLocalizer) {
        guard !isDownloadingSemanticTitleAssets else {
            return
        }
        isDownloadingSemanticTitleAssets = true
        semanticTitleVectorMessage = localizer.string(.semanticSeriesDownloadingAssets)
        let service = service
        Task { @MainActor in
            defer { isDownloadingSemanticTitleAssets = false }
            do {
                _ = try await service.requestSemanticTitleAssets()
                semanticTitleVectorStats = try await service.semanticTitleVectorStats()
                semanticTitleVectorMessage = localizer.string(.semanticSeriesAssetsReady)
            } catch {
                semanticTitleVectorMessage = error.localizedDescription
            }
        }
    }

    func rebuildSemanticTitleVectorIndex(localizer: AppLocalizer) {
        runSemanticTitleVectorIndexTask(
            phase: localizer.string(.semanticSeriesRebuildingIndex),
            successMessage: localizer.string(.semanticSeriesIndexReady),
            localizer: localizer
        ) { service, phase, progress in
            try await service.rebuildSemanticTitleVectorIndex(phase: phase, progress: progress)
        }
    }

    func updateSemanticTitleVectorIndex(localizer: AppLocalizer) {
        runSemanticTitleVectorIndexTask(
            phase: localizer.string(.semanticSeriesUpdatingIndex),
            successMessage: localizer.string(.semanticSeriesIndexReady),
            localizer: localizer
        ) { service, phase, progress in
            try await service.updateSemanticTitleVectors(phase: phase, progress: progress)
        }
    }

    private func runSemanticTitleVectorIndexTask(
        phase: String,
        successMessage: String,
        localizer: AppLocalizer,
        operation: @escaping @Sendable (
            BookLibraryService,
            String,
            @escaping @Sendable (SemanticTitleVectorIndexProgress) -> Void
        ) async throws -> SemanticTitleVectorIndexStats
    ) {
        guard !isDeletingBook else { return }
        guard !isUpdatingSemanticTitleVectors else {
            return
        }
        isUpdatingSemanticTitleVectors = true
        semanticTitleVectorMessage = phase
        semanticTitleVectorProgress = .init(phase: phase, completed: 0, total: 1, failed: 0)
        let taskGeneration = UUID()
        mutationTaskGenerations["semanticTitleVectorIndexTask"] = taskGeneration
        let service = service
        retireMutationTask(semanticTitleVectorIndexTask)
        semanticTitleVectorIndexTask = Task { @MainActor in
            defer {
                if self.mutationTaskGenerations["semanticTitleVectorIndexTask"] == taskGeneration {
                    isUpdatingSemanticTitleVectors = false
                }
            }
            do {
                let stats = try await operation(service, phase) { progress in
                    Task { @MainActor in
                        guard self.mutationTaskGenerations["semanticTitleVectorIndexTask"] == taskGeneration, !self.isDeletingBook else { return }
                        self.semanticTitleVectorProgress = progress
                    }
                }
                guard !Task.isCancelled else {
                    return
                }
                semanticTitleVectorStats = stats
                semanticTitleVectorMessage = successMessage
            } catch is CancellationError {
                guard mutationTaskGenerations["semanticTitleVectorIndexTask"] == taskGeneration else { return }
                semanticTitleVectorMessage = localizer.string(.semanticSeriesIndexCancelled)
            } catch {
                semanticTitleVectorMessage = error.localizedDescription
            }
        }
    }

    func rebuildCoverVectorIndex(localizer: AppLocalizer) {
        runCoverVectorIndexTask(
            phase: localizer.string(.coverVectorsRebuilding),
            successMessage: localizer.string(.coverVectorsRebuildFinished)
        ) { service, phase, progress in
            try service.rebuildCoverVectorIndex(phase: phase, progress: progress)
        }
    }

    func updateMissingCoverVectors(
        localizer: AppLocalizer,
        completion: (@MainActor @Sendable (Bool) -> Void)? = nil
    ) {
        runCoverVectorIndexTask(
            phase: localizer.string(.coverVectorsUpdating),
            successMessage: localizer.string(.coverVectorsUpdateFinished),
            completion: completion
        ) { service, phase, progress in
            try service.updateMissingCoverVectors(phase: phase, progress: progress)
        }
    }

    func clearCoverVectorIndex(localizer: AppLocalizer) {
        do {
            try service.clearCoverVectorIndex()
            coverVectorStats = try service.coverVectorStats()
            coverVectorProgress = .idle
            coverVectorMessage = localizer.string(.coverVectorsCleared)
        } catch {
            coverVectorMessage = error.localizedDescription
        }
    }

    func generateCoverDistanceReport(referenceThreshold: Double, localizer: AppLocalizer) {
        guard !isGeneratingCoverDistanceReport else {
            return
        }
        isGeneratingCoverDistanceReport = true
        coverDistanceReport = localizer.string(.coverDistanceReportGenerating)
        let service = service
        coverDistanceReportTask?.cancel()
        coverDistanceReportTask = Task { @MainActor in
            do {
                let report = try await Task.detached(priority: .userInitiated) {
                    try service.coverDistanceReport(referenceThreshold: referenceThreshold)
                }.cancellableValue
                guard !Task.isCancelled else {
                    return
                }
                coverDistanceReport = report
            } catch {
                guard !Task.isCancelled else {
                    return
                }
                coverDistanceReport = error.localizedDescription
            }
            isGeneratingCoverDistanceReport = false
        }
    }

    private func runCoverVectorIndexTask(
        phase: String,
        successMessage: String,
        completion: (@MainActor @Sendable (Bool) -> Void)? = nil,
        operation: @escaping @Sendable (
            BookLibraryService,
            String,
            @escaping @Sendable (CoverVectorIndexProgress) -> Void
        ) throws -> CoverVectorIndexStats
    ) {
        guard !isDeletingBook else { return }
        guard !isUpdatingCoverVectors else {
            return
        }
        isUpdatingCoverVectors = true
        coverVectorMessage = phase
        coverVectorProgress = CoverVectorIndexProgress(phase: phase, completed: 0, total: 1, failed: 0)
        let taskGeneration = UUID()
        mutationTaskGenerations["coverVectorIndexTask"] = taskGeneration
        let service = service
        retireMutationTask(coverVectorIndexTask)
        coverVectorIndexTask = Task { @MainActor in
            do {
                let stats = try await Task.detached(priority: .utility) {
                    try operation(service, phase) { progress in
                        Task { @MainActor in
                            guard self.mutationTaskGenerations["coverVectorIndexTask"] == taskGeneration else { return }
                            self.coverVectorProgress = progress
                        }
                    }
                }.cancellableValue
                guard !Task.isCancelled else {
                    return
                }
                coverVectorStats = stats
                coverVectorMessage = successMessage
                completion?(true)
            } catch {
                guard !Task.isCancelled else {
                    return
                }
                coverVectorMessage = error.localizedDescription
                completion?(false)
            }
            isUpdatingCoverVectors = false
        }
    }

    func acceptCreateVersionGroupRecommendation(_ item: VersionRecommendationDisplayItem) {
        guard !isAcceptingVersionRecommendation else {
            return
        }
        isAcceptingVersionRecommendation = true
        enqueueOrganizationMutation(.acceptCreateVersionGroup(item))
    }

    func acceptAddToSelectedVersionGroupRecommendation(_ item: VersionRecommendationDisplayItem) {
        guard !isAcceptingVersionRecommendation else {
            return
        }
        isAcceptingVersionRecommendation = true
        guard let group = selectedVersionGroupID.flatMap(versionGroup(id:)),
              let recommendedBook = item.books.first else {
            isAcceptingVersionRecommendation = false
            return
        }
        enqueueOrganizationMutation(.acceptAddToVersionGroup(
            item,
            book(id: recommendedBook.id) ?? recommendedBook,
            group
        ))
    }

    func dismissVersionRecommendation(_ item: VersionRecommendationDisplayItem) {
        enqueueOrganizationMutation(.dismissVersion(item))
    }

    private func enqueueOrganizationMutation(
        _ mutation: OrganizationMutation,
        useSemanticSimilarity: Bool = false,
        completion: ((String?) -> Void)? = nil
    ) {
        guard !isDeletingBook else {
            completion?(NyaEHError.groupingRepositoryUnavailable.localizedDescription)
            return
        }
        switch mutation {
        case .createVersionGroup, .addToVersionGroup, .removeFromVersionGroup, .deleteVersionGroup,
             .setPrimaryVersion, .acceptCreateVersionGroup, .acceptAddToVersionGroup:
            flushAllCollectionOrders()
        default:
            break
        }
        let token = UUID()
        let keys = organizationSavingKeys(for: mutation)
        for key in keys { organizationPendingCounts[key, default: 0] += 1 }
        savingOrganizationKeys = Set(organizationPendingCounts.keys)
        isSavingOrganization = true
        pendingOrganizationMutations.append((token, mutation, optimistic: completion == nil))
        if completion == nil { applyOptimisticOrganizationMutation(mutation) }

        let previous = organizationTail
        organizationQueueRevision &+= 1
        let queueRevision = organizationQueueRevision
        let worker = organizationWorker
        let selectedCollection = selectedCollectionID.flatMap(collection(id:))?.databaseID
        let selectedVersionGroup = selectedVersionGroupID.flatMap(versionGroup(id:))?.databaseID
        let task = Task { @MainActor [self] in
            await previous?.value
            do {
                let result = try await worker.execute(
                    mutation,
                    selectedCollectionID: selectedCollection,
                    selectedVersionGroupID: selectedVersionGroup
                )
                pendingOrganizationMutations.removeAll { $0.0 == token }
                applyOrganizationResult(result)
                loadError = result.failures.isEmpty ? nil : result.failures.joined(separator: "\n")
                organizationSaveError = loadError
                if case .acceptCreateCollection = mutation {
                    refreshCollectionRecommendationsAfterAcceptance(
                        focusBookIDs: mutation.bookIDs,
                        useSemanticSimilarity: useSemanticSimilarity
                    )
                } else if case .acceptAddToCollection = mutation {
                    refreshCollectionRecommendationsAfterAcceptance(
                        focusBookIDs: mutation.bookIDs,
                        useSemanticSimilarity: useSemanticSimilarity
                    )
                }
                if case .acceptCreateVersionGroup = mutation { continueImportPipelineReviewIfReady() }
                if case .acceptAddToVersionGroup = mutation { continueImportPipelineReviewIfReady() }
                if case .dismissVersion = mutation { continueImportPipelineReviewIfReady() }
                if case .dismissCollection = mutation { continueImportPipelineReviewIfReady() }
            } catch {
                pendingOrganizationMutations.removeAll { $0.0 == token }
                let errorMessage = error.localizedDescription
                if let snapshot = try? await worker.snapshot(
                    for: mutation,
                    selectedCollectionID: selectedCollection,
                    selectedVersionGroupID: selectedVersionGroup
                ) {
                    applyOrganizationResult(snapshot)
                }
                loadError = errorMessage
                organizationSaveError = errorMessage
            }
            completion?(organizationSaveError)
            for key in keys {
                let remaining = (organizationPendingCounts[key] ?? 1) - 1
                if remaining > 0 { organizationPendingCounts[key] = remaining }
                else { organizationPendingCounts.removeValue(forKey: key) }
            }
            savingOrganizationKeys = Set(organizationPendingCounts.keys)
            isSavingOrganization = !organizationPendingCounts.isEmpty
            switch mutation {
            case .acceptCreateCollection, .acceptAddToCollection:
                isAcceptingCollectionRecommendation = false
            case .acceptCreateVersionGroup, .acceptAddToVersionGroup:
                isAcceptingVersionRecommendation = false
            default: break
            }
            if organizationQueueRevision == queueRevision { organizationTail = nil }
        }
        organizationTail = task
    }

    private func organizationSavingKeys(for mutation: OrganizationMutation) -> Set<String> {
        var keys = Set(mutation.bookIDs.map { "book:\($0)" })
        keys.formUnion(mutation.collectionIDs.map { "collection:\($0)" })
        keys.formUnion(mutation.versionGroupIDs.map { "version:\($0)" })
        if keys.isEmpty { keys.insert("organization") }
        return keys
    }

    func waitForOrganizationMutations() async {
        await organizationTail?.value
    }

    private func applyOrganizationResult(_ result: OrganizationMutationResult) {
        if let updatedCollections = result.collections {
            collections = updatedCollections
            collectionIndex = Dictionary(uniqueKeysWithValues: updatedCollections.map { ($0.id, $0) })
        }
        if let updatedVersionGroups = result.versionGroups {
            versionGroups = updatedVersionGroups
            versionGroupIndex = Dictionary(uniqueKeysWithValues: updatedVersionGroups.map { ($0.id, $0) })
        }
        versionLabelSuggestions = mergedVersionLabelSuggestions(result.labelSuggestions)
        createCollectionRecommendations = result.createCollectionRecommendations
        addToCollectionRecommendationCounts = result.addToCollectionRecommendationCounts
        createVersionGroupRecommendations = result.createVersionRecommendations
        addToVersionGroupRecommendationCounts = result.addToVersionRecommendationCounts
        if selectedCollectionID.flatMap(collection(id:))?.databaseID == result.selectedCollectionID {
            addToSelectedCollectionRecommendations = result.selectedCollectionRecommendations
        }
        if selectedVersionGroupID.flatMap(versionGroup(id:))?.databaseID == result.selectedVersionGroupID {
            addToSelectedVersionGroupRecommendations = result.selectedVersionRecommendations
        }
        patchOrganizationBooks(result.books)
        if result.books.isEmpty { scheduleOrganizationDerivedRefresh() }
        if let createdCollectionID = result.createdCollectionID { selectedCollectionID = String(createdCollectionID) }
        if let createdVersionGroupID = result.createdVersionGroupID { selectedVersionGroupID = String(createdVersionGroupID) }
        if selectedCollectionID.flatMap(collection(id:)) == nil { selectedCollectionID = nil }
        if selectedVersionGroupID.flatMap(versionGroup(id:)) == nil { selectedVersionGroupID = versionGroups.first?.id }
        for (_, mutation, optimistic) in pendingOrganizationMutations where optimistic { applyOptimisticOrganizationMutation(mutation) }
        reloadAddToSelectedCollectionRecommendationsAsync()
        reloadAddToSelectedVersionGroupRecommendationsAsync()
        if !result.books.isEmpty { changeBus.publish(.booksUpserted(result.books)) }
        reloadSearchAfterLibraryChange()
    }

    private func applyOptimisticOrganizationMutation(_ mutation: OrganizationMutation) {
        switch mutation {
        case .renameCollection(let collection, let name):
            guard let index = collections.firstIndex(where: { $0.id == collection.id }) else { return }
            collections[index].name = name.trimmingCharacters(in: .whitespacesAndNewlines)
            collectionIndex[collections[index].id] = collections[index]
        case .addToCollection(let members, let collection):
            guard let collectionID = collection.databaseID else { return }
            var nextOrder = (booksByCollectionID[collectionID]?.compactMap(\.collectionOrder).max() ?? -1) + 1
            var changed: [LibraryBook] = []
            var seen = Set<LibraryBook.ID>()
            for member in members where !seen.contains(member.id) {
                let current = bookIndex[member.id] ?? member
                let companions = current.versionGroupID.flatMap { booksByVersionGroupID[$0] } ?? [current]
                seen.formUnion(companions.map(\.id))
                let assigned = companions.filter { $0.collectionID == collectionID }
                let existingOrder = assigned.first(where: \.isPrimaryVersion)?.collectionOrder
                    ?? assigned.compactMap(\.collectionOrder).min()
                let order = existingOrder ?? nextOrder
                for var companion in companions {
                    companion.collectionID = collectionID
                    companion.collectionOrder = order
                    companion.hiddenBook = true
                    changed.append(companion)
                }
                if existingOrder == nil { nextOrder += 1 }
            }
            patchOrganizationBooks(changed)
        case .removeFromCollection(let member, _):
            let current = bookIndex[member.id] ?? member
            let companions = current.versionGroupID.flatMap { booksByVersionGroupID[$0] } ?? [current]
            patchOrganizationBooks(companions.map { companion in
                var updated = companion
                updated.collectionID = nil
                updated.collectionOrder = nil
                updated.hiddenBook = updated.versionGroupID != nil && !updated.isPrimaryVersion
                return updated
            })
        case .removeFromCollectionBatch(let members, _):
            for member in members {
                let current = bookIndex[member.id] ?? member
                let companions = current.versionGroupID.flatMap { booksByVersionGroupID[$0] } ?? [current]
                patchOrganizationBooks(companions.map { companion in
                    var updated = companion
                    updated.collectionID = nil
                    updated.collectionOrder = nil
                    updated.hiddenBook = updated.versionGroupID != nil && !updated.isPrimaryVersion
                    return updated
                })
            }
        case .reorderCollection(let members, let collection):
            guard let collectionID = collection.databaseID else { return }
            applyOptimisticCollectionOrder(members, collectionID: collectionID, shouldCommit: false)
        case .setPrimaryVersion(let member):
            guard let groupID = (bookIndex[member.id] ?? member).versionGroupID else { return }
            let members = booksByVersionGroupID[groupID] ?? []
            let logicalOrder = members.first(where: \.isPrimaryVersion)?.collectionOrder
            patchOrganizationBooks(members.map { companion in
                var updated = companion
                updated.isPrimaryVersion = companion.id == member.id
                updated.hiddenBook = updated.collectionID != nil || !updated.isPrimaryVersion
                if updated.collectionID != nil { updated.collectionOrder = logicalOrder }
                return updated
            })
        case .setVersionLabels(let labels, let member):
            guard var current = bookIndex[member.id] else { return }
            current.versionLabel = VersionLabelFormatter.displayText(for: VersionLabelFormatter.normalizedLabels(labels))
            patchOrganizationBooks([current])
        default: break
        }
    }

    private func patchOrganizationBooks(_ updatedBooks: [LibraryBook]) {
        guard !updatedBooks.isEmpty else { return }
        var touchedCollections = Set<BookCollection.DatabaseID>()
        var touchedVersionGroups = Set<BookVersionGroup.DatabaseID>()
        let changedIDs = Set(updatedBooks.map(\.id))
        for updated in updatedBooks {
            if let old = bookIndex[updated.id] {
                if let oldCollectionID = old.collectionID { touchedCollections.insert(oldCollectionID) }
                if let oldVersionGroupID = old.versionGroupID { touchedVersionGroups.insert(oldVersionGroupID) }
            }
            if let newCollectionID = updated.collectionID { touchedCollections.insert(newCollectionID) }
            if let newVersionGroupID = updated.versionGroupID { touchedVersionGroups.insert(newVersionGroupID) }
            if let position = bookPositions[updated.id] { books[position] = updated }
            bookIndex[updated.id] = updated
        }
        for collectionID in touchedCollections {
            var members = booksByCollectionID[collectionID] ?? []
            members.removeAll { changedIDs.contains($0.id) }
            members.append(contentsOf: updatedBooks.filter { $0.collectionID == collectionID })
            members.sort(by: collectionSort)
            booksByCollectionID[collectionID] = members
            displayBooksByCollectionID[collectionID] = members.filter(\.isPrimaryVersion)
        }
        for groupID in touchedVersionGroups {
            var members = booksByVersionGroupID[groupID] ?? []
            members.removeAll { changedIDs.contains($0.id) }
            members.append(contentsOf: updatedBooks.filter { $0.versionGroupID == groupID })
            members.sort(by: versionGroupSort)
            booksByVersionGroupID[groupID] = members
        }
        if updatedBooks.count <= 16 {
            collectionCandidateBaseBooks.removeAll { changedIDs.contains($0.id) }
            versionCandidateBaseBooks.removeAll { changedIDs.contains($0.id) }
            for book in updatedBooks {
                if book.collectionID == nil && isPrimaryDisplayVersion(book) {
                    Self.insertManagementCandidate(book, into: &collectionCandidateBaseBooks)
                }
                if book.versionGroupID == nil {
                    Self.insertManagementCandidate(book, into: &versionCandidateBaseBooks)
                }
            }
        }
        collectionOrderRevision &+= 1
        derivedDataRevision &+= 1
        scheduleOrganizationDerivedRefresh()
    }

    private static func insertManagementCandidate(_ book: LibraryBook, into candidates: inout [LibraryBook]) {
        let title = BookTitleFormatter.displayTitle(for: book, mode: .originalTitle)
        var lower = 0
        var upper = candidates.count
        while lower < upper {
            let middle = (lower + upper) / 2
            let middleTitle = BookTitleFormatter.displayTitle(for: candidates[middle], mode: .originalTitle)
            if middleTitle.localizedCaseInsensitiveCompare(title) == .orderedAscending { lower = middle + 1 }
            else { upper = middle }
        }
        candidates.insert(book, at: lower)
    }

    private func scheduleOrganizationDerivedRefresh() {
        organizationProjectionRevision &+= 1
        let revision = organizationProjectionRevision
        organizationProjectionTask?.cancel()
        let snapshot = books
        let states = readingStates
        let currentCollections = collections
        let currentSearchText = searchText
        let currentFilter = filter
        let worker = organizationProjectionWorker
        organizationProjectionTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(60))
            guard !Task.isCancelled else { return }
            guard let derived = await worker.build(
                books: snapshot,
                readingStates: states,
                collections: currentCollections,
                searchText: currentSearchText,
                filter: currentFilter
            ), let self, !Task.isCancelled, revision == organizationProjectionRevision else { return }
            guard currentCollections == collections,
                  currentSearchText == searchText, currentFilter == filter else {
                scheduleOrganizationDerivedRefresh()
                return
            }
            collectionCandidateBaseBooks = derived.collectionCandidates
            versionCandidateBaseBooks = derived.versionCandidates
            recommendedBooks = derived.recommendedBooks
            homeFavoritePreview = derived.homeFavoritePreview
            favoriteManagementBooks = derived.favoriteManagementBooks
            continueReadingBooks = derived.continueReadingBooks
            recentlyViewedBooks = derived.recentlyViewedBooks
            recentlyAddedBooks = derived.recentlyAddedBooks
            homeArrivalDays = derived.homeArrivalDays
            searchedBooks = derived.searchedBooks
            displayItems = derived.displayItems
            filteredDisplayItems = derived.filteredDisplayItems
            filteredBooks = derived.filteredBooks
            derivedDataRevision &+= 1
            organizationProjectionTask = nil
        }
    }

    func versionLabelSuggestions(matching query: String) -> [VersionLabelSuggestion] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return versionLabelSuggestions
        }

        let lowered = trimmed.lowercased()
        return versionLabelSuggestions
            .filter { $0.label.lowercased().contains(lowered) }
            .sorted { lhs, rhs in
                let lhsLowered = lhs.label.lowercased()
                let rhsLowered = rhs.label.lowercased()
                let lhsPrefix = lhsLowered.hasPrefix(lowered)
                let rhsPrefix = rhsLowered.hasPrefix(lowered)
                if lhsPrefix != rhsPrefix {
                    return lhsPrefix
                }
                if lhs.usageCount != rhs.usageCount {
                    return lhs.usageCount > rhs.usageCount
                }
                if lhs.lastUsedAt != rhs.lastUsedAt {
                    return lhs.lastUsedAt > rhs.lastUsedAt
                }
                return lhs.label.localizedCaseInsensitiveCompare(rhs.label) == .orderedAscending
            }
    }

    private func mergedVersionLabelSuggestions(_ suggestions: [VersionLabelSuggestion]) -> [VersionLabelSuggestion] {
        var result = suggestions
        let existing = Set(suggestions.map { $0.label.lowercased() })
        for preset in VersionLabelPreset.all where !existing.contains(preset.lowercased()) {
            result.append(VersionLabelSuggestion(label: preset, usageCount: 0))
        }
        return result.sorted { lhs, rhs in
            if lhs.usageCount != rhs.usageCount {
                return lhs.usageCount > rhs.usageCount
            }
            if lhs.lastUsedAt != rhs.lastUsedAt {
                return lhs.lastUsedAt > rhs.lastUsedAt
            }
            return lhs.label.localizedStandardCompare(rhs.label) == .orderedAscending
        }
    }

    func collectionCandidateBooks(for _: BookCollection, query: String) -> [LibraryBook] {
        collectionCandidateBaseBooks
            .filter { matchesManagementSearch($0, query: query) }
    }

    func collectionCandidateBooksAsync(query: String) async -> [LibraryBook] {
        let candidates = collectionCandidateBaseBooks
        return await organizationProjectionWorker.filterCandidates(candidates, query: query)
    }

    func versionCandidateBooks(query: String) -> [LibraryBook] {
        versionCandidateBaseBooks
            .filter { matchesManagementSearch($0, query: query) }
    }

    func versionCandidateBooksAsync(query: String) async -> [LibraryBook] {
        let candidates = versionCandidateBaseBooks
        return await organizationProjectionWorker.filterCandidates(candidates, query: query)
    }

    func scanLibrary(
        rootURL: URL,
        localizer: AppLocalizer,
        onCompletion: @escaping @MainActor (LibraryScanResult) -> Void = { _ in }
    ) {
        guard !isDeletingBook else { return }
        // 扫描读取原始 archive，耗时和 IO 都不可预期；完成后统一刷新标签、作品索引和封面向量缓存。
        guard !isScanning else {
            return
        }

        isScanning = true
        lastScanRootURL = rootURL
        let taskGeneration = UUID()
        mutationTaskGenerations["scanTask"] = taskGeneration
        let service = service
        scanProgress = .init(phase: localizer.string(.starting), completed: 0, total: 1)
        let progressHandler: @Sendable (LibraryScanProgress) -> Void = { [weak self] progress in
            Task { @MainActor [weak self] in
                guard let self, self.mutationTaskGenerations["scanTask"] == taskGeneration else { return }
                self.scanProgress = progress
            }
        }
        retireMutationTask(scanTask)
        scanTask = Task { @MainActor in
            defer {
                if self.mutationTaskGenerations["scanTask"] == taskGeneration {
                    isScanning = false
                    scanTask = nil
                }
            }

            do {
                let result = try await Task.detached(priority: .utility) {
                    try service.scanLibrary(
                        rootURL: rootURL,
                        progress: progressHandler,
                        isCancelled: { Task.isCancelled }
                    )
                }.cancellableValue
                guard !Task.isCancelled else {
                    return
                }
                scanSummary = localizer.scanSummary(result)
                onCompletion(result)
                invalidateTagSummaries()
                refresh()
                reloadImportPipeline()
                updateWorkCharacterIndexIfNeeded(localizer: localizer)
                updateMissingCoverVectors(localizer: localizer)
                if lastTaskFailure?.kind == .scan { lastTaskFailure = nil }
            } catch {
                guard !Task.isCancelled else {
                    return
                }
                loadError = error.localizedDescription
                lastTaskFailure = .init(
                    kind: .scan,
                    title: localizer.string(.scanLibrary),
                    detail: error.localizedDescription,
                    canRetry: true
                )
            }
        }
    }

    func cancelLibraryScan() {
        retireMutationTask(scanTask)
        scanTask = nil
        isScanning = false
    }

    func importExhentaiMangaManager(from folderURL: URL, localizer: AppLocalizer) {
        guard !isDeletingBook else { return }
        guard !isImporting else {
            return
        }

        isImporting = true
        lastImportFolderURL = folderURL
        importSummary = nil
        importBackupPath = nil
        importProgress = ExternalLibraryImportProgress(
            phase: localizer.string(.importValidating),
            completed: 0,
            total: 7
        )
        let taskGeneration = UUID()
        mutationTaskGenerations["importTask"] = taskGeneration
        let service = service
        let progressHandler: @Sendable (ExternalLibraryImportProgress) -> Void = { [weak self] progress in
            Task { @MainActor [weak self] in
                guard self?.mutationTaskGenerations["importTask"] == taskGeneration else { return }
                self?.importProgress = progress.localized(with: localizer)
            }
        }
        retireMutationTask(importTask)
        importTask = Task { @MainActor [weak self] in
            defer {
                if self?.mutationTaskGenerations["importTask"] == taskGeneration {
                    self?.isImporting = false
                    self?.importTask = nil
                }
            }
            do {
                let result = try await Task.detached(priority: .utility) {
                    try service.importExhentaiMangaManager(from: folderURL, progress: progressHandler)
                }.cancellableValue
                guard !Task.isCancelled, let self else { return }
                importBackupPath = result.backupURL.path
                importSummary = localizer.importSummary(result)
                invalidateTagSummaries()
                refresh()
                updateWorkCharacterIndexIfNeeded(localizer: localizer)
                updateMissingCoverVectors(localizer: localizer)
                loadError = nil
                if lastTaskFailure?.kind == .externalImport { lastTaskFailure = nil }
            } catch is CancellationError {
                return
            } catch {
                guard let self else { return }
                loadError = error.localizedDescription
                importSummary = error.localizedDescription
                lastTaskFailure = .init(
                    kind: .externalImport,
                    title: localizer.string(.importExternalLibrary),
                    detail: error.localizedDescription,
                    canRetry: true
                )
            }
        }
    }

    func cancelImport() {
        retireMutationTask(importTask)
        importTask = nil
        isImporting = false
    }

    func retryLastFailedTask(localizer: AppLocalizer) {
        guard let failure = lastTaskFailure else { return }
        switch failure.kind {
        case .scan:
            if let lastScanRootURL { scanLibrary(rootURL: lastScanRootURL, localizer: localizer) }
        case .externalImport:
            if let lastImportFolderURL { importExhentaiMangaManager(from: lastImportFolderURL, localizer: localizer) }
        case .metadata:
            resumeMetadataBatch(localizer: localizer)
        case .importPipeline, .workCharacterIndex, .collectionRecommendations, .versionRecommendations,
             .coverVectors, .semanticTitleVectors, .tagTranslations, .lastFailure:
            break
        }
    }

    func cancelCoverVectorTask() {
        retireMutationTask(coverVectorIndexTask)
        coverVectorIndexTask = nil
        isUpdatingCoverVectors = false
    }

    func cancelSemanticTitleVectorTask() {
        retireMutationTask(semanticTitleVectorIndexTask)
        semanticTitleVectorIndexTask = nil
        isUpdatingSemanticTitleVectors = false
    }

    func cancelRecommendationTasks() {
        retireMutationTask(collectionRecommendationRefreshTask)
        retireMutationTask(versionRecommendationRefreshTask)
        collectionRecommendationRefreshTask = nil
        versionRecommendationRefreshTask = nil
        isRefreshingCollectionRecommendations = false
        isRefreshingVersionRecommendations = false
    }

    func cancelWorkCharacterIndexTask() {
        retireMutationTask(workCharacterIndexTask)
        workCharacterIndexTask = nil
        isUpdatingWorkCharacterIndex = false
    }

    func fetchMetadataForSelectedBook(
        configuration: GalleryMetadataFetchConfiguration,
        localizer: AppLocalizer
    ) async {
        guard !isDeletingBook else { return }
        guard !isFetchingMetadata, !metadataBatchProgress.isActive, let selectedBook else {
            return
        }

        isFetchingMetadata = true
        metadataFetchMessage = localizer.string(.fetchingMetadata)
        defer {
            isFetchingMetadata = false
        }

        do {
            let service = service
            let task = Task { try await service.fetchMetadata(
                for: selectedBook,
                configuration: configuration
            ) }
            manualMetadataTask = task
            defer { manualMetadataTask = nil }
            let updatedBook = try await task.cancellableValue
            guard !isDeletingBook, books.contains(where: { $0.databaseID == updatedBook.databaseID }) else { return }
            refresh()
            invalidateTagSummaries()
            selectedBookID = updatedBook.id
            metadataFetchMessage = localizer.string(.metadataFetchSucceeded)
            updateWorkCharacterIndexIfNeeded(localizer: localizer)
            loadError = nil
        } catch {
            metadataFetchMessage = error.localizedDescription
            loadError = error.localizedDescription
        }
    }

    func fetchMetadataForSelectedBook(
        galleryURLString: String,
        configuration: GalleryMetadataFetchConfiguration,
        localizer: AppLocalizer
    ) async {
        guard !isDeletingBook else { return }
        guard !isFetchingMetadata, !metadataBatchProgress.isActive, let selectedBook else {
            return
        }
        _ = await fetchMetadata(
            for: selectedBook,
            galleryURLString: galleryURLString,
            configuration: configuration,
            localizer: localizer
        )
    }

    func fetchMetadata(
        for book: LibraryBook,
        galleryURLString: String,
        configuration: GalleryMetadataFetchConfiguration,
        localizer: AppLocalizer
    ) async -> LibraryBook? {
        guard !isDeletingBook else { return nil }
        guard !isFetchingMetadata, !metadataBatchProgress.isActive else {
            return nil
        }
        let trimmed = galleryURLString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed), GalleryMetadataFetchService.isSupportedGalleryURL(url) else {
            metadataFetchMessage = BookMetadataEditError.invalidGalleryURL.localizedDescription
            loadError = metadataFetchMessage
            return nil
        }

        isFetchingMetadata = true
        metadataFetchMessage = localizer.string(.fetchingMetadata)
        defer {
            isFetchingMetadata = false
        }

        do {
            let service = service
            let task = Task { try await service.fetchMetadata(
                for: book,
                galleryURL: url,
                configuration: configuration
            ) }
            manualMetadataTask = task
            defer { manualMetadataTask = nil }
            let updatedBook = try await task.cancellableValue
            guard !isDeletingBook, books.contains(where: { $0.databaseID == updatedBook.databaseID }) else { return nil }
            refresh()
            invalidateTagSummaries()
            selectedBookID = updatedBook.id
            metadataFetchMessage = localizer.string(.metadataFetchSucceeded)
            updateWorkCharacterIndexIfNeeded(localizer: localizer)
            loadError = nil
            return updatedBook
        } catch {
            metadataFetchMessage = error.localizedDescription
            loadError = error.localizedDescription
            return nil
        }
    }

    func saveMetadataDraft(
        _ draft: BookMetadataEditDraft,
        for book: LibraryBook,
        localizer: AppLocalizer
    ) throws -> LibraryBook {
        let updatedBook = try service.saveManualMetadataDraft(draft, for: book)
        refresh()
        invalidateTagSummaries()
        selectedBookID = updatedBook.id
        updateWorkCharacterIndexIfNeeded(localizer: localizer)
        loadError = nil
        return updatedBook
    }

    func clearMetadata(for book: LibraryBook, localizer: AppLocalizer) throws -> LibraryBook {
        let updatedBook = try service.clearMetadata(for: book)
        refresh()
        invalidateTagSummaries()
        selectedBookID = updatedBook.id
        updateWorkCharacterIndexIfNeeded(localizer: localizer)
        loadError = nil
        return updatedBook
    }

    func rescanCover(for book: LibraryBook, localizer: AppLocalizer) {
        guard !isRescanningCover else {
            return
        }

        isRescanningCover = true
        coverRescanMessage = localizer.string(.rescanningCover)
        defer {
            isRescanningCover = false
        }

        do {
            let oldCoverPath = book.coverPath
            let updatedBook = try service.rescanCover(for: book)
            if let oldCoverPath {
                CoverImageCache.shared.removeImage(for: oldCoverPath)
            }
            if let updatedCoverPath = updatedBook.coverPath {
                CoverImageCache.shared.removeImage(for: updatedCoverPath)
            }
            refresh()
            selectedBookID = updatedBook.id
            coverRescanMessage = localizer.string(.coverRescanSucceeded)
            updateMissingCoverVectors(localizer: localizer)
            loadError = nil
        } catch {
            refresh()
            coverRescanMessage = localizer.string(.coverRescanFailed)
            loadError = error.localizedDescription
        }
    }

    private func retireMutationTask(_ task: Task<Void, Never>?) {
        guard let task else { return }
        task.cancel()
        let id = UUID()
        retiredMutationTasks[id] = task
        Task { @MainActor [weak self] in
            await task.value
            self?.retiredMutationTasks[id] = nil
        }
    }

    func deleteBookAndSourceFile(_ book: LibraryBook, securityScopedRootURL: URL? = nil) async {
        guard !isDeletingBook, let bookID = book.databaseID else { return }
        flushAllCollectionOrders()
        isDeletingBook = true
        deletingBookIDs.insert(bookID)
        deletionCleanupWarning = nil
        defer {
            deletingBookIDs.remove(bookID)
            isDeletingBook = false
        }
        // Hold the mutation gate until every retained worker has actually exited.
        // No replacement task can start while this operation waits.
        let tasks = [scanTask, importTask, metadataBatchTask, importPipelineTask,
                     collectionRecommendationRefreshTask, versionRecommendationRefreshTask,
                     coverVectorIndexTask, semanticTitleVectorIndexTask, workCharacterIndexTask]
            .compactMap { $0 } + Array(retiredMutationTasks.values)
        let metadataTask = manualMetadataTask
        metadataTask?.cancel()
        tasks.forEach { $0.cancel() }
        _ = try? await metadataTask?.value
        for task in tasks { await task.value }
        await organizationTail?.value
        if var batch = try? service.loadImportPipelineSnapshot().activeBatch, batch.status == .running {
            batch.status = .paused
            try? service.updateImportPipelineBatch(batch)
        }
        isRefreshingVersionRecommendations = false
        isRefreshingCollectionRecommendations = false
        isUpdatingCoverVectors = false
        isUpdatingSemanticTitleVectors = false
        isUpdatingWorkCharacterIndex = false
        if metadataBatchProgress.isActive { metadataBatchProgress.state = .paused }
        readingProgressTasks[bookID]?.cancel()
        readingProgressTasks[bookID] = nil
        pendingReadingProgress[bookID] = nil
        readingProgressRevisions[bookID, default: 0] += 1
        do {
            let service = service
            let result = try await Task.detached(priority: .userInitiated) {
                try service.deleteBookAndSourceFile(book, securityScopedRootURL: securityScopedRootURL)
            }.value
            // Once the file operation starts it completes its journal protocol even if the view disappears.
            deletionCleanupWarning = result.cleanupWarning
            if let path = book.coverPath { CoverImageCache.shared.removeImage(for: path) }
            invalidateWorkDetails()
            invalidateTagSummaries()
            refresh()
            changeBus.publish(.booksDeleted([bookID]))
            if !collections.contains(where: { $0.id == selectedCollectionID }) { selectedCollectionID = nil }
            if !versionGroups.contains(where: { $0.id == selectedVersionGroupID }) { selectedVersionGroupID = nil }
            loadError = nil
        } catch {
            refresh()
            loadError = error.localizedDescription
        }
        // Release the gate before a settled review starts the next analysis wave.
        deletingBookIDs.remove(bookID)
        isDeletingBook = false
        if loadError == nil { continueImportPipelineReviewIfReady() }
    }

    func reloadImportPipeline() {
        do {
            try service.reconcileImportPipeline(books: books)
            importPipelineSnapshot = try service.loadImportPipelineSnapshot()
        } catch {
            importPipelineMessage = error.localizedDescription
            loadError = error.localizedDescription
        }
    }

    func startImportPipeline(
        securityScopedRootURL: URL,
        configuration: MetadataBatchConfiguration,
        useCoverSimilarity: Bool,
        useSemanticSeriesSimilarity: Bool,
        maximumCoverDistance: Double,
        localizer: AppLocalizer
    ) {
        guard !isDeletingBook else { return }
        guard !isProcessingImportPipeline, !metadataBatchProgress.isActive else { return }
        reloadImportPipeline()
        importPipelineUsesSemanticSeries = useSemanticSeriesSimilarity
        isProcessingImportPipeline = true
        importPipelineMessage = localizer.string(.starting)
        let taskGeneration = UUID()
        mutationTaskGenerations["importPipelineTask"] = taskGeneration
        retireMutationTask(importPipelineTask)
        let predecessors = Array(retiredMutationTasks.values)
        importPipelineTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                if self.mutationTaskGenerations["importPipelineTask"] == taskGeneration {
                    isProcessingImportPipeline = false
                    importPipelineTask = nil
                    reloadImportPipeline()
                }
            }
            do {
                // A quick pause/resume must finish the old item's cancellation bookkeeping
                // before reading the batch snapshot for the replacement run.
                for predecessor in predecessors { await predecessor.value }
                try Task.checkCancellation()
                guard var batch = try service.createImportPipelineBatch() else {
                    importPipelineMessage = localizer.string(.metadataBatchNoEligibleBooks)
                    return
                }
                if batch.stage == .metadata, batch.status == .paused {
                    try prepareImportPipelineMetadataResume(batchID: batch.id)
                }
                batch.status = .running
                batch.pauseReason = nil
                try service.updateImportPipelineBatch(batch)
                try await runImportPipeline(
                    batch: batch,
                    securityScopedRootURL: securityScopedRootURL,
                    configuration: configuration,
                    useCoverSimilarity: useCoverSimilarity,
                    maximumCoverDistance: maximumCoverDistance,
                    localizer: localizer
                )
            } catch is CancellationError {
                return
            } catch {
                importPipelineMessage = error.localizedDescription
                loadError = error.localizedDescription
                if var batch = try? service.loadImportPipelineSnapshot().activeBatch {
                    batch.status = .paused
                    batch.pauseReason = error.localizedDescription
                    try? service.updateImportPipelineBatch(batch)
                }
            }
        }
    }

    func pauseImportPipeline() {
        retireMutationTask(importPipelineTask)
        importPipelineTask = nil
        isProcessingImportPipeline = false
        if var batch = importPipelineSnapshot.activeBatch {
            batch.status = .paused
            batch.pauseReason = "Paused by user."
            try? service.updateImportPipelineBatch(batch)
        }
        reloadImportPipeline()
    }

    func retryImportPipelineItem(_ item: ImportPipelineItem, preferredGalleryURL: String? = nil) {
        var updated = item
        updated.batchID = nil
        updated.stage = .metadataPending
        updated.preferredGalleryURL = preferredGalleryURL ?? item.preferredGalleryURL
        updated.attemptCount = 0
        updated.lastErrorKind = nil
        updated.lastErrorMessage = nil
        updated.retryAfter = nil
        updated.completedAt = nil
        do {
            try service.updateImportPipelineItem(updated)
            reloadImportPipeline()
        } catch {
            loadError = error.localizedDescription
        }
    }

    func skipImportPipelineMetadata(_ item: ImportPipelineItem) {
        var updated = item
        updated.stage = .completedMetadataSkipped
        updated.metadataSource = .skipped
        updated.lastErrorKind = nil
        updated.lastErrorMessage = nil
        updated.retryAfter = nil
        updated.completedAt = Timestamp.nowMilliseconds()
        do {
            try service.updateImportPipelineItem(updated)
            reloadImportPipeline()
        } catch {
            loadError = error.localizedDescription
        }
    }

    func resetDismissedImportRecommendations(for book: LibraryBook) {
        do {
            try service.resetDismissedRecommendations(for: book)
            if book.status == .correct,
               let bookID = book.databaseID,
               var item = try service.importPipelineItem(bookID: bookID) {
                item.batchID = nil
                item.stage = .versionAnalysisPending
                item.completedAt = nil
                try service.updateImportPipelineItem(item)
            }
            reloadVersionRecommendations()
            reloadCollectionRecommendations()
            reloadImportPipeline()
        } catch {
            loadError = error.localizedDescription
        }
    }

    private func continueImportPipelineReviewIfReady() {
        guard !isDeletingBook else { return }
        guard !isProcessingImportPipeline,
              let initialBatch = (try? service.loadImportPipelineSnapshot())?.activeBatch,
              initialBatch.status == .waitingForReview else {
            return
        }

        isProcessingImportPipeline = true
        let taskGeneration = UUID()
        mutationTaskGenerations["importPipelineTask"] = taskGeneration
        retireMutationTask(importPipelineTask)
        importPipelineTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                if self.mutationTaskGenerations["importPipelineTask"] == taskGeneration {
                    isProcessingImportPipeline = false
                    importPipelineTask = nil
                    reloadImportPipeline()
                }
            }
            do {
                var batch = initialBatch
                switch batch.stage {
                case .versionReview:
                    let focus = try pipelineFocusBookIDs(batchID: batch.id, stages: [.versionReviewPending])
                    guard try service.pendingVersionRecommendationCount(involving: focus) == 0 else { return }
                    try movePipelineItems(
                        batchID: batch.id,
                        from: .versionReviewPending,
                        to: .collectionAnalysisPending
                    )
                    batch.stage = .collectionAnalysis
                    batch.status = .running
                    batch.reviewCount = 0
                    try service.updateImportPipelineBatch(batch)
                    try await runImportCollectionAnalysis(
                        batch: &batch,
                        useSemanticSimilarity: importPipelineUsesSemanticSeries
                    )
                case .collectionReview:
                    let focus = try pipelineCollectionFocusBookIDs(batchID: batch.id)
                    guard try service.pendingCollectionRecommendationCount(involving: focus) == 0 else { return }
                    try completeImportPipelineBatch(&batch)
                default:
                    return
                }
            } catch {
                importPipelineMessage = error.localizedDescription
                loadError = error.localizedDescription
            }
        }
    }

    private func runImportPipeline(
        batch initialBatch: ImportPipelineBatch,
        securityScopedRootURL: URL,
        configuration: MetadataBatchConfiguration,
        useCoverSimilarity: Bool,
        maximumCoverDistance: Double,
        localizer: AppLocalizer
    ) async throws {
        var batch = initialBatch
        if batch.stage == .metadata {
            try await runImportMetadataStage(
                batch: &batch,
                securityScopedRootURL: securityScopedRootURL,
                configuration: configuration,
                localizer: localizer
            )
            guard batch.status == .running else { return }
        }
        if batch.stage == .versionReview {
            let focus = try pipelineFocusBookIDs(batchID: batch.id, stages: [.versionReviewPending])
            if try service.pendingVersionRecommendationCount(involving: focus) > 0 {
                batch.status = .waitingForReview
                try service.updateImportPipelineBatch(batch)
                return
            }
            try movePipelineItems(batchID: batch.id, from: .versionReviewPending, to: .collectionAnalysisPending)
            batch.stage = .collectionAnalysis
            batch.status = .running
            try service.updateImportPipelineBatch(batch)
        }
        if batch.stage == .versionAnalysis {
            try await runImportVersionAnalysis(
                batch: &batch,
                useCoverSimilarity: useCoverSimilarity,
                maximumCoverDistance: maximumCoverDistance
            )
            guard batch.stage != .versionReview else { return }
        }
        if batch.stage == .collectionReview {
            let focus = try pipelineCollectionFocusBookIDs(batchID: batch.id)
            if try service.pendingCollectionRecommendationCount(involving: focus) > 0 {
                batch.status = .waitingForReview
                try service.updateImportPipelineBatch(batch)
                return
            }
            try completeImportPipelineBatch(&batch)
            return
        }
        if batch.stage == .collectionAnalysis {
            try await runImportCollectionAnalysis(
                batch: &batch,
                useSemanticSimilarity: importPipelineUsesSemanticSeries
            )
        }
    }

    private func prepareImportPipelineMetadataResume(batchID: ImportPipelineBatch.ID) throws {
        for var item in try service.importPipelineItems(batchID: batchID)
            where item.stage == .metadataDeferred && item.retryAfter != nil {
            item.stage = .metadataPending
            item.retryAfter = nil
            try service.updateImportPipelineItem(item)
        }
    }

    private func updateImportPipelineCounts(_ batch: inout ImportPipelineBatch) throws {
        let items = try service.importPipelineItems(batchID: batch.id)
        batch.readyCount = items.count(where: {
            $0.stage == .versionAnalysisPending
                || $0.stage == .versionReviewPending
                || $0.stage == .collectionAnalysisPending
                || $0.stage == .collectionReviewPending
                || $0.stage == .completed
        })
        batch.deferredCount = items.count(where: {
            $0.stage == .metadataDeferred || $0.stage == .sourceNeedsAttention
        })
        try service.updateImportPipelineBatch(batch)
        importPipelineSnapshot = try service.loadImportPipelineSnapshot()
    }

    private func runImportMetadataStage(
        batch: inout ImportPipelineBatch,
        securityScopedRootURL: URL,
        configuration: MetadataBatchConfiguration,
        localizer: AppLocalizer
    ) async throws {
        var items = try service.importPipelineItems(batchID: batch.id)
        let persistedBooks = try service.loadBooks()
        var consecutiveTransientFailures = 0
        for index in items.indices where items[index].stage == .metadataPending {
            try Task.checkCancellation()
            guard let book = books.first(where: { $0.databaseID == items[index].bookID })
                ?? persistedBooks.first(where: { $0.databaseID == items[index].bookID }) else {
                items[index].stage = .sourceNeedsAttention
                items[index].lastErrorKind = "missingBook"
                items[index].lastErrorMessage = "The library record no longer exists."
                try service.updateImportPipelineItem(items[index])
                try updateImportPipelineCounts(&batch)
                continue
            }
            guard book.exist, book.status != .broken, book.status != .missing else {
                items[index].stage = .sourceNeedsAttention
                items[index].lastErrorKind = "sourceUnavailable"
                items[index].lastErrorMessage = "The source archive is missing or broken."
                try service.updateImportPipelineItem(items[index])
                try updateImportPipelineCounts(&batch)
                continue
            }

            items[index].stage = .metadataRunning
            items[index].attemptCount += 1
            try service.updateImportPipelineItem(items[index])
            importPipelineMessage = BookTitleFormatter.displayTitle(for: book, mode: metadataBatchTitleDisplayMode)

            let result = await fetchImportPipelineMetadata(
                book: book,
                item: items[index],
                securityScopedRootURL: securityScopedRootURL,
                configuration: configuration
            )
            switch result {
            case .success(let updatedBook, let source, let usedRemote):
                consecutiveTransientFailures = 0
                items[index].stage = .versionAnalysisPending
                items[index].metadataSource = source
                items[index].lastErrorKind = nil
                items[index].lastErrorMessage = nil
                items[index].retryAfter = nil
                try service.updateImportPipelineItem(items[index])
                applyBookUpdatesIncrementally([updatedBook])
                try updateImportPipelineCounts(&batch)
                if usedRemote, items[index].id != items.last?.id {
                    try await waitForImportPipeline(seconds: configuration.nextDelaySeconds())
                }
            case .deferred(let kind, let message, let transient):
                if transient { consecutiveTransientFailures += 1 } else { consecutiveTransientFailures = 0 }
                items[index].stage = .metadataDeferred
                items[index].lastErrorKind = kind
                items[index].lastErrorMessage = message
                items[index].retryAfter = transient
                    ? Timestamp.nowMilliseconds() + 60_000
                    : nil
                try service.updateImportPipelineItem(items[index])
                try updateImportPipelineCounts(&batch)
                if consecutiveTransientFailures >= 3 {
                    batch.status = .paused
                    batch.pauseReason = message
                    try service.updateImportPipelineBatch(batch)
                    importPipelineMessage = message
                    return
                }
            case .pause(let kind, let message):
                items[index].stage = .metadataPending
                items[index].lastErrorKind = kind
                items[index].lastErrorMessage = message
                try service.updateImportPipelineItem(items[index])
                batch.status = .paused
                batch.pauseReason = message
                try service.updateImportPipelineBatch(batch)
                importPipelineMessage = message
                return
            case .cancelled:
                items[index].stage = .metadataPending
                try service.updateImportPipelineItem(items[index])
                throw CancellationError()
            }
        }

        items = try service.importPipelineItems(batchID: batch.id)
        batch.readyCount = items.count(where: { $0.stage == .versionAnalysisPending })
        batch.deferredCount = items.count(where: {
            $0.stage == .metadataDeferred || $0.stage == .sourceNeedsAttention
        })
        batch.failedCount = 0
        batch.stage = .versionAnalysis
        batch.status = .running
        try service.updateImportPipelineBatch(batch)
        invalidateTagSummaries()
        refresh()
        updateWorkCharacterIndexIfNeeded(localizer: localizer)
    }

    private func fetchImportPipelineMetadata(
        book: LibraryBook,
        item: ImportPipelineItem,
        securityScopedRootURL: URL,
        configuration: MetadataBatchConfiguration
    ) async -> ImportPipelineMetadataResult {
        do {
            let galleryURL: URL?
            if let preferred = item.preferredGalleryURL?.trimmingCharacters(in: .whitespacesAndNewlines),
               !preferred.isEmpty {
                guard let url = URL(string: preferred), GalleryMetadataFetchService.isSupportedGalleryURL(url) else {
                    return .deferred("invalidGalleryURL", BookMetadataEditError.invalidGalleryURL.localizedDescription, false)
                }
                galleryURL = url
            } else {
                let archiveURL = URL(fileURLWithPath: book.filepath)
                galleryURL = try await Task.detached(priority: .utility) {
                    try ArchiveWebInfoReader().galleryURL(
                        in: archiveURL,
                        securityScopedRootURL: securityScopedRootURL
                    )
                }.cancellableValue
            }
            if galleryURL == nil {
                guard book.hash.range(of: #"^[A-Fa-f0-9]{40}$"#, options: .regularExpression) != nil else {
                    return .deferred("invalidSHA1", "The source record does not contain a valid SHA1 hash.", false)
                }
                if let cached = try service.applyCachedMetadata(for: book) {
                    return .success(cached, .localCache, false)
                }
            }

            var attempt = 0
            while true {
                do {
                    let updated: LibraryBook
                    let source: ImportMetadataSource
                    if let galleryURL {
                        updated = try await service.fetchMetadata(
                            for: book,
                            galleryURL: galleryURL,
                            configuration: configuration.fetchConfiguration
                        )
                        source = .galleryURL
                    } else {
                        updated = try await service.fetchMetadata(for: book, configuration: configuration.fetchConfiguration)
                        source = .hashSearch
                    }
                    return .success(updated, source, true)
                } catch {
                    if Task.isCancelled { return .cancelled }
                    if Self.isImportPipelineBlockingMetadataError(error) {
                        return .pause(String(describing: error), error.localizedDescription)
                    }
                    if Self.isTransientMetadataError(error), attempt < configuration.retryCount {
                        attempt += 1
                        try await waitForImportPipeline(seconds: 60 * attempt + Int.random(in: 0...10))
                        continue
                    }
                    return .deferred(
                        String(describing: error),
                        error.localizedDescription,
                        Self.isTransientMetadataError(error)
                    )
                }
            }
        } catch {
            if Task.isCancelled { return .cancelled }
            return .deferred(String(describing: error), error.localizedDescription, false)
        }
    }

    private func runImportVersionAnalysis(
        batch: inout ImportPipelineBatch,
        useCoverSimilarity: Bool,
        maximumCoverDistance: Double
    ) async throws {
        let focus = try pipelineFocusBookIDs(batchID: batch.id, stages: [.versionAnalysisPending])
        guard !focus.isEmpty else {
            try completeImportPipelineBatch(&batch)
            return
        }
        importPipelineMessage = "Analyzing version groups"
        let libraryService = service
        if useCoverSimilarity {
            _ = try await Task.detached(priority: .utility) {
                try libraryService.updateMissingCoverVectors(
                    phase: "Generating cover vectors",
                    progress: { _ in }
                )
            }.cancellableValue
        }
        _ = try await Task.detached(priority: .userInitiated) {
            try libraryService.updateVersionRecommendationsIncrementally(
                useCoverSimilarity: useCoverSimilarity,
                maximumCoverDistance: maximumCoverDistance,
                focusBookIDs: focus
            )
        }.cancellableValue
        reloadVersionRecommendations()
        let pending = try service.pendingVersionRecommendationCount(involving: focus)
        if pending > 0 {
            try movePipelineItems(batchID: batch.id, from: .versionAnalysisPending, to: .versionReviewPending)
            batch.stage = .versionReview
            batch.status = .waitingForReview
            batch.reviewCount = pending
            try service.updateImportPipelineBatch(batch)
            importPipelineMessage = "Version recommendations need review."
            return
        }
        try movePipelineItems(batchID: batch.id, from: .versionAnalysisPending, to: .collectionAnalysisPending)
        batch.stage = .collectionAnalysis
        batch.status = .running
        batch.reviewCount = 0
        try service.updateImportPipelineBatch(batch)
        try await runImportCollectionAnalysis(
            batch: &batch,
            useSemanticSimilarity: importPipelineUsesSemanticSeries
        )
    }

    private func runImportCollectionAnalysis(
        batch: inout ImportPipelineBatch,
        useSemanticSimilarity: Bool
    ) async throws {
        let focus = try pipelineCollectionFocusBookIDs(batchID: batch.id)
        guard !focus.isEmpty else {
            try completeImportPipelineBatch(&batch)
            return
        }
        importPipelineMessage = "Analyzing collections"
        let libraryService = service
        var semanticConfiguration: SemanticSeriesConfiguration = .disabled
        if useSemanticSimilarity {
            do {
                _ = try await libraryService.updateSemanticTitleVectors(
                    focusBookIDs: focus,
                    phase: "Generating semantic title vectors",
                    progress: { _ in }
                )
                semanticConfiguration = .precisionFirst
            } catch {
                // 系统模型资产和可重建索引不是导入硬依赖；失败时继续现有标题规则。
                importPipelineMessage = "Semantic title model unavailable; using standard series rules."
            }
        }
        _ = try await Task.detached(priority: .userInitiated) {
            try libraryService.updateCollectionRecommendationsIncrementally(
                focusBookIDs: focus,
                semanticConfiguration: semanticConfiguration
            )
        }.cancellableValue
        reloadCollectionRecommendations()
        let pending = try service.pendingCollectionRecommendationCount(involving: focus)
        if pending > 0 {
            try movePipelineItems(batchID: batch.id, from: .collectionAnalysisPending, to: .collectionReviewPending)
            batch.stage = .collectionReview
            batch.status = .waitingForReview
            batch.reviewCount = pending
            try service.updateImportPipelineBatch(batch)
            importPipelineMessage = "Collection recommendations need review."
            return
        }
        try completeImportPipelineBatch(&batch)
    }

    private func pipelineFocusBookIDs(
        batchID: ImportPipelineBatch.ID,
        stages: Set<ImportPipelineItemStage>
    ) throws -> Set<LibraryBook.DatabaseID> {
        Set(try service.importPipelineItems(batchID: batchID).filter { stages.contains($0.stage) }.map(\.bookID))
    }

    private func pipelineCollectionFocusBookIDs(batchID: ImportPipelineBatch.ID) throws -> Set<LibraryBook.DatabaseID> {
        let items = try service.importPipelineItems(batchID: batchID).filter {
            $0.stage == .collectionAnalysisPending || $0.stage == .collectionReviewPending
        }
        let allBooks = try service.loadBooks()
        let byID = Dictionary(uniqueKeysWithValues: allBooks.compactMap { book in
            book.databaseID.map { ($0, book) }
        })
        let byGroup = Dictionary(grouping: allBooks.compactMap { book -> LibraryBook? in
            book.versionGroupID == nil ? nil : book
        }, by: { $0.versionGroupID! })
        return Set(items.compactMap { item in
            guard let book = byID[item.bookID] else { return nil }
            guard let groupID = book.versionGroupID else { return item.bookID }
            return byGroup[groupID]?.first(where: \.isPrimaryVersion)?.databaseID
        })
    }

    private func movePipelineItems(
        batchID: ImportPipelineBatch.ID,
        from source: ImportPipelineItemStage,
        to destination: ImportPipelineItemStage
    ) throws {
        for var item in try service.importPipelineItems(batchID: batchID) where item.stage == source {
            item.stage = destination
            item.lastErrorKind = nil
            item.lastErrorMessage = nil
            try service.updateImportPipelineItem(item)
        }
    }

    private func completeImportPipelineBatch(_ batch: inout ImportPipelineBatch) throws {
        let now = Timestamp.nowMilliseconds()
        for var item in try service.importPipelineItems(batchID: batch.id) {
            switch item.stage {
            case .versionAnalysisPending, .versionReviewPending, .collectionAnalysisPending, .collectionReviewPending:
                item.stage = .completed
                item.completedAt = now
                try service.updateImportPipelineItem(item)
            default:
                break
            }
        }
        batch.stage = .completed
        batch.status = .completed
        batch.reviewCount = 0
        batch.completedAt = now
        try service.updateImportPipelineBatch(batch)
        importPipelineMessage = "Import batch completed."
    }

    private static func isImportPipelineBlockingMetadataError(_ error: Error) -> Bool {
        guard let fetchError = error as? GalleryMetadataFetchError else { return false }
        switch fetchError {
        case .ipBanned, .exHentaiAccessDenied, .missingExHentaiCookies, .httpStatus(429):
            return true
        default:
            return false
        }
    }

    private func waitForImportPipeline(seconds: Int) async throws {
        guard seconds > 0 else { return }
        try await sleep(UInt64(seconds) * 1_000_000_000)
    }

    func startMetadataBatch(
        books sourceBooks: [LibraryBook],
        configuration: MetadataBatchConfiguration,
        titleDisplayMode: BookTitleDisplayMode = .originalTitle,
        localizer: AppLocalizer
    ) {
        guard !isDeletingBook else { return }
        // 批量元数据请求必须尊重用户设置的数量、间隔和重试；访问受限或连续瞬时失败时暂停，
        // 让用户显式恢复，而不是继续 hammer 远端站点。
        guard metadataBatchProgress.state != .running,
              !isProcessingImportPipeline,
              importPipelineSnapshot.activeBatch == nil else {
            return
        }

        let taskGeneration = UUID()
        mutationTaskGenerations["metadataBatchTask"] = taskGeneration
        retireMutationTask(metadataBatchTask)
        let eligibleBooks = sourceBooks.filter(Self.isEligibleForMetadataBatch)
        let limitedBooks = configuration.limit == 0 ? eligibleBooks : Array(eligibleBooks.prefix(configuration.limit))
        guard !limitedBooks.isEmpty else {
            metadataBatchQueue = []
            metadataBatchIndex = 0
            metadataBatchConfiguration = nil
            metadataBatchProgress = MetadataBatchProgress(
                state: .idle,
                skipped: sourceBooks.count,
                lastError: localizer.string(.metadataBatchNoEligibleBooks)
            )
            return
        }

        metadataBatchQueue = limitedBooks
        metadataBatchIndex = 0
        metadataBatchConfiguration = configuration
        metadataBatchDidUpdateMetadata = false
        metadataBatchLocalizer = localizer
        metadataBatchTitleDisplayMode = titleDisplayMode
        metadataBatchProgress = MetadataBatchProgress(
            state: .running,
            total: limitedBooks.count,
            skipped: sourceBooks.count - eligibleBooks.count
        )
        metadataBatchTask = Task {
            await runMetadataBatch(localizer: localizer, generation: taskGeneration)
        }
    }

    func pauseMetadataBatch() {
        guard metadataBatchProgress.state == .running else {
            return
        }

        retireMutationTask(metadataBatchTask)
        metadataBatchTask = nil
        metadataBatchProgress.state = .paused
        metadataBatchProgress.currentTitle = nil
        metadataBatchProgress.nextRequestAt = nil
        flushMetadataBatchWorkCharacterIndexUpdateIfNeeded()
    }

    func resumeMetadataBatch(localizer: AppLocalizer) {
        guard !isDeletingBook else { return }
        guard metadataBatchProgress.state == .paused,
              metadataBatchConfiguration != nil,
              metadataBatchIndex < metadataBatchQueue.count else {
            return
        }

        metadataBatchProgress.state = .running
        let taskGeneration = UUID()
        mutationTaskGenerations["metadataBatchTask"] = taskGeneration
        metadataBatchTask = Task {
            await runMetadataBatch(localizer: localizer, generation: taskGeneration)
        }
    }

    func cancelMetadataBatch() {
        retireMutationTask(metadataBatchTask)
        metadataBatchTask = nil
        metadataBatchQueue = []
        metadataBatchIndex = 0
        metadataBatchConfiguration = nil
        metadataBatchProgress.state = .cancelled
        metadataBatchProgress.currentTitle = nil
        metadataBatchProgress.nextRequestAt = nil
        flushMetadataBatchWorkCharacterIndexUpdateIfNeeded()
    }

    private func runMetadataBatch(localizer: AppLocalizer, generation: UUID) async {
        guard let configuration = metadataBatchConfiguration else {
            metadataBatchProgress.state = .idle
            return
        }

        var consecutiveTransientFailures = 0

        while metadataBatchIndex < metadataBatchQueue.count {
            if Task.isCancelled || mutationTaskGenerations["metadataBatchTask"] != generation {
                return
            }

            let book = metadataBatchQueue[metadataBatchIndex]
            metadataBatchProgress.state = .running
            metadataBatchProgress.currentTitle = BookTitleFormatter.displayTitle(
                for: book,
                mode: metadataBatchTitleDisplayMode
            )
            metadataBatchProgress.nextRequestAt = nil

            let result = await fetchMetadataWithRetry(
                for: book,
                configuration: configuration,
                localizer: localizer
            )

            guard !Task.isCancelled, mutationTaskGenerations["metadataBatchTask"] == generation else { return }
            switch result {
            case .success:
                consecutiveTransientFailures = 0
                metadataBatchProgress.succeeded += 1
                metadataBatchProgress.processed += 1
                metadataBatchIndex += 1
                metadataBatchDidUpdateMetadata = true
                invalidateTagSummaries()
                refresh()
            case .recoverableFailure(let message):
                consecutiveTransientFailures = 0
                metadataBatchProgress.failed += 1
                metadataBatchProgress.processed += 1
                metadataBatchProgress.lastError = message
                metadataBatchIndex += 1
            case .transientFailure(let message):
                consecutiveTransientFailures += 1
                metadataBatchProgress.lastError = message
                if consecutiveTransientFailures >= 3 {
                    flushMetadataBatchWorkCharacterIndexUpdateIfNeeded(localizer: localizer)
                    pauseMetadataBatch(with: message)
                    return
                }
                metadataBatchProgress.failed += 1
                metadataBatchProgress.processed += 1
                metadataBatchIndex += 1
            case .blockingFailure(let message):
                flushMetadataBatchWorkCharacterIndexUpdateIfNeeded(localizer: localizer)
                pauseMetadataBatch(with: message)
                return
            case .cancelled:
                return
            }

            guard metadataBatchIndex < metadataBatchQueue.count else {
                break
            }

            let delaySeconds = configuration.nextDelaySeconds()
            do {
                try await wait(seconds: delaySeconds)
            } catch {
                return
            }
        }

        metadataBatchTask = nil
        metadataBatchConfiguration = nil
        metadataBatchProgress.state = .completed
        metadataBatchProgress.currentTitle = nil
        metadataBatchProgress.nextRequestAt = nil
        invalidateTagSummaries()
        refresh()
        flushMetadataBatchWorkCharacterIndexUpdateIfNeeded(localizer: localizer)
    }

    private func fetchMetadataWithRetry(
        for book: LibraryBook,
        configuration: MetadataBatchConfiguration,
        localizer: AppLocalizer
    ) async -> MetadataBatchItemResult {
        var attempt = 0

        while true {
            do {
                _ = try await service.fetchMetadata(
                    for: book,
                    configuration: configuration.fetchConfiguration
                )
                return .success
            } catch {
                if Task.isCancelled {
                    return .cancelled
                }

                if Self.isBlockingMetadataError(error) {
                    return .blockingFailure(error.localizedDescription)
                }

                if Self.isTransientMetadataError(error) {
                    guard attempt < configuration.retryCount else {
                        return .transientFailure(error.localizedDescription)
                    }
                    attempt += 1
                    let retryDelay = 60 * attempt + Int.random(in: 0...10)
                    do {
                        try await wait(seconds: retryDelay)
                    } catch {
                        return .cancelled
                    }
                    continue
                }

                return .recoverableFailure(error.localizedDescription)
            }
        }
    }

    private func wait(seconds: Int) async throws {
        guard seconds > 0 else {
            metadataBatchProgress.nextRequestAt = nil
            return
        }

        metadataBatchProgress.nextRequestAt = Date().addingTimeInterval(TimeInterval(seconds))
        try await sleep(UInt64(seconds) * 1_000_000_000)
        metadataBatchProgress.nextRequestAt = nil
    }

    private func pauseMetadataBatch(with message: String) {
        retireMutationTask(metadataBatchTask)
        metadataBatchTask = nil
        metadataBatchProgress.state = .paused
        metadataBatchProgress.currentTitle = nil
        metadataBatchProgress.nextRequestAt = nil
        metadataBatchProgress.lastError = message
    }

    private func flushMetadataBatchWorkCharacterIndexUpdateIfNeeded(localizer: AppLocalizer? = nil) {
        guard metadataBatchDidUpdateMetadata else {
            return
        }
        metadataBatchDidUpdateMetadata = false
        updateWorkCharacterIndexIfNeeded(localizer: localizer ?? metadataBatchLocalizer ?? AppLocalizer(language: .system))
    }

    private static func isEligibleForMetadataBatch(_ book: LibraryBook) -> Bool {
        book.status == .unscanned
            && book.exist
            && book.hash.range(of: #"^[A-Fa-f0-9]{40}$"#, options: .regularExpression) != nil
    }

    private static func isBlockingMetadataError(_ error: Error) -> Bool {
        guard let fetchError = error as? GalleryMetadataFetchError else {
            return false
        }
        return fetchError == .ipBanned || fetchError == .exHentaiAccessDenied
    }

    private static func isTransientMetadataError(_ error: Error) -> Bool {
        if let fetchError = error as? GalleryMetadataFetchError {
            switch fetchError {
            case .httpStatus(let statusCode):
                return statusCode == 429 || (500...599).contains(statusCode)
            default:
                return false
            }
        }

        return error is URLError
    }

    private func rebuildDerivedCaches() {
        // 大列表页面只能读取这些预计算集合。不要把全书库过滤/排序重新塞回 SwiftUI body，
        // 否则窗口移动、滚动和导航动画都会重新触发昂贵计算。
        candidateDisplayTagCache.removeAll()
        bookIndex = Dictionary(uniqueKeysWithValues: books.map { ($0.id, $0) })
        bookPositions = Dictionary(uniqueKeysWithValues: books.enumerated().map { ($0.element.id, $0.offset) })
        collectionIndex = Dictionary(uniqueKeysWithValues: collections.map { ($0.id, $0) })
        versionGroupIndex = Dictionary(uniqueKeysWithValues: versionGroups.map { ($0.id, $0) })

        booksByCollectionID = Dictionary(grouping: books.compactMap { book -> (BookCollection.DatabaseID, LibraryBook)? in
            guard let collectionID = book.collectionID else {
                return nil
            }
            return (collectionID, book)
        }, by: \.0).mapValues { entries in
            entries.map(\.1).sorted(by: collectionSort)
        }

        displayBooksByCollectionID = booksByCollectionID.mapValues { books in
            books.filter(\.isPrimaryVersion)
        }

        booksByVersionGroupID = Dictionary(grouping: books.compactMap { book -> (BookVersionGroup.DatabaseID, LibraryBook)? in
            guard let groupID = book.versionGroupID else {
                return nil
            }
            return (groupID, book)
        }, by: \.0).mapValues { entries in
            entries.map(\.1).sorted(by: versionGroupSort)
        }

        collectionCandidateBaseBooks = books
            .filter { $0.collectionID == nil }
            .filter(isPrimaryDisplayVersion)
            .sorted(by: managementCandidateSort)

        versionCandidateBaseBooks = books
            .filter { $0.versionGroupID == nil }
            .sorted(by: managementCandidateSort)

        rebuildHomeShelves()
        rebuildSearchDerivedCaches()
        derivedDataRevision += 1
    }

    private func replaceBooks(_ updatedBooks: [LibraryBook]) {
        guard !updatedBooks.isEmpty else {
            return
        }
        let updatedByID = Dictionary(uniqueKeysWithValues: updatedBooks.map { ($0.id, $0) })
        for index in books.indices {
            if let updated = updatedByID[books[index].id] {
                books[index] = updated
            }
        }
        rebuildDerivedCaches()
        loadError = nil
    }

    private func applyBookUpdatesIncrementally(_ updatedBooks: [LibraryBook]) {
        guard !updatedBooks.isEmpty else { return }
        let updatedByID = Dictionary(uniqueKeysWithValues: updatedBooks.map { ($0.id, $0) })

        let arrivalOrderChanged = updatedBooks.contains { book in
            guard let old = bookIndex[book.id] else { return true }
            return old.createdAt != book.createdAt || old.title != book.title || old.isUserHidden != book.isUserHidden
        }
        for index in books.indices {
            if let updated = updatedByID[books[index].id] {
                books[index] = updated
                bookIndex[updated.id] = updated
            }
        }
        for index in searchedBooks.indices {
            if let updated = updatedByID[searchedBooks[index].id] { searchedBooks[index] = updated }
        }
        for index in advancedSearchResults.indices {
            if let updated = updatedByID[advancedSearchResults[index].id] {
                advancedSearchResults[index] = updated
            }
        }

        for index in advancedSearchHits.indices {
            if let updated = updatedByID[advancedSearchHits[index].representativeBook.id] {
                advancedSearchHits[index].representativeBook = updated
            }
        }

        advancedSearchResults.removeAll { book in
            if isCoverImageSearchActive {
                return book.isUserHidden
            }
            switch advancedSearchScope {
            case .hidden: return !book.isUserHidden
            case .marked: return !book.mark || book.isUserHidden
            default: return book.isUserHidden
            }
        }
        advancedSearchHits.removeAll { hit in
            !advancedSearchResults.contains { $0.id == hit.representativeBook.id }
        }
        advancedSearchDisplayItems = makeAdvancedSearchDisplayItems(from: advancedSearchHits)

        for updated in updatedBooks {
            patchBook(updated, in: &recommendedBooks)
            patchBook(updated, in: &continueReadingBooks)
            patchBook(updated, in: &recentlyViewedBooks)
            patchBook(updated, in: &recentlyAddedBooks)
            if updated.lastReadAt != nil,
               !updated.hiddenBook,
               !updated.isUserHidden,
               !recentlyViewedBooks.contains(where: { $0.id == updated.id }) {
                recentlyViewedBooks.append(updated)
            }
            favoriteManagementBooks.removeAll { $0.id == updated.id }
            if updated.mark && !updated.isUserHidden && isPrimaryDisplayVersion(updated) {
                favoriteManagementBooks.append(updated)
            }
        }
        homeFavoritePreview = HomeFavoritePreview(favorites: favoriteManagementBooks)
        favoriteManagementBooks.sort(by: favoriteManagementSort)
        recentlyViewedBooks.sort(by: recentlyViewedSort)
        recentlyViewedBooks = Array(recentlyViewedBooks.prefix(10))
        if arrivalOrderChanged { rebuildArrivalShelves() }
        changeBus.publish(.booksUpserted(updatedBooks))
        loadError = nil
    }

    private func patchBook(_ book: LibraryBook, in collection: inout [LibraryBook]) {
        guard let index = collection.firstIndex(where: { $0.id == book.id }) else { return }
        collection[index] = book
    }

    private func applyOptimisticCollectionOrder(
        _ orderedBooks: [LibraryBook],
        collectionID: BookCollection.DatabaseID,
        shouldCommit: Bool
    ) {
        let currentMembers = displayBooksByCollectionID[collectionID] ?? []
        let currentIDs = Set(currentMembers.compactMap(\.databaseID))
        let orderedIDs = Set(orderedBooks.compactMap(\.databaseID))
        guard currentIDs == orderedIDs else {
            return
        }

        let now = Timestamp.nowMilliseconds()
        let updatedMembers = orderedBooks.enumerated().map { order, book in
            var updated = bookIndex[book.id] ?? book
            updated.collectionOrder = order
            updated.updatedAt = now
            return updated
        }
        applyCollectionOrderMembers(updatedMembers, collectionID: collectionID, bumpsRevision: true)

        guard shouldCommit else {
            return
        }
        scheduleCollectionOrderCommit(updatedMembers, collectionID: collectionID)
    }

    private func applyCollectionOrderMembers(
        _ updatedMembers: [LibraryBook],
        collectionID: BookCollection.DatabaseID,
        bumpsRevision: Bool
    ) {
        guard !updatedMembers.isEmpty else {
            return
        }
        let updatedByID = Dictionary(uniqueKeysWithValues: updatedMembers.map { ($0.id, $0) })
        for updated in updatedMembers {
            if let position = bookPositions[updated.id] { books[position] = updated }
            bookIndex[updated.id] = updated
        }

        let existingCollectionBooks = booksByCollectionID[collectionID] ?? books.filter { $0.collectionID == collectionID }
        let updatedCollectionBooks = existingCollectionBooks
            .map { updatedByID[$0.id] ?? $0 }
            .sorted(by: collectionSort)
        booksByCollectionID[collectionID] = updatedCollectionBooks
        displayBooksByCollectionID[collectionID] = updatedCollectionBooks.filter(\.isPrimaryVersion)
        loadError = nil

        guard bumpsRevision else {
            return
        }
        collectionOrderRevision += 1
    }

    private func scheduleCollectionOrderCommit(
        _ orderedBooks: [LibraryBook],
        collectionID: BookCollection.DatabaseID
    ) {
        collectionOrderCommitTasks[collectionID]?.cancel()
        let revision = (collectionOrderCommitRevisions[collectionID] ?? 0) + 1
        collectionOrderCommitRevisions[collectionID] = revision
        if pendingCollectionOrders[collectionID] == nil {
            organizationPendingCounts["collection:\(collectionID)", default: 0] += 1
            savingOrganizationKeys = Set(organizationPendingCounts.keys)
            isSavingOrganization = true
        }
        pendingCollectionOrders[collectionID] = orderedBooks
        let sleep = sleep
        let task = Task { @MainActor [weak self, sleep, collectionID, revision] in
            do {
                try await sleep(320_000_000)
                guard let self, !Task.isCancelled,
                      self.collectionOrderCommitRevisions[collectionID] == revision else { return }
                self.flushCollectionOrder(for: collectionID)
            } catch {
                guard let self, self.collectionOrderCommitRevisions[collectionID] == revision else { return }
                self.collectionOrderCommitTasks[collectionID] = nil
            }
        }
        collectionOrderCommitTasks[collectionID] = task
    }

    private func flushCollectionOrder(for collectionID: BookCollection.DatabaseID?) {
        guard let collectionID, let orderedBooks = pendingCollectionOrders.removeValue(forKey: collectionID) else { return }
        collectionOrderCommitTasks[collectionID]?.cancel()
        collectionOrderCommitTasks[collectionID] = nil
        let collection = collection(id: String(collectionID)) ?? BookCollection(databaseID: collectionID, name: "")
        enqueueOrganizationMutation(.reorderCollection(orderedBooks, collection))
        let key = "collection:\(collectionID)"
        let remaining = (organizationPendingCounts[key] ?? 1) - 1
        if remaining > 0 { organizationPendingCounts[key] = remaining }
        else { organizationPendingCounts.removeValue(forKey: key) }
        savingOrganizationKeys = Set(organizationPendingCounts.keys)
        isSavingOrganization = !organizationPendingCounts.isEmpty
    }

    private func flushAllCollectionOrders() {
        for collectionID in Array(pendingCollectionOrders.keys).sorted() {
            flushCollectionOrder(for: collectionID)
        }
    }

    private func rebuildSearchDerivedCaches() {
        searchedBooks = books.filter(matchesSearch)
        displayItems = makeDisplayItems(from: searchedBooks)
        rebuildFilterDerivedCaches()
    }

    private func reloadSearchAfterLibraryChange() {
        guard isCoverImageSearchActive || lastSearchTranslationEnabled != nil else { return }
        // SQL search results are snapshots, separate from the shared book cache.
        // Drop old entities immediately and supersede any in-flight query before reloading.
        advancedSearchHits = []
        advancedSearchResults = []
        advancedSearchDisplayItems = []
        advancedSearchFacetsByNamespace = [:]
        advancedSearchTagFacets = []
        advancedSearchSuggestions = []
        advancedSearchSuggestionTask?.cancel()
        advancedSearchSuggestionRevision += 1
        if isCoverImageSearchActive, let localizer = coverSearchLocalizer,
           let fileName = coverImageSearchFileName, let provider = coverSearchProvider {
            let data = coverImageSearchQueryData
            runCoverImageSearch(fileName: fileName, localizer: localizer) {
                if let data { return data }
                return try provider()
            }
        } else {
            submitAdvancedSearch(isTagTranslationEnabled: lastSearchTranslationEnabled ?? false)
        }
    }

    private func rebuildFilterDerivedCaches() {
        filteredDisplayItems = displayItems.filter(itemMatchesCurrentFilter)
        filteredBooks = searchedBooks.filter { !$0.hiddenBook && matches(filter: filter, book: $0) }
    }

    private func rebuildHomeShelves() {
        let primaryDisplayBooks = books.filter(isPrimaryDisplayVersion)
        recommendedBooks = Array(
            primaryDisplayBooks
                .sorted { recommendationScore(for: $0) < recommendationScore(for: $1) }
                .prefix(10)
        )
        favoriteManagementBooks = primaryDisplayBooks
            .filter(\.mark)
            .sorted(by: favoriteManagementSort)
        homeFavoritePreview = HomeFavoritePreview(favorites: favoriteManagementBooks)
        continueReadingBooks = primaryDisplayBooks
            .filter { book in
                guard let bookID = book.databaseID, let state = readingStates[bookID] else { return false }
                return state.currentPageIndex > 0 && !state.isCompleted && !book.isUserHidden
            }
            .sorted { lhs, rhs in
                let left = lhs.databaseID.flatMap { readingStates[$0]?.updatedAt } ?? 0
                let right = rhs.databaseID.flatMap { readingStates[$0]?.updatedAt } ?? 0
                return left == right ? lhs.id < rhs.id : left > right
            }
            .prefix(10)
            .map { $0 }
        recentlyViewedBooks = Array(
            books
                .filter { !$0.hiddenBook && $0.lastReadAt != nil }
                .sorted(by: recentlyViewedSort)
                .prefix(10)
        )
        rebuildArrivalShelves()
    }

    private func rebuildArrivalShelves() {
        let byArrival = books.sorted(by: HomeArrivalDay.newer)
        recentlyAddedBooks = Array(byArrival.prefix(10))
        homeArrivalDays = HomeArrivalDay.latest(from: byArrival)
    }

    private func matchesSearch(_ book: LibraryBook) -> Bool {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            return true
        }

        return book.title.localizedCaseInsensitiveContains(query)
            || book.filepath.localizedCaseInsensitiveContains(query)
            || book.hash.localizedCaseInsensitiveContains(query)
            || (book.titleJpn?.localizedCaseInsensitiveContains(query) ?? false)
            || (book.url?.localizedCaseInsensitiveContains(query) ?? false)
    }

    private func makeDisplayItems(from sourceBooks: [LibraryBook]) -> [LibraryDisplayItem] {
        let sourceIDs = Set(sourceBooks.map(\.id))
        let collectionItems = collections.compactMap { collection -> LibraryDisplayItem? in
            let displayBooks = displayBooks(in: collection).filter { sourceIDs.contains($0.id) }
            guard !displayBooks.isEmpty else {
                return nil
            }
            return .collection(BookCollectionDisplayItem(collection: collection, books: displayBooks))
        }

        let bookItems = sourceBooks
            .filter { !$0.hiddenBook }
            .map(LibraryDisplayItem.book)

        return (collectionItems + bookItems).sorted {
            let leftDate = $0.representativeBook?.date ?? 0
            let rightDate = $1.representativeBook?.date ?? 0
            if leftDate == rightDate {
                return title(for: $0).localizedCaseInsensitiveCompare(title(for: $1)) == .orderedAscending
            }
            return leftDate > rightDate
        }
    }

    private func makeAdvancedSearchDisplayItems(from hits: [LibrarySearchHit]) -> [SearchDisplayItem] {
        hits.compactMap { hit in
            switch hit.entityKey {
            case .collection(let collectionID):
                guard let collection = collection(id: collectionID) else { return nil }
                let allMembers = books(in: collection)
                let matchedBooks = allMembers.filter { hit.matchedBookIDs.contains($0.id) }
                var members = displayBooks(in: collection).filter(matchesAdvancedSearchUserVisibility)

                for matchedBook in matchedBooks where matchesAdvancedSearchUserVisibility(matchedBook) {
                    let isRepresented = members.contains { member in
                        member.id == matchedBook.id
                            || (matchedBook.versionGroupID != nil && member.versionGroupID == matchedBook.versionGroupID)
                    }
                    if !isRepresented {
                        members.append(matchedBook)
                    }
                }
                members.sort(by: collectionSort)
                guard !members.isEmpty else { return nil }

                let displayedMatchIDs = Set(matchedBooks.compactMap { matchedBook -> LibraryBook.ID? in
                    members.first { member in
                        member.id == matchedBook.id
                            || (matchedBook.versionGroupID != nil && member.versionGroupID == matchedBook.versionGroupID)
                    }?.id
                })
                let otherVersionMatchedBookIDs = Set(matchedBooks.compactMap { matchedBook -> LibraryBook.ID? in
                    guard !members.contains(where: { $0.id == matchedBook.id }) else { return nil }
                    return members.first { member in
                        matchedBook.versionGroupID != nil && member.versionGroupID == matchedBook.versionGroupID
                    }?.id
                })
                return SearchDisplayItem(
                    item: .collection(BookCollectionDisplayItem(collection: collection, books: members)),
                    matchedBookIDs: displayedMatchIDs,
                    otherVersionMatchedBookIDs: otherVersionMatchedBookIDs,
                    similarityDistance: hit.similarityDistance
                )

            case .versionGroup(let versionGroupID):
                guard let group = versionGroup(id: versionGroupID) else { return nil }
                let members = books(inVersionGroup: group).filter(matchesAdvancedSearchUserVisibility)
                guard let representative = members.first(where: \.isPrimaryVersion)
                    ?? members.first(where: { hit.matchedBookIDs.contains($0.id) }) else { return nil }
                return SearchDisplayItem(
                    item: .book(representative),
                    matchedBookIDs: hit.matchedBookIDs.contains(representative.id) ? [representative.id] : [],
                    otherVersionMatchedBookIDs: hit.matchedBookIDs.contains { $0 != representative.id }
                        ? [representative.id]
                        : [],
                    similarityDistance: hit.similarityDistance
                )

            case .book:
                let book = bookIndex[hit.representativeBook.id] ?? hit.representativeBook
                guard matchesAdvancedSearchUserVisibility(book) else { return nil }
                return SearchDisplayItem(
                    item: .book(book),
                    matchedBookIDs: [book.id],
                    otherVersionMatchedBookIDs: [],
                    similarityDistance: hit.similarityDistance
                )
            }
        }
    }

    private func matchesAdvancedSearchUserVisibility(_ book: LibraryBook) -> Bool {
        if isCoverImageSearchActive {
            return !book.isUserHidden
        }
        return advancedSearchScope == .hidden ? book.isUserHidden : !book.isUserHidden
    }

    private func sortedAdvancedSearchBooks(_ books: [LibraryBook]) -> [LibraryBook] {
        books.sorted(by: advancedSearchBookSort)
    }

    private func advancedSearchDisplayItemSort(_ lhs: LibraryDisplayItem, _ rhs: LibraryDisplayItem) -> Bool {
        switch (lhs.representativeBook, rhs.representativeBook) {
        case (.some(let left), .some(let right)):
            if advancedSearchBookSort(left, right) {
                return true
            }
            if advancedSearchBookSort(right, left) {
                return false
            }
        case (.some, .none):
            return true
        case (.none, .some):
            return false
        case (.none, .none):
            break
        }
        return title(for: lhs).localizedCaseInsensitiveCompare(title(for: rhs)) == .orderedAscending
    }

    private func advancedSearchBookSort(_ lhs: LibraryBook, _ rhs: LibraryBook) -> Bool {
        if let result = advancedSearchPrimaryComparison(lhs, rhs) {
            return result
        }

        let titleComparison = lhs.title.localizedCaseInsensitiveCompare(rhs.title)
        if titleComparison != .orderedSame {
            return titleComparison == .orderedAscending
        }

        return lhs.id < rhs.id
    }

    private func advancedSearchPrimaryComparison(_ lhs: LibraryBook, _ rhs: LibraryBook) -> Bool? {
        switch advancedSearchSortKey {
        case .posted:
            return orderedComparison(left: lhs.posted ?? lhs.date, right: rhs.posted ?? rhs.date)
        case .added:
            return orderedComparison(left: lhs.createdAt, right: rhs.createdAt)
        case .title:
            let comparison = lhs.title.localizedCaseInsensitiveCompare(rhs.title)
            guard comparison != .orderedSame else {
                return nil
            }
            return advancedSearchSortDirection == .ascending ? comparison == .orderedAscending : comparison == .orderedDescending
        case .rating:
            return orderedComparison(left: lhs.rating ?? 0, right: rhs.rating ?? 0)
        case .pages:
            return orderedComparison(left: lhs.pages ?? lhs.fileCount ?? 0, right: rhs.pages ?? rhs.fileCount ?? 0)
        case .marked:
            return orderedComparison(left: lhs.mark ? 1 : 0, right: rhs.mark ? 1 : 0)
        }
    }

    private func orderedComparison<T: Comparable>(left: T, right: T) -> Bool? {
        guard left != right else {
            return nil
        }
        return advancedSearchSortDirection == .ascending ? left < right : left > right
    }

    private func itemMatchesCurrentFilter(_ item: LibraryDisplayItem) -> Bool {
        switch item {
        case .book(let book):
            return matches(filter: filter, book: book)
        case .collection(let item):
            return item.books.contains { matches(filter: filter, book: $0) }
        }
    }

    private func itemMatchesMarked(_ item: LibraryDisplayItem) -> Bool {
        switch item {
        case .book(let book):
            return book.mark
        case .collection(let item):
            return item.books.contains(where: \.mark)
        }
    }

    private func matches(filter: LibraryFilter, book: LibraryBook) -> Bool {
        switch filter {
        case .all:
            return true
        case .marked:
            return book.mark
        case .correct:
            return book.status == .correct
        case .unscanned:
            return book.status == .unscanned
        case .broken:
            return book.status == .broken
        case .missing:
            return book.status == .missing || !book.exist
        }
    }

    private func title(for item: LibraryDisplayItem) -> String {
        switch item {
        case .book(let book):
            return book.title
        case .collection(let item):
            return item.collection.name
        }
    }

    private func collectionSort(_ lhs: LibraryBook, _ rhs: LibraryBook) -> Bool {
        let left = lhs.collectionOrder ?? Int.max
        let right = rhs.collectionOrder ?? Int.max
        if left == right {
            return lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
        }
        return left < right
    }

    private func versionGroupSort(_ lhs: LibraryBook, _ rhs: LibraryBook) -> Bool {
        if lhs.isPrimaryVersion != rhs.isPrimaryVersion {
            return lhs.isPrimaryVersion
        }
        return lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
    }

    private func favoriteManagementSort(_ lhs: LibraryBook, _ rhs: LibraryBook) -> Bool {
        if lhs.date == rhs.date {
            return lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
        }
        return lhs.date > rhs.date
    }

    private func recentlyViewedSort(_ lhs: LibraryBook, _ rhs: LibraryBook) -> Bool {
        let left = lhs.lastReadAt ?? 0
        let right = rhs.lastReadAt ?? 0
        if left == right {
            return lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
        }
        return left > right
    }

    private func managementCandidateSort(_ lhs: LibraryBook, _ rhs: LibraryBook) -> Bool {
        displayTitle(lhs).localizedCaseInsensitiveCompare(displayTitle(rhs)) == .orderedAscending
    }

    private func isPrimaryDisplayVersion(_ book: LibraryBook) -> Bool {
        book.versionGroupID == nil || book.isPrimaryVersion
    }

    private func displayTitle(_ book: LibraryBook) -> String {
        BookTitleFormatter.displayTitle(for: book, mode: .originalTitle)
    }

    private func matchesManagementSearch(_ book: LibraryBook, query: String) -> Bool {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return true
        }

        return book.title.localizedCaseInsensitiveContains(trimmed)
            || (book.titleJpn?.localizedCaseInsensitiveContains(trimmed) ?? false)
            || book.filepath.localizedCaseInsensitiveContains(trimmed)
            || book.hash.localizedCaseInsensitiveContains(trimmed)
            || (book.url?.localizedCaseInsensitiveContains(trimmed) ?? false)
    }

    private func recommendationScore(for book: LibraryBook) -> UInt64 {
        let components = Calendar.current.dateComponents([.year, .month, .day], from: Date())
        let dateKey = "\(components.year ?? 0)-\(components.month ?? 0)-\(components.day ?? 0)"
        let source = "\(dateKey)|\(book.id)|\(book.hash)|\(book.filepath)"
        return source.utf8.reduce(UInt64(14_695_981_039_346_656_037)) { hash, byte in
            (hash ^ UInt64(byte)) &* 1_099_511_628_211
        }
    }

    private func advancedSearchRequest(isTagTranslationEnabled: Bool) -> LibrarySearchRequest {
        LibrarySearchRequest(
            rawQuery: advancedSearchText,
            isRegexEnabled: isAdvancedSearchRegexEnabled,
            mode: advancedSearchMode,
            selectedTags: [],
            excludedTags: [],
            isTagTranslationEnabled: isTagTranslationEnabled,
            scope: advancedSearchScope,
            page: advancedSearchPage,
            pageSize: advancedSearchPageSize,
            sortKey: advancedSearchSortKey,
            sortDirection: advancedSearchSortDirection,
            showsIndividualBooks: advancedSearchShowsIndividualBooks
        )
    }

    private func applyAdvancedSearchResult(
        response: LibrarySearchResponse,
        suggestions: [SearchTagSuggestion]
    ) {
        advancedSearchHits = response.items
        advancedSearchResults = response.items.map(\.representativeBook)
        advancedSearchDisplayItems = makeAdvancedSearchDisplayItems(from: advancedSearchHits)
        advancedSearchTotalCount = response.totalCount
        advancedSearchParsedQuery = response.parsedQuery
        advancedSearchSuggestions = suggestions
        advancedSearchError = nil
        loadError = nil
    }

    private func loadAdvancedSearchFacets(
        request: LibrarySearchRequest,
        knownTotalCount: Int,
        searchRevision: Int
    ) {
        let key = SearchFacetCacheKey(request: request, tagRevision: tagSummaryRevision)
        if let cached = advancedSearchFacetCache[key] {
            applyAdvancedSearchFacets(cached)
            isAdvancedSearchLoading = false
            return
        }

        advancedSearchFacetRevision += 1
        let facetRevision = advancedSearchFacetRevision
        let service = service
        advancedSearchFacetTask = Task(priority: .utility) { [weak self] in
            do {
                let facets = try await Task.detached(priority: .utility) {
                    try service.searchTagFacets(request, knownTotalCount: knownTotalCount)
                }.cancellableValue
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    guard let self,
                          searchRevision == self.advancedSearchRevision,
                          facetRevision == self.advancedSearchFacetRevision else { return }
                    self.advancedSearchFacetCache[key] = facets
                    self.applyAdvancedSearchFacets(facets)
                    self.advancedSearchFacetTask = nil
                    self.isAdvancedSearchLoading = false
                }
            } catch is CancellationError {
                return
            } catch {
                await MainActor.run {
                    guard let self, facetRevision == self.advancedSearchFacetRevision else { return }
                    self.advancedSearchFacetTask = nil
                    self.advancedSearchError = error.localizedDescription
                    self.isAdvancedSearchLoading = false
                }
            }
        }
    }

    private func applyAdvancedSearchFacets(_ facets: [SearchTagFacet]) {
        advancedSearchTagFacets = facets
        advancedSearchFacetsByNamespace = Dictionary(grouping: facets, by: { $0.tag.namespace })
    }

    private func advancedSearchSuggestionRequest(isTagTranslationEnabled: Bool) -> SearchTagSuggestionRequest? {
        guard let query = SearchQueryTextEditor.suggestionQuery(
            in: advancedSearchText,
            activeRange: advancedSearchActiveTokenRange
        ) else {
            return nil
        }
        return SearchTagSuggestionRequest(
            query: query.text,
            namespace: query.namespace,
            excludedRawValue: query.excludedRawValue,
            isTagTranslationEnabled: isTagTranslationEnabled
        )
    }

    private func tagSummaryCacheKey(
        namespace: String,
        isTagTranslationEnabled: Bool
    ) -> String {
        "\(namespace)|translated:\(isTagTranslationEnabled)"
    }

    private static let candidateTagNamespaces: Set<String> = [
        "female",
        "male",
        "mixed",
        "location",
        "other"
    ]

    private func invalidateTagSummaries() {
        tagSummaryCache.removeAll()
        tagSummaryErrors.removeAll()
        candidateDisplayTagCache.removeAll()
        invalidateHomeInsightCharts()
        tagSummaryRevision += 1
    }

    private func invalidateHomeInsightCharts() {
        homeInsightChartCache.removeAll()
        homeInsightCharts = .empty
        homeInsightChartError = nil
    }

    private func mapHomeInsightCharts(
        _ transform: (TagDisplaySummary) -> TagDisplaySummary
    ) -> HomeInsightCharts {
        mapHomeInsightCharts(homeInsightCharts, transform)
    }

    private func mapHomeInsightCharts(
        _ charts: HomeInsightCharts,
        _ transform: (TagDisplaySummary) -> TagDisplaySummary
    ) -> HomeInsightCharts {
        var updated = charts
        for kind in HomeInsightChartKind.allCases {
            updated[kind] = charts[kind].map(transform)
        }
        return updated
    }
}

private struct PendingReadingProgress: Sendable {
    let book: LibraryBook
    let currentPageIndex: Int
    let totalPages: Int
    let forceCompleted: Bool?
}

private struct CandidateDisplayTagCacheKey: Hashable {
    var bookID: LibraryBook.ID
    var isTagTranslationEnabled: Bool
    var revision: Int
}

private enum MetadataBatchItemResult {
    case success
    case recoverableFailure(String)
    case transientFailure(String)
    case blockingFailure(String)
    case cancelled
}

private final class InMemoryLibraryBookRepository: LibraryBookRepository {
    private var books: [LibraryBook] = []
    private var nextID: LibraryBook.DatabaseID = 1

    func fetchAll() throws -> [LibraryBook] {
        books
    }

    func fetch(id: LibraryBook.DatabaseID) throws -> LibraryBook? {
        books.first { $0.databaseID == id }
    }

    func fetchByHash(_ hash: String) throws -> [LibraryBook] {
        books.filter { $0.hash == hash }
    }

    func fetchByFilepath(_ filepath: String) throws -> LibraryBook? {
        books.first { $0.filepath == filepath }
    }

    func fetchByCollectionID(_ collectionID: BookCollection.DatabaseID) throws -> [LibraryBook] {
        books.filter { $0.collectionID == collectionID }
    }

    func fetchByVersionGroupID(_ versionGroupID: BookVersionGroup.DatabaseID) throws -> [LibraryBook] {
        books.filter { $0.versionGroupID == versionGroupID }
    }

    func insert(_ book: LibraryBook) throws -> LibraryBook {
        var saved = book
        saved.databaseID = nextID
        nextID += 1
        books.append(saved)
        return saved
    }

    func update(_ book: LibraryBook) throws -> LibraryBook {
        guard let id = book.databaseID else {
            throw NyaEHError.bookHasNoID
        }

        if let index = books.firstIndex(where: { $0.databaseID == id }) {
            books[index] = book
        }
        return book
    }

    func replaceCollectionOrder(
        bookIDs: [LibraryBook.DatabaseID],
        collectionID: BookCollection.DatabaseID
    ) throws -> [LibraryBook] {
        let now = Timestamp.nowMilliseconds()
        for (order, bookID) in bookIDs.enumerated() {
            guard let index = books.firstIndex(where: { $0.databaseID == bookID && $0.collectionID == collectionID }) else {
                continue
            }
            books[index].collectionOrder = order
            books[index].updatedAt = now
        }
        return books
            .filter { $0.collectionID == collectionID }
            .sorted {
                let left = $0.collectionOrder ?? Int.max
                let right = $1.collectionOrder ?? Int.max
                if left == right {
                    return $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
                }
                return left < right
            }
    }

    func delete(id: LibraryBook.DatabaseID) throws {
        books.removeAll { $0.databaseID == id }
    }

    func incrementReadCount(bookID: LibraryBook.DatabaseID) throws -> LibraryBook? {
        guard let index = books.firstIndex(where: { $0.databaseID == bookID }) else {
            return nil
        }

        books[index].readCount += 1
        let now = Timestamp.nowMilliseconds()
        books[index].lastReadAt = now
        books[index].updatedAt = now
        return books[index]
    }

    func updateStatus(bookID: LibraryBook.DatabaseID, status: BookStatus, exist: Bool) throws {
        guard let index = books.firstIndex(where: { $0.databaseID == bookID }) else {
            return
        }
        books[index].status = status
        books[index].exist = exist
        books[index].updatedAt = Timestamp.nowMilliseconds()
    }

    func markMissingExcept(filepaths: Set<String>) throws {
        for index in books.indices where !filepaths.contains(books[index].filepath) {
            books[index].status = .missing
            books[index].exist = false
            books[index].updatedAt = Timestamp.nowMilliseconds()
        }
    }
}

private struct CoverImageSearchEntityAccumulator {
    var representativeBook: LibraryBook
    var matchedBookIDs: Set<LibraryBook.ID>
    var distance: Double
}

private enum ImportPipelineMetadataResult {
    case success(LibraryBook, ImportMetadataSource, Bool)
    case deferred(String, String, Bool)
    case pause(String, String)
    case cancelled
}

private final class InMemoryGalleryMetadataRepository: GalleryMetadataRepository {
    private var metadata: [String: GalleryMetadata] = [:]

    func fetch(hash: String) throws -> GalleryMetadata? {
        metadata[hash]
    }

    func upsert(_ metadata: GalleryMetadata) throws -> GalleryMetadata {
        self.metadata[metadata.hash] = metadata
        return metadata
    }

    func delete(hash: String) throws {
        metadata[hash] = nil
    }
}

private extension ExternalLibraryImportProgress {
    func localized(with localizer: AppLocalizer) -> ExternalLibraryImportProgress {
        let localizedPhase: String
        switch phase {
        case "Validating import files":
            localizedPhase = localizer.string(.importValidating)
        case "Creating database backup":
            localizedPhase = localizer.string(.importBackup)
        case "Importing collections":
            localizedPhase = localizer.string(.importCollections)
        case "Rebuilding tag index":
            localizedPhase = localizer.string(.importRebuildingTags)
        case "Finished":
            localizedPhase = localizer.string(.importFinished)
        default:
            localizedPhase = phase
        }

        return ExternalLibraryImportProgress(
            phase: localizedPhase,
            completed: completed,
            total: total
        )
    }
}
