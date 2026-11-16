// 本文件实现合集与版本组管理页，包括推荐接受、候选列表、版本标签和合集排序拖拽。

import AppKit
import SwiftUI

struct CollectionManagementView: View {
    @Bindable var store: OrganizationStore
    let titleDisplayMode: BookTitleDisplayMode
    let isTagTranslationEnabled: Bool
    let isSemanticSeriesRecommendationEnabled: Bool
    @Binding var candidatePageSize: Int
    @Binding var isCandidateAreaVisible: Bool
    let showsManagementToolbar: Bool
    let localizer: AppLocalizer
    let onSelect: (LibraryBook) -> Void

    @State private var listTab: ManagementListTab = .groups
    @State private var candidateTab: ManagementCandidateTab = .candidates
    @State private var isCompactLayout = false
    @State private var isCompactCandidatePresented = false
    @State private var candidateSearch = ""
    @State private var collectionListSearch = ""
    @State private var candidatePage = 1
    @State private var collectionName = ""
    @State private var editingCollection: BookCollection?
    @FocusState private var isCollectionNameFocused: Bool
    @State private var candidates: [LibraryBook] = []
    @State private var hasLoadedCandidates = false
    @State private var candidateRefreshTask: Task<Void, Never>?
    @State private var seriesConflictConfirmation: SeriesConflictConfirmation?
    @State private var collectionToDelete: BookCollection?
    @State private var isDeleteConfirmationPresented = false
    @State private var deletionFollowUp: CollectionDeletionFollowUp?
    @State private var deletionSelectionChangedByUser = false
    @State private var memberSelection = CollectionMemberSelectionState()
    @State private var memberDrag: CollectionMemberDrag?
    @State private var memberDropTarget: CollectionMemberDropTarget?
    @State private var isMoveDestinationPresented = false
    @State private var movingMemberIDs: Set<LibraryBook.ID> = []

    private var selectedCollection: BookCollection? {
        store.catalog.selectedCollectionID.flatMap(store.catalog.collection(id:))
    }

    private var filteredCollections: [BookCollection] {
        _ = store.catalog.collectionOrderRevision
        let query = managementSearchToken(collectionListSearch)
        let matches = store.catalog.collections.filter { query.isEmpty || collectionMatchesSearch($0, query: query) }
        return ManagementRecommendationOrdering.prioritized(matches) { collection in
            collection.databaseID.flatMap { store.catalog.addToCollectionRecommendationCounts[$0] } ?? 0
        }
    }

    private var candidatePageBooks: [LibraryBook] {
        Pagination.pageItems(candidates, page: candidatePage, pageSize: candidatePageSize)
    }

    private var candidateRowItems: [ManagementCandidateRowItem] {
        candidatePageBooks.map { candidateRowItem(for: $0) }
    }

    private var selectedCollectionMemberBooks: [LibraryBook] {
        _ = store.catalog.collectionOrderRevision
        return selectedCollection.map(store.catalog.displayBooks(in:)) ?? []
    }

    private var isCandidateAreaHidden: Bool {
        isCompactLayout ? !isCompactCandidatePresented : !isCandidateAreaVisible
    }

    var body: some View {
        splitContent
    }

    private var splitContent: some View {
        GeometryReader { geometry in
            HSplitView {
                collectionListColumn
                    .frame(minWidth: 270, idealWidth: 310, maxWidth: 360)

                memberColumn
                    .frame(minWidth: 420, idealWidth: 620)

                if isCandidateAreaVisible && geometry.size.width >= 1_120 {
                    candidateColumn
                        .frame(minWidth: 350, idealWidth: 380, maxWidth: 460)
                }
            }
            .padding(10)
            .onAppear { isCompactLayout = geometry.size.width < 1_120 }
            .onChange(of: geometry.size.width) { _, width in
                isCompactLayout = width < 1_120
                if !isCompactLayout { isCompactCandidatePresented = false }
            }
        }
        .sheet(isPresented: $isCompactCandidatePresented) {
            candidateColumn
                .frame(minWidth: 440, minHeight: 560)
                .confirmSeriesConflict($seriesConflictConfirmation, localizer: localizer)
        }
        .sheet(isPresented: $isMoveDestinationPresented) {
            CollectionMoveDestinationSheet(
                collections: store.catalog.collections.filter { $0.id != selectedCollection?.id },
                localizer: localizer,
                onChoose: moveSelectedMembers
            )
        }
        .confirmationDialog(
            collectionToDelete.map { localizer.string(.deleteCollection) + " · " + $0.name } ?? localizer.string(.deleteCollection),
            isPresented: $isDeleteConfirmationPresented,
            titleVisibility: .visible
        ) {
            Button(localizer.string(.deleteCollection), role: .destructive) {
                confirmCollectionDeletion()
            }
            Button(localizer.string(.cancel), role: .cancel) {
                collectionToDelete = nil
            }
        } message: {
            if let collectionToDelete {
                Text(localizer.deleteCollectionConfirmation(name: collectionToDelete.name,
                    count: store.catalog.displayBooks(in: collectionToDelete).count))
            }
        }
        .confirmSeriesConflict(Binding(
            get: { isCompactCandidatePresented ? nil : seriesConflictConfirmation },
            set: { seriesConflictConfirmation = $0 }
        ), localizer: localizer)
        .managementPageToolbar(
            navigationTitle: localizer.string(.collectionManagement),
            updateTitle: localizer.string(.updateCollectionRecommendations),
            newTitle: localizer.string(.newCollection),
            candidateAreaTitle: localizer.string(isCandidateAreaHidden ? .showCandidateArea : .hideCandidateArea),
            isCandidateAreaHidden: isCandidateAreaHidden,
            isRefreshing: store.catalog.isRefreshingCollectionRecommendations,
            showsActions: showsManagementToolbar,
            onUpdate: {
                store.catalog.updateCollectionRecommendationsIncrementally(
                    useSemanticSimilarity: isSemanticSeriesRecommendationEnabled,
                    localizer: localizer
                )
            },
            onCreate: {
                store.catalog.createCollection(localizer: localizer)
            },
            onToggleCandidateArea: {
                if isCompactLayout {
                    isCompactCandidatePresented.toggle()
                } else {
                    isCandidateAreaVisible.toggle()
                }
            }
        )
        .onAppear {
            if store.catalog.selectedCollectionID == nil {
                store.catalog.selectedCollectionID = filteredCollections.first?.id ?? store.catalog.collections.first?.id
            }
            collectionName = selectedCollection?.name ?? ""
            refreshCandidates()
        }
        .onChange(of: collectionListSearch) { _, _ in
            selectFirstFilteredCollectionIfNeeded()
        }
        .onChange(of: isCandidateAreaHidden) { _, isHidden in
            handleCandidateAreaVisibilityChange(isHidden: isHidden)
        }
        .onChange(of: store.catalog.selectedCollectionID) { _, newID in
            if let deletionFollowUp,
               store.catalog.collection(id: deletionFollowUp.deletedID) != nil,
               newID != deletionFollowUp.deletedID {
                deletionSelectionChangedByUser = true
            }
            listTab = .groups
            memberSelection.clear()
            memberDrag = nil
            memberDropTarget = nil
            isMoveDestinationPresented = false
            finishCollectionNameEdit()
            collectionName = selectedCollection?.name ?? ""
            candidatePage = 1
            refreshCandidates()
            store.catalog.reloadAddToSelectedCollectionRecommendationsAsync()
        }
        .onChange(of: candidateSearch) { _, _ in
            candidatePage = 1
            scheduleCandidateRefresh()
        }
        .onChange(of: candidatePageSize) { _, _ in
            candidatePage = 1
            prepareCandidatePage()
        }
        .onChange(of: candidatePage) { _, _ in
            prepareCandidatePage()
        }
        .onChange(of: store.catalog.derivedDataRevision) { _, _ in
            selectFirstFilteredCollectionIfNeeded()
            refreshCandidates(preservingVisibleContent: true)
        }
        .onChange(of: store.catalog.collections.map(\.id)) { _, ids in
            reconcileCollectionDeletion(availableIDs: ids)
        }
        .onChange(of: store.catalog.savingOrganizationKeys) { _, keys in
            if let deletionFollowUp,
               !keys.contains("collection:\(deletionFollowUp.deletedID)"),
               store.catalog.collection(id: deletionFollowUp.deletedID) != nil {
                self.deletionFollowUp = nil
            }
        }
        .onChange(of: selectedCollectionMemberBooks.map(\.id)) { _, ids in
            memberSelection.retain(ids)
            if let memberDrag, !Set(memberDrag.bookIDs).isSubset(of: Set(ids)) {
                finishMemberDrag()
            }
        }
        .onChange(of: isTagTranslationEnabled) { _, _ in
            prepareCandidatePage()
        }
        .onDisappear {
            memberSelection.clear()
            memberDrag = nil
            memberDropTarget = nil
            finishCollectionNameEdit()
            candidateRefreshTask?.cancel()
            collectionToDelete = nil
            isDeleteConfirmationPresented = false
            deletionFollowUp = nil
            deletionSelectionChangedByUser = false
        }
    }

