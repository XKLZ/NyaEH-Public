// 本文件封装非秘密偏好设置、UserDefaults 隔离和设置页使用的派生配置。

import Foundation
import Observation
import AppKit
import SwiftUI

@MainActor
@Observable
final class AppPreferences {
    nonisolated static let userDefaultsSuiteEnvironmentKey = "NYAEH_USER_DEFAULTS_SUITE"

    var savedSearches: [SavedBookSearch] {
        didSet {
            if let data = try? JSONEncoder().encode(savedSearches) {
                userDefaults.set(data, forKey: Keys.savedSearches)
            }
        }
    }

    var themeMode: ThemeMode {
        didSet {
            userDefaults.set(themeMode.rawValue, forKey: Keys.themeMode)
        }
    }

    var accentColorMode: AppAccentColor {
        didSet {
            userDefaults.set(accentColorMode.rawValue, forKey: Keys.accentColorMode)
        }
    }

    var customAccentColorHex: String {
        didSet {
            if NSColor.nyaehColor(hex: customAccentColorHex) == nil {
                customAccentColorHex = oldValue
                return
            }
            userDefaults.set(customAccentColorHex, forKey: Keys.customAccentColorHex)
        }
    }

    private(set) var language: AppLanguage
    private(set) var languageStorageError: String?
    @ObservationIgnored private let activeLanguageSelection: AppLanguage
    @ObservationIgnored private let activeResolvedLanguage: AppLanguage
    @ObservationIgnored private let migratedLanguageRequiresRestart: Bool

    var languageChangeRequiresRestart: Bool {
        migratedLanguageRequiresRestart || language != activeLanguageSelection
    }

    func selectLanguage(_ selection: AppLanguage) {
        do {
            try languagePreferenceStore.save(selection)
            language = selection
            languageStorageError = nil
        } catch {
            languageStorageError = error.localizedDescription
        }
    }

    var libraryRootPath: String? {
        didSet {
            userDefaults.set(libraryRootPath, forKey: Keys.libraryRootPath)
        }
    }

    var libraryRootBookmarkData: Data? {
        didSet {
            userDefaults.set(libraryRootBookmarkData, forKey: Keys.libraryRootBookmarkData)
        }
    }

    var lastLibraryScanCompletedAt: Int64? {
        didSet {
            if let lastLibraryScanCompletedAt {
                userDefaults.set(lastLibraryScanCompletedAt, forKey: Keys.lastLibraryScanCompletedAt)
            } else {
                userDefaults.removeObject(forKey: Keys.lastLibraryScanCompletedAt)
            }
        }
    }

    var gallerySearchSite: GallerySearchSite {
        didSet {
            userDefaults.set(gallerySearchSite.rawValue, forKey: Keys.gallerySearchSite)
        }
    }

    var isTagTranslationEnabled: Bool {
        didSet {
            userDefaults.set(isTagTranslationEnabled, forKey: Keys.isTagTranslationEnabled)
        }
    }

    var isCoverSimilarityVersionRecommendationEnabled: Bool {
        didSet {
            userDefaults.set(isCoverSimilarityVersionRecommendationEnabled, forKey: Keys.coverSimilarityVersionRecommendationEnabled)
        }
    }

    var isSemanticSeriesRecommendationEnabled: Bool {
        didSet {
            userDefaults.set(
                isSemanticSeriesRecommendationEnabled,
                forKey: Keys.semanticSeriesRecommendationEnabled
            )
        }
    }

    var coverSimilarityMaximumDistance: Double {
        didSet {
            let normalized = Self.normalizedCoverSimilarityMaximumDistance(coverSimilarityMaximumDistance)
            if coverSimilarityMaximumDistance != normalized {
                coverSimilarityMaximumDistance = normalized
                return
            }
            userDefaults.set(coverSimilarityMaximumDistance, forKey: Keys.coverSimilarityMaximumDistance)
        }
    }

    var bookTitleDisplayMode: BookTitleDisplayMode {
        didSet {
            userDefaults.set(bookTitleDisplayMode.rawValue, forKey: Keys.bookTitleDisplayMode)
        }
    }

    var readerInitialLoadLimit: Int {
        get {
            readerInitialLoadLimitStorage
        }
        set {
            readerInitialLoadLimitStorage = Self.nearestAllowedValue(newValue, allowed: Self.readerInitialLoadLimitValues)
            userDefaults.set(readerInitialLoadLimitStorage, forKey: Keys.readerInitialLoadLimit)
        }
    }

    var readerHoverPreviewDelayMilliseconds: Int {
        get {
            readerHoverPreviewDelayMillisecondsStorage
        }
        set {
            readerHoverPreviewDelayMillisecondsStorage = Self.nearestAllowedValue(newValue, allowed: Self.readerHoverPreviewDelayValues)
            userDefaults.set(readerHoverPreviewDelayMillisecondsStorage, forKey: Keys.readerHoverPreviewDelayMilliseconds)
        }
    }

