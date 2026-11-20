// 本文件实现设置窗口，集中暴露偏好、凭据、网络、导入、推荐缓存和数据库维护入口。

import AppKit
import SwiftUI

struct SettingsView: View {
    @Bindable var preferences: AppPreferences
    @Bindable var store: MaintenanceStore
    @Bindable var localHighlightServer: LocalHighlightServerController
    let updateManager: UpdateManager?
    @State private var selectedTab: SettingsTab = .general
    @State private var measuredHeights: [SettingsTab: CGFloat] = [:]

    private var localizer: AppLocalizer {
        preferences.localizer
    }

    private var windowHeight: CGFloat {
        let contentHeight = measuredHeights[selectedTab] ?? 360
        let maxHeight = min(720, (NSScreen.main?.visibleFrame.height ?? 800) - 80)
        return min(max(contentHeight + 116, 360), maxHeight)
    }

    var body: some View {
        TabView(selection: $selectedTab) {
            SettingsPaneContent(tab: .general) {
                GeneralSettingsPane(preferences: preferences, localizer: localizer, updateManager: updateManager)
            }
                .tabItem {
                    Label(localizer.string(.settingsGeneral), systemImage: "gearshape")
                }
                .tag(SettingsTab.general)

            SettingsPaneContent(tab: .library) {
                LibrarySettingsPane(preferences: preferences, store: store, localizer: localizer)
            }
                .tabItem {
                    Label(localizer.string(.library), systemImage: "books.vertical")
                }
                .tag(SettingsTab.library)

            SettingsPaneContent(tab: .storage) {
                StorageMaintenanceSettingsPane(store: store, localizer: localizer)
            }
                .tabItem {
                    Label(localizer.string(.storageMaintenance), systemImage: "externaldrive")
                }
                .tag(SettingsTab.storage)

            SettingsPaneContent(tab: .reading) {
                ReadingSettingsPane(preferences: preferences, localizer: localizer)
            }
                .tabItem {
                    Label(localizer.string(.settingsReading), systemImage: "book.pages")
                }
                .tag(SettingsTab.reading)

            SettingsPaneContent(tab: .metadata) {
                MetadataSettingsPane(preferences: preferences, store: store, localizer: localizer)
            }
                .tabItem {
                    Label(localizer.string(.settingsMetadata), systemImage: "tag")
                }
                .tag(SettingsTab.metadata)

            SettingsPaneContent(tab: .network) {
                NetworkSettingsPane(
                    preferences: preferences,
                    localHighlightServer: localHighlightServer,
                    localizer: localizer
                )
            }
                .tabItem {
                    Label(localizer.string(.settingsNetwork), systemImage: "network")
                }
                .tag(SettingsTab.network)

            SettingsPaneContent(tab: .account) {
                AccountSettingsPane(preferences: preferences, localizer: localizer)
            }
                .tabItem {
                    Label(localizer.string(.settingsAccount), systemImage: "person.crop.circle")
                }
                .tag(SettingsTab.account)
        }
        .padding()
        .onPreferenceChange(SettingsHeightPreferenceKey.self) { heights in
            measuredHeights.merge(heights) { _, new in new }
        }
        .frame(width: 620, height: windowHeight)
    }
}

private enum SettingsTab: Hashable {
    case general
    case library
    case storage
    case reading
    case metadata
    case network
    case account
}

private struct SettingsHeightPreferenceKey: PreferenceKey {
    static let defaultValue: [SettingsTab: CGFloat] = [:]

    static func reduce(value: inout [SettingsTab: CGFloat], nextValue: () -> [SettingsTab: CGFloat]) {
        value.merge(nextValue()) { _, new in new }
    }
}

private struct SettingsPaneContent<Content: View>: View {
    let tab: SettingsTab
    @ViewBuilder var content: Content

    var body: some View {
        ScrollView {
            content
                .padding()
                .frame(maxWidth: .infinity, alignment: .topLeading)
                .background(
                    GeometryReader { proxy in
                        Color.clear.preference(
                            key: SettingsHeightPreferenceKey.self,
                            value: [tab: proxy.size.height]
                        )
                    }
                )
        }
    }
}

private struct GeneralSettingsPane: View {
    @Bindable var preferences: AppPreferences
    let localizer: AppLocalizer
    let updateManager: UpdateManager?
    @State private var showingLanguageRestartPrompt = false
    @State private var languageChangeError: String?
    @State private var isRestartingForLanguage = false

