// 本文件集中注册 macOS 菜单命令和快捷键，把页面相关动作交给 focused command context 执行。

import SwiftUI

struct NyaEHCommands: Commands {
    let preferences: AppPreferences
    let updateManager: UpdateManager?

    @FocusedValue(\.nyaehAppCommands) private var appCommands
    @FocusedValue(\.nyaehBookCommands) private var bookCommands
    @FocusedValue(\.nyaehViewCommands) private var viewCommands
    @FocusedValue(\.nyaehPageCommands) private var pageCommands

    private var localizer: AppLocalizer {
        preferences.localizer
    }

    var body: some Commands {
        CommandGroup(after: .appInfo) {
            if let updateManager {
                Button(localizer.string(.checkForUpdates)) { updateManager.checkForUpdates() }
            }
        }

        CommandGroup(replacing: .newItem) {
            commandButton(.toggleFavorite, isEnabled: bookCommands?.canToggleFavorite ?? false) {
                bookCommands?.toggleFavorite()
            }
            commandButton(.copyTitle, isEnabled: bookCommands?.canCopyTitle ?? false) {
                bookCommands?.copyTitle()
            }
            commandButton(.fetchMetadata, isEnabled: bookCommands?.canFetchMetadata ?? false) {
                bookCommands?.fetchMetadata()
            }
            commandButton(.editMetadata, isEnabled: bookCommands?.canEditMetadata ?? false) {
                bookCommands?.editMetadata()
            }
            commandButton(.rescanCover, isEnabled: bookCommands?.canRescanCover ?? false) {
                bookCommands?.rescanCover()
            }

            Divider()

            commandButton(.navigateImport, isEnabled: appCommands != nil) {
                appCommands?.navigate(.importLibrary)
            }
        }

        CommandGroup(replacing: .toolbar) {
            commandButton(.increaseCardSize, isEnabled: viewCommands?.canIncreaseCardSize ?? false) {
                viewCommands?.increaseCardSize()
            }
            commandButton(.decreaseCardSize, isEnabled: viewCommands?.canDecreaseCardSize ?? false) {
                viewCommands?.decreaseCardSize()
            }

            Divider()

            Menu(localizer.string(.viewDisplayMode)) {
                viewOptionButton(.setLayoutCard, isSelected: viewCommands?.layout == .card, isEnabled: viewCommands?.layout != nil) {
                    viewCommands?.setLayout(.card)
                }
                viewOptionButton(.setLayoutRow, isSelected: viewCommands?.layout == .row, isEnabled: viewCommands?.layout != nil) {
                    viewCommands?.setLayout(.row)
                }
                viewOptionButton(.setLayoutExpandedRow, isSelected: viewCommands?.layout == .expandedRow, isEnabled: viewCommands?.layout != nil) {
                    viewCommands?.setLayout(.expandedRow)
                }
            }
            .disabled(viewCommands?.layout == nil)

            Menu(localizer.string(.viewSortStrategy)) {
                if viewCommands?.searchResultSortKey != nil {
                    ForEach(SearchResultSortKey.allCases) { key in
                        searchSortOptionButton(key)
                    }
                } else {
                    viewOptionButton(.setSortAlphabetical, isSelected: viewCommands?.sortStrategy == .alphabetical, isEnabled: viewCommands?.sortStrategy != nil) {
                        viewCommands?.setSortStrategy(.alphabetical)
                    }
                    viewOptionButton(.setSortCount, isSelected: viewCommands?.sortStrategy == .count, isEnabled: viewCommands?.sortStrategy != nil) {
                        viewCommands?.setSortStrategy(.count)
                    }
                }
            }
            .disabled(viewCommands?.sortStrategy == nil && viewCommands?.searchResultSortKey == nil)

            Divider()

            viewOptionButton(.setSortAscending, isSelected: viewCommands?.sortDirection == .ascending, isEnabled: viewCommands?.sortDirection != nil) {
                viewCommands?.setSortDirection(.ascending)
            }
            viewOptionButton(.setSortDescending, isSelected: viewCommands?.sortDirection == .descending, isEnabled: viewCommands?.sortDirection != nil) {
                viewCommands?.setSortDirection(.descending)
            }
        }

        CommandMenu(localizer.string(.commandMenuNavigate)) {
            commandButton(.navigateHome, isEnabled: appCommands != nil) {
                appCommands?.navigate(.home)
            }

            Divider()

            commandButton(.navigateWorkTags, isEnabled: appCommands != nil) {
                appCommands?.navigate(.tagCategory(.work))
            }
            commandButton(.navigateCreatorTags, isEnabled: appCommands != nil) {
                appCommands?.navigate(.tagCategory(.creator))
            }
            commandButton(.navigateContentTags, isEnabled: appCommands != nil) {
                appCommands?.navigate(.tagCategory(.tags))
            }

            Divider()

            commandButton(.navigateFavorites, isEnabled: appCommands != nil) {
                appCommands?.navigate(.favoriteManagement)
            }
            commandButton(.navigateCollections, isEnabled: appCommands != nil) {
                appCommands?.navigate(.collectionManagement)
            }
            commandButton(.navigateVersions, isEnabled: appCommands != nil) {
                appCommands?.navigate(.versionManagement)
            }
        }

        CommandMenu(localizer.string(.commandMenuAction)) {
            commandButton(.focusSearch, isEnabled: appCommands != nil) {
                appCommands?.focusSearch()
            }
            commandButton(.refreshLibrary, isEnabled: appCommands != nil) {
                appCommands?.refreshLibrary()
            }
            commandButton(.goBack, isEnabled: appCommands?.canGoBack ?? false) {
                appCommands?.goBack()
            }
            commandButton(.previousPage, isEnabled: pageCommands?.canGoPrevious ?? false) {
                pageCommands?.goPrevious()
            }
            commandButton(.nextPage, isEnabled: pageCommands?.canGoNext ?? false) {
                pageCommands?.goNext()
            }
        }
    }

    private func commandButton(
        _ id: AppCommandID,
        isEnabled: Bool,
        action: @escaping @MainActor () -> Void
    ) -> some View {
        let shortcut = AppShortcutPreset.shortcut(id)
        return Button(localizer.string(shortcut.titleKey), action: action)
            .appKeyboardShortcut(shortcut)
            .disabled(!isEnabled)
    }

    private func viewOptionButton(
        _ id: AppCommandID,
        isSelected: Bool,
        isEnabled: Bool,
        action: @escaping @MainActor () -> Void
    ) -> some View {
        let shortcut = AppShortcutPreset.shortcut(id)
        let title = localizer.string(shortcut.titleKey)
        return Button(isSelected ? "\(localizer.string(.selectedMenuItemPrefix)) \(title)" : title, action: action)
            .disabled(!isEnabled)
    }

    private func searchSortOptionButton(_ key: SearchResultSortKey) -> some View {
        let isSelected = viewCommands?.searchResultSortKey == key
        let title = localizer.string(key.titleKey)
        return Button(isSelected ? "\(localizer.string(.selectedMenuItemPrefix)) \(title)" : title) {
            viewCommands?.setSearchResultSortKey(key)
        }
        .disabled(viewCommands?.searchResultSortKey == nil)
    }
}
