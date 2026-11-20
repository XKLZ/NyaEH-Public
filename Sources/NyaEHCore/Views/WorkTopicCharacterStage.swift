import SwiftUI

extension EnvironmentValues {
    @Entry var workTopicPortraitDirection: CGSize = .zero
    /// Horizontal distance from the full-bleed scroll viewport to the unobscured detail column.
    @Entry var workTopicSidebarUnderlap: CGFloat = 0
}

struct WorkTopicReadableContent: ViewModifier {
    @Environment(\.workTopicSidebarUnderlap) private var underlap

    func body(content: Content) -> some View {
        content
            .padding(.horizontal, 18)
            .frame(maxWidth: 1540)
            .frame(maxWidth: .infinity)
            .padding(.leading, underlap)
    }
}

struct WorkTopicStageLayout {
    static let cardInset: CGFloat = 14
    static let maximumPortraitWidth: CGFloat = 340

    let width: CGFloat
    let panelX: CGFloat
    let portraitWidth: CGFloat
    let trailingInset: CGFloat

    init(available: CGFloat, underlap: CGFloat) {
        width = max(0, available)
        let sidebar = min(max(0, underlap), width)
        let safeWidth = width - sidebar
        let outerMargin = 18 + max(0, (safeWidth - 1540) / 2)
        panelX = sidebar + outerMargin
        trailingInset = outerMargin
        let contentWidth = max(0, safeWidth - 2 * outerMargin)
        // Keep the first single-row cover fully visible, including in compact detail columns.
        portraitWidth = min(Self.maximumPortraitWidth, contentWidth * 0.29, max(40, contentWidth - 168 - Self.cardInset))
    }

    var panelRight: CGFloat { panelX + portraitWidth }
    var firstCoverX: CGFloat { panelRight + Self.cardInset }
    var usableShelfWidth: CGFloat { max(0, width - panelRight - trailingInset) }

    // A character always occupies one full double-row stage, even beside a single row of books.
    static func height(fields: BookCardFields) -> CGFloat {
        WorkCharacterShelfMetrics.carouselHeight(metrics: WorkCharacterShelfMetrics.cardMetrics(usesDoubleRow: true),
                                                usesDoubleRow: true, fields: fields)
    }

    static func panelHeight(fields: BookCardFields) -> CGFloat {
        height(fields: fields) - WorkCharacterShelfMetrics.verticalCardPadding
    }
}

struct WorkCharacterShelfFrame<Panel: View, Carousel: View>: View {
    @ViewBuilder let panel: () -> Panel
    @ViewBuilder let carousel: (WorkTopicStageLayout) -> Carousel
    @Environment(\.bookCardFields) private var fields
    @Environment(\.workTopicSidebarUnderlap) private var underlap

    var body: some View {
        GeometryReader { proxy in
            let layout = WorkTopicStageLayout(available: proxy.size.width, underlap: underlap)
            ZStack(alignment: .topLeading) {
                carousel(layout)
                panel()
                    .frame(width: layout.portraitWidth, height: WorkTopicStageLayout.panelHeight(fields: fields))
                    .padding(.top, WorkCharacterShelfMetrics.verticalCardPadding / 2)
                    .padding(.leading, layout.panelX)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(height: WorkTopicStageLayout.height(fields: fields))
    }
}

/// Keep moving covers visible beneath the whole glass, including the system sidebar beyond it.
struct WorkTopicShelfEdge: View {
    let panelRight: CGFloat

    var body: some View {
        let feather = min(28, panelRight)
        HStack(spacing: 0) {
            Color.white.opacity(0.76).frame(width: max(0, panelRight - feather))
            LinearGradient(colors: [.white.opacity(0.76), .white], startPoint: .leading, endPoint: .trailing)
                .frame(width: feather)
            Color.white
        }
    }
}

struct WorkTopicCharacterNameplate: View {
    let character: TagDisplaySummary
    let bookCount: Int
    let localizer: AppLocalizer
    let onSelectCharacter: (TagDisplaySummary) -> Void

    var body: some View {
        Button { onSelectCharacter(character) } label: {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(character.displayText)
                        .font(.headline)
                        .lineLimit(1)
                    Text(localizer.workDetailBookCount(bookCount))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Image(systemName: "arrow.up.right")
                    .font(.caption.weight(.semibold))
            }
            .padding(.horizontal, 4)
            .padding(.vertical, 2)
        }
        .buttonStyle(.glass)
        .buttonBorderShape(.roundedRectangle(radius: 12))
        .help(localizer.string(.workDetailOpenCharacter))
        .accessibilityHint(localizer.string(.workDetailOpenCharacter))
    }
}
