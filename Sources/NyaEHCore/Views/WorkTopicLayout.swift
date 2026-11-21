import SwiftUI

enum WorkTopicLayoutSpace: Hashable {
    case page
}

struct WorkTopicHeaderMetrics: Equatable {
    static let compactHeight: CGFloat = 64
    static let topInset: CGFloat = 16
    static let selectorGap: CGFloat = 20

    let expandedHeight: CGFloat
    let height: CGFloat

    init(viewportHeight: CGFloat, offset: CGFloat) {
        expandedHeight = min(520, max(440, viewportHeight * 0.62))
        height = max(Self.compactHeight, expandedHeight - max(0, offset))
    }

    var travel: CGFloat { expandedHeight - Self.compactHeight }
    var progress: CGFloat { (expandedHeight - height) / travel }
    var canExpand: Bool { height < expandedHeight }

    func entryOffset(saved: CGFloat?) -> CGFloat { saved ?? travel }

    // The descriptive layers clear the card before its controls settle into the pinned row.
    var introductionOpacity: Double { max(0, 1 - progress / 0.52) }
    var artworkOpacity: Double { max(0, 1 - progress / 0.76) }
    var searchLabelOpacity: Double { min(1, max(0, (0.50 - progress) / 0.26)) }
    var searchLabelSpace: CGFloat { min(1, (1 - progress) / 0.50) }

    func interpolate(_ expanded: CGFloat, _ compact: CGFloat) -> CGFloat {
        expanded + (compact - expanded) * progress
    }
}

/// Reserve the expanded card's full scroll distance, even when its visible height is compact.
struct WorkTopicLayout<Hero: View, Selector: View, Content: View>: View {
    let browsing: WorkTopicBrowsingState
    var isPlaceholder = false
    @ViewBuilder let hero: (WorkTopicHeaderMetrics, @escaping () -> Void) -> Hero
    @ViewBuilder let selector: () -> Selector
    @ViewBuilder let content: () -> Content

    var body: some View {
        GeometryReader { viewport in
            GeometryReader { extended in
                if viewport.size.height > 0 {
                    page(viewport: viewport.size, underlap: max(0, extended.size.width - viewport.size.width))
                }
            }
            .ignoresSafeArea(.container, edges: .leading)
        }
        .coordinateSpace(name: WorkTopicLayoutSpace.page)
    }

    private func page(viewport: CGSize, underlap: CGFloat) -> some View {
        let expanded = WorkTopicHeaderMetrics(viewportHeight: viewport.height, offset: 0)
        let surroundingHeight = WorkTopicHeaderMetrics.topInset + WorkTopicHeaderMetrics.selectorGap + WorkTopicSelector.height

        return WorkTopicVerticalScroll(browsing: browsing, expanded: expanded, isPlaceholder: isPlaceholder) { y, expand in
            let presentation = WorkTopicHeaderMetrics(viewportHeight: viewport.height, offset: y)
            VStack(spacing: 0) {
                VStack(spacing: WorkTopicHeaderMetrics.selectorGap) {
                    hero(presentation, expand)
                        .frame(height: presentation.height)
                        .clipShape(.rect(cornerRadius: WorkDetailSurfaceRole.hero.cornerRadius))
                        .glassEffect(.regular, in: .rect(cornerRadius: WorkDetailSurfaceRole.hero.cornerRadius))
                        .padding(.horizontal, viewport.width < 620 ? 18 : 34)
                        .frame(maxWidth: 1540)
                        .frame(maxWidth: .infinity)
                        .padding(.leading, underlap)
                    selector()
                        .padding(.leading, isPlaceholder ? underlap : 0)
                }
                .padding(.top, WorkTopicHeaderMetrics.topInset)
                .offset(y: y)
                .frame(height: expanded.expandedHeight + surroundingHeight, alignment: .top)
                .zIndex(1)

                content()
                    .padding(.vertical, 14)
                    .frame(minHeight: max(0, viewport.height - WorkTopicHeaderMetrics.compactHeight - surroundingHeight), alignment: .top)
            }
        }
        .environment(\.workTopicSidebarUnderlap, underlap)
    }
}

private struct WorkTopicVerticalScroll<Content: View>: View {
    let browsing: WorkTopicBrowsingState
    let expanded: WorkTopicHeaderMetrics
    let isPlaceholder: Bool
    @ViewBuilder let content: (CGFloat, @escaping () -> Void) -> Content
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var scroll: ScrollPosition
    @State private var offset: CGFloat
    @State private var needsRestore = true

    init(browsing: WorkTopicBrowsingState, expanded: WorkTopicHeaderMetrics, isPlaceholder: Bool,
         @ViewBuilder content: @escaping (CGFloat, @escaping () -> Void) -> Content) {
        self.browsing = browsing
        self.expanded = expanded
        self.isPlaceholder = isPlaceholder
        self.content = content
        // Seed the native scroller and the pinned header together on each route mount.
        let entry = expanded.entryOffset(saved: browsing.verticalOffset)
        _scroll = State(initialValue: ScrollPosition(y: entry))
        _offset = State(initialValue: entry)
    }