    var readerDisplayPreferences: ReaderDisplayPreferences {
        didSet {
            let normalized = readerDisplayPreferences.normalized()
            if readerDisplayPreferences != normalized {
                readerDisplayPreferences = normalized
                return
            }
            userDefaults.set(readerDisplayPreferences.layoutMode.rawValue, forKey: Keys.readerLayoutMode)
            userDefaults.set(readerDisplayPreferences.fitMode.rawValue, forKey: Keys.readerFitMode)
            userDefaults.set(readerDisplayPreferences.zoom, forKey: Keys.readerZoom)
            userDefaults.set(readerDisplayPreferences.showsThumbnails, forKey: Keys.readerShowsThumbnails)
        }
    }

    func savedReaderWindowFrame() -> CGRect? {
        guard let value = userDefaults.string(forKey: Keys.readerWindowFrame) else {
            return nil
        }
        return ReaderWindowFramePreferenceCodec.decode(value)
    }

    func saveReaderWindowFrame(_ frame: CGRect) {
        guard let value = ReaderWindowFramePreferenceCodec.encode(frame) else {
            return
        }
        userDefaults.set(value, forKey: Keys.readerWindowFrame)
    }

    func savedMainWindowSize() -> CGSize? {
        guard let values = userDefaults.array(forKey: Keys.mainWindowSize) as? [Double],
              values.count == 2 else { return nil }
        let size = CGSize(width: values[0], height: values[1])
        return MainWindowGeometry.isValid(size) ? size : nil
    }

    func saveMainWindowSize(_ size: CGSize) {
        guard MainWindowGeometry.isValid(size), size != savedMainWindowSize() else { return }
        userDefaults.set([Double(size.width), Double(size.height)], forKey: Keys.mainWindowSize)
    }

    func savedMainSidebarWidth() -> CGFloat? {
        guard let width = userDefaults.object(forKey: Keys.mainSidebarWidth) as? Double else { return nil }
        return MainWindowGeometry.sidebarWidth(CGFloat(width))
    }

    func saveMainSidebarWidth(_ width: CGFloat) {
        guard let width = MainWindowGeometry.sidebarWidth(width),
              width != savedMainSidebarWidth() else { return }
        userDefaults.set(Double(width), forKey: Keys.mainSidebarWidth)
    }

    var metadataBatchIntervalStrategy: MetadataBatchIntervalStrategy {
        get {
            metadataBatchIntervalStrategyStorage
        }
        set {
            metadataBatchIntervalStrategyStorage = newValue
            userDefaults.set(newValue.rawValue, forKey: Keys.metadataBatchIntervalStrategy)
        }
    }

    var metadataBatchMinDelaySeconds: Int {
        get {
            metadataBatchMinDelaySecondsStorage
        }
        set {
            metadataBatchMinDelaySecondsStorage = Self.normalizedBatchDelay(newValue)
            if metadataBatchMaxDelaySecondsStorage < metadataBatchMinDelaySecondsStorage {
                metadataBatchMaxDelaySecondsStorage = metadataBatchMinDelaySecondsStorage
                userDefaults.set(metadataBatchMaxDelaySecondsStorage, forKey: Keys.metadataBatchMaxDelaySeconds)
            }
            userDefaults.set(metadataBatchMinDelaySecondsStorage, forKey: Keys.metadataBatchMinDelaySeconds)
        }
    }

    var metadataBatchMaxDelaySeconds: Int {
        get {
            metadataBatchMaxDelaySecondsStorage
        }
        set {
            metadataBatchMaxDelaySecondsStorage = max(Self.normalizedBatchDelay(newValue), metadataBatchMinDelaySecondsStorage)
            userDefaults.set(metadataBatchMaxDelaySecondsStorage, forKey: Keys.metadataBatchMaxDelaySeconds)
        }
    }

    var metadataBatchRetryCount: Int {
        get {
            metadataBatchRetryCountStorage
        }
        set {
            metadataBatchRetryCountStorage = Self.nearestAllowedValue(newValue, allowed: Self.metadataBatchRetryValues)
            userDefaults.set(metadataBatchRetryCountStorage, forKey: Keys.metadataBatchRetryCount)
        }
    }

    var metadataBatchLimit: Int {
        get {
            metadataBatchLimitStorage
        }
        set {
            metadataBatchLimitStorage = Self.nearestAllowedValue(newValue, allowed: Self.metadataBatchLimitValues)
            userDefaults.set(metadataBatchLimitStorage, forKey: Keys.metadataBatchLimit)
        }
    }