    var body: some View {
        Form {
            Picker(localizer.string(.theme), selection: $preferences.themeMode) {
                ForEach(ThemeMode.allCases) { mode in
                    Text(localizer.string(mode.titleKey))
                        .tag(mode)
                }
            }

            AccentColorSettingsRow(preferences: preferences, localizer: localizer)

            Picker(localizer.string(.appLanguage), selection: Binding(
                get: { preferences.language },
                set: { selected in
                    preferences.selectLanguage(selected)
                    if let error = preferences.languageStorageError {
                        languageChangeError = error
                    } else if preferences.languageChangeRequiresRestart {
                        showingLanguageRestartPrompt = true
                    }
                }
            )) {
                ForEach(AppLanguage.allCases) { language in
                    Text(localizer.string(language.titleKey))
                        .tag(language)
                }
            }

            if preferences.languageChangeRequiresRestart {
                LabeledContent(localizer.string(.languageRestartRequired)) {
                    Button(localizer.string(.languageRestartNow)) { restartForLanguageChange() }
                        .disabled(isRestartingForLanguage)
                }
            }
            if let error = preferences.languageStorageError {
                Text("\(localizer.string(.languageChangeFailed)): \(error)")
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            Picker(localizer.string(.bookTitleDisplayMode), selection: $preferences.bookTitleDisplayMode) {
                ForEach(BookTitleDisplayMode.allCases) { mode in
                    Text(localizer.string(mode.titleKey))
                        .tag(mode)
                }
            }

            Section(localizer.string(.cardDisplay)) {
                cardFieldGroup(.cardMetadata, fields: [
                    (.language, .cardLanguage), (.color, .fullColor), (.censorship, .statusCensorshipShort), (.pages, .pages)
                ])
                cardFieldGroup(.cardEvaluation, fields: [(.rating, .rating), (.directRead, .cardDirectRead)])
                cardFieldGroup(.cardReading, fields: [(.readingStatus, .cardReading), (.readingNumbers, .cardReadingNumbers)])
                Button(localizer.string(.cardRestoreDefaults)) { preferences.bookCardFields = .all }
                    .disabled(preferences.bookCardFields == .all)
            }

            CoverPrivacySettings(preferences: preferences, localizer: localizer)

            if let updateManager {
                Section(localizer.string(.softwareUpdates)) {
                    Button(localizer.string(.checkForUpdates)) {
                        updateManager.checkForUpdates()
                    }

                    Toggle(
                        localizer.string(.automaticallyCheckForUpdates),
                        isOn: Binding(
                            get: { updateManager.automaticallyChecksForUpdates },
                            set: { updateManager.setAutomaticallyChecksForUpdates($0) }
                        )
                    )

                    Toggle(
                        localizer.string(.automaticallyDownloadAndInstallUpdates),
                        isOn: Binding(
                            get: { updateManager.automaticallyDownloadsUpdates },
                            set: { updateManager.setAutomaticallyDownloadsUpdates($0) }
                        )
                    )
                    .disabled(!updateManager.allowsAutomaticUpdates)

                    Text(localizer.string(.updateDialogsFollowAppLanguage))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .alert(localizer.string(.languageRestartTitle), isPresented: $showingLanguageRestartPrompt) {
            Button(localizer.string(.languageRestartNow)) { restartForLanguageChange() }
            Button(localizer.string(.languageRestartLater), role: .cancel) {}
        } message: {
            Text(localizer.string(.languageRestartMessage))
        }
        .alert(
            localizer.string(.languageChangeFailed),
            isPresented: Binding(
                get: { languageChangeError != nil },
                set: { if !$0 { languageChangeError = nil } }
            )
        ) {
            Button("OK", role: .cancel) { languageChangeError = nil }
        } message: {
            Text(languageChangeError ?? "")
        }
    }

    private func cardFieldGroup(_ title: L10nKey, fields: [(BookCardFields, L10nKey)]) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text(localizer.string(title))
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                ForEach(fields, id: \.0.rawValue) { field, label in
                    Toggle(localizer.string(label), isOn: Binding(
                        get: { preferences.bookCardFields.contains(field) },
                        set: { enabled in
                            if enabled {
                                preferences.bookCardFields.insert(field)
                            } else {
                                preferences.bookCardFields.remove(field)
                            }
                        }
                    ))
                    .toggleStyle(.checkbox)
                }
            }
            .frame(width: 180, alignment: .leading)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(localizer.string(title))
    }

    private func restartForLanguageChange() {
        guard !isRestartingForLanguage else { return }
        isRestartingForLanguage = true
        Task {
            do { try await AppRelauncher.relaunch() }
            catch { languageChangeError = error.localizedDescription }
            isRestartingForLanguage = false
        }
    }
}

private struct AccentColorSettingsRow: View {
    @Bindable var preferences: AppPreferences
    let localizer: AppLocalizer

    private var customColor: Binding<Color> {
        Binding {
            AppAccentColor.custom.color(customHex: preferences.customAccentColorHex) ?? .blue
        } set: { color in
            preferences.customAccentColorHex = NSColor(color).nyaehHexString
            preferences.accentColorMode = .custom
        }
    }

    var body: some View {
        LabeledContent(localizer.string(.accentColor)) {
            HStack(spacing: 8) {
                ForEach(AppAccentColor.allCases) { mode in
                    if mode == .custom {
                        CustomAccentColorPicker(
                            preferences: preferences,
                            color: customColor,
                            title: localizer.string(mode.titleKey)
                        )
                    } else {
                        AccentColorButton(
                            mode: mode,
                            customHex: preferences.customAccentColorHex,
                            isSelected: preferences.accentColorMode == mode,
                            title: localizer.string(mode.titleKey)
                        ) {
                            preferences.accentColorMode = mode
                        }
                    }
                }
            }
        }
    }
}

private struct CustomAccentColorPicker: View {
    @Bindable var preferences: AppPreferences
    @Binding var color: Color
    let title: String

    var body: some View {
        ColorPicker(selection: $color, supportsOpacity: false) {
            ZStack {
                Circle()
                    .fill(AppAccentColor.custom.color(customHex: preferences.customAccentColorHex) ?? .blue)
                    .frame(width: 18, height: 18)

                if preferences.accentColorMode == .custom {
                    Circle()
                        .stroke(.primary.opacity(0.68), lineWidth: 2)
                        .frame(width: 26, height: 26)
                    Image(systemName: "checkmark")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.white)
                }
            }
            .frame(width: 30, height: 30)
        }
        .labelsHidden()
        .help(title)
        .accessibilityLabel(title)
    }
}

private struct AccentColorButton: View {
    let mode: AppAccentColor
    let customHex: String
    let isSelected: Bool
    let title: String
    let action: () -> Void

