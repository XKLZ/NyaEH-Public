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
    var backArrowX: CGFloat { panelRight + (usableShelfWidth < 300 ? 12 : 18) }

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
            WorkTopicNameplateSurface(glass: .clear.interactive()) {
                HStack(spacing: 6) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(character.displayText)
                            .font(.headline)
                            .lineLimit(1)
                        Text(localizer.workDetailBookCount(bookCount))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "arrow.up.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                }
            }
        }
        .buttonStyle(.plain)
        .help(localizer.string(.workDetailOpenCharacter))
        .accessibilityLabel(character.displayText)
        .accessibilityValue(localizer.workDetailBookCount(bookCount))
        .accessibilityHint(localizer.string(.workDetailOpenCharacter))
    }
}

private struct WorkTopicNameplateSurface<Content: View>: View {
    let glass: Glass
    @ViewBuilder let content: () -> Content
    @Environment(\.workTopicPortraitDirection) private var direction

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 14, style: .continuous)
        content()
            .offset(x: -direction.width * 1.5, y: -direction.height * 1.5)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, minHeight: 56, alignment: .leading)
            .glassEffect(glass, in: shape)
            .contentShape(shape)
    }
}

struct WorkTopicNameplatePlaceholder: View {
    var body: some View {
        WorkTopicNameplateSurface(glass: .clear) {
            HStack(spacing: 6) {
                VStack(alignment: .leading, spacing: 5) {
                    Capsule().fill(.secondary.opacity(0.18)).frame(maxWidth: 82).frame(height: 9)
                    Capsule().fill(.secondary.opacity(0.12)).frame(maxWidth: 34).frame(height: 6)
                }
                Spacer(minLength: 0)
                Image(systemName: "arrow.up.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary.opacity(0.3))
            }
        }
    }
}