    var advancedSearchPageSize: Int {
        get {
            access(keyPath: \.advancedSearchPageSize)
            return advancedSearchPageSizeStorage
        }
        set {
            let normalized = Self.normalizedPageSize(newValue)
            guard advancedSearchPageSizeStorage != normalized else {
                userDefaults.set(normalized, forKey: Keys.advancedSearchPageSize)
                return
            }
            withMutation(keyPath: \.advancedSearchPageSize) {
                advancedSearchPageSizeStorage = normalized
            }
            userDefaults.set(normalized, forKey: Keys.advancedSearchPageSize)
        }
    }

    func saveSearch(_ savedSearch: SavedBookSearch) {
        savedSearches = [savedSearch] + savedSearches.filter {
            $0.query != savedSearch.query
                || $0.scope != savedSearch.scope
                || $0.mode != savedSearch.mode
        }
    }

    func removeSavedSearch(id: SavedBookSearch.ID) {
        savedSearches = savedSearches.filter { $0.id != id }
    }

    var isAdvancedSearchFacetPanelExpanded: Bool {
        didSet {
            userDefaults.set(isAdvancedSearchFacetPanelExpanded, forKey: Keys.advancedSearchFacetPanelExpanded)
        }
    }

    var isCollectionCandidateAreaVisible: Bool {
        didSet {
            userDefaults.set(isCollectionCandidateAreaVisible, forKey: Keys.collectionCandidateAreaVisible)
        }
    }

    var isVersionCandidateAreaVisible: Bool {
        didSet {
            userDefaults.set(isVersionCandidateAreaVisible, forKey: Keys.versionCandidateAreaVisible)
        }
    }

    var isAdvancedSearchHeaderPinned: Bool {
        didSet {
            userDefaults.set(isAdvancedSearchHeaderPinned, forKey: Keys.advancedSearchHeaderPinned)
        }
    }

    var isAdvancedSearchCollectionMembersExpanded: Bool {
        didSet {
            userDefaults.set(
                isAdvancedSearchCollectionMembersExpanded,
                forKey: Keys.advancedSearchCollectionMembersExpanded
            )
        }
    }

    var isHomeInsightChartsExpanded: Bool {
        didSet {
            userDefaults.set(isHomeInsightChartsExpanded, forKey: Keys.homeInsightChartsExpanded)
        }
    }

    var libraryCollectionPageSize: Int {
        get {
            libraryCollectionPageSizeStorage
        }
        set {
            libraryCollectionPageSizeStorage = Self.normalizedPageSize(newValue)
            userDefaults.set(libraryCollectionPageSizeStorage, forKey: Keys.libraryCollectionPageSize)
        }
    }

    var tagCategoryPageSize: Int {
        didSet {
            let normalized = Self.normalizedPageSize(tagCategoryPageSize)
            if tagCategoryPageSize != normalized {
                tagCategoryPageSize = normalized
                return
            }
            userDefaults.set(tagCategoryPageSize, forKey: Keys.tagCategoryPageSize)
        }
    }

    var bookCardFields: BookCardFields {
        didSet { userDefaults.set(bookCardFields.rawValue, forKey: Keys.bookCardFields) }
    }

    var homeCardWidth: Int {
        didSet {
            let normalized = Self.normalizedCardWidth(homeCardWidth)
            if homeCardWidth != normalized {
                homeCardWidth = normalized
                return
            }
            userDefaults.set(homeCardWidth, forKey: Keys.homeCardWidth)
        }
    }

    var advancedSearchCardWidth: Int {
        didSet {
            let normalized = Self.normalizedCardWidth(advancedSearchCardWidth)
            if advancedSearchCardWidth != normalized {
                advancedSearchCardWidth = normalized
                return
            }
            userDefaults.set(advancedSearchCardWidth, forKey: Keys.advancedSearchCardWidth)
        }
    }

    var libraryShelfCardWidth: Int {
        didSet {
            let normalized = Self.normalizedCardWidth(libraryShelfCardWidth)
            if libraryShelfCardWidth != normalized {
                libraryShelfCardWidth = normalized
                return
            }
            userDefaults.set(libraryShelfCardWidth, forKey: Keys.libraryShelfCardWidth)
        }
    }

    var collectionCandidatePageSize: Int {
        get {
            collectionCandidatePageSizeStorage
        }
        set {
            collectionCandidatePageSizeStorage = Self.normalizedManagementCandidatePageSize(newValue)
            userDefaults.set(collectionCandidatePageSizeStorage, forKey: Keys.collectionCandidatePageSize)
        }
    }

    var versionCandidatePageSize: Int {
        get {
            versionCandidatePageSizeStorage
        }
        set {
            versionCandidatePageSizeStorage = Self.normalizedManagementCandidatePageSize(newValue)
            userDefaults.set(versionCandidatePageSizeStorage, forKey: Keys.versionCandidatePageSize)
        }
    }

