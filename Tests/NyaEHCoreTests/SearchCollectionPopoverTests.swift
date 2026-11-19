import Foundation
import Testing
@testable import NyaEHCore

@Suite("Search series member popover")
struct SearchCollectionPopoverTests {
    @Test("only collection cards use the series popover")
    func activationByLayout() {
        for layout in SearchResultLayout.allCases {
            #expect(SearchPrimaryActivationPolicy.opensCollectionPopover(for: source().item, layout: layout) == (layout == .card))
            #expect(!SearchPrimaryActivationPolicy.opensCollectionPopover(for: .book(book(1)), layout: layout))

        }
    }

    @Test("popover state rejects both list layouts and clears any older return record")
    func listLayoutsCannotOpen() throws {
        for layout in [SearchResultLayout.row, .expandedRow] {
            let state = try suspendedState()
            state.open(collectionID: "1", context: context(layout: layout))
            #expect(state.presentation == nil)
            #expect(state.returnSession == nil)
            #expect(state.restoreRequestID == nil)
        }
    }

    @Test("switching to either list layout closes the popover and switching back cannot restore it")
    func layoutSwitchCancelsPresentationAndReturn() throws {
        for layout in [SearchResultLayout.row, .expandedRow] {
            var state = SearchCollectionPopoverState()
            state.open(collectionID: "1", context: context())
            state.invalidate(ifContextChanged: context(layout: layout))
            #expect(state.presentation == nil)
            state.requestReturn(context: context(), items: [source()])
            state.restoreAtAnchor(collectionID: "1")
            #expect(state.presentation == nil)

            state = try suspendedState()
            state.requestReturn(context: context(layout: layout), items: [], isLoading: true)
            #expect(state.returnSession == nil)
            state.requestReturn(context: context(), items: [source()])
            state.restoreAtAnchor(collectionID: "1")
            #expect(state.presentation == nil)
            #expect(state.restoreRequestID == nil)
        }
    }

    @Test("only one series is presented and stale dismissal cannot close its replacement")
    func presentationIdentity() throws {
        let state = SearchCollectionPopoverState()
        state.open(collectionID: "1", context: context())
        let oldID = try #require(state.presentation?.id)
        state.open(collectionID: "2", context: context())
        let current = try #require(state.presentation)
        #expect(current.collectionID == "2")
        #expect(current.id != oldID)
        state.dismiss(presentationID: oldID)
        #expect(state.presentation == current)
        state.dismiss(presentationID: current.id)
        #expect(state.presentation == nil)
        #expect(state.returnSession == nil)
    }

