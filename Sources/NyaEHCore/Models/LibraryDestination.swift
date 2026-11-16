// 本文件定义 LibraryDestination 领域模型，是数据库、服务层和 SwiftUI 视图之间传递业务状态的结构。

import Foundation
import CoreGraphics

enum LibraryDestination: Hashable, Identifiable, Sendable {
    case home
    case search
    @available(*, deprecated, message: "Search is the user-facing library browser; keep only for internal programmatic access.")
    case library
    case tagCategory(TagCategory)
    case collection(LibraryFilter)
    case favoriteManagement
    case collectionManagement
    case versionManagement
    case importLibrary
    case developmentTools

    var id: String {
        switch self {
        case .home:
            return "home"
        case .search:
            return "search"
        case .library:
            return "library"
        case .tagCategory(let category):
            return "tagCategory.\(category.id)"
        case .collection(let filter):
            return "collection.\(filter.id)"
        case .favoriteManagement:
            return "favoriteManagement"
        case .collectionManagement:
            return "collectionManagement"
        case .versionManagement:
            return "versionManagement"
        case .importLibrary:
            return "importLibrary"
        case .developmentTools:
            return "developmentTools"
        }
    }

    var sidebarDestination: LibraryDestination {
        self
    }
}

enum LibraryRoute: Hashable, Identifiable, Sendable {
    case collectionDetail(BookCollection.ID)
    case workDetail(Tag.DatabaseID)
    case characterDetail(Tag.DatabaseID)
    case bookDetail(LibraryBook.ID)

    var id: String {
        switch self {
        case .collectionDetail(let collectionID):
            return "collection.\(collectionID)"
        case .workDetail(let tagID):
            return "work.\(tagID)"
        case .characterDetail(let tagID):
            return "character.\(tagID)"
        case .bookDetail(let bookID):
            return "book.\(bookID)"
        }
    }
}

enum LibraryNavigationPathReducer {
    static func pathAfterSelectingBaseDestination() -> [LibraryRoute] {
        []
    }

    static func pathAfterGoingBack(from path: [LibraryRoute]) -> [LibraryRoute] {
        guard !path.isEmpty else {
            return path
        }
        return Array(path.dropLast())
    }

    static func pathAfterOpeningTopic(_ route: LibraryRoute, currentPath: [LibraryRoute]) -> [LibraryRoute] {
        switch route {
        case .workDetail, .characterDetail:
            return topicPath(appending: route, to: currentPath)
        case .bookDetail, .collectionDetail:
            return currentPath
        }
    }

    private static func topicPath(appending route: LibraryRoute, to path: [LibraryRoute]) -> [LibraryRoute] {
        guard path.last != route else { return path }
        if path.dropLast().last == route {
            return Array(path.dropLast())
        }
        return Array(path.suffix(1)) + [route]
    }

    static func pathAfterOpeningBook(
        _ bookID: LibraryBook.ID,
        source: BookOpenSource,
        currentPath: [LibraryRoute]
    ) -> [LibraryRoute] {
        let route = LibraryRoute.bookDetail(bookID)

        switch source {
        case .bookDetail:
            return currentPath
        case .workDetail, .characterDetail, .collectionDetail:
            return pathAfterAppending(route, currentPath: currentPath)
        case .home, .search, .library, .management:
            return [route]
        }
    }

    private static func pathAfterAppending(_ route: LibraryRoute, currentPath: [LibraryRoute]) -> [LibraryRoute] {
        guard currentPath.last != route else {
            return currentPath
        }
        return currentPath + [route]
    }

}

enum TagOpenDestination: Equatable {
    case search
    case workDetail
    case characterDetail
}

enum TagOpenDestinationResolver {
    static func destination(for tag: TagDisplaySummary) -> TagOpenDestination {
        if tag.namespace == "character" {
            return .characterDetail
        }
        guard tag.namespace == "parody" else {
            return .search
        }

        return isOriginalWorkTag(tag) ? .search : .workDetail
    }

    private static func isOriginalWorkTag(_ tag: TagDisplaySummary) -> Bool {
        let normalizedName = tag.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let normalizedRawValue = tag.rawValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

        return normalizedName == "original"
            || normalizedName == "origin"
            || normalizedRawValue == "parody:original"
            || normalizedRawValue == "parody:origin"
    }
}

