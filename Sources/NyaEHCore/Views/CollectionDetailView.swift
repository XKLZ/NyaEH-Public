// 本文件实现合集详情页的轻量容器，成员数据和打开行为仍由 Store 与上层导航持有。

import SwiftUI

struct CollectionDetailView: View {
    @Bindable var store: OrganizationStore
    let collection: BookCollection?
    let titleDisplayMode: BookTitleDisplayMode
    @Binding var pageSize: Int
    let localizer: AppLocalizer
    let onSelect: (LibraryBook) -> Void

    @State private var page = 1

    var body: some View {
        Group {
            if let collection {
                VStack(spacing: 0) {
                        let books = store.catalog.displayBooks(in: collection)
                        ScrollView {
                            LazyVGrid(
                                columns: [
                                    GridItem(.adaptive(minimum: 142, maximum: 160), spacing: 22, alignment: .top)
                                ],
                                alignment: .leading,
                                spacing: 24
                            ) {
                                ForEach(Pagination.pageItems(books, page: page, pageSize: pageSize)) { book in
                                    BookCardButton(
                                        book: book,
                                        titleDisplayMode: titleDisplayMode,
                                        localizer: localizer,
                                        action: {
                                            onSelect(book)
                                        }
                                    )
                                }
                            }
                            .padding(24)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }

                        Divider()

                        PaginationControls(
                            page: $page,
                            pageSize: $pageSize,
                            itemCount: books.count,
                            localizer: localizer
                        )
                        .padding(12)
                }
                .navigationTitle(collection.name)
                .onChange(of: collection.id) { _, _ in
                    page = 1
                }
                .onChange(of: pageSize) { _, _ in
                    page = 1
                }
            } else {
                ContentUnavailableView(
                    localizer.string(.selectCollection),
                    systemImage: "rectangle.stack",
                    description: Text(localizer.string(.collectionManagementDescription))
                )
            }
        }
    }
}