    @ViewBuilder
    private var candidateColumn: some View {
        ManagementColumn {
            ManagementGlassTabSwitch(
                selection: $candidateTab,
                title: localizer.string(.candidateArea),
                first: (.candidates, localizer.string(.candidates), candidates.count),
                second: (.recommendations, localizer.string(.managementAddRecommendationsTab),
                    store.catalog.addToSelectedCollectionRecommendations.count)
            )
            .frame(maxWidth: 360)
            .frame(maxWidth: .infinity, alignment: .center)

            if candidateTab == .candidates {
                TextField(localizer.string(.searchCandidates), text: $candidateSearch)
                    .managementGlassSearchField()

                if let collection = selectedCollection {
                    if !hasLoadedCandidates && candidates.isEmpty {
                        ProgressView()
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else if candidates.isEmpty {
                        ManagementUnavailableView(
                            title: localizer.string(.managementNoCandidates),
                            systemImage: "books.vertical",
                            description: ""
                        )
                    } else {
                        ManagementExpandableScrollList(
                            items: candidateRowItems,
                            context: .init(groupID: collection.databaseID, page: candidatePage, query: candidateSearch, pageSize: candidatePageSize),
                            usesGlassPreview: true
                        ) { item, expansion, controller in
                            CandidateBookRow(
                                item: item,
                                expansion: expansion,
                                onToggleExpansion: { controller.togglePinned(for: item.id) },
                                localizer: localizer,
                                actionTitle: localizer.string(.addToCollection),
                                systemImage: "plus.circle.fill",
                                action: {
                                    requestSeriesMove([item.book], to: collection)
                                }
                            )
                        } preview: { item in
                            ManagementBookExpandedInfo(book: item.book, localizer: localizer, showsDivider: false, scrollsTags: false)
                        }

                        PaginationControls(
                            page: $candidatePage,
                            pageSize: $candidatePageSize,
                            itemCount: candidates.count,
                            localizer: localizer,
                            usesIconOnlyNavigation: true,
                            allowedPageSizes: AppPreferences.managementCandidatePageSizeValues
                        )
                        .frame(maxWidth: .infinity, alignment: .center)
                    }
                } else {
                    ManagementUnavailableView(
                        title: localizer.string(.selectCollection),
                        systemImage: "rectangle.stack",
                        description: localizer.string(.collectionManagementDescription)
                    )
                }
            } else if !store.catalog.addToSelectedCollectionRecommendations.isEmpty {
                ManagementExpandableScrollList(
                    items: store.catalog.addToSelectedCollectionRecommendations,
                    context: .init(groupID: selectedCollection?.databaseID),
                    usesGlassPreview: true
                ) { item, expansion, controller in
                    CollectionRecommendationBookRow(
                        item: item,
                        expansion: expansion,
                        onToggleExpansion: { controller.togglePinned(for: item.id) },
                        titleDisplayMode: titleDisplayMode,
                        localizer: localizer,
                        acceptTitle: localizer.string(.addToCollection),
                        acceptSystemImage: "plus.circle.fill",
                        isAccepting: store.catalog.isAcceptingCollectionRecommendation,
                        onAccept: {
                            store.catalog.acceptAddToSelectedCollectionRecommendation(
                                item,
                                useSemanticSimilarity: isSemanticSeriesRecommendationEnabled
                            )
                        },
                        onDismiss: {
                            store.catalog.dismissCollectionRecommendation(item)
                        },
                        onSelect: onSelect
                    )
                } preview: { item in
                    if let book = item.books.first {
                        ManagementBookExpandedInfo(book: book, localizer: localizer, showsDivider: false, scrollsTags: false)
                    }
                }
            } else if selectedCollection == nil {
                ManagementUnavailableView(
                    title: localizer.string(.selectCollection),
                    systemImage: "rectangle.stack",
                    description: localizer.string(.collectionManagementDescription)
                )
            } else {
                ManagementUnavailableView(
                    title: localizer.string(.managementNoRecommendations),
                    systemImage: "sparkles",
                    description: ""
                )
            }
        }
    }

    @ViewBuilder
    private var memberColumn: some View {
        if let collection = selectedCollection {
            ManagementColumn {
                collectionNameHeader(collection)

                Button {
                    store.catalog.autoSortBooks(in: collection)
                } label: {
                    Label(localizer.string(.autoSortCollection), systemImage: "arrow.up.arrow.down")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help(localizer.string(.autoSortCollection))

                ManagementScrollList(trailingInset: 12) {
                    ForEach(Array(selectedCollectionMemberBooks.enumerated()), id: \.element.id) { index, book in
                        CollectionMemberCard(
                            store: store,
                            book: book,
                            number: index + 1,
                            isSelected: memberSelection.selectedIDs.contains(book.id),
                            isDragging: memberDrag != nil,
                            dropEdge: memberDropTarget?.bookID == book.id ? memberDropTarget?.edge : nil,
                            titleDisplayMode: titleDisplayMode,
                            localizer: localizer,
                            onSelect: onSelect,
                            onSelectRow: { selectMember(book) },
                            onSecondaryClick: { toggleMemberForSecondaryClick(book) },
                            contextCount: contextMemberIDs(for: book).count,
                            onMove: { direction in moveContextMembers(for: book, direction: direction) },
                            onMoveToBoundary: { atStart in moveContextMembersToBoundary(for: book, atStart: atStart) },
                            onMoveToCollection: { presentMoveDestination(for: book) },
                            onRemove: { removeContextMembers(for: book) },
                            onRemoveOne: { removeSingleMember(book, from: collection) },
                            onDragStarted: { beginMemberDrag(at: book, in: collection) },
                            onDragEnded: { finishMemberDrag() },
                            onDropHover: { edge in
                                if let edge, memberDrag != nil {
                                    memberDropTarget = .init(bookID: book.id, edge: edge)
                                } else if memberDropTarget?.bookID == book.id {
                                    memberDropTarget = nil
                                }
                            },
                            onDrop: { token, edge in dropMembers(token: token, at: index, edge: edge, in: collection) }
                        )
                    }
                }
                .onExitCommand { memberSelection.clear() }

                HStack {
                    ManagementMemberCountPill(text: localizer.collectionBookCount(selectedCollectionMemberBooks.count))
                    Spacer()
                    Button(role: .destructive) {
                        collectionToDelete = collection
                        isDeleteConfirmationPresented = true
                    } label: {
                        Label(localizer.string(.deleteCollection), systemImage: "trash")
                    }
                    .controlSize(.small)
                    .disabled(collection.databaseID.map { store.catalog.savingOrganizationKeys.contains("collection:\($0)") } ?? true)
                }
            }
        } else {
            ManagementUnavailableView(
                title: localizer.string(.selectCollection),
                systemImage: "rectangle.stack",
                description: localizer.string(.collectionManagementDescription)
            )
        }
    }

    private var collectionListColumn: some View {
        ManagementColumn {
            OrganizationSaveStatusView(store: store.catalog, localizer: localizer)

            ManagementGlassTabSwitch(
                selection: $listTab,
                title: localizer.string(.collectionManagement),
                first: (.groups, localizer.string(.managementCollectionTab), store.catalog.collections.count),
                second: (.recommendations, localizer.string(.managementNewRecommendationsTab),
                    store.catalog.createCollectionRecommendations.count)
            )
            .frame(maxWidth: 360)
            .frame(maxWidth: .infinity, alignment: .center)

            if listTab == .groups {
                TextField(localizer.string(.searchCollections), text: $collectionListSearch)
                    .managementGlassSearchField()

                if filteredCollections.isEmpty {
                    ManagementUnavailableView(
                        title: localizer.string(store.catalog.collections.isEmpty ? .selectCollection : .managementNoResults),
                        systemImage: "rectangle.stack",
                        description: store.catalog.collections.isEmpty
                            ? localizer.string(.collectionManagementDescription) : ""
                    )
                } else {
                    List(selection: $store.selectedCollectionID) {
                        ForEach(filteredCollections) { collection in
                            ManagementGroupListRow(
                                title: collection.name,
                                memberCountText: localizer.collectionBookCount(store.catalog.displayBooks(in: collection).count),
                                recommendationCount: collection.databaseID.flatMap {
                                    store.catalog.addToCollectionRecommendationCounts[$0]
                                } ?? 0,
                                isSelected: store.catalog.selectedCollectionID == collection.id,
                                isSaving: collection.databaseID.map {
                                    store.catalog.savingOrganizationKeys.contains("collection:\($0)")
                                } ?? false,
                                localizer: localizer
                            )
                            .tag(collection.id)
                        }
                    }
                    .listStyle(.sidebar)
                    .scrollContentBackground(.hidden)
                }

            } else if !store.catalog.createCollectionRecommendations.isEmpty {
                ManagementScrollList {
                    ForEach(store.catalog.createCollectionRecommendations) { item in
                        NewCollectionRecommendationRow(
                            item: item,
                            titleDisplayMode: titleDisplayMode,
                            localizer: localizer,
                            isAccepting: store.catalog.isAcceptingCollectionRecommendation,
                            onAccept: {
                                store.catalog.acceptCreateCollectionRecommendation(
                                    item,
                                    useSemanticSimilarity: isSemanticSeriesRecommendationEnabled,
                                    localizer: localizer
                                )
                            },
                            onDismiss: {
                                store.catalog.dismissCollectionRecommendation(item)
                            },
                            onSelect: onSelect
                        )
                    }
                }
            } else {
                ManagementUnavailableView(
                    title: localizer.string(.managementNoRecommendations),
                    systemImage: "sparkles",
                    description: ""
                )
            }
        }
    }

    private func refreshCandidates(preservingVisibleContent: Bool = false) {
        candidateRefreshTask?.cancel()
        guard !isCandidateAreaHidden else {
            unloadCandidates()
            return
        }
        guard let collection = selectedCollection else {
            candidates = []
            hasLoadedCandidates = false
            return
        }
        let query = candidateSearch
        if !preservingVisibleContent {
            candidates = []
            hasLoadedCandidates = false
        }
        candidateRefreshTask = Task { @MainActor in
            let found = await store.catalog.collectionCandidateBooksAsync(query: query)
            guard !Task.isCancelled, selectedCollection?.id == collection.id, candidateSearch == query else { return }
            if candidates != found { candidates = found }
            hasLoadedCandidates = true
            candidatePage = Pagination.clampedPage(candidatePage, itemCount: candidates.count, pageSize: candidatePageSize)
            prepareCandidatePage()
        }
    }

    private func scheduleCandidateRefresh() {
        candidateRefreshTask?.cancel()
        candidates = []
        hasLoadedCandidates = false
        guard !isCandidateAreaHidden else {
            return
        }
        candidateRefreshTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(180))
            guard !Task.isCancelled else {
                return
            }
            refreshCandidates()
        }
    }

    private func prepareCandidatePage() {
        guard !isCandidateAreaHidden else {
            return
        }
        store.catalog.prepareCandidateDisplayData(
            for: candidatePageBooks,
            isTagTranslationEnabled: isTagTranslationEnabled
        )
    }

    private func handleCandidateAreaVisibilityChange(isHidden: Bool) {
        if isHidden {
            unloadCandidates()
        } else {
            refreshCandidates()
        }
    }

    private func unloadCandidates() {
        candidateRefreshTask?.cancel()
        candidates = []
        hasLoadedCandidates = false
        candidatePage = 1
    }

    private func candidateRowItem(for book: LibraryBook) -> ManagementCandidateRowItem {
        ManagementCandidateRowItem(
            book: book,
            displayTitle: BookTitleFormatter.displayTitle(for: book, mode: titleDisplayMode),
            previewTags: Array(store.catalog.candidateDisplayTags(
                for: book,
                isTagTranslationEnabled: isTagTranslationEnabled
            ).prefix(4))
        )
    }

    private func selectFirstFilteredCollectionIfNeeded() {
        guard deletionFollowUp == nil else { return }
        guard !managementSearchToken(collectionListSearch).isEmpty else {
            return
        }
        if let selectedID = store.catalog.selectedCollectionID,
           filteredCollections.contains(where: { $0.id == selectedID }) {
            return
        }
        store.catalog.selectedCollectionID = filteredCollections.first?.id
    }

    private func confirmCollectionDeletion() {
        guard let requested = collectionToDelete,
              let collection = store.catalog.collection(id: requested.id),
              let id = collection.databaseID,
              !store.catalog.savingOrganizationKeys.contains("collection:\(id)") else {
            collectionToDelete = nil
            return
        }
        deletionFollowUp = CollectionDeletionFollowUp(
            deletedID: collection.id,
            orderedIDs: filteredCollections.map(\.id)
        )
        deletionSelectionChangedByUser = false
        collectionToDelete = nil
        store.catalog.deleteCollection(collection)
    }

    private func reconcileCollectionDeletion(availableIDs: [BookCollection.ID]) {
        guard let deletionFollowUp, !availableIDs.contains(deletionFollowUp.deletedID) else { return }
        defer {
            self.deletionFollowUp = nil
            deletionSelectionChangedByUser = false
        }
        guard !deletionSelectionChangedByUser else { return }
        store.catalog.selectedCollectionID = deletionFollowUp.neighbor(
            availableIDs: filteredCollections.map(\.id)
        )
    }

    private func selectMember(_ book: LibraryBook) {
        let modifiers = NSApp.currentEvent?.modifierFlags ?? []
        memberSelection.select(
            book.id,
            orderedIDs: selectedCollectionMemberBooks.map(\.id),
            command: modifiers.contains(.command),
            shift: modifiers.contains(.shift)
        )
    }

    private func toggleMemberForSecondaryClick(_ book: LibraryBook) {
        memberSelection.toggleForSecondaryClick(book.id, orderedIDs: selectedCollectionMemberBooks.map(\.id))
    }

    private func contextMemberIDs(for book: LibraryBook) -> Set<LibraryBook.ID> {
        memberSelection.menuTargetIDs(for: book.id)
    }

    private func contextMemberBooks(for book: LibraryBook) -> [LibraryBook] {
        let ids = contextMemberIDs(for: book)
        return selectedCollectionMemberBooks.filter { ids.contains($0.id) }
    }

    private func commitMemberOrder(_ orderedIDs: [LibraryBook.ID], in collection: BookCollection) {
        let current = selectedCollectionMemberBooks
        guard orderedIDs != current.map(\.id) else { return }
        let booksByID = Dictionary(uniqueKeysWithValues: current.map { ($0.id, $0) })
        let orderedBooks = orderedIDs.compactMap { booksByID[$0] }
        guard orderedBooks.count == current.count else { return }
        store.catalog.reorderBooks(orderedBooks, in: collection)
    }

    private func moveContextMembers(for book: LibraryBook, direction: CollectionMoveDirection) {
        guard let collection = selectedCollection else { return }
        let orderedIDs = selectedCollectionMemberBooks.map(\.id)
        commitMemberOrder(CollectionMemberOrderPlanner.shifted(
            orderedIDs,
            selectedIDs: contextMemberIDs(for: book),
            direction: direction
        ), in: collection)
    }

    private func moveContextMembersToBoundary(for book: LibraryBook, atStart: Bool) {
        guard let collection = selectedCollection else { return }
        let orderedIDs = selectedCollectionMemberBooks.map(\.id)
        commitMemberOrder(CollectionMemberOrderPlanner.movedToBoundary(
            orderedIDs,
            selectedIDs: contextMemberIDs(for: book),
            atStart: atStart
        ), in: collection)
    }

    private func removeSingleMember(_ book: LibraryBook, from collection: BookCollection) {
        memberSelection.clear()
        store.catalog.removeBook(book, from: collection)
    }

    private func removeContextMembers(for book: LibraryBook) {
        guard let collection = selectedCollection else { return }
        let books = contextMemberBooks(for: book)
        memberSelection.clear()
        store.catalog.removeBooks(books, from: collection)
    }

    private func presentMoveDestination(for book: LibraryBook) {
        movingMemberIDs = contextMemberIDs(for: book)
        isMoveDestinationPresented = true
    }

    private func moveSelectedMembers(to destination: BookCollection) {
        let books = selectedCollectionMemberBooks.filter { movingMemberIDs.contains($0.id) }
        isMoveDestinationPresented = false
        movingMemberIDs.removeAll()
        memberSelection.clear()
        guard !books.isEmpty else { return }
        requestSeriesMove(books, to: destination)
    }

    private func requestSeriesMove(_ books: [LibraryBook], to collection: BookCollection) {
        if books.contains(where: { store.catalog.seriesIDs(for: $0).count > 1 }) {
            seriesConflictConfirmation = SeriesConflictConfirmation(collectionName: collection.name) {
                store.catalog.addBooks(books, to: collection)
            }
        } else {
            store.catalog.addBooks(books, to: collection)
        }
    }

    private func beginMemberDrag(at book: LibraryBook, in collection: BookCollection) -> String {
        if !memberSelection.selectedIDs.contains(book.id) {
            memberSelection.select(book.id, orderedIDs: selectedCollectionMemberBooks.map(\.id))
        }
        let token = UUID().uuidString
        memberDrag = CollectionMemberDrag(
            token: token,
            collectionID: collection.id,
            bookIDs: selectedCollectionMemberBooks.map(\.id).filter { memberSelection.selectedIDs.contains($0) }
        )
        return token
    }

    private func dropMembers(token: String, at index: Int, edge: CollectionMemberDropEdge, in collection: BookCollection) {
        defer { finishMemberDrag() }
        guard let memberDrag, memberDrag.token == token, memberDrag.collectionID == collection.id else { return }
        let orderedIDs = selectedCollectionMemberBooks.map(\.id)
        guard Set(memberDrag.bookIDs).isSubset(of: Set(orderedIDs)) else { return }
        commitMemberOrder(CollectionMemberOrderPlanner.inserted(
            orderedIDs,
            selectedIDs: Set(memberDrag.bookIDs),
            beforeIndex: index + (edge == .bottom ? 1 : 0)
        ), in: collection)
    }

    private func finishMemberDrag() {
        memberDrag = nil
        memberDropTarget = nil
    }

    private func collectionMatchesSearch(_ collection: BookCollection, query: String) -> Bool {
        let searchTexts = [collection.name] + store.catalog.displayBooks(in: collection).flatMap { book in
            [
                book.title,
                book.titleJpn ?? "",
                BookTitleFormatter.displayTitle(for: book, mode: titleDisplayMode)
            ]
        }
        return searchTexts.contains { managementSearchToken($0).contains(query) }
    }

