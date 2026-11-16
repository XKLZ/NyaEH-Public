// 本文件提供详情路由冻结占位层，避免隐藏的重视图在导航动画后继续参与布局和绘制。

import Foundation
import SwiftUI

struct FrozenWorkRouteView: View {
    let detail: WorkDetail?
    let fallbackTitle: String
    let localizer: AppLocalizer

    var body: some View {
        FrozenRoutePlaceholder(
            systemImage: "rectangle.stack",
            title: detail?.work.displayText ?? fallbackTitle,
            metrics: workMetrics
        )
    }

    private var workMetrics: [String] {
        guard let detail else {
            return []
        }
        return [
            localizer.workDetailCharacterCount(detail.characterCount),
            localizer.workDetailBookCount(detail.totalBookCount)
        ]
    }
}

struct FrozenCharacterRouteView: View {
    let detail: CharacterDetail?
    let fallbackTitle: String
    let localizer: AppLocalizer

    var body: some View {
        FrozenRoutePlaceholder(
            systemImage: "person.crop.square",
            title: detail?.character.displayText ?? fallbackTitle,
            metrics: characterMetrics
        )
    }

    private var characterMetrics: [String] {
        guard let detail else {
            return []
        }
        return [
            localizer.characterDetailWorkCount(detail.workCount),
            localizer.workDetailBookCount(detail.totalBookCount)
        ]
    }
}

struct FrozenCollectionRouteView: View {
    let collection: BookCollection?
    let bookCount: Int
    let localizer: AppLocalizer

    var body: some View {
        FrozenRoutePlaceholder(
            systemImage: "rectangle.stack.fill",
            title: collection?.name ?? localizer.string(.selectCollection),
            metrics: [localizer.collectionBookCount(bookCount)]
        )
    }
}

struct FrozenBookRouteView: View {
    let book: LibraryBook?
    let titleDisplayMode: BookTitleDisplayMode
    let localizer: AppLocalizer

    var body: some View {
        FrozenRoutePlaceholder(
            systemImage: "book.closed",
            title: book.map { BookTitleFormatter.displayTitle(for: $0, mode: titleDisplayMode) }
                ?? localizer.string(.details),
            metrics: bookMetrics
        )
    }

    private var bookMetrics: [String] {
        guard let book else {
            return []
        }
        if let pages = book.pages ?? book.fileCount {
            return ["\(localizer.string(.pages)): \(pages)"]
        }
        return []
    }
}

struct WorkDetailTransitionShell: View {
    let detail: WorkDetail?
    let fallbackTitle: String
    let localizer: AppLocalizer

    var body: some View {
        // 转场 shell 是同页骨架，不是新页面；它遮住真实重视图挂载时间，避免导航动画期间出现空白或卡顿。
        ZStack(alignment: .top) {
            Rectangle()
                .fill(Color(nsColor: .windowBackgroundColor))
                .ignoresSafeArea()

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    heroShell

                    LazyVStack(alignment: .leading, spacing: 14) {
                        ForEach(0..<skeletonCount, id: \.self) { index in
                            WorkDetailTransitionSectionSkeleton(usesDoubleRow: index == 0)
                        }
                    }
                    .padding(.horizontal, 34)
                }
                .padding(.bottom, 34)
                .frame(maxWidth: 1540, alignment: .topLeading)
                .frame(maxWidth: .infinity, alignment: .top)
            }
        }
        .redacted(reason: .placeholder)
    }

    private var heroShell: some View {
        VStack(alignment: .leading, spacing: 20) {
            RoundedRectangle(cornerRadius: 18)
                .fill(.secondary.opacity(0.16))
                .frame(width: 330, height: 185)

            Text(detail?.work.displayText ?? fallbackTitle)
                .font(.system(size: 54, weight: .bold))
                .lineLimit(2)

            HStack(spacing: 10) {
                ForEach(metrics, id: \.self) { metric in
                    Text(metric)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 5)
                        .background(.regularMaterial, in: Capsule())
                }
            }

            RoundedRectangle(cornerRadius: 8)
                .fill(.secondary.opacity(0.16))
                .frame(maxWidth: 760, minHeight: 72, maxHeight: 72)
        }
        .frame(maxWidth: 920, alignment: .leading)
        .padding(.horizontal, 58)
        .padding(.top, 58)
        .padding(.bottom, 54)
        .frame(maxWidth: .infinity, minHeight: 520, alignment: .bottomLeading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(.white.opacity(0.16), lineWidth: 1)
        }
        .padding(.horizontal, 34)
    }

    private var metrics: [String] {
        guard let detail else {
            return [
                localizer.workDetailCharacterCount(12),
                localizer.workDetailBookCount(48)
            ]
        }
        return [
            localizer.workDetailCharacterCount(detail.characterCount),
            localizer.workDetailBookCount(detail.totalBookCount)
        ]
    }

    private var skeletonCount: Int {
        min(max(detail?.sections.count ?? WorkDetailSectionRenderBudget.initialUnlockedCount, 1), 3)
    }
}

