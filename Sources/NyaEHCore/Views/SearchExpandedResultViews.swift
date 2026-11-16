import SwiftUI

func searchTagNamespaceTitle(_ namespace: String, localizer: AppLocalizer) -> String {
    switch namespace {
    case "artist": return localizer.string(.tagNamespaceArtist)
    case "group": return localizer.string(.tagNamespaceGroup)
    case "parody": return localizer.string(.tagNamespaceParody)
    case "character": return localizer.string(.tagNamespaceCharacter)
    case "female": return localizer.string(.tagNamespaceFemale)
    case "male": return localizer.string(.tagNamespaceMale)
    case "mixed": return localizer.string(.tagNamespaceMixed)
    case "location": return localizer.string(.tagNamespaceLocation)
    case "other": return localizer.string(.tagNamespaceOther)
    case "cosplayer": return localizer.string(.tagNamespaceCosplayer)
    case "reclass": return localizer.string(.tagNamespaceReclass)
    case "language": return localizer.string(.appLanguage)
    default: return namespace
    }
}

enum SearchExpandedRowMetrics {
    static let coverWidth: CGFloat = 156
    static let coverHeight: CGFloat = 222
    static let coverCornerRadius: CGFloat = 8
    static let verticalInset: CGFloat = 12
    static let columnSpacing: CGFloat = 18
    static let rowHeight = coverHeight + 2 * verticalInset
}

struct SearchExpandedCoverButton: View {
    let book: LibraryBook
    let title: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            BookCoverThumbnail(
                book: book,
                width: SearchExpandedRowMetrics.coverWidth,
                height: SearchExpandedRowMetrics.coverHeight,
                cornerRadius: SearchExpandedRowMetrics.coverCornerRadius,
                fitsEntireImage: true
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .bookCardHoverSurface()
        .help(title)
        .accessibilityLabel(title)
    }
}

struct SearchCollectionCoverStrip<Content: View>: View {
    let localizer: AppLocalizer
    @ViewBuilder let content: () -> Content

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var position = ScrollPosition(x: 0)
    @State private var scroll = ScrollMetrics()

    private static var spacing: CGFloat { 14 }
    private static var contentPadding: CGFloat { 7 }

    var body: some View {
        HStack(spacing: 5) {
            arrow(backward: true)
                .disabled(scroll.offset <= 1)

            ScrollView(.horizontal) {
                LazyHStack(spacing: Self.spacing, content: content)
                    .padding(.horizontal, Self.contentPadding)
                    .padding(.vertical, SearchExpandedRowMetrics.verticalInset)
            }
            .scrollPosition($position)
            .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
            .onScrollGeometryChange(for: ScrollMetrics.self) { geometry in
                let maximum = max(0, geometry.contentSize.width - geometry.containerSize.width)
                return ScrollMetrics(
                    offset: min(max(0, geometry.contentOffset.x), maximum),
                    maximum: maximum,
                    viewport: geometry.containerSize.width
                )
            } action: { _, metrics in
                scroll = metrics
            }
            .frame(height: SearchExpandedRowMetrics.rowHeight)

            arrow(backward: false)
                .disabled(scroll.maximum - scroll.offset <= 1)
        }
    }

    private func arrow(backward: Bool) -> some View {
        let title = localizer.string(backward ? .previousPage : .nextPage)
        return Button {
            let step = SearchExpandedRowMetrics.coverWidth + Self.spacing
            let available = scroll.viewport - Self.contentPadding * 2
            let distance = max(1, floor((available + Self.spacing) / step)) * step
            let target = min(max(0, scroll.offset + (backward ? -distance : distance)), scroll.maximum)
            withAnimation(reduceMotion ? nil : .snappy(duration: 0.27)) {
                position.scrollTo(x: target)
            }
        } label: {
            Label(title, systemImage: backward ? "chevron.left" : "chevron.right")
                .labelStyle(.iconOnly)
                .frame(width: 20, height: 24)
        }
        .buttonStyle(.bordered)
        .help(title)
    }

    private struct ScrollMetrics: Equatable {
        var offset: CGFloat = 0
        var maximum: CGFloat = 0
        var viewport: CGFloat = 0
    }
}


struct SearchExpandedBookRow: View {
    let book: LibraryBook
    let isMatched: Bool
    let store: SearchStore
    let isTagTranslationEnabled: Bool
    let title: String
    let localizer: AppLocalizer
    let showsAllTags: Bool
    let onSelect: () -> Void
    let onToggleMarked: () -> Void
    let onToggleTags: () -> Void

