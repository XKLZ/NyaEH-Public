// 本文件实现首页推荐和洞察区域，主要消费 HomeStore 预先构建的派生书籍集合。

import SwiftUI

private let homeContentPadding: CGFloat = 24

struct LibraryHomeView: View {
    @Bindable var store: HomeStore
    let pageIsActive: Bool
    let isTagTranslationEnabled: Bool
    let titleDisplayMode: BookTitleDisplayMode
    @Binding var cardWidth: Int
    @Binding var isInsightChartsExpanded: Bool
    let localizer: AppLocalizer
    let onSelect: (LibraryBook) -> Void
    let onOpenFavorites: () -> Void
    let onOpenRecentSearch: () -> Void
    let onSelectInsightTag: (TagDisplaySummary) -> Void

    private var hasCards: Bool {
        !store.catalog.homeFavoritePreview.books.isEmpty
            || !store.catalog.recentlyAddedBooks.isEmpty
    }

    let onImport: () -> Void

    var body: some View {
        GeometryReader { proxy in
            let catalog = store.catalog
            let books = HomeShowcaseBooks(continuing: catalog.continueReadingBooks, recent: catalog.recentlyViewedBooks,
                                          recommended: catalog.recommendedBooks)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 26) {
                    if catalog.books.isEmpty {
                        ContentUnavailableView {
                            Label(localizer.string(.noBooks), systemImage: "books.vertical")
                        } description: {
                            Text(localizer.string(.importedBooksDescription))
                        } actions: {
                            Button(localizer.string(.importLibrary), action: onImport)
                        }
                        .frame(maxWidth: .infinity, minHeight: 240)
                    } else {
                        if books.resolve(nil) != nil {
                            HomeBookShowcase(books: books, catalog: catalog, pageIsActive: pageIsActive,
                                             titleMode: titleDisplayMode, localizer: localizer,
                                             translatesTags: isTagTranslationEnabled, onSelect: onSelect)
                                .frame(height: proxy.size.height / 2)
                        }

                        HomeCollectionPanels(favorites: catalog.homeFavoritePreview,
                                             days: catalog.homeArrivalDays, height: proxy.size.height / 2,
                                             cardWidth: cardWidth, titleMode: titleDisplayMode, localizer: localizer,
                                             onSelect: onSelect, onFavorites: onOpenFavorites, onSearch: onOpenRecentSearch)

                        HomeInsights(charts: catalog.homeInsightCharts,
                                     isLoadingCharts: catalog.isLoadingHomeInsightCharts, chartError: catalog.homeInsightChartError,
                                     isChartsExpanded: $isInsightChartsExpanded, localizer: localizer, onSelectTag: onSelectInsightTag)
                            .task(id: "\(isTagTranslationEnabled)-\(catalog.tagSummaryRevision)-\(isInsightChartsExpanded)") {
                                if isInsightChartsExpanded {
                                    catalog.loadHomeInsightCharts(isTagTranslationEnabled: isTagTranslationEnabled)
                                }
                            }
                    }
                }
                .padding(homeContentPadding)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .overlay(alignment: .bottomTrailing) {
            if hasCards {
                FloatingGlassPanel {
                    CardSizeSliderControl(cardWidth: $cardWidth)
                }
                .fixedSize()
                .padding(.trailing, 16)
                .padding(.bottom, 12)
            }
        }
        .navigationTitle(localizer.string(.home))
        .focusedSceneValue(\.nyaehViewCommands, viewCommandContext)
    }

    private var viewCommandContext: NyaEHViewCommandContext {
        NyaEHViewCommandContext(
            canIncreaseCardSize: cardWidth < BookCardMetrics.maximumWidth,
            increaseCardSize: { cardWidth = BookCardMetrics.normalizedWidth(cardWidth + BookCardMetrics.step) },
            canDecreaseCardSize: cardWidth > BookCardMetrics.minimumWidth,
            decreaseCardSize: { cardWidth = BookCardMetrics.normalizedWidth(cardWidth - BookCardMetrics.step) },
            layout: nil,
            setLayout: { _ in },
            sortStrategy: nil,
            setSortStrategy: { _ in },
            searchResultSortKey: nil,
            setSearchResultSortKey: { _ in },
            sortDirection: nil,
            setSortDirection: { _ in }
        )
    }
}