struct CharacterDetailTransitionShell: View {
    let detail: CharacterDetail?
    let fallbackTitle: String
    let localizer: AppLocalizer

    var body: some View {
        ZStack(alignment: .top) {
            Rectangle()
                .fill(Color(nsColor: .windowBackgroundColor))
                .ignoresSafeArea()

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    heroShell

                    LazyVStack(alignment: .leading, spacing: 14) {
                        ForEach(0..<skeletonCount, id: \.self) { index in
                            CharacterDetailTransitionSectionSkeleton(usesDoubleRow: index == 0)
                        }
                    }
                    .padding(.horizontal, 34)
                }
                .padding(.bottom, 34)
                .frame(maxWidth: 1540, alignment: .topLeading)
                .frame(maxWidth: .infinity, alignment: .top)
            }
        }
        .redacted(reason: .placeholder)
    }

    private var heroShell: some View {
        CharacterDetailHeroArrangement {
            VStack(alignment: .leading, spacing: 20) {
                Text(detail?.character.displayText ?? fallbackTitle)
                    .font(.system(size: 54, weight: .bold))
                    .lineLimit(2)

                HStack(spacing: 10) {
                    ForEach(metrics, id: \.self) { metric in
                        Text(metric)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 9)
                            .padding(.vertical, 5)
                            .background(.regularMaterial, in: Capsule())
                    }
                }

                RoundedRectangle(cornerRadius: 8)
                    .fill(.secondary.opacity(0.16))
                    .frame(maxWidth: 760, minHeight: 72, maxHeight: 72)
            }
            .frame(maxWidth: CharacterDetailHeroLayoutMetrics.textColumnMaxWidth, alignment: .leading)
        } figure: {
            RoundedRectangle(cornerRadius: 26)
                .fill(.secondary.opacity(0.12))
                .frame(width: 260, height: 540)
        }
        .padding(.horizontal, 34)
    }

    private var metrics: [String] {
        guard let detail else {
            return [
                localizer.characterDetailWorkCount(8),
                localizer.workDetailBookCount(48)
            ]
        }
        return [
            localizer.characterDetailWorkCount(detail.workCount),
            localizer.workDetailBookCount(detail.totalBookCount)
        ]
    }

    private var skeletonCount: Int {
        min(max(detail?.sections.count ?? WorkDetailSectionRenderBudget.initialUnlockedCount, 1), 3)
    }
}

struct BookDetailTransitionShell: View {
    let book: LibraryBook?
    let titleDisplayMode: BookTitleDisplayMode
    let localizer: AppLocalizer

