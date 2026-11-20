// 首页展示与调试书架共用目录中预先整理好的书籍集合。

import SwiftUI

private let homeContentPadding: CGFloat = 24

struct LibraryHomeView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Bindable var store: HomeStore
    let pageIsActive: Bool
    let isTagTranslationEnabled: Bool
    let titleDisplayMode: BookTitleDisplayMode
    let localizer: AppLocalizer
    let onSelect: (LibraryBook) -> Void
    let onOpenFavorites: () -> Void
    let onOpenRecentSearch: () -> Void
    let onImport: () -> Void

    var body: some View {
        GeometryReader { proxy in
            let catalog = store.catalog
            let books = HomeShowcaseBooks(continuing: catalog.continueReadingBooks, recent: catalog.recentlyViewedBooks,
                                          recommended: catalog.recommendedBooks)
            let hasLead = books.resolve(nil) != nil
            let topPadding: CGFloat = 16
            let gap = homeContentPadding
            let cardHeight = max(260, (proxy.size.height - topPadding - gap - homeContentPadding) / 2)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: gap) {
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
                        if hasLead {
                            HomeBookShowcase(books: books, catalog: catalog, pageIsActive: pageIsActive,
                                             titleMode: titleDisplayMode, localizer: localizer,
                                             translatesTags: isTagTranslationEnabled, onSelect: onSelect)
                                .frame(height: cardHeight)
                        }

                        HomeCollectionPanels(favorites: catalog.homeFavoritePreview,
                                             days: catalog.homeArrivalDays, height: cardHeight,
                                             cardWidth: BookCardMetrics.maximumWidth, catalog: catalog,
                                             translatesTags: isTagTranslationEnabled, titleMode: titleDisplayMode, localizer: localizer,
                                             onSelect: onSelect, onFavorites: onOpenFavorites, onSearch: onOpenRecentSearch)
                    }
                }
                .padding(.horizontal, homeContentPadding)
                .padding(.top, topPadding)
                .padding(.bottom, homeContentPadding)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .backgroundPreferenceValue(HomeToolbarTint.self) { tint in
                LinearGradient(stops: [
                    .init(color: (tint ?? .clear).opacity(0.18), location: 0),
                    .init(color: .clear, location: 0.18)
                ], startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea(.container, edges: .top)
                .animation(reduceMotion ? nil : .easeInOut(duration: 0.22), value: tint)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
            }
        }
        .navigationTitle(localizer.string(.home))
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