private struct HomeInsights: View {
    let charts: HomeInsightCharts
    let isLoadingCharts: Bool
    let chartError: String?
    @Binding var isChartsExpanded: Bool
    let localizer: AppLocalizer
    let onSelectTag: (TagDisplaySummary) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Button {
                withAnimation(.smooth(duration: 0.32)) { isChartsExpanded.toggle() }
            } label: {
                HStack {
                    Text(localizer.string(.homeInsights)).font(.title2.weight(.semibold))
                    Spacer()
                    Image(systemName: isChartsExpanded ? "chevron.up" : "chevron.down")
                        .foregroundStyle(.secondary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            HomeInsightRevealContainer(isExpanded: isChartsExpanded) { insightGrid }
        }
    }


    private var insightGrid: some View {
        ViewThatFits(in: .horizontal) {
            LazyVGrid(
                columns: [
                    GridItem(.flexible(), spacing: 14),
                    GridItem(.flexible(), spacing: 14),
                    GridItem(.flexible(), spacing: 14)
                ],
                spacing: 14
            ) {
                ForEach(HomeInsightChartKind.allCases) { kind in
                    insightTile(kind)
                }
            }
            .frame(minWidth: 900, maxWidth: .infinity)

            VStack(spacing: 14) {
                ForEach(HomeInsightChartKind.allCases) { kind in
                    insightTile(kind)
                }
            }
        }
    }

    private func insightTile(_ kind: HomeInsightChartKind) -> some View {
        HomeInsightChartTile(
            kind: kind,
            tags: charts[kind],
            isLoading: isLoadingCharts,
            error: chartError,
            localizer: localizer,
            onSelectTag: onSelectTag
        )
        .frame(maxWidth: .infinity)
    }

}

private struct HomeInsightRevealContainer<Content: View>: View {
    let isExpanded: Bool
    @ViewBuilder let content: () -> Content

    @State private var measuredHeight: CGFloat = 0
    @State private var isContentMounted = false
    @State private var unmountTask: Task<Void, Never>?

    private static var animation: Animation {
        .smooth(duration: 0.32)
    }

    private static var unmountDelayNanoseconds: UInt64 {
        360_000_000
    }

    private var shouldRenderContent: Bool {
        isExpanded || isContentMounted
    }

    var body: some View {
        Group {
            if shouldRenderContent {
                content()
                    .background {
                        GeometryReader { proxy in
                            Color.clear.preference(
                                key: HomeInsightRevealHeightKey.self,
                                value: proxy.size.height
                            )
                        }
                    }
                    .opacity(isExpanded ? 1 : 0)
                    .scaleEffect(isExpanded ? 1 : 0.985, anchor: .top)
                    .frame(height: isExpanded ? measuredHeight : 0, alignment: .top)
                    .clipped()
            }
        }
        .onAppear {
            isContentMounted = isExpanded
        }
        .onChange(of: isExpanded) { _, isExpanded in
            unmountTask?.cancel()
            if isExpanded {
                isContentMounted = true
            } else {
                scheduleUnmount()
            }
        }
        .onPreferenceChange(HomeInsightRevealHeightKey.self) { height in
            guard height > 0, abs(height - measuredHeight) > 0.5 else {
                return
            }
            if isExpanded {
                withAnimation(Self.animation) {
                    measuredHeight = height
                }
            } else {
                measuredHeight = height
            }
        }
        .onDisappear {
            unmountTask?.cancel()
        }
    }

    private func scheduleUnmount() {
        unmountTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: Self.unmountDelayNanoseconds)
            guard !Task.isCancelled, !isExpanded else {
                return
            }
            isContentMounted = false
        }
    }
}

private struct HomeInsightRevealHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

private struct HomeInsightChartTile: View {
    let kind: HomeInsightChartKind
    let tags: [TagDisplaySummary]
    let isLoading: Bool
    let error: String?
    let localizer: AppLocalizer
    let onSelectTag: (TagDisplaySummary) -> Void