enum LibraryRouteTransitionStyle: Equatable {
    case identity
    case trailingMoveOpacity
}

enum LibraryRouteLayerState: Equatable {
    case active
    case transitionBacking
    case frozen
}

enum LibraryRouteContentWeight: Equatable {
    case full
    case frozenPlaceholder
}

enum LibraryRouteFrozenContentPolicy: Equatable {
    case placeholderOnly
}

enum LibraryRouteBackingActivationAnimationPolicy: Equatable {
    case disabledAnimation
}

enum WorkDetailScrollLifecycleEvent: Equatable {
    case routeFrozenThenRestored
    case baseDestinationChanged
    case bookDetailReplacement
}

enum WorkDetailScrollRestorationPolicy {
    static let restorationAnimationPolicy: LibraryRouteBackingActivationAnimationPolicy = .disabledAnimation

    static func shouldPreserveScrollOffset(for event: WorkDetailScrollLifecycleEvent) -> Bool {
        switch event {
        case .routeFrozenThenRestored, .bookDetailReplacement:
            return true
        case .baseDestinationChanged:
            return false
        }
    }

    static func clampedOffset(_ offset: CGFloat, documentHeight: CGFloat, viewportHeight: CGFloat) -> CGFloat {
        min(max(offset, 0), max(documentHeight - viewportHeight, 0))
    }
}

enum WorkDetailRouteScrollCachePolicy {
    static func cacheAfterBaseDestinationChange(_ cache: [LibraryRoute.ID: CGFloat]) -> [LibraryRoute.ID: CGFloat] {
        [:]
    }

    static func cacheAfterPathChange(
        _ cache: [LibraryRoute.ID: CGFloat],
        oldPath: [LibraryRoute],
        newPath: [LibraryRoute]
    ) -> [LibraryRoute.ID: CGFloat] {
        let newRouteIDs = Set(newPath.map(\.id))
        let removedWorkRouteIDs = Set(oldPath.map(\.id))
            .subtracting(newRouteIDs)
            .filter { $0.hasPrefix("work.") || $0.hasPrefix("character.") }

        guard !removedWorkRouteIDs.isEmpty else {
            return cache
        }
        return cache.filter { !removedWorkRouteIDs.contains($0.key) }
    }
}

final class WorkDetailRouteScrollOffsetStore {
    private var offsets: [LibraryRoute.ID: CGFloat] = [:]

    func offset(for routeID: LibraryRoute.ID) -> CGFloat? {
        offsets[routeID]
    }

    func setOffset(_ offset: CGFloat, for routeID: LibraryRoute.ID) {
        offsets[routeID] = offset
    }

    func clearAfterBaseDestinationChange() {
        offsets = WorkDetailRouteScrollCachePolicy.cacheAfterBaseDestinationChange(offsets)
    }

    func pruneAfterPathChange(oldPath: [LibraryRoute], newPath: [LibraryRoute]) {
        offsets = WorkDetailRouteScrollCachePolicy.cacheAfterPathChange(
            offsets,
            oldPath: oldPath,
            newPath: newPath
        )
    }
}

enum WorkDetailSectionContentWeight: Equatable {
    case full
    case placeholder
}

enum WorkDetailSectionViewportPolicy {
    static let initialVisibleIndex = 0
    static let prefetchDistance = 1
    static let maximumTrackedDistance = 4

    static func contentWeight(
        for index: Int,
        visibleRange: ClosedRange<Int>?,
        totalCount: Int
    ) -> WorkDetailSectionContentWeight {
        guard totalCount > 0 else {
            return .placeholder
        }

        let lowerBound: Int
        let upperBound: Int
        if let visibleRange {
            lowerBound = max(visibleRange.lowerBound - prefetchDistance, 0)
            upperBound = min(visibleRange.upperBound + prefetchDistance, totalCount - 1)
        } else {
            lowerBound = 0
            upperBound = min(WorkDetailSectionRenderBudget.initialUnlockedCount - 1, totalCount - 1)
        }

        return (lowerBound...upperBound).contains(index) ? .full : .placeholder
    }

