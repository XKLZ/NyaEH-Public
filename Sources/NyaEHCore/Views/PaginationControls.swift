// 本文件提供统一分页控件，供搜索、书库、标签和管理页面复用。

import SwiftUI

struct PaginationControls: View {
    @Binding var page: Int
    @Binding var pageSize: Int
    let itemCount: Int
    let localizer: AppLocalizer
    var usesIconOnlyNavigation = false
    var allowedPageSizes = PageSizeOption.allowedValues
    var resetsPageOnPageSizeChange = true

    private var pageCount: Int {
        Pagination.pageCount(itemCount: itemCount, pageSize: pageSize)
    }

    private var clampedPage: Int {
        Pagination.clampedPage(page, itemCount: itemCount, pageSize: pageSize)
    }

    var body: some View {
        HStack(spacing: 14) {
            PageSizePicker(
                page: $page,
                pageSize: $pageSize,
                localizer: localizer,
                allowedPageSizes: allowedPageSizes,
                resetsPageOnChange: resetsPageOnPageSizeChange
            )

            PageNavigationControls(
                page: $page,
                pageSize: pageSize,
                itemCount: itemCount,
                localizer: localizer,
                usesIconOnlyNavigation: usesIconOnlyNavigation
            )
        }
    }
}

struct PageSizePicker: View {
    @Binding var page: Int
    @Binding var pageSize: Int
    let localizer: AppLocalizer
    var allowedPageSizes = PageSizeOption.allowedValues
    var resetsPageOnChange = true

    var body: some View {
        Picker(localizer.string(.pageSize), selection: $pageSize) {
            ForEach(allowedPageSizes, id: \.self) { option in
                Text("\(option)")
                    .tag(option)
            }
        }
        .pickerStyle(.menu)
        .controlSize(.small)
        .frame(width: 116)
        .onChange(of: pageSize) { _, newValue in
            pageSize = AppPreferences.nearestAllowedValue(newValue, allowed: allowedPageSizes)
            if resetsPageOnChange {
                page = 1
            }
        }
    }
}

struct PageNavigationControls: View {
    @Binding var page: Int
    let pageSize: Int
    let itemCount: Int
    let localizer: AppLocalizer
    var usesIconOnlyNavigation = false

    private var pageCount: Int {
        Pagination.pageCount(itemCount: itemCount, pageSize: pageSize)
    }

    private var clampedPage: Int {
        Pagination.clampedPage(page, itemCount: itemCount, pageSize: pageSize)
    }

    var body: some View {
        HStack(spacing: 14) {
            Button {
                page = max(1, clampedPage - 1)
            } label: {
                navigationLabel(title: localizer.string(.previousPage), systemImage: "chevron.left")
            }
            .help(localizer.string(.previousPage))
            .disabled(clampedPage <= 1)

            Text(localizer.pageIndicator(current: clampedPage, total: pageCount))
                .font(.callout)
                .foregroundStyle(.secondary)
                .monospacedDigit()

            Button {
                page = min(pageCount, clampedPage + 1)
            } label: {
                navigationLabel(title: localizer.string(.nextPage), systemImage: "chevron.right")
            }
            .help(localizer.string(.nextPage))
            .disabled(clampedPage >= pageCount)
        }
        .onChange(of: itemCount) { _, _ in
            page = clampedPage
        }
        .onChange(of: pageCount) { _, _ in
            page = clampedPage
        }
        .focusedSceneValue(\.nyaehPageCommands, pageCommandContext)
    }

    private var pageCommandContext: NyaEHPageCommandContext {
        NyaEHPageCommandContext(
            canGoPrevious: clampedPage > 1,
            goPrevious: {
                page = max(1, clampedPage - 1)
            },
            canGoNext: clampedPage < pageCount,
            goNext: {
                page = min(pageCount, clampedPage + 1)
            }
        )
    }

    @ViewBuilder
    private func navigationLabel(title: String, systemImage: String) -> some View {
        if usesIconOnlyNavigation {
            Image(systemName: systemImage)
                .accessibilityLabel(title)
        } else {
            Label(title, systemImage: systemImage)
        }
    }
}
