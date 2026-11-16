// 本文件实现书架页的网格展示和筛选浏览，是普通书库列表的主要容器。

import SwiftUI

@available(*, deprecated, message: "Search is the user-facing library browser; keep only for internal programmatic access.")
struct LibraryShelfView: View {
    @Bindable var store: CatalogStore
    let titleDisplayMode: BookTitleDisplayMode
    @Binding var pageSize: Int
    @Binding var cardWidth: Int
    let localizer: AppLocalizer
    let onSelect: (LibraryDisplayItem) -> Void

    @State private var page = 1

    private var pageCount: Int {
        store.libraryPageCount(pageSize: pageSize)
    }

    private var pageItems: [LibraryDisplayItem] {
        store.libraryPageItems(page: clampedPage, pageSize: pageSize)
    }

    private var clampedPage: Int {
        min(max(page, 1), pageCount)
    }

    private var cardMetrics: BookCardMetrics {
        BookCardMetrics(width: cardWidth)
    }

    var body: some View {
        VStack(spacing: 0) {
                ScrollView {
                    if store.displayItems.isEmpty {
                        ContentUnavailableView(
                            localizer.string(.noBooks),
                            systemImage: "square.grid.3x3",
                            description: Text(localizer.string(.importedBooksDescription))
                        )
                        .frame(maxWidth: .infinity, minHeight: 360)
                        .padding(24)
                    } else {
                        LazyVGrid(
                            columns: [
                                GridItem(.adaptive(minimum: cardMetrics.gridMinimumWidth, maximum: cardMetrics.gridMaximumWidth), spacing: 22, alignment: .top)
                            ],
                            alignment: .leading,
                            spacing: 24
                        ) {
                            ForEach(pageItems) { item in
                                LibraryDisplayItemCardButton(
                                    item: item,
                                    titleDisplayMode: titleDisplayMode,
                                    localizer: localizer,
                                    metrics: cardMetrics,
                                    action: { selectedItem in
                                        onSelect(selectedItem)
                                    }
                                )
                            }
                        }
                        .padding(24)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }

                Divider()

                LibraryShelfFooter(
                    page: $page,
                    pageSize: $pageSize,
                    cardWidth: $cardWidth,
                    itemCount: store.displayItems.count,
                    localizer: localizer
                )
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
        }
        .navigationTitle(localizer.string(.libraryShelf))
        .onChange(of: store.searchText) { _, _ in
            page = 1
        }
        .onChange(of: pageCount) { _, newValue in
            page = min(max(page, 1), newValue)
        }
        .onChange(of: pageSize) { _, _ in
            page = 1
        }
    }
}

private struct LibraryShelfFooter: View {
    @Binding var page: Int
    @Binding var pageSize: Int
    @Binding var cardWidth: Int
    let itemCount: Int
    let localizer: AppLocalizer

    private var pageCount: Int {
        Pagination.pageCount(itemCount: itemCount, pageSize: pageSize)
    }

    private var clampedPage: Int {
        Pagination.clampedPage(page, itemCount: itemCount, pageSize: pageSize)
    }

    var body: some View {
        HStack(spacing: 12) {
            HStack(spacing: 14) {
                Picker(localizer.string(.pageSize), selection: $pageSize) {
                    ForEach(PageSizeOption.allowedValues, id: \.self) { option in
                        Text("\(option)")
                            .tag(option)
                    }
                }
                .pickerStyle(.menu)
                .controlSize(.small)
                .frame(width: 116)

                Button {
                    page = max(1, clampedPage - 1)
                } label: {
                    Label(localizer.string(.previousPage), systemImage: "chevron.left")
                }
                .help(localizer.string(.previousPage))
                .disabled(clampedPage <= 1)

                Text(localizer.pageIndicator(current: clampedPage, total: pageCount))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()

                Button {
                    page = min(pageCount, clampedPage + 1)
                } label: {
                    Label(localizer.string(.nextPage), systemImage: "chevron.right")
                }
                .help(localizer.string(.nextPage))
                .disabled(clampedPage >= pageCount)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .cardControlCapsule()

            CardSizeSliderControl(cardWidth: $cardWidth)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .cardControlCapsule()
        }
        .frame(maxWidth: .infinity, alignment: .center)
        .onChange(of: pageSize) { _, newValue in
            pageSize = AppPreferences.nearestAllowedValue(newValue, allowed: PageSizeOption.allowedValues)
            page = 1
        }
        .onChange(of: itemCount) { _, _ in
            page = clampedPage
        }
        .onChange(of: pageCount) { _, _ in
            page = clampedPage
        }
        .focusedSceneValue(\.nyaehViewCommands, viewCommandContext)
        .focusedSceneValue(\.nyaehPageCommands, pageCommandContext)
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

    private var pageCommandContext: NyaEHPageCommandContext {
        NyaEHPageCommandContext(
            canGoPrevious: clampedPage > 1,
            goPrevious: {
                page = max(1, clampedPage - 1)
            },
            canGoNext: clampedPage < pageCount,
            goNext: {
                page = min(pageCount, clampedPage + 1)
            }
        )
    }
}
