import SwiftUI

struct SearchResultPreviewView: View {
    let store: SearchStore
    let item: LibraryDisplayItem?
    let isTagTranslationEnabled: Bool
    let titleDisplayMode: BookTitleDisplayMode
    let localizer: AppLocalizer
    let onOpen: (LibraryDisplayItem) -> Void

    var body: some View {
        Group {
            if let item {
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        if let book = item.representativeBook {
                            BookCoverThumbnail(
                                book: book, width: 178, height: 250, cornerRadius: 8, fitsEntireImage: true
                            )
                            .frame(maxWidth: .infinity)
                        }

                        switch item {
                        case .book(let book):
                            title(BookTitleFormatter.displayTitle(for: book, mode: titleDisplayMode))
                            SearchPreviewBookSummary(
                                store: store,
                                book: book,
                                isTagTranslationEnabled: isTagTranslationEnabled,
                                localizer: localizer
                            )
                        case .collection(let collection):
                            title(collection.collection.name)
                            Text(localizer.collectionBookCount(collection.books.count))
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        }

                        Button {
                            onOpen(item)
                        } label: {
                            Label(localizer.string(.details), systemImage: "info.circle")
                        }
                        .buttonStyle(.bordered)
                    }
                    .padding(16)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .id(item.id)
            } else {
                ContentUnavailableView(
                    localizer.string(.advancedSearchPreviewPlaceholder),
                    systemImage: "eye"
                )
                .padding(12)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .controlBackgroundColor))
    }

    private func title(_ title: String) -> some View {
        Text(title)
            .font(.headline)
            .fixedSize(horizontal: false, vertical: true)
            .textSelection(.enabled)
    }
}

private struct SearchPreviewBookSummary: View {
    let store: SearchStore
    let book: LibraryBook
    let isTagTranslationEnabled: Bool
    let localizer: AppLocalizer

    @State private var tags: [TagDisplaySummary] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                BookRatingStarsView(rating: book.rating, localizer: localizer)
                if book.mark {
                    Label(localizer.string(.markedStatus), systemImage: "heart.fill")
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                LabeledContent(
                    localizer.string(.appLanguage),
                    value: book.languageCode == "unknown" ? localizer.string(.unknown) : book.languageCode.capitalized
                )
                LabeledContent(
                    localizer.string(.pages),
                    value: (book.pages ?? book.fileCount).map { String($0) } ?? "–"
                )
                if let posted = book.posted {
                    LabeledContent(
                        localizer.string(.advancedSearchSortPosted),
                        value: Date(timeIntervalSince1970: TimeInterval(posted)).formatted(date: .numeric, time: .shortened)
                    )
                }
            }
            .font(.caption)
            .padding(10)
            .background(Color.secondary.opacity(0.07), in: RoundedRectangle(cornerRadius: 8))

            if !tags.isEmpty {
                SearchResultTagCloud(tags: tags, isExpanded: false)
            }
        }
        .task(id: TagRequest(bookID: book.id, updatedAt: book.updatedAt, revision: store.catalog.tagSummaryRevision, translates: isTagTranslationEnabled)) {
            // Coalesce rapid pointer movement before resolving tags for the settled preview.
            do { try await Task.sleep(for: .milliseconds(150)) } catch { return }
            let loadedTags = await store.catalog.searchResultTags(for: book, isTagTranslationEnabled: isTagTranslationEnabled)
            if !Task.isCancelled { tags = loadedTags }
        }
    }

    private struct TagRequest: Equatable {
        let bookID: LibraryBook.ID
        let updatedAt: Int64
        let revision: Int
        let translates: Bool
    }
}