    var body: some View {
        ZStack(alignment: .top) {
            Rectangle()
                .fill(Color(nsColor: .windowBackgroundColor))
                .ignoresSafeArea()

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    heroShell

                    LazyVStack(alignment: .leading, spacing: 14) {
                        ForEach(0..<3, id: \.self) { index in
                            BookDetailTransitionSectionSkeleton(columnCount: index == 0 ? 4 : 6)
                        }
                    }
                    .padding(.horizontal, 34)
                }
                .padding(.bottom, 34)
                .frame(maxWidth: BookDetailHeroMotionMetrics.maxContentWidth, alignment: .topLeading)
                .frame(maxWidth: .infinity, alignment: .top)
            }
        }
        .redacted(reason: .placeholder)
    }

    private var heroShell: some View {
        HStack(alignment: .bottom, spacing: 26) {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(.secondary.opacity(0.16))
                .frame(width: 230, height: 322)

            VStack(alignment: .leading, spacing: 18) {
                Text(title)
                    .font(.system(size: 42, weight: .bold))
                    .lineLimit(3)

                HStack(spacing: 10) {
                    ForEach(metrics, id: \.self) { metric in
                        Text(metric)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 9)
                            .padding(.vertical, 5)
                            .background(.regularMaterial, in: Capsule())
                    }
                }

                VStack(alignment: .leading, spacing: 10) {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(.secondary.opacity(0.16))
                        .frame(maxWidth: 560, minHeight: 22, maxHeight: 22)
                    RoundedRectangle(cornerRadius: 8)
                        .fill(.secondary.opacity(0.13))
                        .frame(maxWidth: 460, minHeight: 22, maxHeight: 22)
                    RoundedRectangle(cornerRadius: 8)
                        .fill(.secondary.opacity(0.11))
                        .frame(maxWidth: 360, minHeight: 22, maxHeight: 22)
                }
            }
            .frame(maxWidth: 720, alignment: .leading)
        }
        .padding(.horizontal, 46)
        .padding(.top, 48)
        .padding(.bottom, 44)
        .frame(maxWidth: .infinity, minHeight: 440, alignment: .bottomLeading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(.white.opacity(0.16), lineWidth: 1)
        }
        .padding(.horizontal, 34)
        .padding(.top, 34)
    }

    private var title: String {
        book.map { BookTitleFormatter.displayTitle(for: $0, mode: titleDisplayMode) }
            ?? localizer.string(.details)
    }

    private var metrics: [String] {
        guard let book else {
            return [
                "\(localizer.string(.pages)): 120",
                localizer.string(.unrate)
            ]
        }

        var values: [String] = []
        if let category = book.category, !category.isEmpty {
            values.append(category)
        }
        if let pages = book.pages ?? book.fileCount {
            values.append("\(localizer.string(.pages)): \(pages)")
        }
        if let rating = book.rating {
            values.append(String(format: "%.2f", rating))
        }
        return values.isEmpty ? [localizer.string(.details)] : values
    }
}

private struct BookDetailTransitionSectionSkeleton: View {
    let columnCount: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            RoundedRectangle(cornerRadius: 8)
                .fill(.secondary.opacity(0.18))
                .frame(width: 220, height: 26)

            HStack(spacing: 12) {
                ForEach(0..<columnCount, id: \.self) { index in
                    VStack(alignment: .leading, spacing: 8) {
                        RoundedRectangle(cornerRadius: 8)
                            .fill(.secondary.opacity(0.14))
                            .frame(height: index == 0 ? 62 : 44)
                        RoundedRectangle(cornerRadius: 6)
                            .fill(.secondary.opacity(0.12))
                            .frame(height: 16)
                    }
                }
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(.white.opacity(0.12), lineWidth: 1)
        }
    }
}

private struct WorkDetailTransitionSectionSkeleton: View {
    let usesDoubleRow: Bool