    @ViewBuilder
    private func collectionNameHeader(_ collection: BookCollection) -> some View {
        if editingCollection?.id == collection.id {
            TextField(localizer.string(.collectionName), text: $collectionName)
                .managementGlassSearchField()
                .font(.title2.weight(.semibold))
                .multilineTextAlignment(.center)
                .focused($isCollectionNameFocused)
                .onSubmit(finishCollectionNameEdit)
                .onExitCommand(perform: cancelCollectionNameEdit)
                .onChange(of: isCollectionNameFocused) { _, isFocused in
                    if !isFocused { finishCollectionNameEdit() }
                }
                .task { isCollectionNameFocused = true }
        } else {
            Button {
                collectionName = collection.name
                editingCollection = collection
            } label: {
                Text(collection.name)
                    .font(.title2.weight(.semibold))
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity, alignment: .center)
            }
            .buttonStyle(.plain)
            .help(localizer.string(.collectionName))
            .frame(minHeight: 32)
        }
    }

    private func finishCollectionNameEdit() {
        guard let editingCollection else { return }
        let proposedName = collectionName.trimmingCharacters(in: .whitespacesAndNewlines)
        self.editingCollection = nil
        isCollectionNameFocused = false
        if !proposedName.isEmpty && proposedName != editingCollection.name {
            store.catalog.renameCollection(editingCollection, name: proposedName)
        }
    }

    private func cancelCollectionNameEdit() {
        guard let editingCollection else { return }
        collectionName = editingCollection.name
        self.editingCollection = nil
        isCollectionNameFocused = false
    }
}

struct VersionManagementView: View {
    @Environment(\.undoManager) private var undoManager
    @Bindable var store: OrganizationStore
    let titleDisplayMode: BookTitleDisplayMode
    let isTagTranslationEnabled: Bool
    let isCoverSimilarityVersionRecommendationEnabled: Bool
    let coverSimilarityMaximumDistance: Double
    @Binding var candidatePageSize: Int
    @Binding var isCandidateAreaVisible: Bool
    let showsManagementToolbar: Bool
    let localizer: AppLocalizer
    let onSelect: (LibraryBook) -> Void
    let onOpenReader: (LibraryBook) -> Void

    @State private var listTab: ManagementListTab = .groups
    @State private var candidateTab: ManagementCandidateTab = .candidates
    @State private var isCompactLayout = false
    @State private var isCompactCandidatePresented = false
    @State private var candidateSearch = ""
    @State private var versionGroupListSearch = ""
    @State private var candidatePage = 1
    @State private var candidates: [LibraryBook] = []
    @State private var hasLoadedCandidates = false
    @State private var candidateRefreshTask: Task<Void, Never>?
    @State private var versionGroupTitles: [BookVersionGroup.ID: String] = [:]
    @State private var selectedMemberID: LibraryBook.ID?
    @State private var memberToRemove: LibraryBook?
    @State private var groupToDelete: BookVersionGroup?

    private var selectedGroup: BookVersionGroup? {
        store.catalog.selectedVersionGroupID.flatMap(store.catalog.versionGroup(id:))
    }

    private var filteredVersionGroups: [BookVersionGroup] {
        let query = managementSearchToken(versionGroupListSearch)
        let matches = store.catalog.versionGroups.filter { query.isEmpty || versionGroupMatchesSearch($0, query: query) }
        return ManagementRecommendationOrdering.prioritized(matches) { group in
            group.databaseID.flatMap { store.catalog.addToVersionGroupRecommendationCounts[$0] } ?? 0
        }
    }

    private var candidatePageBooks: [LibraryBook] {
        Pagination.pageItems(candidates, page: candidatePage, pageSize: candidatePageSize)
    }

    private var candidateRowItems: [ManagementCandidateRowItem] {
        candidatePageBooks.map { candidateRowItem(for: $0) }
    }

    private var selectedGroupMemberBooks: [LibraryBook] {
        _ = store.catalog.collectionOrderRevision
        return selectedGroup.map(store.catalog.books(inVersionGroup:)) ?? []
    }

    private var isCandidateAreaHidden: Bool {
        isCompactLayout ? !isCompactCandidatePresented : !isCandidateAreaVisible
    }

    var body: some View {
        splitContent
            .confirmationDialog(
                localizer.string(.remove),
                isPresented: Binding(
                    get: { memberToRemove != nil },
                    set: { if !$0 { memberToRemove = nil } }
                ),
                titleVisibility: .visible
            ) {
                Button(localizer.string(.remove), role: .destructive) {
                    if let memberToRemove { removeMember(memberToRemove) }
                    memberToRemove = nil
                }
                Button(localizer.string(.cancel), role: .cancel) { memberToRemove = nil }
            } message: {
                if let memberToRemove {
                    Text(localizer.removeFinalVersionMemberConfirmation(
                        title: BookTitleFormatter.displayTitle(for: memberToRemove, mode: titleDisplayMode)
                    ))
                }
            }
            .confirmationDialog(
                localizer.string(.deleteVersionGroup),
                isPresented: Binding(
                    get: { groupToDelete != nil },
                    set: { if !$0 { groupToDelete = nil } }
                ),
                titleVisibility: .visible
            ) {
                Button(localizer.string(.deleteVersionGroup), role: .destructive) {
                    if let groupToDelete { store.catalog.deleteVersionGroup(groupToDelete) }
                    groupToDelete = nil
                }
                Button(localizer.string(.cancel), role: .cancel) { groupToDelete = nil }
            } message: {
                if let groupToDelete {
                    Text(localizer.deleteVersionGroupConfirmation(
                        title: groupTitle(groupToDelete),
                        count: store.catalog.books(inVersionGroup: groupToDelete).count
                    ))
                }
            }
            .modifier(
                VersionManagementChrome(
                    navigationTitle: localizer.string(.versionManagement),
                    updateTitle: localizer.string(.updateVersionRecommendations),
                    newGroupTitle: localizer.string(.newVersionGroup),
                    candidateAreaTitle: localizer.string(isCandidateAreaHidden ? .showCandidateArea : .hideCandidateArea),
                    isCandidateAreaHidden: isCandidateAreaHidden,
                    isRefreshing: store.catalog.isRefreshingVersionRecommendations,
                    showsManagementToolbar: showsManagementToolbar,
                    versionGroupListSearch: versionGroupListSearch,
                    selectedVersionGroupID: store.catalog.selectedVersionGroupID,
                    candidateSearch: candidateSearch,
                    candidatePageSize: candidatePageSize,
                    candidatePage: candidatePage,
                    derivedDataRevision: store.catalog.derivedDataRevision,
                    titleDisplayMode: titleDisplayMode,
                    isTagTranslationEnabled: isTagTranslationEnabled,
                    onUpdate: {
                        store.catalog.updateVersionRecommendationsIncrementally(
                            useCoverSimilarity: isCoverSimilarityVersionRecommendationEnabled,
                            maximumCoverDistance: coverSimilarityMaximumDistance,
                            localizer: localizer
                        )
                    },
                    onCreateGroup: {
                        store.catalog.createVersionGroup(with: nil)
                    },
                    onToggleCandidateArea: {
                        if isCompactLayout {
                            isCompactCandidatePresented.toggle()
                        } else {
                            isCandidateAreaVisible.toggle()
                        }
                    },
                    onAppear: handleVersionAppear,
                    onCandidateAreaVisibilityChange: handleVersionCandidateAreaVisibilityChange,
                    onSearchChange: selectFirstFilteredVersionGroupIfNeeded,
                    onSelectionChange: handleSelectedVersionGroupChange,
                    onCandidateSearchChange: handleVersionCandidateSearchChange,
                    onCandidatePageSizeChange: handleVersionCandidatePageSizeChange,
                    onCandidatePageChange: prepareCandidatePage,
                    onDerivedDataChange: handleVersionDerivedDataChange,
                    onTitleDisplayModeChange: handleVersionTitleDisplayModeChange,
                    onTagTranslationChange: prepareCandidatePage,
                    onDisappear: { candidateRefreshTask?.cancel() }
                )
            )
    }

    private var splitContent: some View {
        GeometryReader { geometry in
            HSplitView {
                versionListColumn
                    .frame(minWidth: 270, idealWidth: 310, maxWidth: 360)

                memberColumn
                    .frame(minWidth: 440, idealWidth: 650)

                if isCandidateAreaVisible && geometry.size.width >= 1_120 {
                    candidateColumn
                        .frame(minWidth: 350, idealWidth: 380, maxWidth: 460)
                }
            }
            .padding(10)
            .onAppear { isCompactLayout = geometry.size.width < 1_120 }
            .onChange(of: geometry.size.width) { _, width in
                isCompactLayout = width < 1_120
                if !isCompactLayout { isCompactCandidatePresented = false }
            }
        }
        .sheet(isPresented: $isCompactCandidatePresented) {
            candidateColumn
                .frame(minWidth: 440, minHeight: 560)
        }
    }

