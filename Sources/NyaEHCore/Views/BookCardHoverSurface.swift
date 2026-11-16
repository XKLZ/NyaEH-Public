// 本文件提供不加载额外数据的书籍卡片悬停反馈，并在 Search 滚动期间抑制状态写入。

import SwiftUI

struct BookCardHoverVisualState: Equatable, Sendable {
    let coverScale: CGFloat
    let collectionCoverScale: CGFloat
    let verticalOffset: CGFloat
    let surfaceOpacity: Double
    let borderOpacity: Double
    let shadowOpacity: Double

    static func resolve(isHovered: Bool, reduceMotion: Bool) -> Self {
        guard isHovered else {
            return Self(
                coverScale: 1,
                collectionCoverScale: 1,
                verticalOffset: 0,
                surfaceOpacity: 0,
                borderOpacity: 0,
                shadowOpacity: 0
            )
        }

        return Self(
            coverScale: reduceMotion ? 1 : 1.02,
            collectionCoverScale: reduceMotion ? 1 : 1.012,
            verticalOffset: reduceMotion ? 0 : -2,
            surfaceOpacity: 1,
            borderOpacity: 1,
            shadowOpacity: reduceMotion ? 0 : 0.12
        )
    }
}

private struct BookCardHoverActiveEnvironmentKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var isBookCardHovered: Bool {
        get { self[BookCardHoverActiveEnvironmentKey.self] }
        set { self[BookCardHoverActiveEnvironmentKey.self] = newValue }
    }
}

private struct BookCardHoverSurfaceModifier: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.searchScrollActivity) private var scrollActivity

    @State private var isHovered = false
    @State private var hoverGate = SearchScrollHoverGate()

    private var visualState: BookCardHoverVisualState {
        BookCardHoverVisualState.resolve(isHovered: isHovered, reduceMotion: reduceMotion)
    }

    func body(content: Content) -> some View {
        content
            .environment(\.isBookCardHovered, isHovered)
            .offset(y: visualState.verticalOffset)
            .background {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color.primary.opacity(0.055))
                    .padding(-6)
                    .opacity(visualState.surfaceOpacity)
            }
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(Color.accentColor.opacity(0.20), lineWidth: 1)
                    .padding(-6)
                    .opacity(visualState.borderOpacity)
                    .allowsHitTesting(false)
            }
            .shadow(
                color: .black.opacity(visualState.shadowOpacity),
                radius: 10,
                x: 0,
                y: 4
            )
            .onContinuousHover { phase in
                switch phase {
                case .active(let location):
                    let canActivate = hoverGate.pointerBecameActive(
                        at: location,
                        isScrolling: scrollActivity.isScrolling
                    )
                    guard canActivate, !isHovered else { return }
                    isHovered = true
                case .ended:
                    hoverGate.pointerEnded()
                    guard isHovered else { return }
                    isHovered = false
                }
            }
            .onChange(of: scrollActivity.isScrolling) { _, isScrolling in
                hoverGate.scrollActivityChanged(isScrolling: isScrolling)
                guard isScrolling, isHovered else { return }
                isHovered = false
            }
            .animation(
                reduceMotion ? nil : .snappy(duration: 0.18),
                value: isHovered
            )
    }
}

extension View {
    func bookCardHoverSurface() -> some View {
        modifier(BookCardHoverSurfaceModifier())
    }
}
