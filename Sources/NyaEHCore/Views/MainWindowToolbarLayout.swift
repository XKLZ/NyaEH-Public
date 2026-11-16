import SwiftUI

@MainActor
enum MainWindowToolbarLayout {
    // On macOS secondaryAction marks items as centered. Automatic actions follow
    // a flexible spacer in the detail section to align with its trailing edge.
    static let actionPlacement: ToolbarItemPlacement = .automatic
}

/// Keep toolbar spacing in the content column, after the sidebar separator.
/// Attaching these actions to the outer split view puts spacers in the sidebar.
struct MainWindowSplitView<Sidebar: View, Detail: View, Actions: ToolbarContent>: View {
    @ViewBuilder let sidebar: () -> Sidebar
    @ViewBuilder let detail: () -> Detail
    @ToolbarContentBuilder let actions: () -> Actions

    var body: some View {
        NavigationSplitView {
            sidebar()
        } detail: {
            detail()
                .toolbar { actions() }
        }
    }
}