    var proxySettings: NetworkProxySettings {
        NetworkProxySettings(
            isEnabled: isProxyEnabled,
            type: proxyType,
            host: proxyHost,
            port: proxyPort
        )
    }

    var isProxyEnabled: Bool {
        didSet {
            userDefaults.set(isProxyEnabled, forKey: Keys.proxyEnabled)
        }
    }

    var proxyType: NetworkProxyType {
        didSet {
            userDefaults.set(proxyType.rawValue, forKey: Keys.proxyType)
        }
    }

    var proxyHost: String {
        didSet {
            userDefaults.set(proxyHost, forKey: Keys.proxyHost)
        }
    }

    var proxyPort: Int {
        get {
            proxyPortStorage
        }
        set {
            proxyPortStorage = min(max(newValue, 1), 65_535)
            userDefaults.set(proxyPortStorage, forKey: Keys.proxyPort)
        }
    }

    var isLocalHighlightServerEnabled: Bool {
        didSet {
            userDefaults.set(isLocalHighlightServerEnabled, forKey: Keys.localHighlightServerEnabled)
        }
    }

    var localHighlightServerPort: Int {
        get {
            localHighlightServerPortStorage
        }
        set {
            localHighlightServerPortStorage = Self.normalizedLocalHighlightServerPort(newValue)
            userDefaults.set(localHighlightServerPortStorage, forKey: Keys.localHighlightServerPort)
        }
    }

    var exhentaiIgneous: String {
        didSet { persistCredential(exhentaiIgneous, forKey: CredentialKeys.exhentaiIgneous) }
    }

    var exhentaiIPBPassHash: String {
        didSet { persistCredential(exhentaiIPBPassHash, forKey: CredentialKeys.exhentaiIPBPassHash) }
    }

    var exhentaiIPBMemberID: String {
        didSet { persistCredential(exhentaiIPBMemberID, forKey: CredentialKeys.exhentaiIPBMemberID) }
    }

    var exhentaiStar: String {
        didSet { persistCredential(exhentaiStar, forKey: CredentialKeys.exhentaiStar) }
    }

    private(set) var credentialStorageError: String?

    @ObservationIgnored private let userDefaults: UserDefaults
    @ObservationIgnored private let credentialStore: any CredentialStore
    @ObservationIgnored private let languagePreferenceStore: AppLanguagePreferenceStore
    @ObservationIgnored private var metadataBatchIntervalStrategyStorage: MetadataBatchIntervalStrategy
    @ObservationIgnored private var metadataBatchMinDelaySecondsStorage: Int
    @ObservationIgnored private var metadataBatchMaxDelaySecondsStorage: Int
    @ObservationIgnored private var metadataBatchRetryCountStorage: Int
    @ObservationIgnored private var metadataBatchLimitStorage: Int
    @ObservationIgnored private var readerInitialLoadLimitStorage: Int
    @ObservationIgnored private var readerHoverPreviewDelayMillisecondsStorage: Int
    @ObservationIgnored private var proxyPortStorage: Int
    @ObservationIgnored private var localHighlightServerPortStorage: Int
    @ObservationIgnored private var advancedSearchPageSizeStorage: Int
    @ObservationIgnored private var libraryCollectionPageSizeStorage: Int
    // The computed preferences read these observed values so a size change redraws page one too.
    private var collectionCandidatePageSizeStorage: Int
    private var versionCandidatePageSizeStorage: Int

