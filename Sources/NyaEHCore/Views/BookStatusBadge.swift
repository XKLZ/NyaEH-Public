// 本文件把书籍文件状态渲染成小徽章，用于列表和详情中提示缺失或损坏。

import SwiftUI

struct BookStatusBadge: View {
    let status: BookStatus
    let exist: Bool
    let localizer: AppLocalizer

    var body: some View {
        Label(title, systemImage: systemImage)
            .font(.caption)
            .foregroundStyle(foregroundStyle)
            .labelStyle(.titleAndIcon)
    }

    private var title: String {
        if !exist {
            return localizer.string(.missing)
        }

        return localizer.string(status.titleKey)
    }

    private var systemImage: String {
        if !exist {
            return "exclamationmark.triangle"
        }

        switch status {
        case .unscanned:
            return "questionmark.circle"
        case .correct:
            return "checkmark.circle"
        case .broken:
            return "xmark.octagon"
        case .missing:
            return "exclamationmark.triangle"
        }
    }

    private var foregroundStyle: Color {
        if !exist {
            return .orange
        }

        switch status {
        case .unscanned:
            return .secondary
        case .correct:
            return .green
        case .broken:
            return .red
        case .missing:
            return .orange
        }
    }
}