    @ViewBuilder
    private var candidateColumn: some View {
        ManagementColumn {
            ManagementGlassTabSwitch(
                selection: $candidateTab,
                title: localizer.string(.candidateArea),
                first: (.candidates, localizer.string(.candidates), candidates.count),
                second: (.recommendations, localizer.string(.managementAddRecommendationsTab),
                    store.catalog.addToSelectedVersionGroupRecommendations.count)
            )
            .frame(maxWidth: 360)
            .frame(maxWidth: .infinity, alignment: .center)

            if candidateTab == .candidates {
                TextField(localizer.string(.searchCandidates), text: $candidateSearch)
                    .managementGlassSearchField()

                if let group = selectedGroup {
                    if !hasLoadedCandidates && candidates.isEmpty {
                        ProgressView()
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else if candidates.isEmpty {
                        ManagementUnavailableView(
                            title: localizer.string(.managementNoCandidates),
                            systemImage: "books.vertical",
                            description: ""
                        )
                    } else {
                        ManagementExpandableScrollList(
                            items: candidateRowItems,
                            context: .init(groupID: group.databaseID, page: candidatePage, query: candidateSearch, pageSize: candidatePageSize)
                        ) { item, expansion, controller in
                            CandidateBookRow(
                                item: item,
                                expansion: expansion,
                                onToggleExpansion: { controller.togglePinned(for: item.id) },
                                localizer: localizer,
                                actionTitle: localizer.string(.addToVersionGroup),
                                systemImage: "plus.circle.fill",
                                action: {
                                    store.catalog.addBook(item.book, toVersionGroup: group)
                                }
                            )
                        } preview: { item in
                            ManagementBookExpandedInfo(book: item.book, localizer: localizer, showsDivider: false, scrollsTags: false)
                        }

                        PaginationControls(
                            page: $candidatePage,
                            pageSize: $candidatePageSize,
                            itemCount: candidates.count,
                            localizer: localizer,
                            usesIconOnlyNavigation: true,
                            allowedPageSizes: AppPreferences.managementCandidatePageSizeValues
                        )
                        .frame(maxWidth: .infinity, alignment: .center)
                    }
                } else {
                    ManagementUnavailableView(
                        title: localizer.string(.selectVersionGroup),
                        systemImage: "square.2.layers.3d",
                        description: localizer.string(.versionManagementDescription)
                    )
                }
            } else if !store.catalog.addToSelectedVersionGroupRecommendations.isEmpty {
                ManagementExpandableScrollList(
                    items: store.catalog.addToSelectedVersionGroupRecommendations,
                    context: .init(groupID: selectedGroup?.databaseID)
                ) { item, expansion, controller in
                    VersionRecommendationBookRow(
                        item: item,
                        expansion: expansion,
                        onToggleExpansion: { controller.togglePinned(for: item.id) },
                        titleDisplayMode: titleDisplayMode,
                        localizer: localizer,
                        acceptTitle: localizer.string(.addToVersionGroup),
                        acceptSystemImage: "plus.circle.fill",
                        isAccepting: store.catalog.isAcceptingVersionRecommendation,
                        onAccept: {
                            store.catalog.acceptAddToSelectedVersionGroupRecommendation(item)
                        },
                        onDismiss: {
                            store.catalog.dismissVersionRecommendation(item)
                        },
                        onSelect: onSelect
                    )
                } preview: { item in
                    if let book = item.books.first {
                        VStack(alignment: .leading, spacing: 8) {
                            ManagementBookExpandedInfo(book: book, localizer: localizer, showsDivider: false, scrollsTags: false)
                            VersionBookComparisonInfoView(
                                book: book, localizer: localizer, showsTitlesAndTags: false, showsFacts: true
                            )
                        }
                    }
                }
            } else if selectedGroup == nil {
                ManagementUnavailableView(
                    title: localizer.string(.selectVersionGroup),
                    systemImage: "square.2.layers.3d",
                    description: localizer.string(.versionManagementDescription)
                )
            } else {
                ManagementUnavailableView(
                    title: localizer.string(.managementNoRecommendations),
                    systemImage: "sparkles",
                    description: ""
                )
            }
        }
    }

    @ViewBuilder
    private var memberColumn: some View {
        if selectedGroup != nil {
            ManagementColumn {
                ManagementScrollList {
                    ForEach(selectedGroupMemberBooks) { book in
                        VersionMemberCard(
                            store: store,
                            book: book,
                            titleDisplayMode: titleDisplayMode,
                            localizer: localizer,
                            isSelected: selectedMemberID == book.id,
                            onSelect: onSelect,
                            onOpenReader: onOpenReader,
                            onSelectMember: { selectedMemberID = book.id },
                            onRemove: { requestMemberRemoval(book) }
                        )
                        .padding(.horizontal, 10)
                    }
                }

                HStack {
                    ManagementMemberCountPill(text: localizer.collectionBookCount(selectedGroupMemberBooks.count))
                    Spacer()
                    if let group = selectedGroup {
                        Button(role: .destructive) { groupToDelete = group } label: {
                            Label(localizer.string(.deleteVersionGroup), systemImage: "trash")
                        }
                        .controlSize(.small)
                        .disabled(group.databaseID.map {
                            store.catalog.savingOrganizationKeys.contains("version:\($0)")
                        } ?? true)
                    }
                }
            }
        } else {
            ManagementUnavailableView(
                title: localizer.string(.selectVersionGroup),
                systemImage: "square.2.layers.3d",
                description: localizer.string(.versionManagementDescription)
            )
        }
    }

    private var versionListColumn: some View {
        ManagementColumn {
            OrganizationSaveStatusView(store: store.catalog, localizer: localizer)

            ManagementGlassTabSwitch(
                selection: $listTab,
                title: localizer.string(.versionManagement),
                first: (.groups, localizer.string(.managementVersionTab), store.catalog.versionGroups.count),
                second: (.recommendations, localizer.string(.managementNewRecommendationsTab),
                    store.catalog.createVersionGroupRecommendations.count)
            )
            .frame(maxWidth: 360)
            .frame(maxWidth: .infinity, alignment: .center)

            if listTab == .groups {
                TextField(localizer.string(.searchVersionGroups), text: $versionGroupListSearch)
                    .managementGlassSearchField()

                if filteredVersionGroups.isEmpty {
                    ManagementUnavailableView(
                        title: localizer.string(store.catalog.versionGroups.isEmpty ? .selectVersionGroup : .managementNoResults),
                        systemImage: "square.2.layers.3d",
                        description: store.catalog.versionGroups.isEmpty
                            ? localizer.string(.versionManagementDescription) : ""
                    )
                } else {
                    List(selection: $store.selectedVersionGroupID) {
                        ForEach(filteredVersionGroups) { group in
                            ManagementGroupListRow(
                                title: versionGroupTitles[group.id] ?? groupTitle(group),
                                memberCountText: nil,
                                recommendationCount: group.databaseID.flatMap {
                                    store.catalog.addToVersionGroupRecommendationCounts[$0]
                                } ?? 0,
                                isSelected: store.catalog.selectedVersionGroupID == group.id,
                                isSaving: group.databaseID.map {
                                    store.catalog.savingOrganizationKeys.contains("version:\($0)")
                                } ?? false,
                                localizer: localizer
                            )
                            .tag(group.id)
                        }
                    }
                    .listStyle(.sidebar)
                    .scrollContentBackground(.hidden)
                }

            } else if !store.catalog.createVersionGroupRecommendations.isEmpty {
                ManagementScrollList {
                    ForEach(store.catalog.createVersionGroupRecommendations) { item in
                        NewVersionGroupRecommendationRow(
                            item: item,
                            titleDisplayMode: titleDisplayMode,
                            localizer: localizer,
                            isAccepting: store.catalog.isAcceptingVersionRecommendation,
                            onAccept: {
                                store.catalog.acceptCreateVersionGroupRecommendation(item)
                            },
                            onDismiss: {
                                store.catalog.dismissVersionRecommendation(item)
                            },
                            onSelect: onSelect
                        )
                    }
                }
            } else {
                ManagementUnavailableView(
                    title: localizer.string(.managementNoRecommendations),
                    systemImage: "sparkles",
                    description: ""
                )
            }
        }
    }

    private func groupTitle(_ group: BookVersionGroup) -> String {
        let members = store.catalog.books(inVersionGroup: group)
        if let primary = members.first(where: \.isPrimaryVersion) ?? members.first {
            return BookTitleFormatter.displayTitle(for: primary, mode: titleDisplayMode)
        }
        return localizer.string(.emptyVersionGroup)
    }

    private func removeMember(_ book: LibraryBook) {
        guard let group = selectedGroup,
              selectedGroupMemberBooks.contains(where: { $0.id == book.id }) else { return }
        let members = selectedGroupMemberBooks
        let primaryID = members.first(where: \.isPrimaryVersion)?.id
        let labels = members.map { ($0, store.catalog.versionLabels(for: $0)) }
        store.catalog.removeBookFromVersionGroup(book)
        if selectedMemberID == book.id { selectedMemberID = nil }
        undoManager?.registerUndo(withTarget: store.catalog) { target in
            if members.count > 2, let currentGroup = target.versionGroup(id: group.id) {
                target.addBook(target.book(id: book.id) ?? book, toVersionGroup: currentGroup)
            } else {
                let ordered = members.sorted { $0.id == primaryID && $1.id != primaryID }
                target.createVersionGroup(with: ordered.map { target.book(id: $0.id) ?? $0 })
            }
            for (member, previousLabels) in labels where !previousLabels.isEmpty {
                target.setVersionLabels(previousLabels, for: target.book(id: member.id) ?? member)
            }
            if let primaryID, let primary = target.book(id: primaryID) {
                target.setPrimaryVersion(primary)
            }
        }
    }

    private func requestMemberRemoval(_ book: LibraryBook) {
        guard selectedGroupMemberBooks.contains(where: { $0.id == book.id }) else { return }
        if selectedGroupMemberBooks.count == 2 {
            memberToRemove = book
        } else {
            removeMember(book)
        }
    }

    private func refreshCandidates() {
        candidateRefreshTask?.cancel()
        guard !isCandidateAreaHidden else {
            unloadCandidates()
            return
        }
        guard let group = selectedGroup else {
            candidates = []
            hasLoadedCandidates = false
            return
        }
        let query = candidateSearch
        candidates = []
        hasLoadedCandidates = false
        candidateRefreshTask = Task { @MainActor in
            let found = await store.catalog.versionCandidateBooksAsync(query: query)
            guard !Task.isCancelled, selectedGroup?.id == group.id, candidateSearch == query else { return }
            candidates = found
            hasLoadedCandidates = true
            candidatePage = Pagination.clampedPage(candidatePage, itemCount: candidates.count, pageSize: candidatePageSize)
            prepareCandidatePage()
        }
    }

    private func scheduleCandidateRefresh() {
        candidateRefreshTask?.cancel()
        candidates = []
        hasLoadedCandidates = false
        guard !isCandidateAreaHidden else {
            return
        }
        candidateRefreshTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(180))
            guard !Task.isCancelled else {
                return
            }
            refreshCandidates()
        }
    }

    private func prepareCandidatePage() {
        guard !isCandidateAreaHidden else {
            return
        }
        store.catalog.prepareCandidateDisplayData(
            for: candidatePageBooks,
            isTagTranslationEnabled: isTagTranslationEnabled
        )
    }

    private func handleVersionCandidateAreaVisibilityChange() {
        if isCandidateAreaHidden {
            unloadCandidates()
        } else {
            refreshCandidates()
        }
    }

    private func unloadCandidates() {
        candidateRefreshTask?.cancel()
        candidates = []
        hasLoadedCandidates = false
        candidatePage = 1
    }

    private func refreshVersionGroupTitles() {
        versionGroupTitles = Dictionary(uniqueKeysWithValues: store.catalog.versionGroups.map { group in
            (group.id, groupTitle(group))
        })
    }

    private func candidateRowItem(for book: LibraryBook) -> ManagementCandidateRowItem {
        ManagementCandidateRowItem(
            book: book,
            displayTitle: BookTitleFormatter.displayTitle(for: book, mode: titleDisplayMode),
            previewTags: Array(store.catalog.candidateDisplayTags(
                for: book,
                isTagTranslationEnabled: isTagTranslationEnabled
            ).prefix(4))
        )
    }

    private func handleVersionAppear() {
        if store.catalog.selectedVersionGroupID == nil {
            store.catalog.selectedVersionGroupID = filteredVersionGroups.first?.id ?? store.catalog.versionGroups.first?.id
        }
        store.catalog.reloadVersionRecommendations()
        refreshVersionGroupTitles()
        refreshCandidates()
    }

    private func handleSelectedVersionGroupChange() {
        listTab = .groups
        selectedMemberID = nil
        memberToRemove = nil
        candidatePage = 1
        store.catalog.reloadAddToSelectedVersionGroupRecommendationsAsync()
        refreshCandidates()
    }

    private func handleVersionCandidateSearchChange() {
        candidatePage = 1
        scheduleCandidateRefresh()
    }

    private func handleVersionCandidatePageSizeChange() {
        candidatePage = 1
        prepareCandidatePage()
    }

    private func handleVersionDerivedDataChange() {
        refreshVersionGroupTitles()
        selectFirstFilteredVersionGroupIfNeeded()
        refreshCandidates()
    }

    private func handleVersionTitleDisplayModeChange() {
        refreshVersionGroupTitles()
        selectFirstFilteredVersionGroupIfNeeded()
    }

    private func selectFirstFilteredVersionGroupIfNeeded() {
        guard !managementSearchToken(versionGroupListSearch).isEmpty else {
            return
        }
        if let selectedID = store.catalog.selectedVersionGroupID,
           filteredVersionGroups.contains(where: { $0.id == selectedID }) {
            return
        }
        store.catalog.selectedVersionGroupID = filteredVersionGroups.first?.id
    }

    private func versionGroupMatchesSearch(_ group: BookVersionGroup, query: String) -> Bool {
        let members = store.catalog.books(inVersionGroup: group)
        let searchTexts = [versionGroupTitles[group.id] ?? groupTitle(group)] + members.flatMap { book in
            [
                book.title,
                book.titleJpn ?? "",
                BookTitleFormatter.displayTitle(for: book, mode: titleDisplayMode)
            ]
        }
        return searchTexts.contains { managementSearchToken($0).contains(query) }
    }
}

private func managementSearchToken(_ text: String) -> String {
    text
        .folding(options: [.caseInsensitive, .widthInsensitive, .diacriticInsensitive], locale: nil)
        .replacingOccurrences(of: #"[\p{P}\p{S}\s]+"#, with: "", options: .regularExpression)
        .trimmingCharacters(in: .whitespacesAndNewlines)
}

private enum ManagementListTab: Hashable {
    case groups
    case recommendations
}

private enum ManagementCandidateTab: Hashable {
    case candidates
    case recommendations
}

private struct VersionManagementChrome: ViewModifier {
    let navigationTitle: String
    let updateTitle: String
    let newGroupTitle: String
    let candidateAreaTitle: String
    let isCandidateAreaHidden: Bool
    let isRefreshing: Bool
    let showsManagementToolbar: Bool
    let versionGroupListSearch: String
    let selectedVersionGroupID: BookVersionGroup.ID?
    let candidateSearch: String
    let candidatePageSize: Int
    let candidatePage: Int
    let derivedDataRevision: Int
    let titleDisplayMode: BookTitleDisplayMode
    let isTagTranslationEnabled: Bool
    let onUpdate: () -> Void
    let onCreateGroup: () -> Void
    let onToggleCandidateArea: () -> Void
    let onAppear: () -> Void
    let onCandidateAreaVisibilityChange: () -> Void
    let onSearchChange: () -> Void
    let onSelectionChange: () -> Void
    let onCandidateSearchChange: () -> Void
    let onCandidatePageSizeChange: () -> Void
    let onCandidatePageChange: () -> Void
    let onDerivedDataChange: () -> Void
    let onTitleDisplayModeChange: () -> Void
    let onTagTranslationChange: () -> Void
    let onDisappear: () -> Void

    func body(content: Content) -> some View {
        content
            .managementPageToolbar(
                navigationTitle: navigationTitle,
                updateTitle: updateTitle,
                newTitle: newGroupTitle,
                candidateAreaTitle: candidateAreaTitle,
                isCandidateAreaHidden: isCandidateAreaHidden,
                isRefreshing: isRefreshing,
                showsActions: showsManagementToolbar,
                onUpdate: onUpdate,
                onCreate: onCreateGroup,
                onToggleCandidateArea: onToggleCandidateArea
            )
            .onAppear(perform: onAppear)
            .onChange(of: isCandidateAreaHidden) { _, _ in onCandidateAreaVisibilityChange() }
            .onChange(of: versionGroupListSearch) { _, _ in onSearchChange() }
            .onChange(of: selectedVersionGroupID) { _, _ in onSelectionChange() }
            .onChange(of: candidateSearch) { _, _ in onCandidateSearchChange() }
            .onChange(of: candidatePageSize) { _, _ in onCandidatePageSizeChange() }
            .onChange(of: candidatePage) { _, _ in onCandidatePageChange() }
            .onChange(of: derivedDataRevision) { _, _ in onDerivedDataChange() }
            .onChange(of: titleDisplayMode) { _, _ in onTitleDisplayModeChange() }
            .onChange(of: isTagTranslationEnabled) { _, _ in onTagTranslationChange() }
            .onDisappear(perform: onDisappear)
    }
}

private struct ManagementPageToolbar: ViewModifier {
    let navigationTitle: String
    let updateTitle: String
    let newTitle: String
    let candidateAreaTitle: String
    let isCandidateAreaHidden: Bool
    let isRefreshing: Bool
    let showsActions: Bool
    let onUpdate: () -> Void
    let onCreate: () -> Void
    let onToggleCandidateArea: () -> Void

    func body(content: Content) -> some View {
        content
            .navigationTitle(navigationTitle)
            .toolbar {
                if showsActions {
                    ToolbarItemGroup {
                        Button(action: onUpdate) {
                            Label(updateTitle, systemImage: "sparkles")
                        }
                        .disabled(isRefreshing)
                        .help(updateTitle)

                        Button(action: onCreate) {
                            Label(newTitle, systemImage: "plus")
                        }
                        .help(newTitle)

                        Button(action: onToggleCandidateArea) {
                            Image(systemName: isCandidateAreaHidden ? "sidebar.trailing" : "sidebar.right")
                        }
                        .accessibilityLabel(candidateAreaTitle)
                        .help(candidateAreaTitle)
                    }
                }
            }
    }
}

private struct ManagementGlassTabSwitch<Selection: Hashable>: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.nyaehAccentColor) private var accentColor

    @Binding var selection: Selection
    let title: String
    let first: (Selection, String, Int)
    let second: (Selection, String, Int)

    var body: some View {
        HStack(spacing: 3) {
            tab(first.0, title: first.1, count: first.2)
            tab(second.0, title: second.1, count: second.2)
        }
        .padding(3)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(title)
    }

    private func tab(_ tab: Selection, title: String, count: Int) -> some View {
        let isSelected = selection == tab
        return Button {
            if reduceMotion {
                selection = tab
            } else {
                withAnimation(.easeInOut(duration: 0.18)) { selection = tab }
            }
        } label: {
            Text("\(title) \(count)")
                .font(.subheadline.weight(isSelected ? .semibold : .regular))
                .lineLimit(1)
                .minimumScaleFactor(0.85)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 7)
                .padding(.vertical, 7)
                .background {
                    if isSelected {
                        RoundedRectangle(cornerRadius: 11, style: .continuous)
                            .fill(accentColor.opacity(0.12))
                            .overlay {
                                RoundedRectangle(cornerRadius: 11, style: .continuous)
                                    .strokeBorder(accentColor.opacity(0.18), lineWidth: 0.5)
                            }
                    }
                }
                .contentShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

private extension View {
    func managementGlassSearchField() -> some View {
        textFieldStyle(.plain)
            .padding(.horizontal, 11)
            .padding(.vertical, 8)
            .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

private struct ManagementColumn<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            content
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

private struct ManagementMemberCountPill: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(Color.primary.opacity(0.07), in: Capsule())
            .overlay {
                Capsule().strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5)
            }
    }
}

