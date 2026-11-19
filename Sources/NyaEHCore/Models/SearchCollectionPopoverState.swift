import Foundation
import Observation

// 窗口内的临时浏览状态；不保存成员快照，恢复时始终使用当前搜索页的数据。
struct SearchCollectionPopoverContext: Equatable {
    var request: LibrarySearchRequest
    var layout: SearchResultLayout
    var showsCollectionMembers: Bool
    var coverImageFileName: String?
    var isCoverImageSearchActive: Bool
}

struct SearchCollectionBrowsePosition: Equatable {
    var scrollOffset: CGFloat = 0
    var focusedMemberID: LibraryBook.ID?

    mutating func reconcile(memberIDs: [LibraryBook.ID]) {
        if let focusedMemberID, !memberIDs.contains(focusedMemberID) {
            self.focusedMemberID = memberIDs.first
        }
    }
}

struct SearchCollectionPopoverSession: Identifiable, Equatable {
    let id: UUID
    let collectionID: BookCollection.ID
    var position: SearchCollectionBrowsePosition

    var anchorID: String { "entity.collection.\(collectionID)" }
}

@Observable
final class SearchCollectionPopoverState {
    private(set) var presentation: SearchCollectionPopoverSession?
    private(set) var returnSession: SearchCollectionPopoverSession?
    private(set) var isAwaitingAnchor = false
    private var context: SearchCollectionPopoverContext?

    var restoreRequestID: UUID? { isAwaitingAnchor ? returnSession?.id : nil }

    func open(collectionID: BookCollection.ID, context: SearchCollectionPopoverContext) {
        clear()
        guard context.layout == .card else { return }
        self.context = context
        presentation = SearchCollectionPopoverSession(id: UUID(), collectionID: collectionID, position: .init())
    }

    func clear() {
        presentation = nil
        returnSession = nil
        isAwaitingAnchor = false
        context = nil
    }

    // 关闭旧浮窗的回调不能清除刚刚保存的返回记录或新打开的浮窗。
    func dismiss(presentationID: UUID) {
        guard presentation?.id == presentationID else { return }
        clear()
    }

    func invalidate(ifContextChanged next: SearchCollectionPopoverContext) {
        guard next.layout == .card else {
            clear()
            return
        }
        if let context, context != next { clear() }
    }

    func activateMember(
        presentationID: UUID,
        bookID: LibraryBook.ID,
        position: SearchCollectionBrowsePosition
    ) -> Bool {
        guard var session = presentation, session.id == presentationID else { return false }
        session.position = position
        session.position.focusedMemberID = bookID
        returnSession = session
        presentation = nil
        return true
    }

    func searchBecameInactive() {
        presentation = nil
        isAwaitingAnchor = false
        if returnSession == nil { clear() }
    }

    func requestReturn(context: SearchCollectionPopoverContext, items: [SearchDisplayItem], isLoading: Bool = false) {
        invalidate(ifContextChanged: context)
        retainAvailableItems(items, isLoading: isLoading)
        isAwaitingAnchor = returnSession != nil && !isLoading
    }

    func restoreAtAnchor(collectionID: BookCollection.ID) {
        guard isAwaitingAnchor, let session = returnSession, session.collectionID == collectionID else { return }
        presentation = SearchCollectionPopoverSession(id: UUID(), collectionID: collectionID, position: session.position)
        returnSession = nil
        isAwaitingAnchor = false
    }

    func retainAvailableItems(_ items: [SearchDisplayItem], isLoading: Bool = false) {
        // 库变更会先丢弃 SQL 快照再重查；临时空列表不代表系列真的离开结果页。
        guard !isLoading else { return }
        guard let session = presentation ?? returnSession else { return }
        guard let source = items.first(where: { $0.id == "collection.\(session.collectionID)" }),
              !source.books.isEmpty else {
            clear()
            return
        }
        let memberIDs = source.books.map(\.id)
        presentation?.position.reconcile(memberIDs: memberIDs)
        returnSession?.position.reconcile(memberIDs: memberIDs)
    }
}

