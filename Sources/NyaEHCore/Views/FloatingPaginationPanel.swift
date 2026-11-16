// 本文件提供可复用的独立玻璃浮窗与分页组合，避免与背后的滚动内容发生玻璃形状融合。

import SwiftUI

struct FloatingGlassPanel<Content: View>: View {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    let cornerRadius: CGFloat
    let horizontalPadding: CGFloat
    let verticalPadding: CGFloat
    private let content: Content

    init(
        cornerRadius: CGFloat = FloatingPanelMetrics.cornerRadius,
        horizontalPadding: CGFloat = FloatingPanelMetrics.horizontalPadding,
        verticalPadding: CGFloat = FloatingPanelMetrics.verticalPadding,
        @ViewBuilder content: () -> Content
    ) {
        self.cornerRadius = cornerRadius
        self.horizontalPadding = horizontalPadding
        self.verticalPadding = verticalPadding
        self.content = content()
    }

    var body: some View {
        if #available(macOS 26.0, *) {
            GlassEffectContainer(spacing: 0) {
                paddedContent
                    .glassEffect(.regular, in: panelShape)
            }
        } else if reduceTransparency {
            paddedContent
                .background(Color(nsColor: .controlBackgroundColor), in: panelShape)
                .overlay { panelShape.stroke(.separator.opacity(0.65), lineWidth: 1) }
        } else {
            paddedContent
                .background(.regularMaterial, in: panelShape)
                .overlay { panelShape.stroke(.white.opacity(0.17), lineWidth: 1) }
                .shadow(color: .black.opacity(0.05), radius: 12, x: 0, y: 5)
        }
    }

    private var paddedContent: some View {
        content
            .padding(.horizontal, horizontalPadding)
            .padding(.vertical, verticalPadding)
    }

    private var panelShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
    }
}

struct FloatingPaginationPanel<TrailingContent: View>: View {
    @Binding var page: Int
    @Binding var pageSize: Int
    let itemCount: Int
    let localizer: AppLocalizer
    var allowedPageSizes = PageSizeOption.allowedValues
    var resetsPageOnPageSizeChange: Bool
    private let showsTrailingContent: Bool
    private let trailingContent: TrailingContent

    init(
        page: Binding<Int>,
        pageSize: Binding<Int>,
        itemCount: Int,
        localizer: AppLocalizer,
        allowedPageSizes: [Int] = PageSizeOption.allowedValues,
        resetsPageOnPageSizeChange: Bool = true
    ) where TrailingContent == EmptyView {
        _page = page
        _pageSize = pageSize
        self.itemCount = itemCount
        self.localizer = localizer
        self.allowedPageSizes = allowedPageSizes
        self.resetsPageOnPageSizeChange = resetsPageOnPageSizeChange
        showsTrailingContent = false
        trailingContent = EmptyView()
    }

    init(
        page: Binding<Int>,
        pageSize: Binding<Int>,
        itemCount: Int,
        localizer: AppLocalizer,
        allowedPageSizes: [Int] = PageSizeOption.allowedValues,
        resetsPageOnPageSizeChange: Bool = true,
        @ViewBuilder trailingContent: () -> TrailingContent
    ) {
        _page = page
        _pageSize = pageSize
        self.itemCount = itemCount
        self.localizer = localizer
        self.allowedPageSizes = allowedPageSizes
        self.resetsPageOnPageSizeChange = resetsPageOnPageSizeChange
        showsTrailingContent = true
        self.trailingContent = trailingContent()
    }

    var body: some View {
        FloatingGlassPanel {
            HStack(spacing: 10) {
                panelContent

                if showsTrailingContent {
                    Divider()
                        .frame(height: 22)

                    trailingContent
                }
            }
        }
    }

    private var panelContent: some View {
        ViewThatFits(in: .horizontal) {
            paginationControls(usesIconOnlyNavigation: false)
            paginationControls(usesIconOnlyNavigation: true)
        }
    }

    private func paginationControls(usesIconOnlyNavigation: Bool) -> some View {
        PaginationControls(
            page: $page,
            pageSize: $pageSize,
            itemCount: itemCount,
            localizer: localizer,
            usesIconOnlyNavigation: usesIconOnlyNavigation,
            allowedPageSizes: allowedPageSizes,
            resetsPageOnPageSizeChange: resetsPageOnPageSizeChange
        )
    }
}

