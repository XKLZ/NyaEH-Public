// 本文件实现收藏管理页，复用搜索结果布局来批量查看和整理已标记书籍。

import SwiftUI

struct FavoriteManagementView: View {
    @Bindable var store: CatalogStore
    let titleDisplayMode: BookTitleDisplayMode
    let localizer: AppLocalizer
    let onSelect: (LibraryBook) -> Void

    private var books: [LibraryBook] {
        store.favoriteManagementBooks
    }

    var body: some View {
        VStack(spacing: 0) {
            FavoriteManagementToolbar(
                layout: $store.favoriteManagementLayout,
                count: books.count,
                localizer: localizer
            )
            .padding(.horizontal, 16)
            .padding(.top, 14)
            .padding(.bottom, 10)

            if books.isEmpty {
                ContentUnavailableView(
                    localizer.string(.noBooks),
                    systemImage: "star",
                    description: Text(localizer.string(.importedBooksDescription))
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                FavoriteManagementResults(
                    books: books,
                    layout: store.favoriteManagementLayout,
                    titleDisplayMode: titleDisplayMode,
                    localizer: localizer,
                    onSelect: onSelect,
                    onRemove: { book in
                        store.toggleMarked(for: book)
                    }
                )
            }
        }
        .navigationTitle(localizer.string(.favoriteManagement))
        .focusedSceneValue(\.nyaehViewCommands, viewCommandContext)
    }

    private var viewCommandContext: NyaEHViewCommandContext {
        NyaEHViewCommandContext(
            canIncreaseCardSize: false,
            increaseCardSize: {},
            canDecreaseCardSize: false,
            decreaseCardSize: {},
            layout: store.favoriteManagementLayout,
            setLayout: { store.favoriteManagementLayout = $0 },
            sortStrategy: nil,
            setSortStrategy: { _ in },
            searchResultSortKey: nil,
            setSearchResultSortKey: { _ in },
            sortDirection: nil,
            setSortDirection: { _ in }
        )
    }
}

private struct FavoriteManagementToolbar: View {
    @Binding var layout: SearchResultLayout
    let count: Int
    let localizer: AppLocalizer

    var body: some View {
        HStack(spacing: 12) {
            Label(localizer.string(.favoriteManagement), systemImage: "star.fill")
                .font(.headline)

            Text(localizer.collectionBookCount(count))
                .font(.callout)
                .foregroundStyle(.secondary)
                .monospacedDigit()

            Spacer(minLength: 16)

            Picker(localizer.string(.advancedSearchLayout), selection: $layout) {
                Label(localizer.string(.advancedSearchCards), systemImage: "square.grid.3x3")
                    .tag(SearchResultLayout.card)
                Label(localizer.string(.advancedSearchRows), systemImage: "list.bullet")
                    .tag(SearchResultLayout.row)
                Label(localizer.string(.advancedSearchExpanded), systemImage: "list.bullet.rectangle")
                    .tag(SearchResultLayout.expandedRow)
            }
            .pickerStyle(.segmented)
            .frame(width: 328)
            .controlSize(.small)
        }
        .padding(14)
        .favoriteGlassPanel(cornerRadius: 22, material: .regularMaterial, interactive: true)
    }
}

private struct FavoriteManagementResults: View {
    let books: [LibraryBook]
    let layout: SearchResultLayout
    let titleDisplayMode: BookTitleDisplayMode
    let localizer: AppLocalizer
    let onSelect: (LibraryBook) -> Void
    let onRemove: (LibraryBook) -> Void