private struct ManagementGroupListRow: View {
    let title: String
    let memberCountText: String?
    let recommendationCount: Int
    let isSelected: Bool
    let isSaving: Bool
    let localizer: AppLocalizer

    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 6) {
            Text(title)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)

            if recommendationCount > 0 {
                ManagementSuggestionGlassBadge(
                    count: recommendationCount,
                    isEmphasized: isHovered || isSelected,
                    localizer: localizer
                )
            }

            if let memberCountText {
                Text(memberCountText)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .fixedSize()
            }

            if isSaving {
                ProgressView().controlSize(.mini)
            }
        }
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
        .listRowBackground(hoverBackground)
        .animation(.easeInOut(duration: 0.16), value: isHovered)
    }

    @ViewBuilder
    private var hoverBackground: some View {
        if isHovered && !isSelected {
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .fill(Color.primary.opacity(0.045))
                .padding(.horizontal, 10)
        }
    }
}

private struct ManagementSuggestionGlassBadge: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast

    let count: Int
    let isEmphasized: Bool
    let localizer: AppLocalizer

    @State private var isShimmering = false

    private var description: String {
        "\(localizer.string(.managementAddRecommendationsTab)) \(count)"
    }

    private var colors: [Color] {
        [
            .purple.opacity(0.28),
            .pink.opacity(0.24),
            .blue.opacity(0.27),
            .cyan.opacity(0.24),
            .purple.opacity(0.28)
        ]
    }

    var body: some View {
        Group {
            if reduceTransparency || contrast == .increased {
                badgeText
                    .background(Color(nsColor: .controlBackgroundColor), in: Capsule())
            } else {
                badgeText
                    .glassEffect(.clear, in: Capsule())
            }
        }
        .overlay {
            if reduceTransparency || contrast == .increased {
                Capsule()
                    .strokeBorder(Color.primary.opacity(0.58), lineWidth: isEmphasized ? 1.3 : 1)
            } else {
                Capsule()
                    .strokeBorder(
                        AngularGradient(
                            colors: colors,
                            center: .center,
                            angle: .degrees(isShimmering ? 360 : 0)
                        ),
                        lineWidth: isEmphasized ? 1 : 0.65
                    )
            }
        }
        .shadow(color: .purple.opacity(isEmphasized && !reduceTransparency ? 0.06 : 0), radius: 2)
        .accessibilityLabel(description)
        .help(description)
        .onAppear(perform: updateShimmer)
        .onChange(of: reduceMotion) { _, _ in updateShimmer() }
        .onChange(of: reduceTransparency) { _, _ in updateShimmer() }
        .onChange(of: contrast) { _, _ in updateShimmer() }
    }

    private var badgeText: some View {
        Image(systemName: "sparkles")
            .font(.system(size: 11))
            .foregroundStyle(.primary)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
    }

    private func updateShimmer() {
        let shouldShimmer = !reduceMotion && !reduceTransparency && contrast != .increased
        guard isShimmering != shouldShimmer else { return }
        if shouldShimmer {
            withAnimation(.linear(duration: 16).repeatForever(autoreverses: false)) {
                isShimmering = true
            }
        } else {
            withAnimation(nil) {
                isShimmering = false
            }
        }
    }
}

private struct ManagementScrollList<Content: View>: View {
    var trailingInset: CGFloat = 0
    @ViewBuilder var content: Content

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 8) {
                content
            }
            .padding(.vertical, 2)
            .padding(.trailing, trailingInset)
        }
    }
}

private struct ManagementUnavailableView: View {
    let title: String
    let systemImage: String
    let description: String

    var body: some View {
        Group {
            if description.isEmpty {
                ContentUnavailableView(title, systemImage: systemImage)
            } else {
                ContentUnavailableView(title, systemImage: systemImage, description: Text(description))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct ManagementCandidateRowItem: Identifiable {
    let book: LibraryBook
    let displayTitle: String
    let previewTags: [TagDisplaySummary]

    var id: LibraryBook.ID {
        book.id
    }
}

private struct CandidateBookRow: View {
    let item: ManagementCandidateRowItem
    let expansion: ManagementCardExpansionState
    let onToggleExpansion: () -> Void
    let localizer: AppLocalizer
    let actionTitle: String
    let systemImage: String
    let action: () -> Void

    @State private var isTitleCopied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: 10) {
                BookCoverThumbnail(book: item.book, width: 42, height: 58, cornerRadius: 6)

                VStack(alignment: .leading, spacing: 5) {
                    Button {
                        copyTitle()
                    } label: {
                        Text(item.displayTitle)
                            .font(.headline)
                            .lineLimit(1)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(localizer.string(.copyTitle))

                    if !item.previewTags.isEmpty {
                        CandidateTagPreview(tags: item.previewTags)
                    }
                }

                ManagementDisclosureButton(isExpanded: expansion.isExpanded, isPinned: expansion.isPinned,
                                           localizer: localizer) {
                    onToggleExpansion()
                }

                Button(action: action) {
                    Image(systemName: systemImage)
                        .accessibilityLabel(actionTitle)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .frame(width: 30, height: 28)
                .help(actionTitle)
            }

            ManagementCardExpandedContent(isExpanded: expansion.isExpanded) {
                ManagementBookExpandedInfo(book: item.book, localizer: localizer)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(minHeight: 74)
        .frame(maxWidth: .infinity, alignment: .leading)
        .managementListRow()
        .contentShape(RoundedRectangle(cornerRadius: 8))
        .overlay(alignment: .topTrailing) {
            if isTitleCopied {
                Label(localizer.string(.titleCopied), systemImage: "checkmark")
                    .font(.caption2)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(Color(nsColor: .controlBackgroundColor), in: Capsule())
                    .overlay {
                        Capsule()
                            .stroke(Color(nsColor: .separatorColor).opacity(0.55), lineWidth: 0.5)
                    }
                    .padding(8)
                    .transition(.opacity)
            }
        }
    }

    private func copyTitle() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(item.displayTitle, forType: .string)
        withAnimation(.easeOut(duration: 0.12)) {
            isTitleCopied = true
        }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.2))
            withAnimation(.easeOut(duration: 0.12)) {
                isTitleCopied = false
            }
        }
    }
}

private struct ManagementDisclosureButton: View {
    let isExpanded: Bool
    let isPinned: Bool
    let localizer: AppLocalizer
    let action: () -> Void

    private var title: String {
        if isPinned { return localizer.string(.collapseSection) }
        if isExpanded { return localizer.string(.managementPinExpanded) }
        return localizer.string(.expandSection)
    }

    var body: some View {
        Button(action: action) {
            Image(systemName: isPinned ? "pin.fill" : (isExpanded ? "pin" : "chevron.right"))
                .frame(width: 18, height: 18)
        }
        .buttonStyle(.borderless)
        .controlSize(.small)
        .accessibilityLabel(title)
        .help(title)
    }
}

private struct ManagementBookExpandedInfo: View {
    let book: LibraryBook
    let localizer: AppLocalizer
    var showsDivider = true
    var scrollsTags = true

    private var japaneseTitle: String? {
        guard let title = book.titleJpn?.trimmingCharacters(in: .whitespacesAndNewlines),
              !title.isEmpty, title != book.title else { return nil }
        return title
    }

    private var tags: [Tag] {
        var seen = Set<String>()
        return TagParser.parseJSON(book.tags).filter { tag in
            seen.insert(tag.rawValue.folding(options: [.caseInsensitive, .widthInsensitive], locale: nil)).inserted
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if showsDivider { Divider() }

            expandedTitle(localizer.string(.bookTitleOriginal), value: book.title)
            if let japaneseTitle {
                expandedTitle(localizer.string(.bookTitleJapanese), value: japaneseTitle)
            }

            if !tags.isEmpty {
                Text(localizer.string(.tags))
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)

                if scrollsTags {
                    ScrollView { tagPills }
                        .frame(maxHeight: 170)
                } else {
                    tagPills
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var tagPills: some View {
        FlowLayout(spacing: 5, lineSpacing: 5) {
            ForEach(tags, id: \.rawValue) { tag in
                Text(tag.rawValue)
                    .font(.caption2)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(Color(nsColor: .quaternaryLabelColor).opacity(0.16), in: Capsule())
            }
        }
    }

    private func expandedTitle(_ label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.caption)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        }
    }
}

private struct NewCollectionRecommendationRow: View {
    let item: CollectionRecommendationDisplayItem
    let titleDisplayMode: BookTitleDisplayMode
    let localizer: AppLocalizer
    let isAccepting: Bool
    let onAccept: () -> Void
    let onDismiss: () -> Void
    let onSelect: (LibraryBook) -> Void

    @State private var isExpanded = false

    private var representativeBook: LibraryBook? {
        item.books.first
    }