    private var maxCount: Int {
        max(tags.map(\.count).max() ?? 0, 1)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label(localizer.string(kind.titleKey), systemImage: kind.systemImage)
                .font(.title3.weight(.semibold))
                .foregroundStyle(.primary)

            content
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 18)
        .frame(maxWidth: .infinity, minHeight: 250, alignment: .topLeading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(.secondary.opacity(0.12), lineWidth: 1)
        }
    }

    @ViewBuilder
    private var content: some View {
        if isLoading && tags.isEmpty {
            ProgressView()
                .controlSize(.small)
                .frame(maxWidth: .infinity, minHeight: 164, alignment: .center)
        } else if error != nil && tags.isEmpty {
            Text(localizer.string(.homeInsightLoadFailed))
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, minHeight: 164, alignment: .center)
        } else if tags.isEmpty {
            Text(localizer.string(.homeInsightNoData))
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, minHeight: 164, alignment: .center)
        } else {
            ScrollView {
                LazyVStack(spacing: 10) {
                    ForEach(tags) { tag in
                        Button {
                            onSelectTag(tag)
                        } label: {
                            HomeInsightChartRow(
                                tag: tag,
                                fraction: HomeInsightChartScale.sqrtFraction(
                                    count: tag.count,
                                    maxCount: maxCount
                                )
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.trailing, 2)
            }
            .scrollIndicators(.automatic)
            .frame(minHeight: 164, maxHeight: 188)
        }
    }
}

private struct HomeInsightChartRow: View {
    let tag: TagDisplaySummary
    let fraction: Double

    var body: some View {
        HStack(spacing: 12) {
            Text(tag.displayText)
                .font(.callout.weight(.medium))
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(width: 118, alignment: .leading)

            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(.secondary.opacity(0.12))
                    Capsule()
                        .fill(.tint.opacity(0.5))
                        .frame(width: max(8, proxy.size.width * min(max(CGFloat(fraction), 0), 1)))
                }
            }
            .frame(height: 11)

            Text(tag.count.formatted())
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .frame(minWidth: 48, alignment: .trailing)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 7)
        .contentShape(Rectangle())
        .background {
            RoundedRectangle(cornerRadius: 7)
                .fill(.primary.opacity(0.001))
        }
    }
}

struct HomeShelfSection: View {
    let title: String
    let books: [LibraryBook]
    let titleDisplayMode: BookTitleDisplayMode
    let metrics: BookCardMetrics
    let leadingBleed: CGFloat
    let localizer: AppLocalizer
    let onSelect: (LibraryBook) -> Void
    var action: HomeShelfAction? = nil
    let position: HomeShelfPosition
    var exhibitGutter: CGFloat? = nil
    @Environment(\.nyaehAccentColor) private var accent
    @State private var scrollPosition = ScrollPosition()
    @State private var edges = HomeShelfEdges()
    @State private var needsRestore = true
    private var leadingBandBleed: CGFloat {
        leadingBleed + homeContentPadding
    }

    @Environment(\.bookCardFields) private var cardFields

    private var carouselBandHeight: CGFloat {
        metrics.cardHeight(for: cardFields) + 28
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(title)
                    .font(.title2)
                    .fontWeight(.semibold)

                Spacer()

                if let action {
                    Button(action: action.perform) {
                        Label(action.title, systemImage: action.systemImage)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
                if exhibitGutter == nil && (edges.backward || edges.forward) {
                    ControlGroup {
                        Button { scroll(by: -scrollPageDistance) } label: {
                            Label(localizer.string(.previousPage), systemImage: "chevron.left")
                        }
                        .help(localizer.string(.previousPage))
                        .disabled(!edges.backward)
                        Button { scroll(by: scrollPageDistance) } label: {
                            Label(localizer.string(.nextPage), systemImage: "chevron.right")
                        }
                        .help(localizer.string(.nextPage))
                        .disabled(!edges.forward)
                    }
                    .labelStyle(.iconOnly)
                    .controlSize(.small)
                }
            }
            .padding(.leading, exhibitGutter ?? 0)

            if let gutter = exhibitGutter {
                exhibitionBand(gutter: gutter)
            } else {
                carouselBand
            }
        }
    }

    private var carouselBand: some View {
        GeometryReader { geometry in
            let bandWidth = geometry.size.width + leadingBandBleed + homeContentPadding

            scrollingBooks(leadingInset: leadingBandBleed, trailingInset: homeContentPadding)
                .frame(width: bandWidth, height: carouselBandHeight, alignment: .leading)
                .homeShelfScrollClipDisabled()
                .homeShelfHorizontalExtension()
                .offset(x: -leadingBandBleed)
                .frame(width: geometry.size.width, height: carouselBandHeight, alignment: .leading)
        }
        .frame(height: carouselBandHeight)
        .onDisappear { needsRestore = true }
    }

    private func exhibitionBand(gutter: CGFloat) -> some View {
        scrollingBooks(leadingInset: 0, trailingInset: 0)
            .frame(height: carouselBandHeight)
            .padding(.horizontal, gutter)
            .background(alignment: .bottom) {
                VStack(spacing: 0) {
                    LinearGradient(colors: [.clear, accent.opacity(0.09)], startPoint: .top, endPoint: .bottom)
                        .frame(height: 44)
                    Rectangle().fill(.primary.opacity(0.14)).frame(height: 3)
                        .overlay(alignment: .top) { Rectangle().fill(.white.opacity(0.45)).frame(height: 1) }
                        .shadow(color: .black.opacity(0.16), radius: 2, y: 2)
                }
                .padding(.horizontal, max(0, gutter - 8))
                .padding(.bottom, 9)
                .allowsHitTesting(false).accessibilityHidden(true)
            }
            .overlay(alignment: .leading) { if gutter > 0 { sideArrow(forward: false) } }
            .overlay(alignment: .trailing) { if gutter > 0 { sideArrow(forward: true) } }
            .onDisappear { needsRestore = true }
    }

