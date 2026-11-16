import AppKit
import Observation
import SwiftUI
import Testing
@testable import NyaEHCore

@MainActor
@Suite("Main-window native toolbar layout", .serialized)
struct MainWindowToolbarLayoutTests {
    @Test("actions stay after a detail-column spacer through page changes, with and without identity",
          arguments: [false, true], [920, 1600])
    func trailingActions(identity: Bool, width: Int) throws {
        _ = NSApplication.shared
        let state = FixtureState()
        let window = NSWindow(
            contentRect: NSRect(x: -10000, y: -10000, width: width, height: 600),
            styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentViewController = NSHostingController(rootView: Fixture(state: state, identity: identity))
        defer {
            window.contentViewController = nil
            window.close()
        }
        // Never order the window on screen, activate the app, or instantiate stores.
        for page in [Page.home, .search, .coverSearch, .home, .categoryWide, .categoryCompact, .detail, .home, .search] {
            state.page = page
            let deadline = Date().addingTimeInterval(1)
            repeat {
                RunLoop.main.run(until: Date().addingTimeInterval(0.01))
            } while actionIDs(in: window.toolbar) != page.actionIDs && Date() < deadline

            let toolbar = try #require(window.toolbar)
            let actual = actionIDs(in: toolbar)
            #expect(actual == page.actionIDs)
            #expect(Set(actual).count == actual.count)
            let firstIndex = try #require(toolbar.items.firstIndex { $0.itemIdentifier.rawValue == page.actionIDs.first })
            let previousItem = try #require(toolbar.items.prefix(firstIndex).last)
            // The broken outer-split layout puts the spacer before the sidebar
            // separator instead, so the first action has no spacer before it.
            #expect(previousItem.itemIdentifier == .flexibleSpace,
                    "Page: \(String(describing: page)), items: \(toolbar.items.map(\.itemIdentifier.rawValue))")
            let trailingItems = toolbar.items[firstIndex...]
            #expect(!trailingItems.contains { $0.itemIdentifier == .flexibleSpace })
            #expect(trailingItems.filter { $0.itemIdentifier == .space }.count == page.actionIDs.count - 1)
            let centered = Set(toolbar.centeredItemIdentifiers.map(\.rawValue))
            #expect(centered.isDisjoint(with: actual))
            #expect(centered == (identity ? ["test-identity"] : []))
            #expect(!window.isVisible)
        }
    }

    private func actionIDs(in toolbar: NSToolbar?) -> [String] {
        toolbar?.items.map(\.itemIdentifier.rawValue).filter { Page.allActionIDs.contains($0) } ?? []
    }
}

private enum Page {
    case home, search, coverSearch, categoryWide, categoryCompact, detail

    var isCategory: Bool { self == .categoryWide || self == .categoryCompact }
    var hidesTitle: Bool { isCategory || self == .detail }

    var actionIDs: [String] {
        switch self {
        case .home, .detail: ["global-actions"]
        case .search: ["search-sorting", "search-display", "search-tools", "search-inspector"]
        case .coverSearch: ["search-display", "search-tools", "search-inspector"]
        case .categoryWide: ["category-sorting", "category-direction", "category-global"]
        case .categoryCompact: ["category-compact", "category-global"]
        }
    }

    static let allActionIDs: Set<String> = Set(
        [Page.home, .search, .coverSearch, .categoryWide, .categoryCompact, .detail].flatMap(\.actionIDs)
    )
}

@MainActor
@Observable
private final class FixtureState {
    var page = Page.home
}

/// Uses the production split/toolbar boundary and placement, with inert actions
/// in place of database-backed pages. Category toolbars belong to the child.
private struct Fixture: View {
    let state: FixtureState
    let identity: Bool

    var body: some View {
        MainWindowSplitView {
            Text("Sidebar")
        } detail: {
            Text("Content")
                .navigationTitle("Content")
                .toolbar {
                    if state.page.isCategory {
                        ToolbarItem(id: "category-navigation", placement: .navigation) {
                            Button("Category") {}
                        }
                        FixtureActions(ids: state.page.actionIDs)
                    } else if state.page == .detail {
                        ToolbarItem(id: "detail-back", placement: .navigation) {
                            Button("Back") {}
                        }
                    }
                }
        } actions: {
            if !state.page.isCategory {
                FixtureActions(ids: state.page.actionIDs)
            }
        }
        .toolbar(removing: state.page.hidesTitle ? .title : nil)
        .toolbar {
            if identity {
                ToolbarItem(id: "test-identity", placement: .principal) { Text("Development") }
            }
        }
    }
}

private struct FixtureActions: ToolbarContent {
    let ids: [String]

    var body: some ToolbarContent {
        ToolbarSpacer(.flexible, placement: MainWindowToolbarLayout.actionPlacement)
        ForEach(ids, id: \.self) { id in
            ToolbarItem(id: id, placement: MainWindowToolbarLayout.actionPlacement) {
                Button(id) {}
            }
            // Match production ownership: a disappearing group takes its
            // following gap with it, including the cover-search sorting group.
            if id != ids.last {
                ToolbarSpacer(.fixed, placement: MainWindowToolbarLayout.actionPlacement)
            }
        }
    }
}