    init(
        userDefaults providedDefaults: UserDefaults? = nil,
        credentialStore: any CredentialStore = CredentialStoreFactory.appDefault(),
        applicationLanguageDefaults: UserDefaults = .standard,
        applicationLanguageDomain: String = Bundle.main.bundleIdentifier ?? "NyaEH",
        preferencesDomain: String? = nil
    ) {
        let userDefaults = providedDefaults ?? Self.defaultUserDefaults()
        if let domain = preferencesDomain ?? (providedDefaults == nil ? Self.configuredDefaultsSuite() ?? Bundle.main.bundleIdentifier : nil) {
            LegacyNaming.migratePreferences(in: userDefaults, domain: domain)
        }
        self.userDefaults = userDefaults
        self.credentialStore = credentialStore
        let languagePreferenceStore = AppLanguagePreferenceStore(
            legacyDefaults: userDefaults,
            applicationDefaults: applicationLanguageDefaults,
            applicationDomain: applicationLanguageDomain
        )
        self.languagePreferenceStore = languagePreferenceStore
        let languageStartup = languagePreferenceStore.loadAndMigrate()
        language = languageStartup.selected
        languageStorageError = languageStartup.error
        activeLanguageSelection = languageStartup.selected
        activeResolvedLanguage = languageStartup.selected.resolved()
        migratedLanguageRequiresRestart = languageStartup.migrated
        let savedMinDelay = userDefaults.object(forKey: Keys.metadataBatchMinDelaySeconds) as? Int ?? 8
        let normalizedMinDelay = Self.normalizedBatchDelay(savedMinDelay)
        let savedMaxDelay = userDefaults.object(forKey: Keys.metadataBatchMaxDelaySeconds) as? Int ?? 20
        let normalizedMaxDelay = max(Self.normalizedBatchDelay(savedMaxDelay), normalizedMinDelay)
        metadataBatchIntervalStrategyStorage = MetadataBatchIntervalStrategy(
            rawValue: userDefaults.string(forKey: Keys.metadataBatchIntervalStrategy) ?? ""
        ) ?? .random
        metadataBatchMinDelaySecondsStorage = normalizedMinDelay
        metadataBatchMaxDelaySecondsStorage = normalizedMaxDelay
        metadataBatchRetryCountStorage = Self.nearestAllowedValue(userDefaults.object(forKey: Keys.metadataBatchRetryCount) as? Int ?? 2, allowed: Self.metadataBatchRetryValues)
        metadataBatchLimitStorage = Self.nearestAllowedValue(userDefaults.object(forKey: Keys.metadataBatchLimit) as? Int ?? 50, allowed: Self.metadataBatchLimitValues)
        readerInitialLoadLimitStorage = Self.nearestAllowedValue(userDefaults.object(forKey: Keys.readerInitialLoadLimit) as? Int ?? 100, allowed: Self.readerInitialLoadLimitValues)
        readerHoverPreviewDelayMillisecondsStorage = Self.nearestAllowedValue(userDefaults.object(forKey: Keys.readerHoverPreviewDelayMilliseconds) as? Int ?? 500, allowed: Self.readerHoverPreviewDelayValues)
        readerDisplayPreferences = ReaderDisplayPreferences(
            layoutMode: ReaderLayoutMode(
                rawValue: userDefaults.string(forKey: Keys.readerLayoutMode) ?? ""
            ) ?? ReaderDisplayPreferences.defaultValue.layoutMode,
            fitMode: ReaderFitMode(
                rawValue: userDefaults.string(forKey: Keys.readerFitMode) ?? ""
            ) ?? ReaderDisplayPreferences.defaultValue.fitMode,
            zoom: userDefaults.object(forKey: Keys.readerZoom) as? Double
                ?? ReaderDisplayPreferences.defaultValue.zoom,
            showsThumbnails: userDefaults.object(forKey: Keys.readerShowsThumbnails) as? Bool
                ?? ReaderDisplayPreferences.defaultValue.showsThumbnails
        )
        advancedSearchPageSizeStorage = Self.normalizedPageSize(userDefaults.object(forKey: Keys.advancedSearchPageSize) as? Int ?? PageSizeOption.defaultValue)
        libraryCollectionPageSizeStorage = Self.normalizedPageSize(userDefaults.object(forKey: Keys.libraryCollectionPageSize) as? Int ?? PageSizeOption.defaultValue)
        tagCategoryPageSize = Self.normalizedPageSize(userDefaults.object(forKey: Keys.tagCategoryPageSize) as? Int ?? PageSizeOption.defaultValue)
        bookCardFields = BookCardFields(rawValue: userDefaults.object(forKey: Keys.bookCardFields) as? Int
                                       ?? ((userDefaults.object(forKey: "NyaEH.cardFields") as? Int ?? BookCardFields.all.rawValue) | BookCardFields.directRead.rawValue)).intersection(.all)
        homeCardWidth = Self.normalizedCardWidth(userDefaults.object(forKey: Keys.homeCardWidth) as? Int ?? BookCardMetrics.defaultWidth)
        advancedSearchCardWidth = Self.normalizedCardWidth(userDefaults.object(forKey: Keys.advancedSearchCardWidth) as? Int ?? BookCardMetrics.defaultWidth)
        libraryShelfCardWidth = Self.normalizedCardWidth(userDefaults.object(forKey: Keys.libraryShelfCardWidth) as? Int ?? BookCardMetrics.defaultWidth)
        collectionCandidatePageSizeStorage = Self.normalizedManagementCandidatePageSize(userDefaults.object(forKey: Keys.collectionCandidatePageSize) as? Int ?? Self.managementCandidatePageSizeDefault)
        versionCandidatePageSizeStorage = Self.normalizedManagementCandidatePageSize(userDefaults.object(forKey: Keys.versionCandidatePageSize) as? Int ?? Self.managementCandidatePageSizeDefault)
        proxyPortStorage = min(max(userDefaults.object(forKey: Keys.proxyPort) as? Int ?? 7890, 1), 65_535)
        localHighlightServerPortStorage = Self.normalizedLocalHighlightServerPort(userDefaults.object(forKey: Keys.localHighlightServerPort) as? Int ?? 23_786)
        savedSearches = userDefaults.data(forKey: Keys.savedSearches)
            .flatMap { try? JSONDecoder().decode([SavedBookSearch].self, from: $0) } ?? []
        themeMode = ThemeMode(rawValue: userDefaults.string(forKey: Keys.themeMode) ?? "") ?? .system
        accentColorMode = AppAccentColor(rawValue: userDefaults.string(forKey: Keys.accentColorMode) ?? "") ?? .blue
        customAccentColorHex = NSColor.nyaehColor(hex: userDefaults.string(forKey: Keys.customAccentColorHex) ?? "")?.nyaehHexString ?? "#0A84FFFF"
        libraryRootPath = userDefaults.string(forKey: Keys.libraryRootPath)
        libraryRootBookmarkData = userDefaults.data(forKey: Keys.libraryRootBookmarkData)
        lastLibraryScanCompletedAt = (userDefaults.object(forKey: Keys.lastLibraryScanCompletedAt) as? NSNumber)?.int64Value
        gallerySearchSite = GallerySearchSite(rawValue: userDefaults.string(forKey: Keys.gallerySearchSite) ?? "") ?? .eHentai
        isProxyEnabled = userDefaults.bool(forKey: Keys.proxyEnabled)
        proxyType = NetworkProxyType(rawValue: userDefaults.string(forKey: Keys.proxyType) ?? "") ?? .http
        proxyHost = userDefaults.string(forKey: Keys.proxyHost) ?? ""
        isLocalHighlightServerEnabled = userDefaults.bool(forKey: Keys.localHighlightServerEnabled)
        isTagTranslationEnabled = userDefaults.bool(forKey: Keys.isTagTranslationEnabled)
        isAdvancedSearchFacetPanelExpanded = userDefaults.object(forKey: Keys.advancedSearchFacetPanelExpanded) as? Bool ?? true
        isCollectionCandidateAreaVisible = userDefaults.object(forKey: Keys.collectionCandidateAreaVisible) as? Bool ?? true
        isVersionCandidateAreaVisible = userDefaults.object(forKey: Keys.versionCandidateAreaVisible) as? Bool ?? true
        isAdvancedSearchHeaderPinned = userDefaults.object(forKey: Keys.advancedSearchHeaderPinned) as? Bool ?? true
        isAdvancedSearchCollectionMembersExpanded = userDefaults.object(
            forKey: Keys.advancedSearchCollectionMembersExpanded
        ) as? Bool ?? false
        isHomeInsightChartsExpanded = userDefaults.object(forKey: Keys.homeInsightChartsExpanded) as? Bool ?? false
        isCoverSimilarityVersionRecommendationEnabled = userDefaults.bool(forKey: Keys.coverSimilarityVersionRecommendationEnabled)
        isSemanticSeriesRecommendationEnabled = SemanticSeriesConfiguration.precisionFirst.isEnabled
            && userDefaults.bool(forKey: Keys.semanticSeriesRecommendationEnabled)
        if !SemanticSeriesConfiguration.precisionFirst.isEnabled {
            userDefaults.set(false, forKey: Keys.semanticSeriesRecommendationEnabled)
        }
        coverSimilarityMaximumDistance = Self.normalizedCoverSimilarityMaximumDistance(
            userDefaults.object(forKey: Keys.coverSimilarityMaximumDistance) as? Double
                ?? VersionRecommendationService.defaultCoverSimilarityMaximumDistance
        )
        bookTitleDisplayMode = BookTitleDisplayMode(rawValue: userDefaults.string(forKey: Keys.bookTitleDisplayMode) ?? "") ?? .originalTitle
        credentialStorageError = nil
        do {
            exhentaiIgneous = try credentialStore.string(forKey: CredentialKeys.exhentaiIgneous)
            exhentaiIPBPassHash = try credentialStore.string(forKey: CredentialKeys.exhentaiIPBPassHash)
            exhentaiIPBMemberID = try credentialStore.string(forKey: CredentialKeys.exhentaiIPBMemberID)
            exhentaiStar = try credentialStore.string(forKey: CredentialKeys.exhentaiStar)
        } catch {
            exhentaiIgneous = ""
            exhentaiIPBPassHash = ""
            exhentaiIPBMemberID = ""
            exhentaiStar = ""
            credentialStorageError = error.localizedDescription
        }
    }