    private var swatchColor: Color {
        mode.color(customHex: customHex) ?? .accentColor
    }

    var body: some View {
        Button(action: action) {
            ZStack {
                if mode == .system {
                    Image(systemName: "circle.lefthalf.filled")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(.secondary, Color.accentColor)
                } else {
                    Circle()
                        .fill(swatchColor)
                        .frame(width: 18, height: 18)
                }

                if isSelected {
                    Circle()
                        .stroke(.primary.opacity(0.68), lineWidth: 2)
                        .frame(width: 26, height: 26)
                    Image(systemName: "checkmark")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(mode == .yellow ? .black.opacity(0.72) : .white)
                }
            }
            .frame(width: 30, height: 30)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(title)
        .accessibilityLabel(title)
    }
}

private struct ReadingSettingsPane: View {
    @Bindable var preferences: AppPreferences
    let localizer: AppLocalizer

    var body: some View {
        Form {
            Section(localizer.string(.settingsReading)) {
                DiscreteValueSlider(
                    title: localizer.string(.readerInitialLoadLimit),
                    value: $preferences.readerInitialLoadLimit,
                    values: AppPreferences.readerInitialLoadLimitValues,
                    label: readerLimitLabel
                )

                DiscreteValueSlider(
                    title: localizer.string(.readerHoverPreviewDelay),
                    value: $preferences.readerHoverPreviewDelayMilliseconds,
                    values: AppPreferences.readerHoverPreviewDelayValues,
                    label: { "\($0)ms" }
                )

            }
        }
        .formStyle(.grouped)
    }

    private func readerLimitLabel(_ value: Int) -> String {
        value == 0 ? localizer.string(.unlimited) : "\(value)"
    }
}

private struct DiscreteValueSlider: View {
    let title: String
    @Binding var value: Int
    let values: [Int]
    let label: (Int) -> String

    var body: some View {
        LabeledContent(title) {
            DiscreteSliderTrack(value: $value, values: values, label: label)
        }
    }
}

private struct DiscreteSliderTrack: View {
    @Binding var value: Int
    let values: [Int]
    let label: (Int) -> String
    private let thumbCenterInset: CGFloat = 11
    private let horizontalSafetyPadding: CGFloat = 16
    private let tickLabelHeight: CGFloat = 24

    private var indexBinding: Binding<Double> {
        Binding {
            Double(values.firstIndex(of: value) ?? nearestIndex(for: value))
        } set: { newValue in
            let index = min(max(Int(newValue.rounded()), 0), values.count - 1)
            value = values[index]
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            VStack(alignment: .leading, spacing: 4) {
                Slider(
                    value: indexBinding,
                    in: 0...Double(max(values.count - 1, 0)),
                    step: 1
                )
                .accessibilityValue(label(value))

                GeometryReader { proxy in
                    let width = max(proxy.size.width, thumbCenterInset * 2)
                    let count = max(values.count - 1, 1)
                    let trackWidth = max(width - thumbCenterInset * 2, 1)

                    ZStack(alignment: .topLeading) {
                        ForEach(Array(values.enumerated()), id: \.offset) { index, option in
                            let fraction = CGFloat(index) / CGFloat(count)
                            Text(label(option))
                                .font(.caption2)
                                .foregroundStyle(option == value ? .secondary : .tertiary)
                                .fixedSize()
                                .lineLimit(1)
                                .position(
                                    x: thumbCenterInset + fraction * trackWidth,
                                    y: tickLabelHeight / 2
                                )
                        }
                    }
                }
                .frame(height: tickLabelHeight)
            }
            .padding(.horizontal, horizontalSafetyPadding)
        }
    }

    private func nearestIndex(for value: Int) -> Int {
        values.indices.min { lhs, rhs in
            abs(values[lhs] - value) < abs(values[rhs] - value)
        } ?? 0
    }
}

private struct LibrarySettingsPane: View {
    @Bindable var preferences: AppPreferences
    @Bindable var store: MaintenanceStore
    let localizer: AppLocalizer