    private var title: String {
        guard let representativeBook else {
            return localizer.string(.newCollection)
        }
        return BookTitleFormatter.displayTitle(for: representativeBook, mode: titleDisplayMode)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: 10) {
                if let representativeBook {
                    BookCoverThumbnail(book: representativeBook, width: 36, height: 50, cornerRadius: 5)
                        .onTapGesture(perform: toggleExpanded)
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(2)

                    Text(localizer.collectionBookCount(item.books.count))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .contentShape(Rectangle())
                .onTapGesture(perform: toggleExpanded)

                Spacer()

                Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(width: 16)

                HStack(spacing: 8) {
                    Button(action: onAccept) {
                        Image(systemName: "plus.square.on.square")
                            .accessibilityLabel(localizer.string(.newCollection))
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(isAccepting)
                    .help(localizer.string(.newCollection))

                    Button(role: .destructive, action: onDismiss) {
                        Image(systemName: "xmark")
                            .accessibilityLabel(localizer.string(.dismissRecommendation))
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .help(localizer.string(.dismissRecommendation))
                }
            }

            CollectionRecommendationReasonText(item: item, localizer: localizer)

            if isExpanded {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(item.books) { book in
                        CollectionRecommendationMemberRow(
                            book: book,
                            titleDisplayMode: titleDisplayMode,
                            implicitFirstVolume: item.recommendation.reasons.contains("implicitFirstVolume")
                                && SeriesTitleAnalysis(title: book.titleJpn ?? book.title)?.isCleanUnnumbered == true,
                            localizer: localizer,
                            onSelect: onSelect
                        )
                    }
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .managementListRow(padding: 10)
    }

    private func toggleExpanded() {
        withAnimation(.snappy(duration: 0.18)) {
            isExpanded.toggle()
        }
    }
}

private struct CollectionRecommendationBookRow: View {
    let item: CollectionRecommendationDisplayItem
    let expansion: ManagementCardExpansionState
    let onToggleExpansion: () -> Void
    let titleDisplayMode: BookTitleDisplayMode
    let localizer: AppLocalizer
    let acceptTitle: String
    let acceptSystemImage: String
    let isAccepting: Bool
    let onAccept: () -> Void
    let onDismiss: () -> Void
    let onSelect: (LibraryBook) -> Void

    private var book: LibraryBook? {
        item.books.first
    }

    var body: some View {
        if let book {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .top, spacing: 12) {
                    ManagementCoverButton(
                        book: book,
                        width: 52,
                        height: 72,
                        cornerRadius: 6,
                        onSelect: onSelect
                    )

                    VStack(alignment: .leading, spacing: 8) {
                        Button {
                            onSelect(book)
                        } label: {
                            Text(BookTitleFormatter.displayTitle(for: book, mode: titleDisplayMode))
                                .font(.headline)
                                .lineLimit(2)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .buttonStyle(.plain)
                        .help(localizer.string(.details))

                        CollectionRecommendationReasonText(item: item, localizer: localizer)
                    }

                    VStack(spacing: 8) {
                        ManagementDisclosureButton(isExpanded: expansion.isExpanded, isPinned: expansion.isPinned,
                                                   localizer: localizer) {
                            onToggleExpansion()
                        }

                        Button(action: onAccept) {
                            Image(systemName: acceptSystemImage)
                                .accessibilityLabel(acceptTitle)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .frame(width: 30, height: 28)
                        .disabled(isAccepting)
                        .help(acceptTitle)

                        Button(role: .destructive, action: onDismiss) {
                            Image(systemName: "xmark")
                                .accessibilityLabel(localizer.string(.dismissRecommendation))
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .frame(width: 30, height: 28)
                        .help(localizer.string(.dismissRecommendation))
                    }
                }

                ManagementCardExpandedContent(isExpanded: expansion.isExpanded) {
                    ManagementBookExpandedInfo(book: book, localizer: localizer)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .frame(minHeight: 108)
            .frame(maxWidth: .infinity, alignment: .leading)
            .managementListRow()
        }
    }
}

private struct CollectionRecommendationMemberRow: View {
    let book: LibraryBook
    let titleDisplayMode: BookTitleDisplayMode
    let implicitFirstVolume: Bool
    let localizer: AppLocalizer
    let onSelect: (LibraryBook) -> Void

    var body: some View {
        HStack(spacing: 8) {
            Button {
                onSelect(book)
            } label: {
                BookCoverThumbnail(book: book, width: 28, height: 40, cornerRadius: 4)
            }
            .buttonStyle(.plain)

            Text(BookTitleFormatter.displayTitle(for: book, mode: titleDisplayMode))
                .font(.caption)
                .lineLimit(1)

            Spacer(minLength: 0)

            if implicitFirstVolume {
                Text(localizer.implicitFirstVolumeOrdinalLabel())
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(.quaternary, in: Capsule())
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .background(Color(nsColor: .quaternaryLabelColor).opacity(0.12), in: RoundedRectangle(cornerRadius: 6))
    }
}

private struct CollectionRecommendationReasonText: View {
    let item: CollectionRecommendationDisplayItem
    let localizer: AppLocalizer

    var body: some View {
        Text(reasonText)
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(2)
    }

    private var reasonText: String {
        let reasons = item.recommendation.reasons
            .map { localizer.collectionRecommendationReason($0) }
            .joined(separator: ", ")
        return "\(item.recommendation.score) · \(reasons)"
    }
}

private struct NewVersionGroupRecommendationRow: View {
    let item: VersionRecommendationDisplayItem
    let titleDisplayMode: BookTitleDisplayMode
    let localizer: AppLocalizer
    let isAccepting: Bool
    let onAccept: () -> Void
    let onDismiss: () -> Void
    let onSelect: (LibraryBook) -> Void

    @State private var isExpanded = false

    private var representativeBook: LibraryBook? {
        item.books.first
    }

    private var title: String {
        guard let representativeBook else {
            return localizer.string(.newVersionGroup)
        }
        return BookTitleFormatter.displayTitle(for: representativeBook, mode: titleDisplayMode)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: 10) {
                if let representativeBook {
                    BookCoverThumbnail(book: representativeBook, width: 36, height: 50, cornerRadius: 5)
                        .onTapGesture(perform: toggleExpanded)
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(2)

                    Text(localizer.versionBookCount(item.books.count))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .contentShape(Rectangle())
                .onTapGesture(perform: toggleExpanded)

                Spacer()

                Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(width: 16)

                Button(action: onAccept) {
                    Image(systemName: "plus.square.on.square")
                        .accessibilityLabel(localizer.string(.createRecommendedVersionGroup))
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(isAccepting)
                .help(localizer.string(.createRecommendedVersionGroup))

                Button(role: .destructive, action: onDismiss) {
                    Image(systemName: "xmark")
                        .accessibilityLabel(localizer.string(.dismissRecommendation))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help(localizer.string(.dismissRecommendation))
            }

            RecommendationReasonText(item: item, localizer: localizer)

            if isExpanded {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(item.books) { book in
                        RecommendationMemberRow(
                            book: book,
                            titleDisplayMode: titleDisplayMode,
                            localizer: localizer,
                            onSelect: onSelect
                        )
                    }
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .managementListRow(padding: 10)
    }

    private func toggleExpanded() {
        withAnimation(.snappy(duration: 0.18)) {
            isExpanded.toggle()
        }
    }
}

private struct VersionRecommendationBookRow: View {
    let item: VersionRecommendationDisplayItem
    let expansion: ManagementCardExpansionState
    let onToggleExpansion: () -> Void
    let titleDisplayMode: BookTitleDisplayMode
    let localizer: AppLocalizer
    let acceptTitle: String
    let acceptSystemImage: String
    let isAccepting: Bool
    let onAccept: () -> Void
    let onDismiss: () -> Void
    let onSelect: (LibraryBook) -> Void

    private var book: LibraryBook? {
        item.books.first
    }

    var body: some View {
        if let book {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .top, spacing: 12) {
                    ManagementCoverButton(
                        book: book,
                        width: 52,
                        height: 72,
                        cornerRadius: 6,
                        onSelect: onSelect
                    )

                    VStack(alignment: .leading, spacing: 8) {
                        Button {
                            onSelect(book)
                        } label: {
                            Text(BookTitleFormatter.displayTitle(for: book, mode: titleDisplayMode))
                                .font(.headline)
                                .lineLimit(2)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .buttonStyle(.plain)
                        .help(localizer.string(.details))

                        RecommendationReasonText(item: item, localizer: localizer)

                        SuggestedVersionLabelPills(
                            labels: VersionLabelClassifier.labels(for: book),
                            localizer: localizer
                        )
                    }

                    VStack(spacing: 8) {
                        ManagementDisclosureButton(isExpanded: expansion.isExpanded, isPinned: expansion.isPinned, localizer: localizer) {
                            onToggleExpansion()
                        }

                        Button(action: onAccept) {
                            Image(systemName: acceptSystemImage)
                                .accessibilityLabel(acceptTitle)
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .frame(width: 30, height: 28)
                        .disabled(isAccepting)
                        .help(acceptTitle)

                        Button(role: .destructive, action: onDismiss) {
                            Image(systemName: "xmark")
                                .accessibilityLabel(localizer.string(.dismissRecommendation))
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .frame(width: 30, height: 28)
                        .help(localizer.string(.dismissRecommendation))
                    }
                }

                ManagementCardExpandedContent(isExpanded: expansion.isExpanded) {
                    VStack(alignment: .leading, spacing: 8) {
                        ManagementBookExpandedInfo(book: book, localizer: localizer)
                        VersionBookComparisonInfoView(
                            book: book,
                            localizer: localizer,
                            showsTitlesAndTags: false,
                            showsFacts: true
                        )
                    }
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .frame(minHeight: 120)
            .frame(maxWidth: .infinity, alignment: .leading)
            .managementListRow()
        }
    }
}

private struct RecommendationMemberRow: View {
    let book: LibraryBook
    let titleDisplayMode: BookTitleDisplayMode
    let localizer: AppLocalizer
    let onSelect: (LibraryBook) -> Void

    var body: some View {
        HStack(spacing: 8) {
            Button {
                onSelect(book)
            } label: {
                BookCoverThumbnail(book: book, width: 28, height: 40, cornerRadius: 4)
            }
            .buttonStyle(.plain)

            VStack(alignment: .leading, spacing: 4) {
                Text(BookTitleFormatter.displayTitle(for: book, mode: titleDisplayMode))
                    .font(.caption)
                    .lineLimit(1)

                SuggestedVersionLabelPills(
                    labels: VersionLabelClassifier.labels(for: book),
                    localizer: localizer
                )
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .background(Color(nsColor: .quaternaryLabelColor).opacity(0.12), in: RoundedRectangle(cornerRadius: 6))
    }
}

private struct RecommendationReasonText: View {
    let item: VersionRecommendationDisplayItem
    let localizer: AppLocalizer

    var body: some View {
        Text(reasonText)
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(2)
    }

    private var reasonText: String {
        let reasons = item.recommendation.reasons
            .map { localizer.versionRecommendationReason($0) }
            .joined(separator: ", ")
        return "\(item.recommendation.score) · \(reasons)"
    }
}

private struct SuggestedVersionLabelPills: View {
    let labels: [String]
    let localizer: AppLocalizer

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(localizer.string(.recommendedVersionLabels))
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)

            FlowLayout(spacing: 5, lineSpacing: 5) {
                ForEach(labels, id: \.self) { label in
                    Text(label)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(Color(nsColor: .quaternaryLabelColor).opacity(0.14), in: Capsule())
                }
            }
        }
    }
}

private struct VersionBookComparisonInfoView: View {
    let book: LibraryBook
    let localizer: AppLocalizer
    let showsTitlesAndTags: Bool
    let showsFacts: Bool

    private static let namespacePriority: [String: Int] = [
        "artist": 0,
        "group": 1,
        "parody": 2,
        "character": 3
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if showsTitlesAndTags {
                VStack(alignment: .leading, spacing: 4) {
                    ComparisonTextRow(
                        label: localizer.string(.bookTitleOriginal),
                        value: displayText(book.title, fallback: localizer.string(.noValue))
                    )
                    ComparisonTextRow(
                        label: localizer.string(.bookTitleJapanese),
                        value: displayText(book.titleJpn, fallback: localizer.string(.noValue))
                    )
                }
            }

            if showsFacts {
                FlowLayout(spacing: 6, lineSpacing: 6) {
                    ComparisonInfoPill(label: localizer.string(.appLanguage), value: languageText)
                    ComparisonInfoPill(label: localizer.string(.translated), value: booleanText(book.isTranslated))
                    ComparisonInfoPill(label: localizer.string(.statusCensorshipShort), value: censorshipText)
                    ComparisonInfoPill(label: localizer.string(.statusColorShort), value: booleanText(book.isFullColor))
                    ComparisonInfoPill(label: localizer.string(.pages), value: pageText)
                }
            }

            if showsTitlesAndTags && !sortedTags.isEmpty {
                VStack(alignment: .leading, spacing: 5) {
                    Text(localizer.string(.tags))
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)

                    FlowLayout(spacing: 5, lineSpacing: 5) {
                        ForEach(sortedTags, id: \.rawValue) { tag in
                            Text(tag.rawValue)
                                .font(.caption2)
                                .fixedSize(horizontal: false, vertical: true)
                                .frame(maxWidth: 220)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 3)
                                .background(Color(nsColor: .quaternaryLabelColor).opacity(0.16), in: Capsule())
                        }
                    }
                }
            }
        }
    }

    private var languageText: String {
        let trimmed = book.languageCode.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty || trimmed == "unknown" ? localizer.string(.unknown) : trimmed.capitalized
    }

    private var censorshipText: String {
        localizer.versionCensorshipDescription(book.censorship)
    }

    private var pageText: String {
        let localCount = book.fileCount.map(String.init)
        let remotePages = book.pages.map(String.init)
        switch (localCount, remotePages) {
        case let (localCount?, remotePages?):
            return "\(localCount) / \(remotePages)"
        case let (localCount?, nil):
            return localCount
        case let (nil, remotePages?):
            return remotePages
        case (nil, nil):
            return localizer.string(.unknown)
        }
    }

    private var sortedTags: [Tag] {
        TagParser.parseJSON(book.tags).sorted { lhs, rhs in
            let lhsPriority = Self.namespacePriority[lhs.namespace] ?? 99
            let rhsPriority = Self.namespacePriority[rhs.namespace] ?? 99
            if lhsPriority != rhsPriority {
                return lhsPriority < rhsPriority
            }
            if lhs.namespace != rhs.namespace {
                return lhs.namespace < rhs.namespace
            }
            return lhs.name < rhs.name
        }
    }

    private func displayText(_ value: String?, fallback: String) -> String {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? fallback : trimmed
    }

    private func booleanText(_ value: Bool) -> String {
        localizer.string(value ? .yes : .noValue)
    }
}

private struct ComparisonTextRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(label)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(width: 64, alignment: .leading)

            Text(value)
                .font(.caption)
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct ComparisonInfoPill: View {
    let label: String
    let value: String

    var body: some View {
        HStack(spacing: 4) {
            Text(label)
                .foregroundStyle(.secondary)
            Text(value)
                .foregroundStyle(.primary)
        }
        .font(.caption2)
        .lineLimit(1)
        .padding(.horizontal, 7)
        .padding(.vertical, 4)
        .background(Color(nsColor: .quaternaryLabelColor).opacity(0.14), in: Capsule())
    }
}

private struct CollectionMemberDrag {
    let token: String
    let collectionID: BookCollection.ID
    let bookIDs: [LibraryBook.ID]
}

private enum CollectionMemberDropEdge: Equatable {
    case top
    case bottom
}

private struct CollectionMemberDropTarget {
    let bookID: LibraryBook.ID
    let edge: CollectionMemberDropEdge
}

private struct CollectionMemberCard: View {
    @Bindable var store: OrganizationStore
    let book: LibraryBook
    let number: Int
    let isSelected: Bool
    let isDragging: Bool
    let dropEdge: CollectionMemberDropEdge?
    let titleDisplayMode: BookTitleDisplayMode
    let localizer: AppLocalizer
    let onSelect: (LibraryBook) -> Void
    let onSelectRow: () -> Void
    let onSecondaryClick: () -> Void
    let contextCount: Int
    let onMove: (CollectionMoveDirection) -> Void
    let onMoveToBoundary: (Bool) -> Void
    let onMoveToCollection: () -> Void
    let onRemove: () -> Void
    let onRemoveOne: () -> Void
    let onDragStarted: () -> String
    let onDragEnded: () -> Void
    let onDropHover: (CollectionMemberDropEdge?) -> Void
    let onDrop: (String, CollectionMemberDropEdge) -> Void

    @State private var isHovered = false
    @State private var isFinderUnavailable = false
    @FocusState private var isFocused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.browsingFocusEffectHidden) private var browsingFocusEffectHidden

    private var showsControls: Bool { isHovered || isFocused || isDragging }

    private var details: [String] {
        var values: [String] = []
        let language = book.languageCode.trimmingCharacters(in: .whitespacesAndNewlines)
        if !language.isEmpty && language.lowercased() != "unknown" { values.append(language.capitalized) }
        if let pages = [book.pages, book.fileCount].compactMap({ $0 }).first(where: { $0 > 0 }) {
            values.append("\(pages) \(localizer.string(.pages))")
        }
        if let groupID = book.versionGroupID,
           let group = store.catalog.versionGroup(id: String(groupID)) {
            let count = store.catalog.books(inVersionGroup: group).count
            if count > 1 { values.append(localizer.versionBookCount(count)) }
        }
        return values
    }

    var body: some View {
        HStack(spacing: 6) {
            Text("\(number)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.tertiary)
                .frame(width: 30, alignment: .trailing)
                .accessibilityLabel("\(number)")

            HStack(spacing: 10) {
                Image(systemName: "line.3.horizontal")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 20, height: 30)
                    .contentShape(Rectangle())
                    .opacity(showsControls ? 1 : 0)
                    .allowsHitTesting(showsControls)
                    .onDrag {
                        NSItemProvider(object: onDragStarted() as NSString)
                    }
                    .onDragSessionUpdated { session in
                        if case .ended = session.phase { onDragEnded() }
                    }
                    .accessibilityLabel(localizer.string(.managementDragToSort))
                    .help(localizer.string(.managementDragToSort))

                ManagementCoverButton(book: book, width: 72, height: 100, cornerRadius: 7, onSelect: onSelect)
                    .overlay(alignment: .topTrailing) {
                        if isSelected { ManagementMemberSelectionMark().padding(4) }
                    }

                VStack(alignment: .leading, spacing: 6) {
                    BookTitleCopyButton(
                        book: book,
                        titleDisplayMode: titleDisplayMode,
                        localizer: localizer,
                        showsFullTitleHelp: true
                    )
                    if !details.isEmpty {
                        Text(details.joined(separator: " · "))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                if let id = book.databaseID,
                   store.catalog.savingOrganizationKeys.contains("book:\(id)") {
                    ProgressView().controlSize(.mini)
                }

                HStack(spacing: 6) {
                    Menu {
                        Button(localizer.string(.details)) { onSelect(book) }
                        Button(localizer.string(.managementShowInFinder)) { revealInFinder() }
                        Divider()
                        Button(localizer.string(.managementMoveToTop)) { onMoveToBoundary(true) }
                        Button(localizer.string(.managementMoveToBottom)) { onMoveToBoundary(false) }
                        Button(localizer.string(.managementMoveToCollection), action: onMoveToCollection)
                        Divider()
                        Button(role: .destructive, action: onRemove) {
                            Text("\(localizer.string(.managementRemoveFromCollection)) · \(localizer.selectedBookCount(contextCount))")
                        }
                    } label: {
                        Image(systemName: "ellipsis")
                            .foregroundStyle(.secondary)
                            .frame(width: 30, height: 30)
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .accessibilityLabel(localizer.string(.managementMoreActions))
                    .help(localizer.string(.managementMoreActions))

                    Button(role: .destructive, action: onRemoveOne) {
                        Image(systemName: "minus.circle")
                            .foregroundStyle(.red)
                            .frame(width: 30, height: 30)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(localizer.string(.remove))
                    .help(localizer.string(.remove))
                }
                .opacity(showsControls ? 1 : 0)
                .allowsHitTesting(showsControls)
            }
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.16), value: showsControls)
            .padding(.horizontal, 10)
            .frame(height: 120)
            .frame(maxWidth: .infinity, alignment: .leading)
            .managementListRow(isSelected: isSelected)
            .overlay {
                if let dropEdge {
                    VStack(spacing: 0) {
                        if dropEdge == .bottom { Spacer(minLength: 0) }
                        Capsule()
                            .fill(Color.accentColor)
                            .frame(height: 3)
                            .padding(.horizontal, 6)
                        if dropEdge == .top { Spacer(minLength: 0) }
                    }
                    .allowsHitTesting(false)
                }
            }
            .contentShape(RoundedRectangle(cornerRadius: 8))
            .onTapGesture(perform: onSelectRow)
            .onHover { isHovered = $0 }
            .focusable()
            .focused($isFocused)
            .focusEffectDisabled(browsingFocusEffectHidden)
            .overlay {
                SearchSecondaryClickBridge(onSecondaryClick: onSecondaryClick)
            }
            .dropDestination(for: String.self, isEnabled: isDragging) { tokens, session in
                guard let token = tokens.first else { return }
                onDrop(token, session.location.y < session.size.height / 2 ? .top : .bottom)
            }
            .onDropSessionUpdated { session in
                switch session.phase {
                case .active, .entering:
                    onDropHover(session.location.y < session.size.height / 2 ? .top : .bottom)
                default:
                    onDropHover(nil)
                }
            }
            .accessibilityAction(named: Text(localizer.string(.moveUp))) { onMove(.up) }
            .accessibilityAction(named: Text(localizer.string(.moveDown))) { onMove(.down) }
            .accessibilityAction(named: Text(localizer.string(.managementMoveToTop))) { onMoveToBoundary(true) }
            .accessibilityAction(named: Text(localizer.string(.managementMoveToBottom))) { onMoveToBoundary(false) }
            .accessibilityAction(named: Text(localizer.string(.managementMoveToCollection)), onMoveToCollection)
            .accessibilityAction(named: Text(localizer.string(.remove)), onRemove)
            .accessibilityAddTraits(isSelected ? .isSelected : [])
            .alert(localizer.string(.managementFinderUnavailable), isPresented: $isFinderUnavailable) {
                Button(localizer.string(.managementAcknowledge), role: .cancel) {}
            }
        }
    }

    private func revealInFinder() {
        guard let url = CollectionMemberFinderReveal.fileURL(
            for: book.filepath,
            fileExists: { _ in book.exist }
        ) else {
            isFinderUnavailable = true
            return
        }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }
}

private struct ManagementMemberSelectionMark: View {
    var body: some View {
        Image(systemName: "checkmark")
            .font(.system(size: 9, weight: .bold))
            .foregroundStyle(.white)
            .frame(width: 18, height: 18)
            .background(Color.accentColor, in: Circle())
            .overlay {
                Circle().strokeBorder(Color(nsColor: .windowBackgroundColor), lineWidth: 1)
            }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

private struct CollectionMoveDestinationSheet: View {
    let collections: [BookCollection]
    let localizer: AppLocalizer
    let onChoose: (BookCollection) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var search = ""

    private var matches: [BookCollection] {
        let query = managementSearchToken(search)
        return collections.filter { query.isEmpty || managementSearchToken($0.name).contains(query) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(localizer.string(.managementMoveToCollection))
                .font(.headline)
            TextField(localizer.string(.searchCollections), text: $search)
                .textFieldStyle(.roundedBorder)
            ScrollView {
                LazyVStack(spacing: 4) {
                    ForEach(matches) { collection in
                        Button(collection.name) {
                            onChoose(collection)
                            dismiss()
                        }
                        .buttonStyle(.plain)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                    }
                }
            }
            HStack {
                Spacer()
                Button(localizer.string(.cancel)) { dismiss() }
            }
        }
        .padding(18)
        .frame(width: 420, height: 500)
    }
}

private struct VersionMemberCard: View {
    @Bindable var store: OrganizationStore
    let book: LibraryBook
    let titleDisplayMode: BookTitleDisplayMode
    let localizer: AppLocalizer
    let isSelected: Bool
    let onSelect: (LibraryBook) -> Void
    let onOpenReader: (LibraryBook) -> Void
    let onSelectMember: () -> Void
    let onRemove: () -> Void

    @State private var isComparisonExpanded = false
    @State private var isHovered = false
    @FocusState private var isFocused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.browsingFocusEffectHidden) private var browsingFocusEffectHidden

    private var currentBook: LibraryBook {
        store.catalog.book(id: book.id) ?? book
    }

    private var isSaving: Bool {
        currentBook.databaseID.map { store.catalog.savingOrganizationKeys.contains("book:\($0)") } ?? false
    }

    private var showsControls: Bool { isHovered || isFocused }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 12) {
                ManagementCoverButton(
                    book: currentBook,
                    width: 65,
                    height: 90,
                    cornerRadius: 7,
                    onSelect: onSelect
                )
                .overlay(alignment: .topTrailing) {
                    if isSelected { ManagementMemberSelectionMark().padding(4) }
                }

                VStack(alignment: .leading, spacing: 9) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        BookTitleCopyButton(
                            book: currentBook,
                            titleDisplayMode: titleDisplayMode,
                            localizer: localizer,
                            showsFullTitleHelp: true
                        )
                        if isSaving {
                            ProgressView()
                                .controlSize(.mini)
                                .accessibilityLabel(localizer.string(.saving))
                        }
                        if currentBook.isPrimaryVersion {
                            Label(localizer.string(.primaryVersion), systemImage: "checkmark")
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(Color.accentColor)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(Color.accentColor.opacity(0.12), in: Capsule())
                                .fixedSize()
                        } else {
                            Button {
                                store.catalog.setPrimaryVersion(currentBook)
                            } label: {
                                Text(localizer.string(.secondaryVersion))
                                    .font(.caption2.weight(.semibold))
                                    .foregroundStyle(.secondary)
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 4)
                                    .background(Color.secondary.opacity(0.1), in: Capsule())
                            }
                            .buttonStyle(.plain)
                            .fixedSize()
                            .help(localizer.string(.setPrimaryVersion))
                            .accessibilityLabel(localizer.string(.setPrimaryVersion))
                        }
                    }

                    compactFacts
                    HStack(alignment: .bottom, spacing: 8) {
                        VersionLabelInlineEditor(store: store, book: currentBook, localizer: localizer)
                        HStack(spacing: 6) {
                            actionsMenu
                            removeButton
                        }
                        .opacity(showsControls ? 1 : 0)
                        .allowsHitTesting(showsControls)
                        .accessibilityHidden(!showsControls)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            if isComparisonExpanded {
                VersionBookComparisonInfoView(
                    book: currentBook,
                    localizer: localizer,
                    showsTitlesAndTags: true,
                    showsFacts: true
                )
                .padding(.leading, 77)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(isSelected ? Color.accentColor.opacity(0.12) : Color.primary.opacity(isHovered ? 0.035 : 0))
        }
        .contentShape(RoundedRectangle(cornerRadius: 12))
        .onTapGesture(perform: onSelectMember)
        .onHover { isHovered = $0 }
        .focusable()
        .focused($isFocused)
        .focusEffectDisabled(browsingFocusEffectHidden)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.16), value: showsControls)
        .contextMenu { actions }
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private var compactFacts: some View {
        FlowLayout(spacing: 5, lineSpacing: 5) {
            VersionMemberFactPill(
                systemImage: "character.book.closed",
                title: localizer.string(.statusTranslatedShort),
                value: localizer.string(currentBook.isTranslated ? .yes : .noValue),
                isActive: currentBook.isTranslated
            )
            VersionMemberFactPill(
                systemImage: "paintpalette",
                title: localizer.string(.statusColorShort),
                value: localizer.string(currentBook.isFullColor ? .yes : .noValue),
                isActive: currentBook.isFullColor
            )
            VersionMemberFactPill(
                systemImage: "eye",
                title: localizer.string(.statusCensorshipShort),
                value: censorshipDescription,
                isActive: currentBook.censorship == "uncensored"
            )
            VersionMemberFactPill(
                systemImage: "book.pages",
                title: localizer.string(.pages),
                value: pageDescription,
                isActive: currentBook.fileCount != nil || currentBook.pages != nil,
                showsValue: true
            )
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var censorshipDescription: String {
        localizer.versionCensorshipDescription(currentBook.censorship)
    }

    private var pageDescription: String {
        switch (currentBook.fileCount, currentBook.pages) {
        case let (local?, remote?): "\(local) / \(remote)"
        case let (local?, nil): String(local)
        case let (nil, remote?): String(remote)
        case (nil, nil): localizer.string(.unknown)
        }
    }

    private var actionsMenu: some View {
        Menu {
            actions
        } label: {
            Image(systemName: "ellipsis")
                .foregroundStyle(.secondary)
                .frame(width: 30, height: 30)
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .accessibilityLabel(localizer.string(.managementMoreActions))
        .help(localizer.string(.managementMoreActions))
    }

    private var removeButton: some View {
        Button(role: .destructive, action: onRemove) {
            Image(systemName: "minus.circle")
                .foregroundStyle(.red)
                .frame(width: 30, height: 30)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(localizer.string(.remove))
        .help(localizer.string(.remove))
    }

    @ViewBuilder private var actions: some View {
        Button {
            onOpenReader(currentBook)
        } label: {
            Label(localizer.string(.readerOpen), systemImage: "book.pages")
        }
        Button {
            onSelect(currentBook)
        } label: {
            Label(localizer.string(.details), systemImage: "book.closed")
        }
        Button {
            withAnimation(.easeInOut(duration: 0.16)) { isComparisonExpanded.toggle() }
        } label: {
            Label(localizer.string(.managementComparisonDetails), systemImage: "list.bullet.rectangle")
        }
        if !currentBook.isPrimaryVersion {
            Button {
                store.catalog.setPrimaryVersion(currentBook)
            } label: {
                Label(localizer.string(.setPrimaryVersion), systemImage: "checkmark.circle")
            }
        }
        Divider()
        Button(role: .destructive, action: onRemove) {
            Label(localizer.string(.remove), systemImage: "minus.circle")
        }
    }
}

private struct VersionMemberFactPill: View {
    let systemImage: String
    let title: String
    let value: String
    let isActive: Bool
    var showsValue = false

    var body: some View {
        Label(showsValue ? value : title, systemImage: systemImage)
            .font(.caption2)
            .foregroundStyle(isActive ? Color.accentColor : Color.secondary)
            .padding(.horizontal, 7)
            .padding(.vertical, 4)
            .background(isActive ? Color.accentColor.opacity(0.1) : Color.secondary.opacity(0.08), in: Capsule())
            .help("\(title): \(value)")
            .accessibilityLabel("\(title): \(value)")
    }
}

private struct BookTitleHeader: View {
    let book: LibraryBook
    let titleDisplayMode: BookTitleDisplayMode
    let statusText: String?
    let localizer: AppLocalizer
    var onSelect: ((LibraryBook) -> Void)? = nil

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            ManagementCoverButton(
                book: book,
                width: 52,
                height: 72,
                cornerRadius: 7,
                onSelect: onSelect
            )
            BookTitleCopyButton(book: book, titleDisplayMode: titleDisplayMode, localizer: localizer)

            if let statusText {
                Text(statusText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Color(nsColor: .quaternaryLabelColor).opacity(0.16), in: Capsule())
            }
        }
        .frame(minHeight: 72)
    }
}

private struct BookTitleCopyButton: View {
    let book: LibraryBook
    let titleDisplayMode: BookTitleDisplayMode
    let localizer: AppLocalizer
    var showsFullTitleHelp = false

    @State private var isTitleCopied = false

    var body: some View {
        HStack(spacing: 6) {
            Button {
                copyTitle()
            } label: {
                Text(BookTitleFormatter.displayTitle(for: book, mode: titleDisplayMode))
                    .font(.headline)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(showsFullTitleHelp
                ? "\(BookTitleFormatter.displayTitle(for: book, mode: titleDisplayMode))\n\(localizer.string(.copyTitle))"
                : localizer.string(.copyTitle))

            if isTitleCopied {
                Image(systemName: "checkmark")
                    .foregroundStyle(.secondary)
                    .help(localizer.string(.titleCopied))
                    .accessibilityLabel(localizer.string(.titleCopied))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func copyTitle() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(BookTitleFormatter.displayTitle(for: book, mode: titleDisplayMode), forType: .string)
        isTitleCopied = true
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.2))
            isTitleCopied = false
        }
    }
}

private struct ManagementCoverButton: View {
    let book: LibraryBook
    let width: CGFloat
    let height: CGFloat
    let cornerRadius: CGFloat
    let onSelect: ((LibraryBook) -> Void)?

    var body: some View {
        BookCoverThumbnail(book: book, width: width, height: height, cornerRadius: cornerRadius)
            .contentShape(RoundedRectangle(cornerRadius: cornerRadius))
            .onTapGesture {
                onSelect?(book)
            }
            .accessibilityAddTraits(onSelect == nil ? [] : .isButton)
            .accessibilityAction {
                onSelect?(book)
            }
    }
}

private struct CandidateTagPreview: View {
    let tags: [TagDisplaySummary]

    private var uniqueTags: [TagDisplaySummary] {
        var seen = Set<String>()
        return tags.filter { tag in
            seen.insert(tag.displayText.folding(options: [.caseInsensitive, .widthInsensitive], locale: nil)).inserted
        }
    }

    var body: some View {
        HStack(spacing: 5) {
            ForEach(uniqueTags) { tag in
                Text(tag.displayText)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(Color(nsColor: .quaternaryLabelColor).opacity(0.16), in: Capsule())
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .clipped()
    }
}

private struct ActionButtonRow<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        HStack(spacing: 8) {
            content
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .labelStyle(.titleAndIcon)
    }
}

private struct VersionLabelInlineEditor: View {
    @Bindable var store: OrganizationStore
    let book: LibraryBook
    let localizer: AppLocalizer

    @State private var isAddPopoverPresented = false
    @State private var isHovered = false
    @FocusState private var isFocused: Bool

    private var showsAddButton: Bool { isHovered || isFocused || isAddPopoverPresented }

    private var currentBook: LibraryBook {
        store.catalog.book(id: book.id) ?? book
    }

    private var labels: [String] {
        store.catalog.versionLabels(for: currentBook)
    }

    var body: some View {
        FlowLayout(spacing: 6, lineSpacing: 6) {
            ForEach(labels, id: \.self) { label in
                VersionLabelChip(
                    label: label,
                    colorRole: .role(for: label),
                    localizer: localizer
                ) {
                    remove(label)
                }
            }

            Button {
                isAddPopoverPresented = true
            } label: {
                Image(systemName: "plus")
                    .font(.caption.weight(.semibold))
                    .frame(width: 22, height: 20)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .opacity(showsAddButton ? 1 : 0)
            .allowsHitTesting(showsAddButton)
            .accessibilityHidden(!showsAddButton)
            .accessibilityLabel(localizer.string(.managementAddVersionLabel))
            .help(localizer.string(.managementAddVersionLabel))
            .popover(isPresented: $isAddPopoverPresented, arrowEdge: .bottom) {
                VersionLabelAddPopover(
                    store: store,
                    book: currentBook,
                    localizer: localizer,
                    isPresented: $isAddPopoverPresented
                )
                .frame(width: 310)
                .padding(16)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
        .focusable()
        .focused($isFocused)
        .accessibilityAction(named: Text(localizer.string(.managementAddVersionLabel))) {
            isAddPopoverPresented = true
        }
    }

    private func remove(_ label: String) {
        let nextLabels = labels.filter { $0.caseInsensitiveCompare(label) != .orderedSame }
        store.catalog.setVersionLabels(nextLabels, for: currentBook)
    }
}

private struct VersionLabelAddPopover: View {
    @Bindable var store: OrganizationStore
    let book: LibraryBook
    let localizer: AppLocalizer
    @Binding var isPresented: Bool

    @State private var draftLabel = ""
    @FocusState private var isDraftFocused: Bool

    private var currentBook: LibraryBook {
        store.catalog.book(id: book.id) ?? book
    }

    private var labels: [String] {
        store.catalog.versionLabels(for: currentBook)
    }

    private var trimmedDraft: String {
        draftLabel.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var availablePresets: [String] {
        VersionLabelPreset.all.filter { preset in
            !labels.contains { $0.caseInsensitiveCompare(preset) == .orderedSame }
                && (trimmedDraft.isEmpty || preset.localizedCaseInsensitiveContains(trimmedDraft))
        }
    }

    private var historicalSuggestions: [VersionLabelSuggestion] {
        guard !trimmedDraft.isEmpty else { return [] }
        let presetKeys = Set(VersionLabelPreset.all.map { $0.lowercased() })
        return Array(store.catalog.versionLabelSuggestions(matching: trimmedDraft)
            .filter { !presetKeys.contains($0.label.lowercased()) }
            .filter { suggestion in
                !labels.contains { $0.caseInsensitiveCompare(suggestion.label) == .orderedSame }
            }
            .prefix(5))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(localizer.string(.managementAddVersionLabel))
                .font(.headline)

            TextField(localizer.string(.managementCustomVersionLabel), text: $draftLabel)
                .textFieldStyle(.roundedBorder)
                .focused($isDraftFocused)
                .onSubmit(addDraft)
                .onKeyPress(.return) {
                    addDraft()
                    return .handled
                }
                .onExitCommand { isPresented = false }

            if !availablePresets.isEmpty {
                Text(localizer.string(.managementQuickAddLabels))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)

                FlowLayout(spacing: 6, lineSpacing: 6) {
                    ForEach(availablePresets, id: \.self) { label in
                        VersionLabelQuickAddChip(
                            label: label,
                            colorRole: .role(for: label)
                        ) {
                            add(label, clearsDraft: false)
                        }
                    }
                }
            }

            if !historicalSuggestions.isEmpty {
                Text(localizer.string(.versionLabelSuggestions))
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)

                FlowLayout(spacing: 6, lineSpacing: 6) {
                    ForEach(historicalSuggestions) { suggestion in
                        Button {
                            add(suggestion.label, clearsDraft: true)
                        } label: {
                            Text(suggestion.label)
                                .font(.caption)
                                .lineLimit(1)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .help(suggestion.label)
                    }
                }
            }

            if !trimmedDraft.isEmpty {
                Button(action: addDraft) {
                    Label(localizer.string(.managementAddVersionLabel) + " “" + trimmedDraft + "”", systemImage: "plus")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(labels.contains { $0.caseInsensitiveCompare(trimmedDraft) == .orderedSame })
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onAppear { isDraftFocused = true }
    }

    private func addDraft() {
        add(draftLabel, clearsDraft: true)
    }

    private func add(_ label: String, clearsDraft: Bool) {
        let currentLabels = labels
        let nextLabels = VersionLabelFormatter.normalizedLabels(currentLabels + [label])
        if nextLabels != currentLabels {
            store.catalog.setVersionLabels(nextLabels, for: currentBook)
        }
        if clearsDraft { draftLabel = "" }
    }
}

enum VersionLabelColorRole: Hashable {
    case original
    case translated
    case fullColor
    case uncensored
    case special
    case custom(Int)

    static func role(for label: String) -> Self {
        let normalized = label.trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive, .widthInsensitive], locale: Locale(identifier: "en_US_POSIX"))
        switch normalized {
        case VersionLabelPreset.original: return .original
        case VersionLabelPreset.translated: return .translated
        case VersionLabelPreset.fullColor: return .fullColor
        case VersionLabelPreset.uncensored: return .uncensored
        case VersionLabelPreset.special: return .special
        default:
            // A fixed hash keeps custom label colors stable across process launches.
            var hash: UInt64 = 14_695_981_039_346_656_037
            for byte in normalized.utf8 {
                hash = (hash ^ UInt64(byte)) &* 1_099_511_628_211
            }
            return .custom(Int(hash % 6))
        }
    }

    var color: Color {
        switch self {
        case .original: return .indigo
        case .translated: return .teal
        case .fullColor: return .orange
        case .uncensored: return .purple
        case .special: return .pink
        case .custom(let index):
            return [Color.blue, .green, .cyan, .mint, .brown, .red][index]
        }
    }
}

private struct VersionLabelChip: View {
    let label: String
    let colorRole: VersionLabelColorRole
    let localizer: AppLocalizer
    let onRemove: () -> Void

    @Environment(\.colorSchemeContrast) private var contrast
    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 7) {
            Text(label)
                .font(.callout.weight(.semibold))
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: 180, alignment: .leading)
                .help(label)

            if isHovered {
                Button(action: onRemove) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.caption)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(localizer.string(.remove)) \(label)")
                .help("\(localizer.string(.remove)) \(label)")
            }
        }
        .foregroundStyle(.primary)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(colorRole.color.opacity(contrast == .increased ? 0.22 : 0.13), in: Capsule())
        .overlay {
            Capsule()
                .stroke(colorRole.color.opacity(contrast == .increased ? 0.8 : 0.48), lineWidth: 1)
        }
        .onHover { isHovered = $0 }
        .accessibilityAction(named: Text("\(localizer.string(.remove)) \(label)"), onRemove)
        .contextMenu {
            Button(role: .destructive, action: onRemove) {
                Label(localizer.string(.remove), systemImage: "minus.circle")
            }
        }
    }
}

private struct VersionLabelQuickAddChip: View {
    let label: String
    let colorRole: VersionLabelColorRole
    let action: () -> Void

    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        Button(action: action) {
            Label(label, systemImage: "plus.circle")
                .font(.caption.weight(.medium))
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: 160, alignment: .leading)
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(colorRole.color.opacity(contrast == .increased ? 0.18 : 0.09), in: Capsule())
                .overlay {
                    Capsule()
                        .stroke(colorRole.color.opacity(contrast == .increased ? 0.75 : 0.38), lineWidth: 1)
                }
        }
        .buttonStyle(.plain)
        .foregroundStyle(.primary)
    }
}

private struct FlowLayout: Layout {
    var spacing: CGFloat = 6
    var lineSpacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = rows(for: subviews, proposalWidth: proposal.width)
        return CGSize(
            width: proposal.width ?? rows.map(\.width).max() ?? 0,
            height: rows.map(\.height).reduce(0, +) + lineSpacing * CGFloat(max(rows.count - 1, 0))
        )
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let rows = rows(for: subviews, proposalWidth: bounds.width)
        var y = bounds.minY
        for row in rows {
            var x = bounds.minX
            for item in row.items {
                subviews[item.index].place(
                    at: CGPoint(x: x, y: y),
                    proposal: ProposedViewSize(item.size)
                )
                x += item.size.width + spacing
            }
            y += row.height + lineSpacing
        }
    }

    private func rows(for subviews: Subviews, proposalWidth: CGFloat?) -> [FlowRow] {
        let maxWidth = proposalWidth ?? .infinity
        var rows: [FlowRow] = []
        var current = FlowRow()

        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            let proposedWidth = current.width == 0 ? size.width : current.width + spacing + size.width
            if proposedWidth > maxWidth, !current.items.isEmpty {
                rows.append(current)
                current = FlowRow()
            }
            current.append(FlowItem(index: index, size: size), spacing: spacing)
        }

        if !current.items.isEmpty {
            rows.append(current)
        }
        return rows
    }

    private struct FlowItem {
        let index: Int
        let size: CGSize
    }

    private struct FlowRow {
        var items: [FlowItem] = []
        var width: CGFloat = 0
        var height: CGFloat = 0

        mutating func append(_ item: FlowItem, spacing: CGFloat) {
            if items.isEmpty {
                width = item.size.width
            } else {
                width += spacing + item.size.width
            }
            height = max(height, item.size.height)
            items.append(item)
        }
    }
}

private extension View {
    func managementPageToolbar(
        navigationTitle: String,
        updateTitle: String,
        newTitle: String,
        candidateAreaTitle: String,
        isCandidateAreaHidden: Bool,
        isRefreshing: Bool,
        showsActions: Bool,
        onUpdate: @escaping () -> Void,
        onCreate: @escaping () -> Void,
        onToggleCandidateArea: @escaping () -> Void
    ) -> some View {
        modifier(
            ManagementPageToolbar(
                navigationTitle: navigationTitle,
                updateTitle: updateTitle,
                newTitle: newTitle,
                candidateAreaTitle: candidateAreaTitle,
                isCandidateAreaHidden: isCandidateAreaHidden,
                isRefreshing: isRefreshing,
                showsActions: showsActions,
                onUpdate: onUpdate,
                onCreate: onCreate,
                onToggleCandidateArea: onToggleCandidateArea
            )
        )
    }

    func managementListRow(padding: CGFloat = 0, isSelected: Bool = false) -> some View {
        self
            .padding(padding)
            .background(
                isSelected ? Color.accentColor.opacity(0.12) : Color(nsColor: .textBackgroundColor).opacity(0.5),
                in: RoundedRectangle(cornerRadius: 8)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 8)
                    .stroke(Color(nsColor: .separatorColor).opacity(0.3), lineWidth: 0.5)
            }
    }

    func managementCard() -> some View {
        padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .managementPanel(cornerRadius: 12)
    }

    func managementPanel(cornerRadius: CGFloat = 12) -> some View {
        background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .stroke(Color(nsColor: .separatorColor).opacity(0.55), lineWidth: 0.5)
            }
            .shadow(color: .black.opacity(0.025), radius: 4, x: 0, y: 1)
    }
}

struct SeriesConflictConfirmation {
    let collectionName: String
    let commit: @MainActor () -> Void
}

extension View {
    func confirmSeriesConflict(_ pending: Binding<SeriesConflictConfirmation?>, localizer: AppLocalizer) -> some View {
        alert(localizer.string(.addToCollection), isPresented: Binding(
            get: { pending.wrappedValue != nil },
            set: { if !$0 { pending.wrappedValue = nil } }
        ), presenting: pending.wrappedValue) { confirmation in
            Button(localizer.string(.addToCollection), action: confirmation.commit)
            Button(localizer.string(.cancel), role: .cancel) {}
        } message: { confirmation in
            Text(String(format: localizer.string(.confirmVersionSeriesAssignment), confirmation.collectionName))
        }
    }
}