    var localizer: AppLocalizer {
        AppLocalizer(language: activeResolvedLanguage)
    }

    var resolvedAccentColor: Color? {
        accentColorMode.color(customHex: customAccentColorHex)
    }

    var effectiveAccentColor: Color {
        resolvedAccentColor ?? .accentColor
    }

    var libraryRootURL: URL? {
        guard let libraryRootPath else {
            return nil
        }

        return URL(fileURLWithPath: libraryRootPath, isDirectory: true)
    }

    var galleryMetadataFetchConfiguration: GalleryMetadataFetchConfiguration {
        GalleryMetadataFetchConfiguration(
            site: gallerySearchSite,
            igneous: exhentaiIgneous,
            ipbPassHash: exhentaiIPBPassHash,
            ipbMemberID: exhentaiIPBMemberID,
            star: exhentaiStar,
            proxySettings: proxySettings
        )
    }

    var metadataBatchConfiguration: MetadataBatchConfiguration {
        MetadataBatchConfiguration(
            fetchConfiguration: galleryMetadataFetchConfiguration,
            intervalStrategy: metadataBatchIntervalStrategy,
            minDelaySeconds: metadataBatchMinDelaySeconds,
            maxDelaySeconds: metadataBatchMaxDelaySeconds,
            retryCount: metadataBatchRetryCount,
            limit: metadataBatchLimit
        )
    }