    var body: some View {
        ScrollView {
            switch layout {
            case .card:
                LazyVGrid(
                    columns: [
                        GridItem(.adaptive(minimum: 154, maximum: 174), spacing: 22, alignment: .top)
                    ],
                    alignment: .leading,
                    spacing: 24
                ) {
                    ForEach(books) { book in
                        FavoriteBookCard(
                            book: book,
                            titleDisplayMode: titleDisplayMode,
                            localizer: localizer,
                            onSelect: onSelect,
                            onRemove: onRemove
                        )
                    }
                }
                .padding(24)
                .frame(maxWidth: .infinity, alignment: .leading)
            case .row, .expandedRow:
                LazyVStack(spacing: 10) {
                    ForEach(books) { book in
                        FavoriteBookRow(
                            book: book,
                            isExpanded: layout == .expandedRow,
                            titleDisplayMode: titleDisplayMode,
                            localizer: localizer,
                            onSelect: onSelect,
                            onRemove: onRemove
                        )
                    }
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 12)
            }
        }
    }
}

private struct FavoriteBookCard: View {
    let book: LibraryBook
    let titleDisplayMode: BookTitleDisplayMode
    let localizer: AppLocalizer
    let onSelect: (LibraryBook) -> Void
    let onRemove: (LibraryBook) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button {
                onSelect(book)
            } label: {
                BookCardView(
                    book: book,
                    titleDisplayMode: titleDisplayMode,
                    localizer: localizer
                )
            }
            .buttonStyle(.plain)
            .bookCardHoverSurface()

            HStack(spacing: 8) {
                Button {
                    onSelect(book)
                } label: {
                    Label(localizer.string(.details), systemImage: "sidebar.right")
                }

                Button(role: .destructive) {
                    onRemove(book)
                } label: {
                    Label(localizer.string(.remove), systemImage: "star.slash")
                }
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.bordered)
            .controlSize(.small)
            .frame(width: 128, alignment: .leading)
        }
        .padding(12)
        .favoriteGlassPanel(cornerRadius: 16, material: .thinMaterial, interactive: true)
    }
}

private struct FavoriteBookRow: View {
    let book: LibraryBook
    let isExpanded: Bool
    let titleDisplayMode: BookTitleDisplayMode
    let localizer: AppLocalizer
    let onSelect: (LibraryBook) -> Void
    let onRemove: (LibraryBook) -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Button {
                onSelect(book)
            } label: {
                HStack(alignment: .center, spacing: 12) {
                    BookCoverThumbnail(
                        book: book,
                        width: isExpanded ? 60 : 44,
                        height: isExpanded ? 82 : 60,
                        cornerRadius: 6
                    )

                    VStack(alignment: .leading, spacing: isExpanded ? 6 : 4) {
                        Text(BookTitleFormatter.displayTitle(for: book, mode: titleDisplayMode))
                            .font(.headline)
                            .lineLimit(isExpanded ? 2 : 1)

                        Text(book.filepath)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(isExpanded ? 2 : 1)

                        if isExpanded {
                            HStack(spacing: 8) {
                                BookStatusBadge(status: book.status, exist: book.exist, localizer: localizer)
                                if let pages = book.pages {
                                    Text("\(localizer.string(.pages)): \(pages)")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                            }
                        }
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Spacer(minLength: 12)

            if !isExpanded {
                BookStatusBadge(status: book.status, exist: book.exist, localizer: localizer)
            }

            Button {
                onSelect(book)
            } label: {
                Label(localizer.string(.details), systemImage: "sidebar.right")
            }
            .help(localizer.string(.details))

            Button(role: .destructive) {
                onRemove(book)
            } label: {
                Label(localizer.string(.remove), systemImage: "star.slash")
            }
            .help(localizer.string(.remove))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, isExpanded ? 12 : 8)
        .labelStyle(.iconOnly)
        .controlSize(.small)
        .favoriteGlassPanel(cornerRadius: 16, material: .thinMaterial, interactive: true)
    }
}

private extension View {
    @ViewBuilder
    func favoriteGlassPanel(
        cornerRadius: CGFloat,
        material: Material,
        interactive: Bool = false
    ) -> some View {
        if #available(macOS 26.0, *) {
            glassEffect(
                interactive ? .regular.interactive() : .regular,
                in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            )
        } else {
            background(material, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .stroke(.white.opacity(0.16), lineWidth: 1)
                }
                .shadow(color: .black.opacity(0.05), radius: 12, x: 0, y: 5)
        }
    }
}