    var body: some View {
        ScrollView {
            content(offset) {
                withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.32)) {
                    scroll.scrollTo(y: 0)
                }
            }
        }
        .scrollPosition($scroll)
        .onScrollGeometryChange(for: Snapshot.self) { geometry in
            Snapshot(y: max(geometry.contentOffset.y + geometry.contentInsets.top, 0),
                     maxOffset: max(geometry.contentSize.height + geometry.contentInsets.top + geometry.contentInsets.bottom - geometry.containerSize.height, 0),
                     hasContent: geometry.contentSize.height > 0 && geometry.containerSize.height > 0)
        } action: { _, current in
            guard current.hasContent else { return }
            if needsRestore {
                let target = min(expanded.entryOffset(saved: browsing.verticalOffset), current.maxOffset)
                needsRestore = false
                if abs(target - current.y) > 1 {
                    offset = target
                    scroll.scrollTo(y: target)
                    return
                }
            }
            offset = current.y
            if !isPlaceholder { browsing.verticalOffset = current.y }
        }
        .onChange(of: expanded.travel) { previous, next in
            guard !needsRestore, offset >= previous - 1 else { return }
            scroll.scrollTo(y: next + max(0, offset - previous))
        }
    }

    private struct Snapshot: Equatable {
        let y: CGFloat
        let maxOffset: CGFloat
        let hasContent: Bool
    }
}

/// The four controls retain their identities throughout the scroll transition.
struct WorkTopicHeroControls: Layout {
    let presentation: WorkTopicHeaderMetrics

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        CGSize(width: proposal.width ?? 0, height: presentation.height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let inset = min(54, max(20, bounds.width * 0.045))
        let textWidth = max(0, bounds.width * 0.5 - inset)
        let introHeight = subviews[2].sizeThatFits(.init(width: textWidth, height: nil)).height
        let frames = WorkTopicHeroFrames.resolve(width: bounds.width, inset: inset, introHeight: introHeight, presentation: presentation)
        for (subview, frame) in zip(subviews, frames) {
            subview.place(at: .init(x: bounds.minX + frame.minX, y: bounds.minY + frame.midY), anchor: .leading,
                          proposal: .init(frame.size))
        }
    }
}

enum WorkTopicHeroFrames {
    static func resolve(width: CGFloat, inset: CGFloat, introHeight: CGFloat, presentation: WorkTopicHeaderMetrics) -> [CGRect] {
        let textWidth = max(0, width * 0.5 - inset)
        let compactInset: CGFloat = min(18, width * 0.035)
        let logoHeight = presentation.expandedHeight * 0.30
        let logoWidth = min(350, textWidth)
        let compactLogoWidth = min(width * 0.24, 168)
        let compactCountX = compactInset + compactLogoWidth + 12
        let controlSize: CGFloat = 34
        let compactY = (WorkTopicHeaderMetrics.compactHeight - controlSize) / 2
        let searchX = width - compactInset - controlSize
        let height = min(introHeight, 88)
        let top = (presentation.expandedHeight - (logoHeight + 18 + 28 + 16 + height + 20 + 38)) / 2
        let countsY = top + logoHeight + 18
        let introY = countsY + 28 + 16
        let searchY = introY + height + 20
        let lerp = presentation.interpolate
        func frame(_ from: CGRect, _ to: CGRect) -> CGRect {
            .init(x: lerp(from.minX, to.minX), y: lerp(from.minY, to.minY),
                  width: lerp(from.width, to.width), height: lerp(from.height, to.height))
        }
        // Move the counts beside the shrinking logo before the two rows share a baseline.
        let align = min(1, presentation.progress / 0.55)
        let identity = CGRect(x: inset + (compactInset - inset) * align, y: lerp(top, 12),
                              width: logoWidth + (compactLogoWidth - logoWidth) * align,
                              height: logoHeight + (40 - logoHeight) * align)
        let counts = CGRect(x: inset + (compactCountX - inset) * align, y: lerp(countsY, compactY),
                            width: lerp(textWidth, max(0, searchX - compactCountX - 8)), height: lerp(28, controlSize))
        let searchWidth = min(178, textWidth)
        let searchCenter = lerp(inset + searchWidth / 2, searchX + controlSize / 2)
        let liveSearchWidth = controlSize + (searchWidth - controlSize) * presentation.searchLabelSpace
        return [
            identity, counts,
            frame(.init(x: inset, y: introY, width: textWidth, height: height),
                  .init(x: compactInset, y: WorkTopicHeaderMetrics.compactHeight / 2, width: textWidth, height: 0)),
            CGRect(x: searchCenter - liveSearchWidth / 2, y: lerp(searchY, compactY),
                   width: liveSearchWidth, height: lerp(38, controlSize))
        ]
    }
}