    func setLibraryRoot(url: URL) throws {
        let bookmark = try LibraryBookmarkService.bookmarkData(for: url)
        libraryRootPath = url.path
        libraryRootBookmarkData = bookmark
    }

    func resolvedLibraryRootURL() throws -> URL? {
        guard let bookmarkData = libraryRootBookmarkData else {
            if let libraryRootURL { try TestRuntime.validateSourceRoot(libraryRootURL) }
            return libraryRootURL
        }

        let resolved = try LibraryBookmarkService.resolveBookmark(bookmarkData)
        if resolved.isStale {
            libraryRootBookmarkData = try LibraryBookmarkService.bookmarkData(for: resolved.url)
        }
        libraryRootPath = resolved.url.path
        return resolved.url
    }

    private enum Keys {
        static let themeMode = "NyaEH.themeMode"
        static let accentColorMode = "NyaEH.accentColor.mode"
        static let customAccentColorHex = "NyaEH.accentColor.customHex"
        static let libraryRootPath = "NyaEH.libraryRootPath"
        static let libraryRootBookmarkData = "NyaEH.libraryRootBookmarkData"
        static let lastLibraryScanCompletedAt = "NyaEH.library.lastScanCompletedAt"
        static let gallerySearchSite = "NyaEH.gallerySearchSite"
        static let isTagTranslationEnabled = "NyaEH.tagTranslation.enabled"
        static let coverSimilarityVersionRecommendationEnabled = "NyaEH.versionRecommendation.coverSimilarity.enabled"
        static let semanticSeriesRecommendationEnabled = "NyaEH.collectionRecommendation.semanticTitle.enabled"
        static let coverSimilarityMaximumDistance = "NyaEH.versionRecommendation.coverSimilarity.maximumDistance"
        static let bookTitleDisplayMode = "NyaEH.bookTitle.displayMode"
        static let readerInitialLoadLimit = "NyaEH.reader.initialLoadLimit"
        static let readerHoverPreviewDelayMilliseconds = "NyaEH.reader.hoverPreviewDelayMilliseconds"
        static let readerLayoutMode = "NyaEH.reader.display.layoutMode"
        static let readerFitMode = "NyaEH.reader.display.fitMode"
        static let readerZoom = "NyaEH.reader.display.zoom"
        static let readerShowsThumbnails = "NyaEH.reader.display.showsThumbnails"
        static let readerWindowFrame = "NyaEH.reader.window.frame"
        static let mainWindowSize = "NyaEH.mainWindow.size"
        static let mainSidebarWidth = "NyaEH.mainWindow.sidebarWidth"
        static let metadataBatchIntervalStrategy = "NyaEH.metadataBatch.intervalStrategy"
        static let metadataBatchMinDelaySeconds = "NyaEH.metadataBatch.minDelaySeconds"
        static let metadataBatchMaxDelaySeconds = "NyaEH.metadataBatch.maxDelaySeconds"
        static let metadataBatchRetryCount = "NyaEH.metadataBatch.retryCount"
        static let metadataBatchLimit = "NyaEH.metadataBatch.limit"
        static let advancedSearchPageSize = "NyaEH.pagination.advancedSearch.pageSize"
        static let advancedSearchFacetPanelExpanded = "NyaEH.advancedSearch.facetPanelExpanded"
        static let collectionCandidateAreaVisible = "NyaEH.management.collection.candidateAreaVisible"
        static let versionCandidateAreaVisible = "NyaEH.management.version.candidateAreaVisible"
        static let advancedSearchHeaderPinned = "NyaEH.advancedSearch.headerPinned"
        static let advancedSearchCollectionMembersExpanded = "NyaEH.advancedSearch.collectionMembersExpanded"
        static let homeInsightChartsExpanded = "NyaEH.home.insightChartsExpanded"
        static let libraryCollectionPageSize = "NyaEH.pagination.libraryCollection.pageSize"
        static let tagCategoryPageSize = "NyaEH.pagination.tagCategory.pageSize"
        static let bookCardFields = "NyaEH.cardFields.v2"
        static let homeCardWidth = "NyaEH.cardWidth.home"
        static let advancedSearchCardWidth = "NyaEH.cardWidth.advancedSearch"
        static let libraryShelfCardWidth = "NyaEH.cardWidth.libraryShelf"
        static let collectionCandidatePageSize = "NyaEH.pagination.collectionCandidate.pageSize"
        static let versionCandidatePageSize = "NyaEH.pagination.versionCandidate.pageSize"
        static let proxyEnabled = "NyaEH.network.proxy.enabled"
        static let proxyType = "NyaEH.network.proxy.type"
        static let proxyHost = "NyaEH.network.proxy.host"
        static let proxyPort = "NyaEH.network.proxy.port"
        static let localHighlightServerEnabled = "NyaEH.localHighlight.server.enabled"
        static let localHighlightServerPort = "NyaEH.localHighlight.server.port"
        static let savedSearches = "NyaEH.search.savedSearches"
    }