    @Test("member detail saves position and restores once at the matching laid-out anchor")
    func detailReturn() throws {
        let source = source()
        let state = SearchCollectionPopoverState()
        state.open(collectionID: "1", context: context())
        let original = try #require(state.presentation)
        #expect(state.activateMember(
            presentationID: original.id, bookID: "2",
            position: .init(scrollOffset: 270, focusedMemberID: "1")
        ))
        #expect(state.presentation == nil)
        #expect(state.restoreRequestID == nil)
        // 原生浮窗回调持有同一个状态对象，关闭时读取最新的展示身份。
        let dismissOriginal = { state.dismiss(presentationID: original.id) }
        dismissOriginal()
        state.searchBecameInactive()
        state.restoreAtAnchor(collectionID: "1")
        #expect(state.presentation == nil)

        state.requestReturn(context: context(), items: [source])
        #expect(state.restoreRequestID == original.id)
        #expect(state.returnSession?.anchorID == "entity.collection.1")
        state.restoreAtAnchor(collectionID: "2")
        #expect(state.presentation == nil)
        state.restoreAtAnchor(collectionID: "1")
        let restored = try #require(state.presentation)
        #expect(restored.id != original.id)
        #expect(restored.position == .init(scrollOffset: 270, focusedMemberID: "2"))
        #expect(state.returnSession == nil)
        #expect(!state.isAwaitingAnchor)
        dismissOriginal()
        #expect(state.presentation == restored)
        state.dismiss(presentationID: restored.id)
        state.requestReturn(context: context(), items: [source])
        #expect(state.presentation == nil)
        #expect(state.restoreRequestID == nil)
    }

    @Test("callbacks from a closed session cannot activate another series")
    func staleMemberCallback() throws {
        let state = SearchCollectionPopoverState()
        state.open(collectionID: "1", context: context())
        let old = try #require(state.presentation?.id)
        state.open(collectionID: "2", context: context())
        #expect(!state.activateMember(
            presentationID: old, bookID: "1", position: .init()
        ))
        #expect(state.presentation?.collectionID == "2")
        #expect(state.returnSession == nil)
    }

    @Test("query, scope, sorting, paging, layout and cover context changes cancel restoration")
    func contextInvalidation() throws {
        let baseline = context()
        var variants: [SearchCollectionPopoverContext] = []
        var changed = baseline
        changed.request.rawQuery = "new query"; variants.append(changed)
        changed = baseline; changed.request.scope = .hidden; variants.append(changed)
        changed = baseline; changed.request.page = 2; variants.append(changed)
        changed = baseline; changed.request.pageSize = 50; variants.append(changed)
        changed = baseline; changed.request.sortDirection = .ascending; variants.append(changed)
        changed = baseline; changed.request.sortKey = .title; variants.append(changed)
        changed = baseline; changed.layout = .expandedRow; variants.append(changed)
        changed = baseline; changed.showsCollectionMembers = true; variants.append(changed)
        changed = baseline; changed.isCoverImageSearchActive = true; variants.append(changed)
        changed = baseline; changed.coverImageFileName = "cover.png"; variants.append(changed)
        for next in variants {
            let state = try suspendedState()
            state.requestReturn(context: next, items: [source()])
            state.restoreAtAnchor(collectionID: "1")
            #expect(state.presentation == nil)
            #expect(state.returnSession == nil)
        }
    }

    @Test("manual dismissal, result scrolling, new submission and leaving Search cancel return")
    func explicitCancellation() throws {
        let state = try suspendedState()
        state.clear()
        state.requestReturn(context: context(), items: [source()])
        #expect(state.restoreRequestID == nil)
        state.open(collectionID: "1", context: context())
        state.searchBecameInactive()
        state.requestReturn(context: context(), items: [source()])
        #expect(state.presentation == nil)
        #expect(state.restoreRequestID == nil)
    }

    @Test("refresh preserves member order and falls back when the focused member was removed")
    func refreshedMembers() throws {
        var state = try suspendedState()
        var refreshed = source()
        refreshed.item = .collection(BookCollectionDisplayItem(collection: collection(), books: [book(3), book(1)]))
        state.requestReturn(context: context(), items: [refreshed])
        state.restoreAtAnchor(collectionID: "1")
        #expect(state.presentation?.position.focusedMemberID == "3")
        #expect(state.presentation?.position.scrollOffset == 270)
        state.retainAvailableItems([])
        #expect(state.presentation == nil)

        state = try suspendedState()
        state.requestReturn(context: context(), items: [])
        #expect(state.returnSession == nil)
        #expect(state.restoreRequestID == nil)
    }

    @Test("same-context data updates keep presentation identity; empty series closes")
    func retainedPresentation() throws {
        let state = SearchCollectionPopoverState()
        state.open(collectionID: "1", context: context())
        let id = try #require(state.presentation?.id)
        state.invalidate(ifContextChanged: context())
        state.retainAvailableItems([source()])
        #expect(state.presentation?.id == id)
        var empty = source()
        empty.item = .collection(BookCollectionDisplayItem(collection: collection(), books: []))
        state.retainAvailableItems([empty])
        #expect(state.presentation == nil)
    }

    @Test("temporary empty search snapshots during a library reload do not discard return position")
    func libraryReloadWhileReturning() throws {
        var state = try suspendedState()
        state.retainAvailableItems([], isLoading: true)
        state.requestReturn(context: context(), items: [], isLoading: true)
        #expect(state.returnSession?.position.scrollOffset == 270)
        #expect(state.restoreRequestID == nil)
        state.restoreAtAnchor(collectionID: "1")
        #expect(state.presentation == nil)
        state.requestReturn(context: context(), items: [source()], isLoading: false)
        state.restoreAtAnchor(collectionID: "1")
        #expect(state.presentation?.position.focusedMemberID == "2")

        state = try suspendedState()
        state.requestReturn(context: context(), items: [], isLoading: true)
        state.requestReturn(context: context(), items: [], isLoading: false)
        #expect(state.returnSession == nil)
    }

    @Test("Tab and Shift-Tab cycle members and details without escaping the popover")
    func focusTraversal() {
        let ids = ["1", "2", "3"]
        #expect(SearchCollectionPopoverFocus.next(after: nil, backwards: false, memberIDs: ids) == .member("1"))
        #expect(SearchCollectionPopoverFocus.next(after: .member("1"), backwards: false, memberIDs: ids) == .member("2"))
        #expect(SearchCollectionPopoverFocus.next(after: .member("3"), backwards: false, memberIDs: ids) == .details)
        #expect(SearchCollectionPopoverFocus.next(after: .details, backwards: false, memberIDs: ids) == .member("1"))
        #expect(SearchCollectionPopoverFocus.next(after: .member("1"), backwards: true, memberIDs: ids) == .details)
        #expect(SearchCollectionPopoverFocus.next(after: .details, backwards: true, memberIDs: ids) == .member("3"))
        #expect(SearchCollectionPopoverFocus.next(after: .member("removed"), backwards: false, memberIDs: ids) == .member("1"))
        #expect(SearchCollectionPopoverFocus.next(after: .member("1"), backwards: false, memberIDs: ids,
                                                   metadataIDs: ["1"]) == .metadata("1"))
        #expect(SearchCollectionPopoverFocus.next(after: .metadata("1"), backwards: false, memberIDs: ids,
                                                   metadataIDs: ["1"]) == .member("2"))
        #expect(SearchCollectionPopoverFocus.next(after: .member("2"), backwards: true, memberIDs: ids,
                                                   metadataIDs: ["1"]) == .metadata("1"))
        #expect(SearchCollectionPopoverFocus.next(after: .metadata("1"), backwards: false, memberIDs: ids,
                                                   metadataIDs: ["1"], showsReader: true) == .reader("1"))
        #expect(SearchCollectionPopoverFocus.next(after: .reader("1"), backwards: false, memberIDs: ids,
                                                   metadataIDs: ["1"], showsReader: true) == .member("2"))
        #expect(SearchCollectionPopoverFocus.next(after: nil, backwards: false, memberIDs: []) == .details)
    }

    @Test("popover fits narrow and short viewports and bounds scrolling")
    func sizing() {
        let large = SearchCollectionPopoverMetrics(viewport: CGSize(width: 1200, height: 900), memberCount: 30)
        #expect(large.size == CGSize(width: 644, height: 540))
        #expect(large.columns == 4)
        let narrow = SearchCollectionPopoverMetrics(viewport: CGSize(width: 460, height: 300), memberCount: 20)
        #expect(narrow.size == CGSize(width: 428, height: 268))
        #expect(narrow.columns == 2)
        let small = SearchCollectionPopoverMetrics(viewport: CGSize(width: 300, height: 700), memberCount: 1)
        #expect(small.size.height < 540)
        #expect(small.columns == 1)
        let zero = SearchCollectionPopoverMetrics(viewport: .zero, memberCount: 0)
        #expect(zero.size == .zero)
        #expect(zero.cardWidth == 0)
        #expect(zero.bookCardMetrics.contentWidth == 0)
        #expect(SearchCollectionPopoverMetrics.clampedOffset(270, contentHeight: 700, viewportHeight: 300) == 270)
        #expect(SearchCollectionPopoverMetrics.clampedOffset(270, contentHeight: 340, viewportHeight: 300) == 40)
        #expect(SearchCollectionPopoverMetrics.clampedOffset(-20, contentHeight: 200, viewportHeight: 300) == 0)
    }

    @Test("shared search card sizes fit one complete row with extra height", arguments: [112, 128, 176])
    func sharedCardSizing(width: Int) {
        let card = BookCardMetrics(width: width)
        let viewport = CGSize(width: 1200, height: 900)
        let expectedColumns = 4
        let metrics = SearchCollectionPopoverMetrics(viewport: viewport, memberCount: expectedColumns, cardMetrics: card)
        #expect(metrics.bookCardMetrics == card)
        #expect(metrics.columns == expectedColumns)
        #expect(metrics.memberHeight == card.cardHeight)

        let scrollHeight = metrics.size.height - SearchCollectionPopoverMetrics.headerHeight - SearchCollectionPopoverMetrics.dividerHeight
        #expect(metrics.contentHeight == card.cardHeight + 32)
        #expect(scrollHeight - metrics.contentHeight >= 12)
        #expect(scrollHeight - metrics.contentHeight < 13)
        #expect(SearchCollectionPopoverMetrics.clampedOffset(10, contentHeight: metrics.contentHeight, viewportHeight: scrollHeight) == 0)

        let multirow = SearchCollectionPopoverMetrics(viewport: viewport, memberCount: expectedColumns + 1, cardMetrics: card)
        #expect(multirow.size.height == 540)
        #expect(multirow.contentHeight > multirow.size.height - 81)
        let short = SearchCollectionPopoverMetrics(viewport: CGSize(width: 1200, height: 300), memberCount: 1, cardMetrics: card)
        #expect(short.size.height == 268)
        #expect(short.contentHeight > short.size.height - 81)
    }

    @Test("cards never stretch to fill a row and only shrink when one cannot fit", arguments: [112, 128, 176])
    func cardWidthBounds(width: Int) {
        let card = BookCardMetrics(width: width)
        for viewportWidth in [CGFloat(0), 20, 48, 100, 300, 460, 1200] {
            let metrics = SearchCollectionPopoverMetrics(
                viewport: CGSize(width: viewportWidth, height: 700), memberCount: 20, cardMetrics: card
            )
            let contentWidth = metrics.size.width - metrics.gridPadding * 2
            #expect(metrics.cardWidth == min(card.cardWidth, contentWidth.rounded(.down)))
            let gridWidth = CGFloat(metrics.columns) * metrics.cardWidth
                + CGFloat(metrics.columns - 1) * SearchCollectionPopoverMetrics.horizontalSpacing
            #expect(gridWidth <= contentWidth)
            #expect(metrics.size.width <= max(0, viewportWidth - 32))
            #expect(metrics.size.height <= 540)
        }
    }

    @Test("restoration waits for a visible positive-size anchor below the pinned header")
    func anchorReadiness() {
        let viewport = CGSize(width: 600, height: 500)
        #expect(!SearchCollectionPopoverMetrics.isAnchorVisible(.zero, viewport: viewport, topInset: 100))
        #expect(!SearchCollectionPopoverMetrics.isAnchorVisible(CGRect(x: 10, y: 10, width: 120, height: 70), viewport: viewport, topInset: 100))
        #expect(!SearchCollectionPopoverMetrics.isAnchorVisible(CGRect(x: 10, y: 510, width: 120, height: 70), viewport: viewport, topInset: 100))
        #expect(SearchCollectionPopoverMetrics.isAnchorVisible(CGRect(x: 10, y: 110, width: 120, height: 70), viewport: viewport, topInset: 100))
    }

    @Test("every layout retains the series anchor and members from the current result")
    func searchSnapshotProjection() {
        let source = source()
        for layout in SearchResultLayout.allCases {
            var snapshot = SearchResultPresentationSnapshot(input: .init(items: [source], layout: layout))
            #expect(snapshot.entries.map(\.id) == ["entity.collection.1"])
            #expect(snapshot.entries.first?.source.books.map(\.id) == ["1", "2"])
            #expect(snapshot.entries.first?.source.hasMatch(for: "1") == true)
            #expect(snapshot.entries.first?.source.hasMatch(for: "2") == true)
            #expect(snapshot.entries.first?.source.hasMatch(for: "3") == false)
            let retained = snapshot.updateIfNeeded(input: snapshot.input)
            #expect(!retained)
            let rebuilt = snapshot.updateIfNeeded(input: .init(items: [], layout: layout))
            #expect(rebuilt)
        }
    }

    @Test("unobstructed covers fit both portrait and landscape images")
    func unobstructedCoversFitAllAspectRatios() {
        for size in [CGSize(width: 800, height: 1_200), CGSize(width: 1_200, height: 800), CGSize(width: 900, height: 900)] {
            #expect(BookCoverThumbnailDisplayMode.resolve(imageSize: size, fitsEntireImage: true) == .fit)
        }
    }

    private func suspendedState() throws -> SearchCollectionPopoverState {
        let state = SearchCollectionPopoverState()
        state.open(collectionID: "1", context: context())
        let id = try #require(state.presentation?.id)
        _ = state.activateMember(
            presentationID: id, bookID: "2", position: .init(scrollOffset: 270)
        )
        state.searchBecameInactive()
        return state
    }

    private func context(layout: SearchResultLayout = .card) -> SearchCollectionPopoverContext {
        .init(request: LibrarySearchRequest(), layout: layout, showsCollectionMembers: false, isCoverImageSearchActive: false)
    }

    private func source() -> SearchDisplayItem {
        .init(
            item: .collection(BookCollectionDisplayItem(collection: collection(), books: [book(1), book(2)])),
            matchedBookIDs: ["2"], otherVersionMatchedBookIDs: ["1"]
        )
    }

    private func collection() -> BookCollection { BookCollection(databaseID: 1, name: "Series") }

    private func book(_ id: Int64) -> LibraryBook {
        LibraryBook(databaseID: id, title: "Book \(id)", hash: "hash-\(id)", filepath: "/tmp/\(id).cbz", type: .archive, status: .correct)
    }
}
