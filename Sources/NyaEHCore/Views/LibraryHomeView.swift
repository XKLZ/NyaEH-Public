// 本文件实现首页推荐和洞察区域，主要消费 HomeStore 预先构建的派生书籍集合。

import AppKit
import SwiftUI

private let homeContentPadding: CGFloat = 24
private let homeShelfBandHorizontalPadding: CGFloat = 26

struct LibraryHomeView: View {
    @Bindable var store: HomeStore
    let isTagTranslationEnabled: Bool
    let titleDisplayMode: BookTitleDisplayMode
    @Binding var cardWidth: Int
    @Binding var isInsightChartsExpanded: Bool
    let localizer: AppLocalizer
    let onSelect: (LibraryBook) -> Void
    let onOpenFavorites: () -> Void
    let onOpenSearchScope: (BookSearchScope) -> Void
    let onOpenCollections: () -> Void
    let onSelectInsightTag: (TagDisplaySummary) -> Void

    private var cardMetrics: BookCardMetrics {
        BookCardMetrics(width: cardWidth)
    }

    private var hasCards: Bool {
        !store.catalog.continueReadingBooks.isEmpty
            || !store.catalog.recentlyViewedBooks.isEmpty
            || !store.catalog.recommendedBooks.isEmpty
            || !store.catalog.markedPreviewBooks.isEmpty
            || !store.catalog.recentlyAddedBooks.isEmpty
    }