    private enum CredentialKeys {
        static let exhentaiIgneous = "NyaEH.exhentai.igneous"
        static let exhentaiIPBPassHash = "NyaEH.exhentai.ipbPassHash"
        static let exhentaiIPBMemberID = "NyaEH.exhentai.ipbMemberID"
        static let exhentaiStar = "NyaEH.exhentai.star"
    }

    static func defaultUserDefaults(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> UserDefaults {
        configuredDefaultsSuite(environment: environment).flatMap(UserDefaults.init(suiteName:)) ?? .standard
    }

    private static func configuredDefaultsSuite(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> String? {
        if environment == ProcessInfo.processInfo.environment,
           let runtime = try? TestRuntime.current.get() { return runtime.defaultsSuite }
        guard let suiteName = environment[userDefaultsSuiteEnvironmentKey], !suiteName.isEmpty else { return nil }
        return suiteName
    }

    private func persistCredential(_ value: String, forKey key: String) {
        do {
            try credentialStore.set(value, forKey: key)
            credentialStorageError = nil
        } catch {
            credentialStorageError = error.localizedDescription
        }
    }

    nonisolated static let readerInitialLoadLimitValues = [20, 50, 80, 100, 150, 200, 0]
    nonisolated static let readerHoverPreviewDelayValues = [200, 300, 500, 700]
    nonisolated static let metadataBatchDelayValues = [4, 6, 8, 10, 12, 16, 20, 30, 60, 120]
    nonisolated static let metadataBatchRetryValues = [0, 1, 2, 3, 5]
    nonisolated static let metadataBatchLimitValues = [25, 50, 75, 100, 200, 0]
    nonisolated static let pageSizeValues = PageSizeOption.allowedValues
    nonisolated static let managementCandidatePageSizeValues = [10, 20, 30]
    nonisolated static let managementCandidatePageSizeDefault = 20
    nonisolated static let coverSimilarityStrictDistance = 12.0
    nonisolated static let coverSimilarityBalancedDistance = VersionRecommendationService.defaultCoverSimilarityMaximumDistance
    nonisolated static let coverSimilarityLooseDistance = 40.0
    nonisolated static let coverSimilarityDistanceRange: ClosedRange<Double> = 4...80

    nonisolated static func normalizedBatchDelay(_ value: Int) -> Int {
        nearestAllowedValue(value, allowed: metadataBatchDelayValues)
    }

    nonisolated static func normalizedPageSize(_ value: Int) -> Int {
        nearestAllowedValue(value, allowed: pageSizeValues)
    }

    nonisolated static func normalizedManagementCandidatePageSize(_ value: Int) -> Int {
        nearestAllowedValue(value, allowed: managementCandidatePageSizeValues)
    }

    nonisolated static func normalizedCardWidth(_ value: Int) -> Int {
        BookCardMetrics.normalizedWidth(value)
    }

    nonisolated static func normalizedLocalHighlightServerPort(_ value: Int) -> Int {
        min(max(value, 1_024), 65_535)
    }

    nonisolated static func normalizedCoverSimilarityMaximumDistance(_ value: Double) -> Double {
        guard value.isFinite else {
            return VersionRecommendationService.defaultCoverSimilarityMaximumDistance
        }
        return min(max(value.rounded(), coverSimilarityDistanceRange.lowerBound), coverSimilarityDistanceRange.upperBound)
    }

    nonisolated static func nearestAllowedValue(_ value: Int, allowed: [Int]) -> Int {
        allowed.min { lhs, rhs in
            abs(lhs - value) < abs(rhs - value)
        } ?? value
    }
}