    static func visibleRange(afterVisibilityChange visibleIndices: Set<Int>, totalCount: Int) -> ClosedRange<Int>? {
        guard totalCount > 0, let minIndex = visibleIndices.min(), let maxIndex = visibleIndices.max() else {
            return nil
        }
        return max(minIndex, 0)...min(maxIndex, totalCount - 1)
    }
}

enum LibraryRouteMountContent: Equatable {
    case transitionShell
    case full
}

enum LibraryRouteMountDeferralPolicy {
    static let activationAnimationPolicy: LibraryRouteBackingActivationAnimationPolicy = .disabledAnimation
    static let contentReplacementAnimationPolicy: LibraryRouteBackingActivationAnimationPolicy = .disabledAnimation
    static let contentReplacementTransitionStyle: LibraryRouteTransitionStyle = .identity

    static func deferredRouteIDs(from oldPath: [LibraryRoute], to newPath: [LibraryRoute]) -> Set<LibraryRoute.ID> {
        if newPath.count == oldPath.count {
            guard let oldTop = oldPath.last,
                  let newTop = newPath.last,
                  oldTop != newTop,
                  newPath.dropLast().last == oldTop else {
                return []
            }
        }
        return deferredTopShellRouteID(in: newPath)
    }

    static func content(for route: LibraryRoute, deferredRouteIDs: Set<LibraryRoute.ID>) -> LibraryRouteMountContent {
        switch route {
        case .workDetail, .characterDetail, .bookDetail:
            return deferredRouteIDs.contains(route.id) ? .transitionShell : .full
        case .collectionDetail:
            return .full
        }
    }

    private static func deferredTopShellRouteID(in path: [LibraryRoute]) -> Set<LibraryRoute.ID> {
        guard let topRoute = path.last else {
            return []
        }
        switch topRoute {
        case .workDetail, .characterDetail, .bookDetail:
            return [topRoute.id]
        case .collectionDetail:
            return []
        }
    }
}

enum LibraryRoutePresentation {
    static func layerState(
        routeID: LibraryRoute.ID,
        index: Int,
        pathCount: Int,
        transitionBackingRouteIDs: Set<LibraryRoute.ID>
    ) -> LibraryRouteLayerState {
        guard !isTopRoute(index: index, pathCount: pathCount) else {
            return .active
        }
        return transitionBackingRouteIDs.contains(routeID) ? .transitionBacking : .frozen
    }

    static func isTopRoute(index: Int, pathCount: Int) -> Bool {
        index == pathCount - 1
    }

    static func allowsHitTesting(layerState: LibraryRouteLayerState) -> Bool {
        layerState == .active
    }

    static func contentWeight(for layerState: LibraryRouteLayerState) -> LibraryRouteContentWeight {
        switch layerState {
        case .active, .transitionBacking:
            return .full
        case .frozen:
            return .frozenPlaceholder
        }
    }

    static func transitionStyle(for route: LibraryRoute) -> LibraryRouteTransitionStyle {
        switch route {
        case .bookDetail, .collectionDetail, .workDetail, .characterDetail:
            return .trailingMoveOpacity
        }
    }

    static func frozenContentPolicy(for route: LibraryRoute) -> LibraryRouteFrozenContentPolicy {
        switch route {
        case .bookDetail, .collectionDetail, .workDetail, .characterDetail:
            return .placeholderOnly
        }
    }
}

enum LibraryRouteTransitionBackingResolver {
    static let activationAnimationPolicy: LibraryRouteBackingActivationAnimationPolicy = .disabledAnimation

    static func backingRouteIDs(from oldPath: [LibraryRoute], to newPath: [LibraryRoute]) -> Set<LibraryRoute.ID> {
        if newPath.count > oldPath.count {
            return oldPath.last.map { [$0.id] } ?? []
        }
        if newPath.count < oldPath.count {
            return newPath.last.map { [$0.id] } ?? []
        }
        if let oldTop = oldPath.last, newPath.dropLast().last == oldTop {
            return [oldTop.id]
        }
        return []
    }
}