    private func sideArrow(forward: Bool) -> some View {
        let enabled = forward ? edges.forward : edges.backward
        let label = localizer.string(forward ? .nextPage : .previousPage)
        return Button { scroll(by: forward ? scrollPageDistance : -scrollPageDistance) } label: {
            Image(systemName: forward ? "chevron.right" : "chevron.left")
                .font(.system(size: 18, weight: .medium))
                .frame(width: 28, height: 52)
                .background(.primary.opacity(0.09), in: Capsule())
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.45)
        .help(label).accessibilityLabel(label)
    }

    private func scrollingBooks(leadingInset: CGFloat, trailingInset: CGFloat) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            LazyHStack(alignment: .top, spacing: BookCardMetrics.shelfSpacing) {
                ForEach(books) { book in
                    BookCardButton(book: book, titleDisplayMode: titleDisplayMode, localizer: localizer,
                                   metrics: metrics, action: onSelect)
                        .id(book.id)
                }
            }
            .padding(.vertical, 14)
            .padding(.leading, leadingInset)
            .padding(.trailing, trailingInset)
        }
        .scrollPosition($scrollPosition)
        .onScrollGeometryChange(for: HomeShelfScrollState.self) { geometry in
            HomeShelfScrollState(geometry: geometry)
        } action: { _, newState in
            guard newState.maxOffsetX > 0 else {
                edges = HomeShelfEdges()
                if exhibitGutter != nil { position.geometry = newState }
                return
            }
            if needsRestore {
                needsRestore = false
                if position.geometry.offsetX > 0 {
                    let target = min(position.geometry.offsetX, newState.maxOffsetX)
                    if abs(newState.offsetX - target) > 1 {
                        scrollPosition.scrollTo(x: target)
                        return
                    }
                }
            }
            position.geometry = newState
            let newEdges = HomeShelfEdges(backward: newState.canScrollBackward, forward: newState.canScrollForward)
            if edges != newEdges { edges = newEdges }
        }
        .scrollIndicators(.hidden, axes: .horizontal)
    }

    private var scrollPageDistance: CGFloat {
        (metrics.cardWidth + BookCardMetrics.shelfSpacing) * 3
    }

    private func scroll(by offset: CGFloat) {
        let geometry = position.geometry
        let targetOffset = min(max(geometry.offsetX + offset, 0), geometry.maxOffsetX)
        withAnimation(.snappy(duration: 0.32)) {
            scrollPosition.scrollTo(x: targetOffset)
        }
    }
}

private struct HomeShelfScrollState: Equatable {
    private static let edgeTolerance: CGFloat = 1

    var offsetX: CGFloat = 0
    var maxOffsetX: CGFloat = 0

    var canScrollBackward: Bool {
        offsetX > Self.edgeTolerance
    }

    var canScrollForward: Bool {
        maxOffsetX - offsetX > Self.edgeTolerance
    }

    init(offsetX: CGFloat = 0, maxOffsetX: CGFloat = 0) {
        self.offsetX = max(offsetX, 0)
        self.maxOffsetX = max(maxOffsetX, 0)
    }

    init(geometry: ScrollGeometry) {
        let maxOffsetX = max(geometry.contentSize.width - geometry.containerSize.width, 0)
        self.init(
            offsetX: min(max(geometry.contentOffset.x, 0), maxOffsetX),
            maxOffsetX: maxOffsetX
        )
    }

}

private struct HomeShelfEdges: Equatable {
    var backward = false
    var forward = false
}

// Scroll callbacks update this reference without invalidating the shelf or its cards.
final class HomeShelfPosition {
    fileprivate var geometry = HomeShelfScrollState()
}

final class HomeShelfPositions {
    private var saved: [L10nKey: HomeShelfPosition] = [:]

    func position(for key: L10nKey) -> HomeShelfPosition {
        if let existing = saved[key] { return existing }
        let position = HomeShelfPosition()
        saved[key] = position
        return position
    }
}

struct HomeShelfAction {
    let title: String
    let systemImage: String
    let perform: () -> Void
}

private extension View {
    @ViewBuilder
    func homeShelfScrollClipDisabled() -> some View {
        if #available(macOS 26.0, *) {
            scrollClipDisabled()
        } else {
            self
        }
    }

    @ViewBuilder
    func homeShelfHorizontalExtension() -> some View {
        if #available(macOS 26.0, *) {
            backgroundExtensionEffect(isEnabled: true)
                .ignoresSafeArea(.container, edges: .leading)
        } else {
            self
        }
    }
}