    @State private var loadedTags: LoadedTags?

    private var tagRequest: TagRequest {
        TagRequest(
            bookID: book.id,
            updatedAt: book.updatedAt,
            revision: store.catalog.tagSummaryRevision,
            translates: isTagTranslationEnabled
        )
    }

    var body: some View {
        let currentTags = loadedTags.flatMap { $0.request == tagRequest ? $0 : nil }
        let groups = currentTags?.groups ?? []

        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: SearchExpandedRowMetrics.columnSpacing) {
                SearchExpandedCoverButton(book: book, title: title, action: onSelect)

                VStack(alignment: .leading, spacing: 9) {
                    HStack(alignment: .top, spacing: 8) {
                        Button(action: onSelect) {
                            Text(title)
                                .font(.title3.weight(.semibold))
                                .multilineTextAlignment(.leading)
                                .lineLimit(2)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .buttonStyle(.plain)
                        .help(title)

                        SearchFavoriteButton(isMarked: book.mark, isExpanded: true, localizer: localizer, action: onToggleMarked)
                    }

                    HStack(spacing: 12) {
                        SearchExpandedInfoIconRow(book: book, localizer: localizer)
                        BookRatingStarsView(rating: book.rating, localizer: localizer)
                        if let posted = book.posted {
                            Text(Date(timeIntervalSince1970: TimeInterval(posted)).formatted(date: .numeric, time: .omitted))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.secondary.opacity(0.07), in: RoundedRectangle(cornerRadius: 6))

                    if let currentTags, currentTags.count > 0 {
                        ForEach(groups.prefix(2)) { group in
                            HStack(spacing: 6) {
                                groupTitle(group)
                                ForEach(group.tags.prefix(3)) { tag in
                                    tagLabel(tag, wraps: false)
                                }
                            }
                        }

                        Button(action: onToggleTags) {
                            Label(
                                localizer.searchResultTagDisclosure(count: currentTags.count, isExpanded: showsAllTags),
                                systemImage: showsAllTags ? "chevron.up" : "chevron.down"
                            )
                        }
                        .buttonStyle(.borderless)
                        .font(.callout)
                    } else if currentTags != nil {
                        Text(localizer.string(.tagNoTags))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
            .frame(height: SearchExpandedRowMetrics.coverHeight)
            .padding(.vertical, SearchExpandedRowMetrics.verticalInset)

            if showsAllTags && !groups.isEmpty {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(groups) { group in
                        VStack(alignment: .leading, spacing: 5) {
                            groupTitle(group)
                            SearchResultTagFlowLayout(spacing: 6, lineSpacing: 6, wrapsLongItems: true) {
                                ForEach(group.tags) { tag in
                                    tagLabel(tag, wraps: true)
                                }
                            }
                        }
                    }
                }
                .padding(12)
                .background(Color.secondary.opacity(0.055), in: RoundedRectangle(cornerRadius: 8))
                .padding(.bottom, SearchExpandedRowMetrics.verticalInset)
            }
        }
        .background {
            if isMatched {
                RoundedRectangle(cornerRadius: 9)
                    .fill(Color.accentColor.opacity(0.09))
            }
        }
        .task(id: tagRequest) { [request = tagRequest] in
            let tags = await store.catalog.searchResultTags(
                for: book,
                isTagTranslationEnabled: request.translates
            )
            guard !Task.isCancelled else { return }
            loadedTags = LoadedTags(request: request, groups: BookDetailTagOrganizer.allGroups(from: tags), count: tags.count)
        }
    }

    private func groupTitle(_ group: BookDetailTagGroup) -> some View {
        Text(searchTagNamespaceTitle(group.namespace, localizer: localizer))
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .layoutPriority(1)
    }

    private func tagLabel(_ tag: TagDisplaySummary, wraps: Bool) -> some View {
        Text(tag.displayText)
            .font(.caption)
            .lineLimit(wraps ? nil : 1)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 5))
            .help(tag.rawValue)
    }

    private struct TagRequest: Equatable {
        let bookID: LibraryBook.ID
        let updatedAt: Int64
        let revision: Int
        let translates: Bool
    }

    private struct LoadedTags {
        let request: TagRequest
        let groups: [BookDetailTagGroup]
        let count: Int
    }
}