    var body: some View {
        HStack(alignment: .bottom, spacing: -18) {
            VStack(alignment: .leading, spacing: 10) {
                RoundedRectangle(cornerRadius: 28)
                    .fill(.secondary.opacity(0.14))
                    .frame(width: 260, height: usesDoubleRow ? 430 : 370)
                RoundedRectangle(cornerRadius: 8)
                    .fill(.secondary.opacity(0.20))
                    .frame(width: 210, height: 36)
                RoundedRectangle(cornerRadius: 8)
                    .fill(.secondary.opacity(0.16))
                    .frame(width: 96, height: 22)
            }
            .frame(width: 340, height: usesDoubleRow ? 560 : 500, alignment: .bottomLeading)

            HStack(alignment: .top, spacing: usesDoubleRow ? 16 : 20) {
                ForEach(0..<5, id: \.self) { _ in
                    VStack(spacing: usesDoubleRow ? 12 : 0) {
                        cardPlaceholder
                        if usesDoubleRow {
                            cardPlaceholder
                        }
                    }
                }
            }
            .padding(.vertical, 10)
            .padding(.leading, 28)
            .padding(.trailing, 18)
        }
        .frame(minHeight: usesDoubleRow ? 590 : 520, alignment: .bottomLeading)
        .padding(.vertical, 8)
        .padding(.horizontal, 12)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 15, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 15, style: .continuous)
                .stroke(.white.opacity(0.14), lineWidth: 1)
        }
    }

    private var cardPlaceholder: some View {
        VStack(alignment: .leading, spacing: 8) {
            RoundedRectangle(cornerRadius: 8)
                .fill(.secondary.opacity(0.16))
                .frame(width: usesDoubleRow ? 120 : 152, height: usesDoubleRow ? 170 : 216)
            RoundedRectangle(cornerRadius: 6)
                .fill(.secondary.opacity(0.18))
                .frame(width: usesDoubleRow ? 104 : 132, height: 18)
            RoundedRectangle(cornerRadius: 5)
                .fill(.secondary.opacity(0.12))
                .frame(width: usesDoubleRow ? 86 : 112, height: 14)
        }
        .frame(width: usesDoubleRow ? 120 : 152, height: usesDoubleRow ? 224 : 286, alignment: .topLeading)
    }
}

private struct CharacterDetailTransitionSectionSkeleton: View {
    let usesDoubleRow: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 10) {
                RoundedRectangle(cornerRadius: 8)
                    .fill(.secondary.opacity(0.18))
                    .frame(width: 220, height: 28)
                RoundedRectangle(cornerRadius: 999)
                    .fill(.secondary.opacity(0.14))
                    .frame(width: 86, height: 24)
            }

            HStack(alignment: .top, spacing: usesDoubleRow ? 16 : 20) {
                ForEach(0..<6, id: \.self) { _ in
                    VStack(spacing: usesDoubleRow ? 12 : 0) {
                        cardPlaceholder
                        if usesDoubleRow {
                            cardPlaceholder
                        }
                    }
                }
            }
        }
        .padding(18)
        .frame(minHeight: usesDoubleRow ? 420 : 330, alignment: .center)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 15, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 15, style: .continuous)
                .stroke(.white.opacity(0.12), lineWidth: 1)
        }
    }

    private var cardPlaceholder: some View {
        VStack(alignment: .leading, spacing: 8) {
            RoundedRectangle(cornerRadius: 10)
                .fill(.secondary.opacity(0.13))
                .frame(width: 122, height: 172)
            RoundedRectangle(cornerRadius: 6)
                .fill(.secondary.opacity(0.12))
                .frame(width: 118, height: 18)
        }
    }
}

private struct FrozenRoutePlaceholder: View {
    let systemImage: String
    let title: String
    let metrics: [String]

    var body: some View {
        ZStack {
            Rectangle()
                .fill(Color(nsColor: .windowBackgroundColor))
                .ignoresSafeArea()

            VStack(alignment: .leading, spacing: 16) {
                Image(systemName: systemImage)
                    .font(.system(size: 44, weight: .semibold))
                    .foregroundStyle(.secondary)

                Text(title)
                    .font(.system(size: 42, weight: .bold))
                    .lineLimit(2)

                if !metrics.isEmpty {
                    HStack(spacing: 8) {
                        ForEach(metrics, id: \.self) { metric in
                            Text(metric)
                                .font(.callout.weight(.medium))
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 7)
                                .background(.regularMaterial, in: Capsule())
                        }
                    }
                }
            }
            .frame(maxWidth: 760, alignment: .leading)
            .padding(48)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .background(.background)
    }
}