struct FloatingPaginationDock<LeadingContent: View, TrailingContent: View, CompactActions: View>: View {
    @Binding var page: Int
    @Binding var pageSize: Int
    let itemCount: Int
    let showsPagination: Bool
    let showsLeadingPanel: Bool
    let showsTrailingPanel: Bool
    let showsCompactMenu: Bool
    let localizer: AppLocalizer
    var allowedPageSizes = PageSizeOption.allowedValues
    var resetsPageOnPageSizeChange: Bool
    private let leadingContent: LeadingContent
    private let trailingContent: TrailingContent
    private let compactActions: CompactActions

    init(
        page: Binding<Int>,
        pageSize: Binding<Int>,
        itemCount: Int,
        showsPagination: Bool,
        showsLeadingPanel: Bool = true,
        showsTrailingPanel: Bool = true,
        showsCompactMenu: Bool = true,
        localizer: AppLocalizer,
        allowedPageSizes: [Int] = PageSizeOption.allowedValues,
        resetsPageOnPageSizeChange: Bool = true,
        @ViewBuilder leadingContent: () -> LeadingContent,
        @ViewBuilder trailingContent: () -> TrailingContent,
        @ViewBuilder compactActions: () -> CompactActions
    ) {
        _page = page
        _pageSize = pageSize
        self.itemCount = itemCount
        self.showsPagination = showsPagination
        self.showsLeadingPanel = showsLeadingPanel
        self.showsTrailingPanel = showsTrailingPanel
        self.showsCompactMenu = showsCompactMenu
        self.localizer = localizer
        self.allowedPageSizes = allowedPageSizes
        self.resetsPageOnPageSizeChange = resetsPageOnPageSizeChange
        self.leadingContent = leadingContent()
        self.trailingContent = trailingContent()
        self.compactActions = compactActions()
    }

    var body: some View {
        ViewThatFits(in: .horizontal) {
            regularLayout
            compactLayout
        }
        .frame(maxWidth: .infinity)
    }

    private var regularLayout: some View {
        HStack(spacing: FloatingPanelMetrics.panelSpacing) {
            if showsLeadingPanel {
                FloatingGlassPanel {
                    leadingContent
                }
                .fixedSize(horizontal: true, vertical: true)
            }

            Spacer(minLength: FloatingPanelMetrics.panelSpacing)

            if showsPagination {
                FloatingPaginationPanel(
                    page: $page,
                    pageSize: $pageSize,
                    itemCount: itemCount,
                    localizer: localizer,
                    allowedPageSizes: allowedPageSizes,
                    resetsPageOnPageSizeChange: resetsPageOnPageSizeChange
                )
                .fixedSize(horizontal: true, vertical: true)
            }

            Spacer(minLength: FloatingPanelMetrics.panelSpacing)

            if showsTrailingPanel {
                FloatingGlassPanel {
                    trailingContent
                }
                .fixedSize(horizontal: true, vertical: true)
            }
        }
    }

    @ViewBuilder
    private var compactLayout: some View {
        HStack(spacing: 0) {
            Spacer(minLength: 0)

            if showsPagination {
                if showsCompactMenu {
                    FloatingPaginationPanel(
                        page: $page,
                        pageSize: $pageSize,
                        itemCount: itemCount,
                        localizer: localizer,
                        allowedPageSizes: allowedPageSizes,
                        resetsPageOnPageSizeChange: resetsPageOnPageSizeChange
                    ) {
                        compactMenu
                    }
                } else {
                    FloatingPaginationPanel(
                        page: $page,
                        pageSize: $pageSize,
                        itemCount: itemCount,
                        localizer: localizer,
                        allowedPageSizes: allowedPageSizes,
                        resetsPageOnPageSizeChange: resetsPageOnPageSizeChange
                    )
                }
            } else if showsCompactMenu {
                FloatingGlassPanel(horizontalPadding: 9, verticalPadding: 9) {
                    compactMenu
                }
            }

            Spacer(minLength: 0)
        }
    }

    private var compactMenu: some View {
        Menu {
            compactActions
        } label: {
            Image(systemName: "ellipsis")
                .frame(width: 18, height: 18)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(localizer.string(.floatingFooterMoreActions))
        .accessibilityLabel(localizer.string(.floatingFooterMoreActions))
    }
}

enum FloatingPaginationPresentation {
    static func showsPagination(itemCount: Int) -> Bool {
        itemCount > 0
    }
}

private enum FloatingPanelMetrics {
    static let cornerRadius: CGFloat = 16
    static let horizontalPadding: CGFloat = 12
    static let verticalPadding: CGFloat = 12
    static let panelSpacing: CGFloat = 14
}
