// 本文件提供 AppCommandShortcut 支撑工具，承载格式化、环境值、缓存或本地化等横切逻辑。

import SwiftUI

enum AppShortcutMenu: String, CaseIterable {
    case file
    case view
    case navigate
    case action
}

enum AppShortcutKey: Hashable {
    case character(Character)
    case returnKey
    case escape
    case leftArrow
    case rightArrow

    var keyEquivalent: KeyEquivalent {
        switch self {
        case .character(let character):
            return KeyEquivalent(character)
        case .returnKey:
            return .return
        case .escape:
            return .escape
        case .leftArrow:
            return .leftArrow
        case .rightArrow:
            return .rightArrow
        }
    }

    var signature: String {
        switch self {
        case .character(let character):
            return String(character)
        case .returnKey:
            return "return"
        case .escape:
            return "escape"
        case .leftArrow:
            return "leftArrow"
        case .rightArrow:
            return "rightArrow"
        }
    }
}

enum AppCommandID: String, CaseIterable {
    case toggleFavorite
    case copyTitle
    case fetchMetadata
    case editMetadata
    case rescanCover
    case navigateImport
    case increaseCardSize
    case decreaseCardSize
    case setLayoutCard
    case setLayoutRow
    case setLayoutExpandedRow
    case setSortAlphabetical
    case setSortCount
    case setSortAscending
    case setSortDescending
    case navigateHome
    case navigateWorkTags
    case navigateCreatorTags
    case navigateContentTags
    case navigateFavorites
    case navigateCollections
    case navigateVersions
    case focusSearch
    case refreshLibrary
    case goBack
    case previousPage
    case nextPage
}

struct AppCommandShortcut: Identifiable {
    let id: AppCommandID
    let menu: AppShortcutMenu
    let titleKey: L10nKey
    let key: AppShortcutKey?
    let modifiers: EventModifiers

    var signature: String? {
        guard let key else {
            return nil
        }
        return "\(key.signature)|\(modifierSignature)"
    }

    private var modifierSignature: String {
        var names: [String] = []
        if modifiers.contains(.command) {
            names.append("command")
        }
        if modifiers.contains(.shift) {
            names.append("shift")
        }
        if modifiers.contains(.option) {
            names.append("option")
        }
        if modifiers.contains(.control) {
            names.append("control")
        }
        return names.joined(separator: "+")
    }
}

enum AppShortcutPreset {
    static let builtIn: [AppCommandShortcut] = [
        AppCommandShortcut(id: .toggleFavorite, menu: .file, titleKey: .toggleFavorite, key: .character("l"), modifiers: [.command, .shift]),
        AppCommandShortcut(id: .copyTitle, menu: .file, titleKey: .copyTitle, key: .character("c"), modifiers: [.command, .shift]),
        AppCommandShortcut(id: .fetchMetadata, menu: .file, titleKey: .fetchMetadata, key: .character("g"), modifiers: [.command, .shift]),
        AppCommandShortcut(id: .editMetadata, menu: .file, titleKey: .editMetadata, key: .character("d"), modifiers: [.command, .shift]),
        AppCommandShortcut(id: .rescanCover, menu: .file, titleKey: .rescanCover, key: .character("r"), modifiers: [.command, .shift]),
        AppCommandShortcut(id: .navigateImport, menu: .file, titleKey: .importLibrary, key: nil, modifiers: []),
        AppCommandShortcut(id: .increaseCardSize, menu: .view, titleKey: .increaseCardSize, key: .character("+"), modifiers: [.command]),
        AppCommandShortcut(id: .decreaseCardSize, menu: .view, titleKey: .decreaseCardSize, key: .character("-"), modifiers: [.command]),
        AppCommandShortcut(id: .setLayoutCard, menu: .view, titleKey: .advancedSearchCards, key: nil, modifiers: []),
        AppCommandShortcut(id: .setLayoutRow, menu: .view, titleKey: .advancedSearchRows, key: nil, modifiers: []),
        AppCommandShortcut(id: .setLayoutExpandedRow, menu: .view, titleKey: .advancedSearchExpanded, key: nil, modifiers: []),
        AppCommandShortcut(id: .setSortAlphabetical, menu: .view, titleKey: .tagSortAlphabetical, key: nil, modifiers: []),
        AppCommandShortcut(id: .setSortCount, menu: .view, titleKey: .tagSortCount, key: nil, modifiers: []),
        AppCommandShortcut(id: .setSortAscending, menu: .view, titleKey: .sortAscending, key: nil, modifiers: []),
        AppCommandShortcut(id: .setSortDescending, menu: .view, titleKey: .sortDescending, key: nil, modifiers: []),
        AppCommandShortcut(id: .navigateHome, menu: .navigate, titleKey: .home, key: nil, modifiers: []),
        AppCommandShortcut(id: .navigateWorkTags, menu: .navigate, titleKey: .worksAndCharacters, key: nil, modifiers: []),
        AppCommandShortcut(id: .navigateCreatorTags, menu: .navigate, titleKey: .authorsAndGroups, key: nil, modifiers: []),
        AppCommandShortcut(id: .navigateContentTags, menu: .navigate, titleKey: .contentTags, key: nil, modifiers: []),
        AppCommandShortcut(id: .navigateFavorites, menu: .navigate, titleKey: .favoriteManagement, key: nil, modifiers: []),
        AppCommandShortcut(id: .navigateCollections, menu: .navigate, titleKey: .collectionManagement, key: nil, modifiers: []),
        AppCommandShortcut(id: .navigateVersions, menu: .navigate, titleKey: .versionManagement, key: nil, modifiers: []),
        AppCommandShortcut(id: .focusSearch, menu: .action, titleKey: .focusSearch, key: .character("f"), modifiers: [.command]),
        AppCommandShortcut(id: .refreshLibrary, menu: .action, titleKey: .refresh, key: .character("r"), modifiers: [.command]),
        AppCommandShortcut(id: .goBack, menu: .action, titleKey: .back, key: .escape, modifiers: []),
        AppCommandShortcut(id: .previousPage, menu: .action, titleKey: .previousPage, key: .leftArrow, modifiers: [.command]),
        AppCommandShortcut(id: .nextPage, menu: .action, titleKey: .nextPage, key: .rightArrow, modifiers: [.command])
    ]

    static func shortcut(_ id: AppCommandID) -> AppCommandShortcut {
        guard let shortcut = builtIn.first(where: { $0.id == id }) else {
            preconditionFailure("Missing built-in shortcut for \(id.rawValue)")
        }
        return shortcut
    }
}

extension View {
    @ViewBuilder
    func appKeyboardShortcut(_ shortcut: AppCommandShortcut) -> some View {
        if let key = shortcut.key {
            keyboardShortcut(key.keyEquivalent, modifiers: shortcut.modifiers)
        } else {
            self
        }
    }
}
