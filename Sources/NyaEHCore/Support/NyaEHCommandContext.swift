// 本文件提供 NyaEHCommandContext 支撑工具，承载格式化、环境值、缓存或本地化等横切逻辑。

import SwiftUI

struct NyaEHAppCommandContext {
    let canGoBack: Bool
    let goBack: @MainActor () -> Void
    let navigate: @MainActor (LibraryDestination) -> Void
    let refreshLibrary: @MainActor () -> Void
    let focusSearch: @MainActor () -> Void
}

struct NyaEHBookCommandContext {
    let canToggleFavorite: Bool
    let toggleFavorite: @MainActor () -> Void
    let canCopyTitle: Bool
    let copyTitle: @MainActor () -> Void
    let canFetchMetadata: Bool
    let fetchMetadata: @MainActor () -> Void
    let canEditMetadata: Bool
    let editMetadata: @MainActor () -> Void
    let canRescanCover: Bool
    let rescanCover: @MainActor () -> Void
}

struct NyaEHViewCommandContext {
    let canIncreaseCardSize: Bool
    let increaseCardSize: @MainActor () -> Void
    let canDecreaseCardSize: Bool
    let decreaseCardSize: @MainActor () -> Void
    let layout: SearchResultLayout?
    let setLayout: @MainActor (SearchResultLayout) -> Void
    let sortStrategy: TagSortStrategy?
    let setSortStrategy: @MainActor (TagSortStrategy) -> Void
    let searchResultSortKey: SearchResultSortKey?
    let setSearchResultSortKey: @MainActor (SearchResultSortKey) -> Void
    let sortDirection: SortDirection?
    let setSortDirection: @MainActor (SortDirection) -> Void
}

struct NyaEHPageCommandContext {
    let canGoPrevious: Bool
    let goPrevious: @MainActor () -> Void
    let canGoNext: Bool
    let goNext: @MainActor () -> Void
}

private struct NyaEHAppCommandContextKey: FocusedValueKey {
    typealias Value = NyaEHAppCommandContext
}

private struct NyaEHBookCommandContextKey: FocusedValueKey {
    typealias Value = NyaEHBookCommandContext
}

private struct NyaEHViewCommandContextKey: FocusedValueKey {
    typealias Value = NyaEHViewCommandContext
}

private struct NyaEHPageCommandContextKey: FocusedValueKey {
    typealias Value = NyaEHPageCommandContext
}

extension FocusedValues {
    var nyaehAppCommands: NyaEHAppCommandContext? {
        get { self[NyaEHAppCommandContextKey.self] }
        set { self[NyaEHAppCommandContextKey.self] = newValue }
    }

    var nyaehBookCommands: NyaEHBookCommandContext? {
        get { self[NyaEHBookCommandContextKey.self] }
        set { self[NyaEHBookCommandContextKey.self] = newValue }
    }

    var nyaehViewCommands: NyaEHViewCommandContext? {
        get { self[NyaEHViewCommandContextKey.self] }
        set { self[NyaEHViewCommandContextKey.self] = newValue }
    }

    var nyaehPageCommands: NyaEHPageCommandContext? {
        get { self[NyaEHPageCommandContextKey.self] }
        set { self[NyaEHPageCommandContextKey.self] = newValue }
    }
}