    var body: some View {
        GeometryReader { proxy in
                let leadingBleed = max(proxy.frame(in: .global).minX, 0)

                ScrollView {
                    VStack(alignment: .leading, spacing: 30) {
                        HomeWelcomeOverview(
                            totalBooks: store.catalog.books.count,
                            favoriteBooks: store.catalog.favoriteManagementBooks.count,
                            recentlyViewedBooks: store.catalog.recentlyViewedBooks.count,
                            collections: store.catalog.collections.count,
                            charts: store.catalog.homeInsightCharts,
                            isLoadingCharts: store.catalog.isLoadingHomeInsightCharts,
                            chartError: store.catalog.homeInsightChartError,
                            isChartsExpanded: $isInsightChartsExpanded,
                            localizer: localizer,
                            onOpenScope: onOpenSearchScope,
                            onOpenCollections: onOpenCollections,
                            onSelectTag: onSelectInsightTag
                        )

                        HomeShelfSection(
                            title: localizer.string(.readerContinue),
                            books: store.catalog.continueReadingBooks,
                            titleDisplayMode: titleDisplayMode,
                            metrics: cardMetrics,
                            leadingBleed: leadingBleed,
                            localizer: localizer,
                            onSelect: onSelect,
                            action: HomeShelfAction(
                                title: localizer.string(.readerContinue),
                                systemImage: "arrow.forward.circle",
                                perform: { onOpenSearchScope(.continueReading) }
                            )
                        )

                        HomeShelfSection(
                            title: localizer.string(.recentlyViewed),
                            books: store.catalog.recentlyViewedBooks,
                            titleDisplayMode: titleDisplayMode,
                            metrics: cardMetrics,
                            leadingBleed: leadingBleed,
                            localizer: localizer,
                            onSelect: onSelect
                        )

                        HomeShelfSection(
                            title: localizer.string(.todayRecommendations),
                            books: store.catalog.recommendedBooks,
                            titleDisplayMode: titleDisplayMode,
                            metrics: cardMetrics,
                            leadingBleed: leadingBleed,
                            localizer: localizer,
                            onSelect: onSelect
                        )

                        HomeShelfSection(
                            title: localizer.string(.myFavorites),
                            books: store.catalog.markedPreviewBooks,
                            titleDisplayMode: titleDisplayMode,
                            metrics: cardMetrics,
                            leadingBleed: leadingBleed,
                            localizer: localizer,
                            onSelect: onSelect,
                            action: HomeShelfAction(
                                title: localizer.string(.favoriteManagement),
                                systemImage: "arrow.forward.circle",
                                perform: onOpenFavorites
                            )
                        )

                        HomeShelfSection(
                            title: localizer.string(.recentlyAdded),
                            books: store.catalog.recentlyAddedBooks,
                            titleDisplayMode: titleDisplayMode,
                            metrics: cardMetrics,
                            leadingBleed: leadingBleed,
                            localizer: localizer,
                            onSelect: onSelect
                        )
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
        .task(id: "\(isTagTranslationEnabled)-\(store.catalog.tagSummaryRevision)-\(isInsightChartsExpanded)") {
            guard isInsightChartsExpanded else {
                return
            }
            store.catalog.loadHomeInsightCharts(isTagTranslationEnabled: isTagTranslationEnabled)
        }
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

private struct HomeWelcomeOverview: View {
    let totalBooks: Int
    let favoriteBooks: Int
    let recentlyViewedBooks: Int
    let collections: Int
    let charts: HomeInsightCharts
    let isLoadingCharts: Bool
    let chartError: String?
    @Binding var isChartsExpanded: Bool
    let localizer: AppLocalizer
    let onOpenScope: (BookSearchScope) -> Void
    let onOpenCollections: () -> Void
    let onSelectTag: (TagDisplaySummary) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 28) {
            headlineBlock

            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) {
                    statTiles
                }
                .frame(maxWidth: 748)
                .frame(maxWidth: .infinity, alignment: .center)

                LazyVGrid(
                    columns: Array(
                        repeating: GridItem(.flexible(minimum: 128, maximum: 178), spacing: 12, alignment: .center),
                        count: 2
                    ),
                    alignment: .center,
                    spacing: 12
                ) {
                    statTiles
                }
                .frame(maxWidth: 368)
                .frame(maxWidth: .infinity, alignment: .center)
            }

            HomeInsightRevealContainer(isExpanded: isChartsExpanded) {
                insightGrid
            }
        }
        .padding(.horizontal, 34)
        .padding(.vertical, 34)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 14))
        .overlay {
            RoundedRectangle(cornerRadius: 14)
                .strokeBorder(.secondary.opacity(0.14), lineWidth: 1)
        }
    }

    private var headlineBlock: some View {
        HStack(alignment: .center, spacing: 16) {
            Text(localizer.string(.welcomeBack))
                .font(.system(.largeTitle, design: .rounded).weight(.bold))
                .multilineTextAlignment(.leading)

            Spacer(minLength: 16)

            Button {
                withAnimation(.smooth(duration: 0.32)) {
                    isChartsExpanded.toggle()
                }
            } label: {
                Label(
                    localizer.string(isChartsExpanded ? .collapseSection : .expandSection),
                    systemImage: isChartsExpanded ? "chevron.up.circle" : "chevron.down.circle"
                )
            }
            .labelStyle(.iconOnly)
            .font(.title3.weight(.semibold))
            .buttonStyle(.borderless)
            .controlSize(.large)
            .help(localizer.string(isChartsExpanded ? .collapseSection : .expandSection))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
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

    private var statTiles: some View {
        Group {
            HomeStatTile(
                systemImage: "books.vertical",
                title: localizer.string(.libraryStatsTotalBooks),
                value: totalBooks,
                action: { onOpenScope(.all) }
            )
            HomeStatTile(
                systemImage: "star.fill",
                title: localizer.string(.libraryStatsFavorites),
                value: favoriteBooks,
                action: { onOpenScope(.marked) }
            )
            HomeStatTile(
                systemImage: "eye.fill",
                title: localizer.string(.libraryStatsRecentlyViewed),
                value: recentlyViewedBooks,
                action: { onOpenScope(.continueReading) }
            )
            HomeStatTile(
                systemImage: "rectangle.stack.fill",
                title: localizer.string(.libraryStatsCollections),
                value: collections,
                action: onOpenCollections
            )
        }
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

private struct HomeStatTile: View {
    let systemImage: String
    let title: String
    let value: Int
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 7) {
                Image(systemName: systemImage)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.secondary)

                Text(value.formatted())
                    .font(.title2.weight(.semibold))
                    .monospacedDigit()

                Text(title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, minHeight: 96, alignment: .center)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .contentShape(RoundedRectangle(cornerRadius: 10))
        .accessibilityLabel("\(title), \(value)")
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

private struct HomeShelfSection: View {
    let title: String
    let books: [LibraryBook]
    let titleDisplayMode: BookTitleDisplayMode
    let metrics: BookCardMetrics
    let leadingBleed: CGFloat
    let localizer: AppLocalizer
    let onSelect: (LibraryBook) -> Void
    var action: HomeShelfAction? = nil

    @State private var scrollPosition = ScrollPosition()
    @State private var scrollState = HomeShelfScrollState()
    @State private var isHoveringCarousel = false

    private var showsBackwardArrow: Bool {
        isHoveringCarousel && scrollState.canScrollBackward
    }

    private var showsForwardArrow: Bool {
        isHoveringCarousel && scrollState.canScrollForward
    }

    private var leadingBandBleed: CGFloat {
        leadingBleed + homeContentPadding
    }

    private var carouselBandHeight: CGFloat {
        metrics.cardHeight + 28
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
            }

            if books.isEmpty {
                ContentUnavailableView(
                    localizer.string(.noBooks),
                    systemImage: "books.vertical",
                    description: Text(localizer.string(.importedBooksDescription))
                )
                .frame(minHeight: 180)
            } else {
                carouselBand
            }
        }
    }

    private var carouselBand: some View {
        GeometryReader { geometry in
            let bandWidth = geometry.size.width + leadingBandBleed + homeContentPadding

            ZStack(alignment: .leading) {
                extendedCarouselLayer(bandWidth: bandWidth)
                    .zIndex(0)

                carouselControlsOverlay(width: geometry.size.width)
                    .zIndex(1)
            }
            .frame(width: geometry.size.width, height: carouselBandHeight, alignment: .leading)
            .contentShape(Rectangle())
            .onHover { isHovering in
                isHoveringCarousel = isHovering
            }
        }
        .frame(height: carouselBandHeight)
        .onChange(of: books.map(\.id)) { _, _ in
            scrollState = .init()
            scrollPosition.scrollTo(edge: .leading)
        }
    }

    private func extendedCarouselLayer(bandWidth: CGFloat) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            LazyHStack(alignment: .top, spacing: 18) {
                ForEach(Array(books.enumerated()), id: \.element.id) { _, book in
                    BookCardButton(
                        book: book,
                        titleDisplayMode: titleDisplayMode,
                        localizer: localizer,
                        metrics: metrics,
                        action: {
                            onSelect(book)
                        }
                    )
                    .id(book.id)
                }
            }
            .padding(.vertical, 14)
            .padding(.leading, leadingBandBleed + homeShelfBandHorizontalPadding)
            .padding(.trailing, homeShelfBandHorizontalPadding)
        }
        .scrollPosition($scrollPosition)
        .onScrollGeometryChange(for: HomeShelfScrollState.self) { geometry in
            HomeShelfScrollState(geometry: geometry)
        } action: { _, newState in
            scrollState = newState
        }
        .frame(width: bandWidth, height: carouselBandHeight, alignment: .leading)
        .background(HiddenHorizontalScrollerAccessor())
        .scrollIndicators(.hidden, axes: .horizontal)
        .homeShelfScrollClipDisabled()
        .homeShelfHorizontalExtension()
        .background(HomeSidebarBleedAccessor())
        .offset(x: -leadingBandBleed)
    }

    private func carouselControlsOverlay(width: CGFloat) -> some View {
        HStack {
            CarouselArrowButton(
                systemImage: "chevron.left",
                help: localizer.string(.previousPage)
            ) {
                scroll(by: -scrollPageDistance)
            }
            .opacity(showsBackwardArrow ? 1 : 0)
            .scaleEffect(showsBackwardArrow ? 1 : 0.92)
            .allowsHitTesting(showsBackwardArrow)

            Spacer()

            CarouselArrowButton(
                systemImage: "chevron.right",
                help: localizer.string(.nextPage)
            ) {
                scroll(by: scrollPageDistance)
            }
            .opacity(showsForwardArrow ? 1 : 0)
            .scaleEffect(showsForwardArrow ? 1 : 0.92)
            .allowsHitTesting(showsForwardArrow)
        }
        .padding(.horizontal, 28)
        .offset(y: -34)
        .frame(width: width, height: carouselBandHeight, alignment: .center)
        .allowsHitTesting(showsBackwardArrow || showsForwardArrow)
        .animation(.easeInOut(duration: 0.16), value: showsBackwardArrow)
        .animation(.easeInOut(duration: 0.16), value: showsForwardArrow)
    }

    private var scrollPageDistance: CGFloat {
        (metrics.cardWidth + 18) * 3
    }

    private func scroll(by offset: CGFloat) {
        let targetOffset = min(max(scrollState.offsetX + offset, 0), scrollState.maxOffsetX)
        scrollState = scrollState.updatingOffset(targetOffset)
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

    func updatingOffset(_ offsetX: CGFloat) -> HomeShelfScrollState {
        HomeShelfScrollState(
            offsetX: min(max(offsetX, 0), maxOffsetX),
            maxOffsetX: maxOffsetX
        )
    }
}