    var body: some View {
        Form {
            Section(localizer.string(.libraryLocation)) {
                LabeledContent(localizer.string(.libraryLocation)) {
                    Text(preferences.libraryRootPath ?? localizer.string(.libraryNotSelected))
                        .foregroundStyle(preferences.libraryRootPath == nil ? .secondary : .primary)
                        .lineLimit(2)
                        .textSelection(.enabled)
                }

                HStack {
                    Button {
                        chooseLibraryRoot()
                    } label: {
                        Label(localizer.string(.selectLibrary), systemImage: "folder")
                    }

                    Button {
                        scanLibrary()
                    } label: {
                        Label(localizer.string(.scanLibrary), systemImage: "arrow.triangle.2.circlepath")
                    }
                    .disabled(preferences.libraryRootPath == nil || store.catalog.isScanning)
                }

                if store.catalog.isScanning {
                    Text(localizer.string(.scanning))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if let scanSummary = store.catalog.scanSummary {
                    LabeledContent(localizer.string(.scanResult), value: scanSummary)
                }
            }

            Section(localizer.string(.importLibraryData)) {
                Button {
                    chooseImportFolder()
                } label: {
                    Label(localizer.string(.importExhentaiMangaManager), systemImage: "square.and.arrow.down")
                }
                .disabled(store.catalog.isImporting)

                if store.catalog.isImporting {
                    VStack(alignment: .leading, spacing: 6) {
                        ProgressView(value: store.catalog.importProgress.fractionCompleted)
                        Text(store.catalog.importProgress.phase)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                if let importSummary = store.catalog.importSummary {
                    LabeledContent(localizer.string(.importProgress), value: importSummary)
                }

                if let importBackupPath = store.catalog.importBackupPath {
                    LabeledContent(localizer.string(.importBackup)) {
                        Text(importBackupPath)
                            .lineLimit(2)
                            .textSelection(.enabled)
                    }
                }
            }

            Section(localizer.string(.collectionManagement)) {
                Button {
                    store.catalog.refreshCollectionRecommendations(
                        useSemanticSimilarity: preferences.isSemanticSeriesRecommendationEnabled,
                        localizer: localizer
                    )
                } label: {
                    Label(localizer.string(.collectionRecommendationsRebuild), systemImage: "rectangle.stack.badge.plus")
                }
                .disabled(store.catalog.isRefreshingCollectionRecommendations)

                if store.catalog.isRefreshingCollectionRecommendations {
                    VStack(alignment: .leading, spacing: 6) {
                        ProgressView(value: store.catalog.collectionRecommendationRefreshProgress.fractionCompleted)
                        Text(store.catalog.collectionRecommendationRefreshProgress.phase)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                if let message = store.catalog.collectionRecommendationMessage {
                    Text(message)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }

            Section(localizer.string(.semanticSeriesRecommendations)) {
                Toggle(
                    localizer.string(.semanticSeriesEnabled),
                    isOn: Binding {
                        preferences.isSemanticSeriesRecommendationEnabled
                    } set: { isEnabled in
                        preferences.isSemanticSeriesRecommendationEnabled = isEnabled
                        store.catalog.refreshCollectionRecommendations(
                            useSemanticSimilarity: isEnabled,
                            localizer: localizer
                        )
                    }
                )
                .disabled(
                    !store.catalog.semanticTitleVectorStats.isReady
                        && !preferences.isSemanticSeriesRecommendationEnabled
                )

                if !store.catalog.semanticTitleVectorStats.isReady {
                    Text(localizer.string(.semanticSeriesUnavailableHint))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Text(
                    String(
                        format: localizer.string(.semanticSeriesStats),
                        store.catalog.semanticTitleVectorStats.vectorCount,
                        store.catalog.semanticTitleVectorStats.missingCount,
                        store.catalog.semanticTitleVectorStats.staleCount,
                        store.catalog.semanticTitleVectorStats.failureCount
                    )
                )
                .font(.caption)
                .foregroundStyle(.secondary)

                if let profile = store.catalog.semanticTitleVectorStats.assetState.profile {
                    Text("revision \(profile.revision) · \(profile.dimension)D · \(profile.modelIdentifier)")
                        .font(.caption2.monospaced())
                        .foregroundStyle(.tertiary)
                        .lineLimit(2)
                        .textSelection(.enabled)
                }

                HStack {
                    Button {
                        store.catalog.requestSemanticTitleAssets(localizer: localizer)
                    } label: {
                        Label(localizer.string(.semanticSeriesDownloadAssets), systemImage: "arrow.down.circle")
                    }
                    .disabled(
                        store.catalog.isDownloadingSemanticTitleAssets
                            || store.catalog.semanticTitleVectorStats.assetState.profile != nil
                    )

                    Button {
                        if store.catalog.semanticTitleVectorStats.vectorCount == 0 {
                            store.catalog.rebuildSemanticTitleVectorIndex(localizer: localizer)
                        } else {
                            store.catalog.updateSemanticTitleVectorIndex(localizer: localizer)
                        }
                    } label: {
                        Label(
                            localizer.string(
                                store.catalog.semanticTitleVectorStats.vectorCount == 0
                                    ? .semanticSeriesBuildIndex
                                    : .semanticSeriesUpdateIndex
                            ),
                            systemImage: "text.magnifyingglass"
                        )
                    }
                    .disabled(
                        store.catalog.isUpdatingSemanticTitleVectors
                            || store.catalog.semanticTitleVectorStats.assetState.profile == nil
                    )

                    Button {
                        store.catalog.rebuildSemanticTitleVectorIndex(localizer: localizer)
                    } label: {
                        Label(localizer.string(.semanticSeriesRebuildIndex), systemImage: "arrow.clockwise")
                    }
                    .disabled(
                        store.catalog.isUpdatingSemanticTitleVectors
                            || store.catalog.semanticTitleVectorStats.assetState.profile == nil
                    )
                }

                if store.catalog.isDownloadingSemanticTitleAssets {
                    ProgressView()
                }

                if store.catalog.isUpdatingSemanticTitleVectors {
                    VStack(alignment: .leading, spacing: 6) {
                        ProgressView(value: store.catalog.semanticTitleVectorProgress.fractionCompleted)
                        Text(store.catalog.semanticTitleVectorProgress.phase)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                if let message = store.catalog.semanticTitleVectorMessage {
                    Text(message)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }

            Section(localizer.string(.coverSimilarityRecommendations)) {
                Toggle(
                    localizer.string(.coverSimilarityRecommendationsEnabled),
                    isOn: $preferences.isCoverSimilarityVersionRecommendationEnabled
                )

                Picker(localizer.string(.coverSimilarityDistancePreset), selection: coverSimilarityDistancePresetBinding) {
                    Text(localizer.string(.coverSimilarityDistanceStrict)).tag(AppPreferences.coverSimilarityStrictDistance)
                    Text(localizer.string(.coverSimilarityDistanceBalanced)).tag(AppPreferences.coverSimilarityBalancedDistance)
                    Text(localizer.string(.coverSimilarityDistanceLoose)).tag(AppPreferences.coverSimilarityLooseDistance)
                }
                .pickerStyle(.segmented)

                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text(localizer.string(.coverSimilarityMaximumDistance))
                        Spacer()
                        VStack(alignment: .trailing, spacing: 2) {
                            Text(String(format: "%.0f", preferences.coverSimilarityMaximumDistance))
                            Text(String(format: "L2 %.2f", sqrt(preferences.coverSimilarityMaximumDistance)))
                                .font(.caption2)
                        }
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                    }
                    Slider(
                        value: $preferences.coverSimilarityMaximumDistance,
                        in: AppPreferences.coverSimilarityDistanceRange,
                        step: 1
                    )
                    Text(localizer.string(.coverSimilarityDistanceDescription))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Button {
                    store.catalog.refreshVersionRecommendations(
                        useCoverSimilarity: preferences.isCoverSimilarityVersionRecommendationEnabled,
                        maximumCoverDistance: preferences.coverSimilarityMaximumDistance,
                        localizer: localizer
                    )
                } label: {
                    Label(localizer.string(.versionRecommendationsRebuild), systemImage: "sparkles")
                }
                .disabled(store.catalog.isRefreshingVersionRecommendations)

                if store.catalog.isRefreshingVersionRecommendations {
                    VStack(alignment: .leading, spacing: 6) {
                        ProgressView(value: store.catalog.versionRecommendationRefreshProgress.fractionCompleted)
                        Text(store.catalog.versionRecommendationRefreshProgress.phase)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                if let message = store.catalog.versionRecommendationMessage {
                    Text(message)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Button {
                    store.catalog.repairVersionGroupMarkedState(localizer: localizer)
                } label: {
                    Label(localizer.string(.versionGroupMarkedRepair), systemImage: "heart.fill")
                }
                .disabled(store.catalog.isRepairingVersionGroupMarkedState)

                if store.catalog.isRepairingVersionGroupMarkedState {
                    ProgressView()
                }

                if let message = store.catalog.versionGroupMarkedRepairMessage {
                    Text(message)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                LabeledContent(localizer.string(.coverVectors)) {
                    Text(coverVectorStatsText)
                        .foregroundStyle(.secondary)
                }

                HStack(spacing: 8) {
                    Button {
                        store.catalog.updateMissingCoverVectors(localizer: localizer)
                    } label: {
                        Label(localizer.string(.coverVectorsUpdate), systemImage: "arrow.triangle.2.circlepath")
                    }
                    .disabled(store.catalog.isUpdatingCoverVectors)

                    Button {
                        store.catalog.rebuildCoverVectorIndex(localizer: localizer)
                    } label: {
                        Label(localizer.string(.coverVectorsRebuild), systemImage: "hammer")
                    }
                    .disabled(store.catalog.isUpdatingCoverVectors)

                    Button(role: .destructive) {
                        store.catalog.clearCoverVectorIndex(localizer: localizer)
                    } label: {
                        Label(localizer.string(.coverVectorsClear), systemImage: "trash")
                    }
                    .disabled(store.catalog.isUpdatingCoverVectors)
                }

                Button {
                    store.catalog.generateCoverDistanceReport(
                        referenceThreshold: preferences.coverSimilarityMaximumDistance,
                        localizer: localizer
                    )
                } label: {
                    Label(localizer.string(.coverDistanceReportGenerate), systemImage: "chart.xyaxis.line")
                }
                .disabled(store.catalog.isGeneratingCoverDistanceReport)

                if store.catalog.isUpdatingCoverVectors {
                    VStack(alignment: .leading, spacing: 6) {
                        ProgressView(value: store.catalog.coverVectorProgress.fractionCompleted)
                        Text("\(store.catalog.coverVectorProgress.phase) \(store.catalog.coverVectorProgress.completed)/\(store.catalog.coverVectorProgress.total)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                if let message = store.catalog.coverVectorMessage {
                    Text(message)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                if let report = store.catalog.coverDistanceReport {
                    ScrollView {
                        Text(report)
                            .font(.system(.caption, design: .monospaced))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                    }
                    .frame(minHeight: 120, maxHeight: 260)
                }
            }
        }
        .formStyle(.grouped)
        .onAppear {
            store.catalog.refreshCoverVectorStats()
            store.catalog.refreshSemanticTitleVectorStats()
        }
        .onChange(of: store.catalog.semanticTitleVectorStats.isReady) { wasReady, isReady in
            if isReady, !wasReady, preferences.isSemanticSeriesRecommendationEnabled {
                store.catalog.refreshCollectionRecommendations(
                    useSemanticSimilarity: true,
                    localizer: localizer
                )
            }
        }
    }

    private var coverVectorStatsText: String {
        let stats = store.catalog.coverVectorStats
        return String(
            format: localizer.string(.coverVectorsStats),
            stats.vectorCount,
            stats.missingCount,
            stats.staleCount,
            stats.failureCount
        )
    }

    private var coverSimilarityDistancePresetBinding: Binding<Double> {
        Binding {
            let value = preferences.coverSimilarityMaximumDistance
            if value == AppPreferences.coverSimilarityStrictDistance {
                return AppPreferences.coverSimilarityStrictDistance
            }
            if value == AppPreferences.coverSimilarityLooseDistance {
                return AppPreferences.coverSimilarityLooseDistance
            }
            return AppPreferences.coverSimilarityBalancedDistance
        } set: { newValue in
            preferences.coverSimilarityMaximumDistance = newValue
        }
    }

    private func chooseLibraryRoot() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.prompt = localizer.string(.selectLibrary)

        guard panel.runModal() == .OK, let url = panel.url else {
            return
        }

        do {
            try preferences.setLibraryRoot(url: url)
            store.catalog.scanSummary = nil
        } catch {
            store.catalog.loadError = error.localizedDescription
        }
    }

    private func scanLibrary() {
        do {
            guard let rootURL = try preferences.resolvedLibraryRootURL() else {
                store.catalog.loadError = localizer.string(.libraryNotSelected)
                return
            }

            store.catalog.scanLibrary(rootURL: rootURL, localizer: localizer) { _ in
                preferences.lastLibraryScanCompletedAt = Timestamp.nowMilliseconds()
            }
        } catch {
            store.catalog.loadError = error.localizedDescription
        }
    }

    private func chooseImportFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        panel.prompt = localizer.string(.importSelectFolder)

        guard panel.runModal() == .OK, let url = panel.url else {
            return
        }

        store.catalog.importExhentaiMangaManager(from: url, localizer: localizer)
    }
}

private struct StorageMaintenanceSettingsPane: View {
    @Bindable var store: MaintenanceStore
    let localizer: AppLocalizer
    @State private var pendingRestoreURL: URL?
    @State private var showingRestoreConfirmation = false
    @State private var showingRepairConfirmation = false
    @State private var showingVacuumConfirmation = false

    var body: some View {
        Form {
            Section(localizer.string(.backupAndRestore)) {
                Text(localizer.string(.backupDescription))
                    .font(.footnote)
                    .foregroundStyle(.secondary)

                HStack {
                    Button(action: exportBackup) {
                        Label(localizer.string(.exportBackup), systemImage: "square.and.arrow.up")
                    }
                    Button(action: chooseRestorePackage) {
                        Label(localizer.string(.importFromThisApp), systemImage: "square.and.arrow.down")
                    }
                }
                .disabled(store.catalog.isManagingBackup)

                if store.catalog.isManagingBackup {
                    ProgressView()
                        .controlSize(.small)
                }
                if let message = store.catalog.backupMessage {
                    Text(message)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }

            Section(localizer.string(.dataHealthCheck)) {
                HStack {
                    Button {
                        store.catalog.runDataHealthCheck()
                    } label: {
                        Label(localizer.string(.runCheck), systemImage: "checkmark.shield")
                    }
                    Button {
                        showingRepairConfirmation = true
                    } label: {
                        Label(localizer.string(.repairDerivedData), systemImage: "wrench.and.screwdriver")
                    }
                    .disabled(store.catalog.dataHealthReport?.issues.contains(where: \.repairable) != true)
                }
                .disabled(store.catalog.isRunningDataHealthCheck)

                if store.catalog.isRunningDataHealthCheck {
                    ProgressView()
                        .controlSize(.small)
                }
                if let report = store.catalog.dataHealthReport {
                    if report.repairedIssueCount > 0 {
                        Text(String(format: localizer.string(.repairSummaryFormat), report.repairedIssueCount))
                            .foregroundStyle(.secondary)
                    }
                    if report.isHealthy {
                        Label(localizer.string(.dataHealthy), systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    } else {
                        ForEach(report.issues) { issue in
                            VStack(alignment: .leading, spacing: 3) {
                                Label(issue.title, systemImage: issue.severity == .error ? "xmark.octagon.fill" : "exclamationmark.triangle.fill")
                                Text(issue.detail)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }

            Section(localizer.string(.databaseMaintenance)) {
                Button {
                    showingVacuumConfirmation = true
                } label: {
                    Label("VACUUM", systemImage: "cylinder.split.1x2")
                }
                .disabled(store.catalog.isRunningDataHealthCheck)
                Text(localizer.string(.vacuumDescription))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .confirmationDialog(localizer.string(.confirmRestore), isPresented: $showingRestoreConfirmation) {
            Button(localizer.string(.restore), role: .destructive) {
                if let pendingRestoreURL {
                    store.catalog.restoreBackup(from: pendingRestoreURL, localizer: localizer)
                }
                pendingRestoreURL = nil
            }
            Button(localizer.string(.cancel), role: .cancel) { pendingRestoreURL = nil }
        } message: {
            Text(localizer.string(.restoreWarning))
        }
        .confirmationDialog(localizer.string(.repairDerivedData), isPresented: $showingRepairConfirmation) {
            Button(localizer.string(.repair)) { store.catalog.repairDerivedData() }
            Button(localizer.string(.cancel), role: .cancel) {}
        } message: {
            Text(localizer.string(.repairBackupNotice))
        }
        .confirmationDialog("VACUUM", isPresented: $showingVacuumConfirmation) {
            Button("VACUUM") { store.catalog.vacuumDatabase() }
            Button(localizer.string(.cancel), role: .cancel) {}
        } message: {
            Text(localizer.string(.vacuumDescription))
        }
    }

    private func exportBackup() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "NyaEH-Backup.\(LibraryBackupService.packageExtension)"
        panel.canCreateDirectories = true
        panel.prompt = localizer.string(.exportBackup)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        store.catalog.exportBackup(to: url, localizer: localizer)
    }

    private func chooseRestorePackage() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = localizer.string(.restore)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        pendingRestoreURL = url
        showingRestoreConfirmation = true
    }
}

private struct MetadataSettingsPane: View {
    @Bindable var preferences: AppPreferences
    @Bindable var store: MaintenanceStore
    let localizer: AppLocalizer

    var body: some View {
        Form {
            Section(localizer.string(.galleryMetadataSettings)) {
                Picker(localizer.string(.gallerySearchSite), selection: $preferences.gallerySearchSite) {
                    ForEach(GallerySearchSite.allCases) { site in
                        Text(site.displayName)
                            .tag(site)
                    }
                }
            }

            Section(localizer.string(.tagTranslations)) {
                Toggle(
                    localizer.string(.tagTranslationsEnabled),
                    isOn: $preferences.isTagTranslationEnabled
                )

                LabeledContent(localizer.string(.source)) {
                    Text("EhTagTranslation/Database")
                }

                LabeledContent(localizer.string(.tagTranslationsCurrentRevision)) {
                    Text(store.catalog.tagTranslationManifest?.revision.prefix(12).description ?? localizer.string(.tagTranslationsNotDownloaded))
                }

                LabeledContent(localizer.string(.tagTranslationsLastUpdated)) {
                    Text(formattedTimestamp(store.catalog.tagTranslationManifest?.downloadedAt) ?? localizer.string(.tagTranslationsNotDownloaded))
                }

                Button {
                    Task {
                        await store.catalog.updateTagTranslations(
                            proxySettings: preferences.proxySettings,
                            localizer: localizer
                        )
                    }
                } label: {
                    if store.catalog.isUpdatingTagTranslations {
                        ProgressView()
                            .controlSize(.small)
                        Text(localizer.string(.tagTranslationsUpdating))
                    } else {
                        Text(localizer.string(.tagTranslationsUpdate))
                    }
                }
                .disabled(store.catalog.isUpdatingTagTranslations)

                if let message = store.catalog.tagTranslationMessage {
                    Text(message)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }

            Section(localizer.string(.workCharacterIndex)) {
                HStack {
                    Button {
                        store.catalog.updateWorkCharacterIndexIncrementally(localizer: localizer)
                    } label: {
                        Label(localizer.string(.workCharacterIndexUpdate), systemImage: "arrow.triangle.2.circlepath")
                    }
                    .disabled(store.catalog.isUpdatingWorkCharacterIndex)

                    Button {
                        store.catalog.rebuildWorkCharacterIndex(localizer: localizer)
                    } label: {
                        Label(localizer.string(.workCharacterIndexRebuild), systemImage: "link.badge.plus")
                    }
                    .disabled(store.catalog.isUpdatingWorkCharacterIndex)
                }

                if store.catalog.isUpdatingWorkCharacterIndex {
                    ProgressView()
                        .controlSize(.small)
                }

                if let message = store.catalog.workCharacterIndexMessage {
                    Text(message)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }

            Section(localizer.string(.metadataBatch)) {
                Picker(localizer.string(.metadataBatchIntervalStrategy), selection: $preferences.metadataBatchIntervalStrategy) {
                    ForEach(MetadataBatchIntervalStrategy.allCases) { strategy in
                        Text(localizer.string(strategy.titleKey))
                            .tag(strategy)
                    }
                }

                BatchDelayRangeSlider(preferences: preferences, localizer: localizer)

                DiscreteValueSlider(
                    title: localizer.string(.metadataBatchRetryCount),
                    value: $preferences.metadataBatchRetryCount,
                    values: AppPreferences.metadataBatchRetryValues,
                    label: { "\($0)" }
                )

                DiscreteValueSlider(
                    title: localizer.string(.metadataBatchLimit),
                    value: $preferences.metadataBatchLimit,
                    values: AppPreferences.metadataBatchLimitValues,
                    label: { $0 == 0 ? localizer.string(.unlimited) : "\($0)" }
                )
            }
            .onChange(of: preferences.metadataBatchMinDelaySeconds) { _, newValue in
                if preferences.metadataBatchMaxDelaySeconds < newValue {
                    preferences.metadataBatchMaxDelaySeconds = newValue
                }
            }
        }
        .formStyle(.grouped)
        .onAppear {
            store.catalog.refreshTagTranslationStatus()
        }
    }

    private func formattedTimestamp(_ milliseconds: Int64?) -> String? {
        guard let milliseconds else {
            return nil
        }

        return Date(timeIntervalSince1970: TimeInterval(milliseconds) / 1000)
            .formatted(date: .abbreviated, time: .shortened)
    }
}

private struct BatchDelayRangeSlider: View {
    @Bindable var preferences: AppPreferences
    let localizer: AppLocalizer

    var body: some View {
        LabeledContent(localizer.string(.metadataBatchIntervalRange)) {
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(localizer.string(.metadataBatchMinDelay))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    DiscreteSliderTrack(
                        value: $preferences.metadataBatchMinDelaySeconds,
                        values: AppPreferences.metadataBatchDelayValues,
                        label: { "\($0)s" }
                    )
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text(localizer.string(.metadataBatchMaxDelay))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    DiscreteSliderTrack(
                        value: $preferences.metadataBatchMaxDelaySeconds,
                        values: AppPreferences.metadataBatchDelayValues,
                        label: { "\($0)s" }
                    )
                }
            }
        }
    }
}

private struct NetworkSettingsPane: View {
    @Bindable var preferences: AppPreferences
    @Bindable var localHighlightServer: LocalHighlightServerController
    let localizer: AppLocalizer
    @State private var proxyTestMessage: String?
    @State private var githubTestMessage: String?
    @State private var ehentaiTestMessage: String?
    @State private var runningTest: NetworkTestTarget?
    @State private var copyMessage: String?

    var body: some View {
        Form {
            Section(localizer.string(.proxySettings)) {
                Toggle(localizer.string(.proxyEnabled), isOn: $preferences.isProxyEnabled)

                Picker(localizer.string(.proxyType), selection: $preferences.proxyType) {
                    Text("HTTP/HTTPS").tag(NetworkProxyType.http)
                    Text("SOCKS").tag(NetworkProxyType.socks)
                }
                .pickerStyle(.segmented)

                TextField(localizer.string(.proxyHost), text: $preferences.proxyHost)
                TextField(
                    localizer.string(.proxyPort),
                    value: $preferences.proxyPort,
                    format: .number
                )
            }

            Section(localizer.string(.connectivityTests)) {
                connectivityButton(
                    target: .proxy,
                    title: localizer.string(.testProxyConnectivity),
                    message: proxyTestMessage
                )
                connectivityButton(
                    target: .github,
                    title: localizer.string(.testGitHubConnectivity),
                    message: githubTestMessage
                )
                connectivityButton(
                    target: .ehentai,
                    title: localizer.string(.testEHentaiConnectivity),
                    message: ehentaiTestMessage
                )
            }

            Section(localizer.string(.localHighlightServer)) {
                Toggle(localizer.string(.localHighlightServerEnabled), isOn: $preferences.isLocalHighlightServerEnabled)
                TextField(
                    localizer.string(.localHighlightServerPort),
                    value: $preferences.localHighlightServerPort,
                    format: .number
                )

                LabeledContent(localizer.string(.status)) {
                    Text(statusMessage)
                        .foregroundStyle(statusColor)
                }

                LabeledContent(localizer.string(.url)) {
                    Text(localHighlightURL)
                        .textSelection(.enabled)
                }

                Button {
                    copyUserscript()
                } label: {
                    Label(localizer.string(.copyUserscript), systemImage: "doc.on.doc")
                }

                if let copyMessage {
                    Text(copyMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
    }

    private func connectivityButton(target: NetworkTestTarget, title: String, message: String?) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                Task {
                    await run(target)
                }
            } label: {
                if runningTest == target {
                    ProgressView()
                        .controlSize(.small)
                    Text(title)
                } else {
                    Label(title, systemImage: "network")
                }
            }
            .disabled(runningTest != nil)

            if let message {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(message.hasPrefix("OK") ? Color.secondary : Color.red)
            }
        }
    }

    private func run(_ target: NetworkTestTarget) async {
        runningTest = target
        defer {
            runningTest = nil
        }

        let service = NetworkConnectivityService()
        let result: NetworkConnectivityResult
        switch target {
        case .proxy:
            result = await service.testProxy(settings: preferences.proxySettings)
            proxyTestMessage = message(for: result)
        case .github:
            result = await service.testGitHub(proxySettings: preferences.proxySettings)
            githubTestMessage = message(for: result)
        case .ehentai:
            result = await service.testEHentai(configuration: preferences.galleryMetadataFetchConfiguration)
            ehentaiTestMessage = message(for: result)
        }
    }

    private func message(for result: NetworkConnectivityResult) -> String {
        "\(result.success ? "OK" : "Failed"): \(result.message)"
    }

    private var localHighlightURL: String {
        "http://127.0.0.1:\(preferences.localHighlightServerPort)/api/highlight/v1/galleries"
    }

    private var statusMessage: String {
        switch localHighlightServer.status {
        case .disabled:
            return localizer.string(.disabled)
        case .starting(let port):
            return "\(localizer.string(.starting)) :\(port)"
        case .running(let port):
            return "\(localizer.string(.running)) :\(port)"
        case .failed(_, let message):
            return "\(localizer.string(.failed)): \(message)"
        }
    }

    private var statusColor: Color {
        switch localHighlightServer.status {
        case .failed:
            return .red
        case .running:
            return .secondary
        default:
            return .secondary
        }
    }

    private func copyUserscript() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(
            LocalHighlightUserscriptTemplate.script(port: preferences.localHighlightServerPort),
            forType: .string
        )
        copyMessage = localizer.string(.userscriptCopied)
    }
}

private enum NetworkTestTarget {
    case proxy
    case github
    case ehentai
}

private struct AccountSettingsPane: View {
    @Bindable var preferences: AppPreferences
    let localizer: AppLocalizer

    var body: some View {
        Form {
            Section(localizer.string(.settingsAccount)) {
                SecureField(localizer.string(.igneous), text: $preferences.exhentaiIgneous)
                SecureField(localizer.string(.ipbPassHash), text: $preferences.exhentaiIPBPassHash)
                SecureField(localizer.string(.ipbMemberID), text: $preferences.exhentaiIPBMemberID)
                SecureField(localizer.string(.star), text: $preferences.exhentaiStar)
                Text(localizer.string(.localCredentialFileNotice))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let error = preferences.credentialStorageError {
                    Text("\(localizer.string(.credentialSaveFailed)): \(error)")
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
        }
        .formStyle(.grouped)
        .padding()
    }
}
