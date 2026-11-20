// 本文件实现标签分类页，使用批量摘要和单层 LazyVGrid 减少大标签集合的滚动成本。

import AppKit
import SwiftUI

struct TagCategoryView: View {
    @Bindable var store: TagDiscoveryStore
    let taskCenterStore: TaskCenterStore
    let category: TagCategory
    let isActive: Bool
    let isTagTranslationEnabled: Bool
    @Binding var pageSize: Int
    @Binding var isTaskCenterPresented: Bool
    let localizer: AppLocalizer
    let onSelectTag: (TagDisplaySummary) -> Void

    @State private var sortStrategy: TagSortStrategy = .count
    @State private var sortDirection: SortDirection = .descending
    @State private var selectedTab: TagCategoryTab = .artist
    @State private var displayMode: TagNamespaceDisplayMode = .grouped
    @State private var selectedNamespaceGroup: TagNamespaceGroup?
    @State private var showsFollowedOnly = false
    @State private var searchText = ""
    @State private var page = 1
    @State private var presentation = TagCategoryPresentation()
    @State private var footerOverlayHeight = TagCategoryFloatingMetrics.defaultFooterHeight

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .bottom) {
                ScrollView {
                    VStack(spacing: 0) {
                        tagScrollableContent

                        Color.clear
                            .frame(height: footerOverlayHeight + TagCategoryFloatingMetrics.contentGap)
                    }
                }

                VStack {
                    Spacer()
                    tagFooter
                        .padding(.horizontal, TagCategoryFloatingMetrics.horizontalPadding)
                        .padding(.bottom, TagCategoryFloatingMetrics.verticalPadding)
                        .padding(.top, 8)
                        .readTagCategoryFooterHeight()
                }
            }
            .toolbar {
                if isActive {
                    if category == .tags {
                        ToolbarItemGroup(placement: .navigation) {
                            ForEach(TagNamespaceToolbarMenu.displayOrder) { mode in
                                selectionToggle(
                                    option: mode,
                                    selection: $displayMode,
                                    titleKey: mode.titleKey,
                                    systemImage: mode.toolbarSystemImage
                                )
                            }
                            if TagNamespaceToolbarMenu.shouldShow(
                                displayMode: displayMode,
                                hasGroups: !availableNamespaceGroups.isEmpty
                            ) {
                                namespaceGroupMenu
                            }
                        }
                    } else {
                        ToolbarItemGroup(placement: .navigation) {
                            ForEach(category.tabs) { tab in
                                selectionToggle(
                                    option: tab,
                                    selection: $selectedTab,
                                    titleKey: tab.titleKey,
                                    systemImage: tab.toolbarSystemImage
                                )
                            }
                        }
                    }
                    ToolbarSpacer(.flexible, placement: MainWindowToolbarLayout.actionPlacement)
                    if TagCategoryToolbarLayout.isCompact(detailWidth: proxy.size.width) {
                        ToolbarItemGroup(placement: MainWindowToolbarLayout.actionPlacement) {
                            compactSortingMenu
                        }
                    } else {
                        ToolbarItem(placement: MainWindowToolbarLayout.actionPlacement) {
                            sortStrategyGlassGroup
                        }
                        .sharedBackgroundVisibility(.hidden)
                        ToolbarSpacer(.fixed, placement: MainWindowToolbarLayout.actionPlacement)
                        ToolbarItem(placement: MainWindowToolbarLayout.actionPlacement) {
                            directionButton
                        }
                    }
                    ToolbarSpacer(.fixed, placement: MainWindowToolbarLayout.actionPlacement)
                    ToolbarItemGroup(placement: MainWindowToolbarLayout.actionPlacement) {
                        SettingsToolbarButton(localizer: localizer)
                        TaskCenterToolbarButton(
                            store: taskCenterStore,
                            isPresented: $isTaskCenterPresented,
                            localizer: localizer
                        )
                    }
                }
            }
        }
        .modifier(ActiveTagCategorySearch(
            isActive: isActive,
            text: $searchText,
            prompt: localizer.string(.tagCategorySearchPlaceholder)
        ))
        .navigationTitle(localizer.string(category.titleKey))
        .focusedSceneValue(\.nyaehViewCommands, viewCommandContext)
        .onPreferenceChange(TagCategoryFooterHeightPreferenceKey.self) { height in
            guard height > 0 else {
                return
            }
            footerOverlayHeight = height
        }
        .onAppear {
            syncSelectedTab()
            rebuildPresentation()
        }
        .onChange(of: category) { _, _ in
            syncSelectedTab()
            resetPresentationPage()
        }
        .onChange(of: selectedTab) { _, _ in
            resetPresentationPage()
        }
        .onChange(of: displayMode) { _, _ in
            resetPresentationPage()
        }
        .onChange(of: selectedNamespaceGroup) { _, _ in
            resetPresentationPage()
        }
        .onChange(of: searchScope) { oldScope, newScope in
            searchText = TagCategorySearchScope.query(
                searchText,
                afterChangingFrom: oldScope,
                to: newScope
            )
        }
        .onChange(of: searchText) { _, _ in
            resetPresentationPage()
        }
        .onChange(of: showsFollowedOnly) { _, _ in
            resetPresentationPage()
        }
        .onChange(of: sortStrategy) { _, _ in
            resetPresentationPage()
        }
        .onChange(of: sortDirection) { _, _ in
            resetPresentationPage()
        }
        .onChange(of: isTagTranslationEnabled) { _, _ in
            resetPresentationPage()
        }
        .onChange(of: store.catalog.tagSummaryRevision) { _, _ in
            if isActive { rebuildPresentation() }
        }
        .onChange(of: isActive) { _, active in
            guard active else { return }
            // Detail routes keep this page mounted. An edit can invalidate its tag counts while covered.
            store.catalog.loadTagSummaries(for: category, isTagTranslationEnabled: isTagTranslationEnabled)
            rebuildPresentation()
        }
        .onChange(of: page) { _, _ in
            rebuildPresentation()
        }
        .onChange(of: pageSize) { _, _ in
            rebuildPresentation()
        }
        .task(id: "\(category.id)-\(isTagTranslationEnabled)") {
            syncSelectedTab()
            store.catalog.reloadTagSummaries(
                for: category,
                isTagTranslationEnabled: isTagTranslationEnabled
            )
            rebuildPresentation()
        }
    }

    private var viewCommandContext: NyaEHViewCommandContext {
        NyaEHViewCommandContext(
            canIncreaseCardSize: false,
            increaseCardSize: {},
            canDecreaseCardSize: false,
            decreaseCardSize: {},
            layout: nil,
            setLayout: { _ in },
            sortStrategy: sortStrategy,
            setSortStrategy: { sortStrategy = $0 },
            searchResultSortKey: nil,
            setSearchResultSortKey: { _ in },
            sortDirection: sortDirection,
            setSortDirection: { sortDirection = $0 }
        )
    }

    private var namespaceGroupMenu: some View {
        let groups = availableNamespaceGroups
        let title = localizer.string(selectedNamespaceGroup?.titleKey ?? .tagDisplayGrouped)
        return Menu {
            ForEach(groups) { group in
                Toggle(
                    localizer.string(group.titleKey),
                    isOn: ExclusiveToolbarSelection.binding(
                        selection: $selectedNamespaceGroup,
                        option: Optional(group)
                    )
                )
            }
        } label: {
            Label(title, systemImage: "square.grid.2x2")
        }
        .labelStyle(.iconOnly)
        .help(title)
        .accessibilityLabel(title)
    }

    private var sortStrategyGlassGroup: some View {
        HStack(spacing: 2) {
            sortStrategyButton(.alphabetical)
            sortStrategyButton(.count)
        }
        .padding(3)
        .glassEffect(.regular, in: Capsule())
        .animation(.snappy(duration: 0.18), value: sortStrategy)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(localizer.string(.tagSortStrategy))
    }

    private func sortStrategyButton(_ strategy: TagSortStrategy) -> some View {
        let title = localizer.string(strategy.titleKey)
        let isSelected = sortStrategy == strategy
        return Button {
            sortStrategy = strategy
        } label: {
            Group {
                if strategy == .alphabetical {
                    Text("Ab")
                        .font(.system(size: 14, weight: .semibold))
                } else {
                    Image(systemName: "number")
                        .font(.system(size: 16, weight: .medium))
                }
            }
            .foregroundStyle(isSelected ? Color.white : Color.primary)
            .frame(width: 32, height: 30)
            .background {
                if isSelected {
                    Circle().fill(Color.accentColor)
                }
            }
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(title)
        .accessibilityLabel(title)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private var directionButton: some View {
        let nextTitle = localizer.string(sortDirection.next == .ascending ? .sortSwitchToAscending : .sortSwitchToDescending)
        return Button {
            sortDirection = sortDirection.next
        } label: {
            Label(nextTitle, systemImage: sortDirection.toolbarSystemImage)
        }
        .labelStyle(.iconOnly)
        .help(nextTitle)
        .accessibilityLabel(nextTitle)
    }

    private func selectionToggle<Option: Equatable & Sendable>(
        option: Option,
        selection: Binding<Option>,
        titleKey: L10nKey,
        systemImage: String
    ) -> some View {
        let title = localizer.string(titleKey)
        return Toggle(isOn: ExclusiveToolbarSelection.binding(selection: selection, option: option)) {
            Label(title, systemImage: systemImage)
        }
        .toggleStyle(.button)
        .labelStyle(.iconOnly)
        .help(title)
        .accessibilityLabel(title)
    }

    private var compactSortingMenu: some View {
        Menu {
            Picker(localizer.string(.tagSortStrategy), selection: $sortStrategy) {
                ForEach(TagSortStrategy.allCases) { strategy in
                    Text(localizer.string(strategy.titleKey)).tag(strategy)
                }
            }
            Button {
                sortDirection = sortDirection.next
            } label: {
                Label(
                    localizer.string(sortDirection.next == .ascending ? .sortSwitchToAscending : .sortSwitchToDescending),
                    systemImage: sortDirection.toolbarSystemImage
                )
            }
        } label: {
            Label(localizer.string(.tagSortStrategy), systemImage: "arrow.up.arrow.down")
        }
        .labelStyle(.iconOnly)
        .accessibilityLabel(localizer.string(.tagSortStrategy))
        .help(localizer.string(.tagSortStrategy))
    }

    private var followedToggle: some View {
        Toggle(localizer.string(.tagFollowedOnly), isOn: $showsFollowedOnly)
            .toggleStyle(.checkbox)
            .controlSize(.small)
    }

    private var tagCountLabel: some View {
        Text(localizer.tagTotalCount(presentation.tagCount))
            .font(.callout)
            .foregroundStyle(.secondary)
            .monospacedDigit()
            .lineLimit(1)
    }

    private var tagFooter: some View {
        FloatingPaginationDock(
            page: $page,
            pageSize: $pageSize,
            itemCount: presentation.tagCount,
            showsPagination: FloatingPaginationPresentation.showsPagination(
                itemCount: presentation.tagCount
            ),
            localizer: localizer
        ) {
            tagCountLabel
        } trailingContent: {
            followedToggle
        } compactActions: {
            tagFooterCompactActions
        }
    }

    @ViewBuilder
    private var tagFooterCompactActions: some View {
        Text(localizer.tagTotalCount(presentation.tagCount))

        Divider()

        Toggle(localizer.string(.tagFollowedOnly), isOn: $showsFollowedOnly)
    }

    @ViewBuilder
    private var tagScrollableContent: some View {
        if store.catalog.isLoadingTagSummaries(
            for: category,
            isTagTranslationEnabled: isTagTranslationEnabled
        ) {
            ProgressView()
                .frame(maxWidth: .infinity, minHeight: 240)
        } else if let error = store.catalog.tagSummaryError(
            for: category,
            isTagTranslationEnabled: isTagTranslationEnabled
        ) {
            ContentUnavailableView(
                localizer.string(.noBooks),
                systemImage: "exclamationmark.triangle",
                description: Text(error)
            )
            .frame(maxWidth: .infinity, minHeight: 240)
        } else if presentation.tagCount == 0 {
            ContentUnavailableView(
                localizer.string(
                    isSearchActive ? .tagSearchNoResults : (showsFollowedOnly ? .tagNoFollowed : .tagNoTags)
                ),
                systemImage: isSearchActive ? "magnifyingglass" : (showsFollowedOnly ? "heart.fill" : category.systemImage),
                description: Text(localizer.string(
                    isSearchActive ? .tagSearchNoResultsDescription
                        : (showsFollowedOnly ? .tagNoFollowedDescription : .tagNoTagsDescription)
                ))
            )
            .frame(maxWidth: .infinity, minHeight: 240)
        } else {
            tagContent
        }
    }

    @ViewBuilder
    private var tagContent: some View {
        TagSummaryGrid(
            sections: presentation.sections,
            cardLayout: TagSummaryCardLayout.resolve(category: category, selectedTab: selectedTab),
            localizer: localizer,
            assetURL: store.catalog.tagVisualAssetURL(relativePath:),
            onSelectTag: onSelectTag,
            onToggleFollowed: { tag in
                store.catalog.setFollowed(
                    !tag.isFollowed,
                    for: tag,
                    isTagTranslationEnabled: isTagTranslationEnabled
                )
            },
            onImportForegroundImage: { imageData, tag in
                store.catalog.importDroppedTagImage(kind: .foreground, imageData: imageData, tag: tag)
            },
            onDropError: { message in
                store.catalog.loadError = message
            }
        )
        .padding(TagSummaryGridMetrics.contentPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func syncSelectedTab() {
        guard let defaultTab = category.defaultTab,
              !category.tabs.contains(selectedTab) else {
            return
        }
        selectedTab = defaultTab
    }

    private func rebuildPresentation() {
        if usesNamespaceGroupSubpages {
            let groups = groupedTagSummaries()
            guard let group = syncSelectedNamespaceGroup(in: groups) else {
                updatePage(forItemCount: 0)
                presentation = TagCategoryPresentation()
                return
            }
            let tags = TagSummarySearch.filtered(
                groups.first { $0.group == group }?.tags ?? [],
                query: searchText
            )
            updatePage(forItemCount: tags.count)
            presentation = TagCategoryPresentation(tags: tags, page: page, pageSize: pageSize)
        } else {
            let tags = sorted(activeTags())
            updatePage(forItemCount: tags.count)
            presentation = TagCategoryPresentation(tags: tags, page: page, pageSize: pageSize)
        }
    }

    private func resetPresentationPage() {
        page = 1
        rebuildPresentation()
    }

    private func updatePage(forItemCount itemCount: Int) {
        let clampedPage = Pagination.clampedPage(page, itemCount: itemCount, pageSize: pageSize)
        if page != clampedPage {
            page = clampedPage
        }
    }

    private var usesNamespaceGroupSubpages: Bool {
        category == .tags && displayMode == .grouped
    }

    private var isSearchActive: Bool {
        !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var searchScope: TagCategorySearchScope {
        TagCategorySearchScope.resolve(
            category: category,
            tab: activeTab,
            displayMode: displayMode,
            group: selectedNamespaceGroup
        )
    }

    private var availableNamespaceGroups: [TagNamespaceGroup] {
        groupedTagSummaries().map(\.group)
    }

    private func groupedTagSummaries() -> [(group: TagNamespaceGroup, tags: [TagDisplaySummary])] {
        TagNamespaceGroup.allCases.compactMap { group in
            let tags = sorted(
                store.catalog.tagSummaries(
                    for: group,
                    isTagTranslationEnabled: isTagTranslationEnabled
                ),
                applyingSearch: false
            )
            guard !tags.isEmpty else {
                return nil
            }
            return (group, tags)
        }
    }

    private func syncSelectedNamespaceGroup(
        in groups: [(group: TagNamespaceGroup, tags: [TagDisplaySummary])]
    ) -> TagNamespaceGroup? {
        let availableGroups = groups.map(\.group)
        if let selectedNamespaceGroup,
           availableGroups.contains(selectedNamespaceGroup) {
            return selectedNamespaceGroup
        }

        let firstGroup = availableGroups.first
        selectedNamespaceGroup = firstGroup
        return firstGroup
    }

    private func activeTags() -> [TagDisplaySummary] {
        let tags: [TagDisplaySummary]
        if category == .tags {
            tags = store.catalog.tagSummaries(
                for: category,
                isTagTranslationEnabled: isTagTranslationEnabled
            )
        } else if let activeTab {
            tags = store.catalog.tagSummaries(
                for: activeTab,
                isTagTranslationEnabled: isTagTranslationEnabled
            )
        } else {
            tags = []
        }
        return tags
    }

    private var activeTab: TagCategoryTab? {
        guard !category.tabs.isEmpty else {
            return nil
        }
        if category.tabs.contains(selectedTab) {
            return selectedTab
        }
        return category.defaultTab
    }

    private func sorted(_ tags: [TagDisplaySummary], applyingSearch: Bool = true) -> [TagDisplaySummary] {
        let followedTags = showsFollowedOnly ? tags.filter(\.isFollowed) : tags
        return TagSummarySorter.sorted(
            applyingSearch ? TagSummarySearch.filtered(followedTags, query: searchText) : followedTags,
            strategy: sortStrategy,
            direction: sortDirection
        )
    }
}

enum ExclusiveToolbarSelection {
    static func next<Option: Equatable & Sendable>(current: Option, option: Option, isOn: Bool) -> Option {
        isOn ? option : current
    }

    static func binding<Option: Equatable & Sendable>(selection: Binding<Option>, option: Option) -> Binding<Bool> {
        Binding(
            get: { selection.wrappedValue == option },
            set: { isOn in
                let updated = next(current: selection.wrappedValue, option: option, isOn: isOn)
                if updated != selection.wrappedValue {
                    selection.wrappedValue = updated
                }
            }
        )
    }
}

enum TagNamespaceToolbarMenu {
    static let displayOrder: [TagNamespaceDisplayMode] = [.flat, .grouped]

    static func shouldShow(displayMode: TagNamespaceDisplayMode, hasGroups: Bool) -> Bool {
        displayMode == .grouped && hasGroups
    }
}

private struct ActiveTagCategorySearch: ViewModifier {
    let isActive: Bool
    @Binding var text: String
    let prompt: String

    @ViewBuilder
    func body(content: Content) -> some View {
        if isActive {
            content.searchable(text: $text, placement: .toolbar, prompt: prompt)
        } else {
            content
        }
    }
}

extension TagCategoryTab {
    var toolbarSystemImage: String {
        switch self {
        case .artist: "paintbrush.pointed"
        case .group: "person.3"
        case .parody: "rectangle.stack"
        case .character: "person.crop.square"
        }
    }
}

extension TagNamespaceDisplayMode {
    var toolbarSystemImage: String {
        switch self {
        case .grouped: "square.grid.2x2"
        case .flat: "list.bullet"
        }
    }
}

extension TagSortStrategy {
    var toolbarSystemImage: String {
        switch self {
        case .alphabetical: "textformat.abc"
        case .count: "number"
        }
    }
}

extension SortDirection {
    var next: Self {
        self == .ascending ? .descending : .ascending
    }

    var toolbarSystemImage: String {
        switch self {
        case .ascending: "arrow.up"
        case .descending: "arrow.down"
        }
    }
}

enum TagSummarySearch {
    static func filtered(_ tags: [TagDisplaySummary], query: String) -> [TagDisplaySummary] {
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty else { return tags }
        return tags.filter {
            $0.displayText.localizedStandardContains(term)
                || $0.name.localizedStandardContains(term)
        }
    }
}

enum TagCategorySearchScope: Equatable {
    case tab(TagCategory, TagCategoryTab?)
    case allTags
    case namespace(TagNamespaceGroup?)

    static func resolve(
        category: TagCategory,
        tab: TagCategoryTab?,
        displayMode: TagNamespaceDisplayMode,
        group: TagNamespaceGroup?
    ) -> Self {
        guard category == .tags else { return .tab(category, tab) }
        return displayMode == .grouped ? .namespace(group) : .allTags
    }

    static func query(_ query: String, afterChangingFrom previous: Self, to current: Self) -> String {
        previous == current ? query : ""
    }
}

struct TagCategoryPresentation: Equatable {
    var sections: [TagSummaryGridSection] = []
    var tagCount = 0

    init() {}

    init(tags: [TagDisplaySummary]) {
        sections = tags.isEmpty
            ? []
            : [TagSummaryGridSection(id: "all", titleKey: nil, tags: tags, hasTopSpacing: false)]
        tagCount = tags.count
    }

    init(tags: [TagDisplaySummary], page: Int, pageSize: Int) {
        let pageTags = Pagination.pageItems(tags, page: page, pageSize: pageSize)
        sections = pageTags.isEmpty
            ? []
            : [TagSummaryGridSection(id: "all", titleKey: nil, tags: pageTags, hasTopSpacing: false)]
        tagCount = tags.count
    }

    init(groupedTags: [(group: TagNamespaceGroup, tags: [TagDisplaySummary])]) {
        sections = groupedTags.enumerated().map { offset, element in
            TagSummaryGridSection(
                id: element.group.id,
                titleKey: element.group.titleKey,
                tags: element.tags,
                hasTopSpacing: offset > 0
            )
        }
        tagCount = groupedTags.reduce(0) { $0 + $1.tags.count }
    }

}

struct TagSummaryGridSection: Identifiable, Equatable {
    let id: String
    let titleKey: L10nKey?
    let tags: [TagDisplaySummary]
    let hasTopSpacing: Bool
}

enum TagSummaryCardLayout: Equatable {
    case textOnly
    case landscape
    case characterPortrait

    static func resolve(category: TagCategory, selectedTab: TagCategoryTab) -> Self {
        guard category == .work else { return .textOnly }
        return selectedTab == .character ? .characterPortrait : .landscape
    }

    var hasImage: Bool {
        self != .textOnly
    }

    var aspectRatio: CGFloat {
        self == .characterPortrait ? 2.0 / 3.0 : 3.0 / 2.0
    }

    var columnWidthRange: ClosedRange<CGFloat> {
        switch self {
        case .textOnly: 220...340
        case .landscape: 240...360
        case .characterPortrait: 210...300
        }
    }

    var informationHeight: CGFloat {
        self == .landscape ? 64 : 80
    }

    var nameLineLimit: Int {
        self == .landscape ? 1 : 2
    }
}

enum TagSummaryGridMetrics {
    static let contentPadding: CGFloat = 24
    static let columnSpacing: CGFloat = 20
    static let rowSpacing: CGFloat = 24
    static let cardInformationSpacing: CGFloat = 8
    static let sectionSpacing: CGFloat = 22

    static func columns(for layout: TagSummaryCardLayout) -> [GridItem] {
        [GridItem(
            .adaptive(minimum: layout.columnWidthRange.lowerBound, maximum: layout.columnWidthRange.upperBound),
            spacing: columnSpacing,
            alignment: .top
        )]
    }
}

enum TagSummaryCardHoverMetrics {
    static let hoveredScale: CGFloat = 1.035

    static func scale(isHovering: Bool, reduceMotion: Bool) -> CGFloat {
        isHovering && !reduceMotion ? hoveredScale : 1
    }
}

private enum TagCategoryFloatingMetrics {
    static let horizontalPadding: CGFloat = 20
    static let verticalPadding: CGFloat = 12
    static let contentGap: CGFloat = 6
    static let defaultFooterHeight: CGFloat = 78
}

enum TagCategoryToolbarLayout {
    static let compactDetailWidth: CGFloat = 860

    static func isCompact(detailWidth: CGFloat) -> Bool {
        detailWidth < compactDetailWidth
    }
}

private struct TagCategoryFooterHeightPreferenceKey: PreferenceKey {
    static let defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

private struct TagSummaryGridSectionHeader: View {
    let section: TagSummaryGridSection
    let localizer: AppLocalizer

    var body: some View {
        if let titleKey = section.titleKey {
            HStack(spacing: 10) {
                Text(localizer.string(titleKey))
                    .font(.title3.weight(.semibold))

                Text(localizer.tagTotalCount(section.tags.count))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            .padding(.top, section.hasTopSpacing ? TagSummaryGridMetrics.sectionSpacing : 0)
            .padding(.bottom, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct TagSummaryGrid: View {
    let sections: [TagSummaryGridSection]
    let cardLayout: TagSummaryCardLayout
    let localizer: AppLocalizer
    let assetURL: (String) -> URL?
    let onSelectTag: (TagDisplaySummary) -> Void
    let onToggleFollowed: (TagDisplaySummary) -> Void
    let onImportForegroundImage: (Data, TagVisualAssetTarget) -> Void
    let onDropError: (String) -> Void

    var body: some View {
        LazyVGrid(
            columns: TagSummaryGridMetrics.columns(for: cardLayout),
            alignment: .leading,
            spacing: TagSummaryGridMetrics.rowSpacing
        ) {
            ForEach(sections) { section in
                Section {
                    ForEach(section.tags) { tag in
                        TagSummaryCard(
                            tag: tag,
                            layout: cardLayout,
                            localizer: localizer,
                            assetURL: assetURL,
                            onSelect: { onSelectTag(tag) },
                            onToggleFollowed: { onToggleFollowed(tag) },
                            onImportForegroundImage: onImportForegroundImage,
                            onDropError: onDropError
                        )
                        .equatable()
                    }
                } header: {
                    TagSummaryGridSectionHeader(section: section, localizer: localizer)
                }
            }
        }
    }
}

struct CharacterPortraitPlacement: Equatable {
    let scale: Double
    let offsetX: Double
    let offsetY: Double

    init(profile: TagVisualProfile?) {
        scale = profile?.foregroundScale ?? 1
        offsetX = profile?.foregroundOffsetX ?? 0
        offsetY = profile?.foregroundOffsetY ?? 0
    }

    func offset(in size: CGSize) -> CGSize {
        CGSize(width: offsetX * size.width, height: offsetY * size.height)
    }
}

private struct TagSummaryCard: View, Equatable {
    let tag: TagDisplaySummary
    let layout: TagSummaryCardLayout
    let localizer: AppLocalizer
    let assetURL: (String) -> URL?
    let onSelect: () -> Void
    let onToggleFollowed: () -> Void
    let onImportForegroundImage: (Data, TagVisualAssetTarget) -> Void
    let onDropError: (String) -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovering = false

    var body: some View {
        Button(action: onSelect) {
            VStack(spacing: TagSummaryGridMetrics.cardInformationSpacing) {
                if layout.hasImage {
                    TagSummaryForegroundImageView(
                        url: tag.visualProfile?.foregroundAssetPath.flatMap(assetURL),
                        profile: tag.visualProfile,
                        layout: layout
                    )
                    .aspectRatio(layout.aspectRatio, contentMode: .fit)
                }

                informationPanel
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(tag.displayText), \(localizer.tagItemCount(tag.count))")
        .overlay(alignment: .bottomTrailing) {
            favoriteButton
                .frame(height: layout.informationHeight)
                .padding(.trailing, 13)
        }
        .tagVisualImageDropTarget(
            kind: .foreground,
            localizer: localizer,
            isEnabled: layout.hasImage,
            cornerRadius: 18,
            hasExistingAsset: { tag.visualProfile?.foregroundAssetPath != nil },
            onImport: { imageData in
                onImportForegroundImage(imageData, assetTarget)
            },
            onError: onDropError
        )
        .scaleEffect(TagSummaryCardHoverMetrics.scale(isHovering: isHovering, reduceMotion: reduceMotion))
        .zIndex(isHovering ? 1 : 0)
        .animation(.snappy(duration: 0.16), value: isHovering)
        .contextMenu {
            Button(localizer.string(.view), action: onSelect)
            Button(localizer.string(tag.isFollowed ? .tagUnfollow : .tagFollow), action: onToggleFollowed)
        }
        .onHover { hovering in
            isHovering = hovering
            hovering ? NSCursor.pointingHand.set() : NSCursor.arrow.set()
        }
    }

    private var informationPanel: some View {
        let shape = RoundedRectangle(cornerRadius: 16, style: .continuous)
        return VStack(alignment: .leading, spacing: 5) {
            Text(tag.displayText)
                .font(.headline.weight(.semibold))
                .lineLimit(layout.nameLineLimit)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)

            Text(localizer.tagItemCount(tag.count))
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
        .padding(.horizontal, 13)
        .padding(.trailing, 42)
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: layout.informationHeight)
        .glassEffect(.regular, in: shape)
        .overlay {
            shape.strokeBorder(.primary.opacity(isHovering ? 0.14 : 0), lineWidth: 1)
                .allowsHitTesting(false)
        }
    }

    private var favoriteButton: some View {
        Button(action: onToggleFollowed) {
            Image(systemName: tag.isFollowed ? "heart.fill" : "heart")
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(tag.isFollowed ? .red : .primary)
                .frame(width: 32, height: 32)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(localizer.string(tag.isFollowed ? .tagUnfollow : .tagFollow))
        .help(localizer.string(tag.isFollowed ? .tagUnfollow : .tagFollow))
    }

    private var assetTarget: TagVisualAssetTarget {
        TagVisualAssetTarget(
            tagID: tag.id,
            namespace: tag.namespace,
            name: tag.name,
            rawValue: tag.rawValue
        )
    }

    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.tag == rhs.tag && lhs.layout == rhs.layout && lhs.localizer.language == rhs.localizer.language
    }
}

private struct TagSummaryForegroundImageView: View {
    let url: URL?
    let profile: TagVisualProfile?
    let layout: TagSummaryCardLayout

    @State private var image: NSImage?

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                if let image {
                    let placement = CharacterPortraitPlacement(profile: profile)
                    let offset = placement.offset(in: proxy.size)
                    Image(nsImage: image)
                        .resizable()
                        .scaledToFit()
                        .scaleEffect(placement.scale)
                        .offset(x: offset.width, y: offset.height)
                        .frame(
                            width: proxy.size.width,
                            height: proxy.size.height,
                            alignment: layout == .characterPortrait ? .bottom : .center
                        )
                } else {
                    Image(systemName: layout == .characterPortrait ? "person.crop.square" : "photo")
                        .font(.system(size: 44, weight: .light))
                        .foregroundStyle(.secondary.opacity(0.52))
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
        .clipped()
        .allowsHitTesting(false)
        .task(id: imageIdentity) {
            image = nil
            guard let url else { return }
            let loaded = await TagVisualImageCache.shared.portraitImage(
                for: url,
                version: profile?.updatedAt ?? 0
            )
            guard !Task.isCancelled else { return }
            image = loaded
        }
    }

    private var imageIdentity: String {
        "\(url?.path ?? "none"):\(profile?.updatedAt ?? 0)"
    }
}

private extension View {
    func readTagCategoryFooterHeight() -> some View {
        background {
            GeometryReader { proxy in
                Color.clear
                    .preference(key: TagCategoryFooterHeightPreferenceKey.self, value: proxy.size.height)
            }
        }
    }

}