enum SearchCollectionPopoverFocus: Hashable {
    case details
    case member(LibraryBook.ID)
    case metadata(LibraryBook.ID)
    case reader(LibraryBook.ID)

    var memberID: LibraryBook.ID? {
        switch self {
        case .member(let id), .metadata(let id), .reader(let id): id
        case .details: nil
        }
    }

    static func next(
        after current: Self?, backwards: Bool, memberIDs: [LibraryBook.ID],
        metadataIDs: Set<LibraryBook.ID> = [], showsReader: Bool = false
    ) -> Self {
        let targets: [Self] = memberIDs.flatMap { id in
            var row: [Self] = [.member(id)]
            if metadataIDs.contains(id) { row.append(.metadata(id)) }
            if showsReader { row.append(.reader(id)) }
            return row
        } + [.details]
        guard let current, let index = targets.firstIndex(of: current) else {
            return backwards ? targets[targets.count - 1] : targets[0]
        }
        return targets[(index + (backwards ? -1 : 1) + targets.count) % targets.count]
    }
}

struct SearchCollectionPopoverMetrics: Equatable {
    static let headerHeight: CGFloat = 80
    static let dividerHeight: CGFloat = 1
    static let horizontalSpacing: CGFloat = 12
    static let verticalSpacing: CGFloat = 16

    let size: CGSize
    let columns: Int
    let bookCardMetrics: BookCardMetrics
    let gridPadding: CGFloat
    let contentHeight: CGFloat

    var cardWidth: CGFloat { bookCardMetrics.cardWidth }
    let memberHeight: CGFloat

    init(viewport: CGSize, memberCount: Int, cardMetrics: BookCardMetrics = .default, fields: BookCardFields = .all) {
        // 给四张当前尺寸的卡片及列间距留足宽度，窗口较窄时仍按可用空间换行。
        let fourColumnWidth = CGFloat(max(0, cardMetrics.width)) * 4 + Self.horizontalSpacing * 3 + 32
        let width = min(max(560, fourColumnWidth), max(0, viewport.width - 32))
        gridPadding = min(16, width / 2)
        let contentWidth = max(0, width - gridPadding * 2)
        // 正常窗口沿用搜索卡片尺寸；只有连一张也放不下时才收窄，不拉伸填满网格。
        bookCardMetrics = BookCardMetrics(width: min(max(0, cardMetrics.width), Int(contentWidth)))
        columns = max(1, Int((contentWidth + Self.horizontalSpacing) / (bookCardMetrics.cardWidth + Self.horizontalSpacing)))
        let rows = max(1, Int(ceil(Double(max(0, memberCount)) / Double(columns))))
        memberHeight = bookCardMetrics.cardHeight(for: fields)
        contentHeight = gridPadding * 2 + CGFloat(rows) * memberHeight + CGFloat(rows - 1) * Self.verticalSpacing
        // 向上取整并留少量空间，避免分数点尺寸及原生焦点滚动造成单排的轻微溢出。
        let naturalHeight = ceil(Self.headerHeight + Self.dividerHeight + contentHeight + 12)
        size = CGSize(width: width, height: min(540, max(0, viewport.height - 32), naturalHeight))
    }

    static func clampedOffset(_ offset: CGFloat, contentHeight: CGFloat, viewportHeight: CGFloat) -> CGFloat {
        min(max(0, offset), max(0, contentHeight - viewportHeight))
    }

    static func isAnchorVisible(_ frame: CGRect, viewport: CGSize, topInset: CGFloat) -> Bool {
        let visible = CGRect(x: 0, y: topInset, width: viewport.width, height: max(0, viewport.height - topInset))
        return frame.width > 0 && frame.height > 0 && !visible.isEmpty && frame.intersects(visible)
    }
}
