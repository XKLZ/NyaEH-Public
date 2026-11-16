// 本文件提供阅读窗口内按需加载的缩略图浮动侧栏，不持有原尺寸页面图片。

import SwiftUI

struct ReaderThumbnailSidebar: View {
    let totalPages: Int
    let currentPageIndex: Int
    let selectedRange: ClosedRange<Int>?
    let thumbnails: [Int: ReaderDecodedThumbnail]
    let loadingIndices: Set<Int>
    let localizer: AppLocalizer
    let onSelectPage: (Int) -> Void
    let onPageVisibilityChange: (Int, Bool) -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ScrollViewReader { proxy in
            FloatingGlassPanel(cornerRadius: 20, horizontalPadding: 8, verticalPadding: 8) {
                ScrollView {
                    LazyVStack(spacing: 9) {
                        ForEach(0..<totalPages, id: \.self) { index in
                            thumbnailButton(index: index)
                                .id(index)
                                .onScrollVisibilityChange(threshold: 0.15) { visible in
                                    onPageVisibilityChange(index, visible)
                                }
                                .onDisappear {
                                    onPageVisibilityChange(index, false)
                                }
                        }
                    }
                    .padding(.vertical, 2)
                }
                .scrollIndicators(.hidden)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .focusable(false)
                .focusEffectDisabled()
                .accessibilityLabel(localizer.string(.readerThumbnails))
            }
            .frame(maxHeight: .infinity)
            .onAppear {
                proxy.scrollTo(currentPageIndex, anchor: .center)
            }
            .onChange(of: currentPageIndex) { _, newValue in
                withAnimation(reduceMotion ? nil : .easeOut(duration: 0.18)) {
                    proxy.scrollTo(newValue, anchor: .center)
                }
            }
        }
        .frame(width: 184)
        .frame(maxHeight: .infinity)
    }

    private func thumbnailButton(index: Int) -> some View {
        let isSelected = selectedRange?.contains(index) == true
        return Button {
            onSelectPage(index)
        } label: {
            ZStack {
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .fill(.black.opacity(isSelected ? 0.38 : 0.22))

                thumbnailContent(index: index)
                    .padding(6)
            }
            .aspectRatio(0.72, contentMode: .fit)
            .overlay {
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .stroke(
                        isSelected ? Color.accentColor : Color.white.opacity(0.12),
                        lineWidth: isSelected ? 2 : 1
                    )
            }
            .overlay(alignment: .bottomTrailing) {
                Text("\(index + 1)")
                    .font(.caption2.monospacedDigit().weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(.black.opacity(0.58), in: Capsule())
                    .padding(7)
            }
            .contentShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
        }
        .buttonStyle(.plain)
        .focusable(false)
        .focusEffectDisabled()
        .accessibilityLabel(localizer.pageIndicator(current: index + 1, total: totalPages))
    }

    @ViewBuilder
    private func thumbnailContent(index: Int) -> some View {
        if let image = thumbnails[index]?.image {
            Image(nsImage: image)
                .resizable()
                .scaledToFit()
        } else if loadingIndices.contains(index) {
            ProgressView()
                .controlSize(.small)
                .tint(.white)
        } else {
            Image(systemName: "photo")
                .font(.title2)
                .foregroundStyle(.white.opacity(0.58))
        }
    }
}
