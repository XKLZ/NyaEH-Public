import SwiftUI

/// Keeps value selection separate from the search field's suggestion key handling.
enum SearchModeKeyboardSelection {
    static func selection(for key: KeyEquivalent, focusedMode: SearchMode?) -> SearchMode? {
        guard let focusedMode else { return nil }
        switch key {
        case .leftArrow: return .broad
        case .rightArrow: return .exact
        case .space: return focusedMode
        default: return nil
        }
    }
}

struct SearchModeControl: View {
    @Environment(\.nyaehAccentColor) private var accentColor
    @Binding var selection: SearchMode
    let localizer: AppLocalizer
    let height: CGFloat
    @FocusState private var focusedMode: SearchMode?

    var body: some View {
        SearchModeEqualWidthLayout {
            modeButton(.broad, titleKey: .advancedSearchBroad)
            modeButton(.exact, titleKey: .advancedSearchExact)
        }
        .padding(2)
        .glassEffect(.regular.interactive(), in: Capsule())
        .fixedSize()
        .accessibilityElement(children: .contain)
        .accessibilityLabel(localizer.string(.advancedSearchMode))
        .onKeyPress(keys: [.leftArrow, .rightArrow, .space], phases: .down) { press in
            guard let mode = SearchModeKeyboardSelection.selection(for: press.key, focusedMode: focusedMode) else {
                return .ignored
            }
            selection = mode
            focusedMode = mode
            return .handled
        }
    }

    private func modeButton(_ mode: SearchMode, titleKey: L10nKey) -> some View {
        Button {
            selection = mode
        } label: {
            Text(localizer.string(titleKey))
                .font(.caption.weight(.semibold))
                .lineLimit(1)
                .padding(.horizontal, 12)
                .frame(height: height - 4)
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(SearchModeSegmentStyle(isSelected: selection == mode, accentColor: accentColor))
        .focused($focusedMode, equals: mode)
        .accessibilityAddTraits(selection == mode ? .isSelected : [])
    }
}

private struct SearchModeSegmentStyle: ButtonStyle {
    let isSelected: Bool
    let accentColor: Color

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(isSelected ? Color.white : Color.primary)
            .background {
                Capsule().fill(
                    isSelected
                        ? accentColor.opacity(configuration.isPressed ? 0.8 : 1)
                        : Color.primary.opacity(configuration.isPressed ? 0.1 : 0)
                )
            }
            .contentShape(Capsule())
    }
}

/// Both segments use the longest localized label's natural width, without a fixed overall width.
private struct SearchModeEqualWidthLayout: Layout {
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let sizes = subviews.map { $0.sizeThatFits(.unspecified) }
        return CGSize(
            width: (sizes.map(\.width).max() ?? 0) * CGFloat(subviews.count),
            height: sizes.map(\.height).max() ?? 0
        )
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard !subviews.isEmpty else { return }
        let width = bounds.width / CGFloat(subviews.count)
        for (index, subview) in subviews.enumerated() {
            subview.place(
                at: CGPoint(x: bounds.minX + CGFloat(index) * width, y: bounds.minY),
                anchor: .topLeading,
                proposal: ProposedViewSize(width: width, height: bounds.height)
            )
        }
    }
}