private struct HomeShelfAction {
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

private struct HiddenHorizontalScrollerAccessor: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        DispatchQueue.main.async {
            hideHorizontalScroller(from: view)
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async {
            hideHorizontalScroller(from: nsView)
        }
    }

    private func hideHorizontalScroller(from view: NSView) {
        guard let scrollView = view.enclosingScrollView ?? view.firstAncestor(ofType: NSScrollView.self) else {
            return
        }

        scrollView.hasHorizontalScroller = false
        scrollView.horizontalScroller = nil
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = .overlay
    }
}

private struct HomeSidebarBleedAccessor: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        DispatchQueue.main.async {
            allowSidebarBleed(from: view)
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async {
            allowSidebarBleed(from: nsView)
        }
    }

    private func allowSidebarBleed(from view: NSView) {
        guard #available(macOS 26.0, *) else {
            return
        }

        if let contentView = view.window?.contentView {
            allowOverflow(in: contentView, remainingDepth: 12)
        }

        var current: NSView? = view
        var remainingAncestorHops = 18
        while let candidate = current, remainingAncestorHops > 0 {
            allowOverflow(on: candidate)

            if candidate === candidate.window?.contentView {
                break
            }

            current = candidate.superview
            remainingAncestorHops -= 1
        }
    }

    private func allowOverflow(in view: NSView, remainingDepth: Int) {
        guard remainingDepth >= 0 else {
            return
        }

        allowOverflow(on: view)
        for subview in view.subviews {
            allowOverflow(in: subview, remainingDepth: remainingDepth - 1)
        }
    }

    private func allowOverflow(on view: NSView) {
        view.clipsToBounds = false
        view.layer?.masksToBounds = false
    }
}

private extension NSView {
    func firstAncestor<T: NSView>(ofType type: T.Type) -> T? {
        var current = superview
        while let view = current {
            if let match = view as? T {
                return match
            }
            current = view.superview
        }
        return nil
    }
}

private struct CarouselArrowButton: View {
    let systemImage: String
    let help: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.title3.weight(.semibold))
                .foregroundStyle(.primary)
                .frame(width: 36, height: 36)
                .background(.regularMaterial, in: Circle())
                .overlay {
                    Circle()
                        .strokeBorder(.secondary.opacity(0.18))
                }
                .shadow(color: .black.opacity(0.16), radius: 8, x: 0, y: 3)
        }
        .buttonStyle(.plain)
        .help(help)
    }
}
