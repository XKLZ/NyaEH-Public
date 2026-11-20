import SwiftUI

extension EnvironmentValues {
    @Entry var coverPrivacyRule = CoverPrivacyRule()
}

/// Install tracking only on an actual protected cover. The enclosing button keeps its own gestures.
struct CoverPrivacySurface<Content: View>: View {
    let context: CoverRevealContext
    let width: CGFloat
    let height: CGFloat
    let cornerRadius: CGFloat
    var perspectivePreview = false
    @ViewBuilder let content: () -> Content

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.appearsActive) private var windowActive
    @Environment(\.coverPrivacyRevealAllowed) private var revealAllowed
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hovering = false
    @State private var reveal = CoverRevealState()
    @State private var wait: Task<Void, Never>?

    @State private var tilt: CGPoint = .zero

    private var allowed: Bool { revealAllowed && windowActive }

    var body: some View {
        // The tracking surface must outlive both the placeholder and the revealed image.
        // Replacing the view that owns onHover can send an exit under a stationary pointer.
        let trackingPlane = Color.clear
            .frame(width: width, height: height)
            .overlay {
                surface
                    .frame(width: width, height: height)
                    .clipShape(.rect(cornerRadius: cornerRadius))
                    .id(context)
                    .id(allowed)
                    .modifier(FavoriteCoverPerspective(position: tilt, size: CGSize(width: width, height: height),
                                                       radius: cornerRadius, enabled: perspectivePreview && !reduceMotion && allowed))
                    .allowsHitTesting(false)
            }
            .contentShape(Rectangle())
            .onHover { inside in
                guard hovering != inside else { return }
                hovering = inside
                update(hovered: inside)
            }
            .onChange(of: context) { update(hovered: hovering) }
            .onChange(of: allowed) { update(hovered: hovering) }
            .onDisappear {
                hovering = false
                update(hovered: false)
            }
            .transaction { $0.animation = nil }

        if perspectivePreview && !reduceMotion && allowed {
            trackingPlane.onContinuousHover { phase in
                switch phase {
                case .active(let point):
                    tilt = CGPoint(x: max(-1, min(1, 2 * point.x / max(1, width) - 1)),
                                   y: max(-1, min(1, 2 * point.y / max(1, height) - 1)))
                case .ended:
                    tilt = .zero
                }
            }
            .onDisappear { tilt = .zero }
        } else {
            trackingPlane
        }
    }

    @ViewBuilder
    private var surface: some View {
        let revealed = allowed && hovering && reveal.isRevealed(for: context)
        if context.rule.mode == .blur {
            let protectedRadius = context.rule.blurRadius(shortEdge: min(width, height))
            content()
                .animation(reduceMotion || !allowed ? nil : .easeOut(duration: revealed ? 0.22 : 0.18)) { cover in
                    cover.blur(radius: revealed ? 0 : protectedRadius)
                }
        } else if context.rule.mode == .off || revealed {
            content()
        } else {
            Rectangle()
                .fill(Color(white: colorScheme == .dark ? 0.20 : 0.87))
                .overlay {
                    Image(systemName: "book.closed")
                        .font(.system(size: min(36, min(width, height) * 0.28)))
                        .foregroundStyle(.secondary)
                }
                .accessibilityHidden(true)
        }
    }

    private func update(hovered: Bool) {
        wait?.cancel()
        wait = nil
        guard let request = reveal.update(for: context, hovered: hovered, allowed: allowed,
                                          now: ContinuousClock.now) else { return }
        wait = Task { @MainActor in
            do { try await ContinuousClock().sleep(until: request.deadline) } catch { return }
            guard !Task.isCancelled else { return }
            reveal.complete(request, now: .now)
        }
    }
}

/// Transform only the rendered cover. Pointer coordinates stay in its stationary image plane.
private struct FavoriteCoverPerspective: ViewModifier {
    let position: CGPoint
    let size: CGSize
    let radius: CGFloat
    let enabled: Bool

    @ViewBuilder func body(content: Content) -> some View {
        if enabled {
            let amount = min(1, hypot(position.x, position.y))
            content
                .overlay {
                    RadialGradient(colors: [.white.opacity(0.15 * amount), .clear],
                                   center: UnitPoint(x: (position.x + 1) / 2, y: (position.y + 1) / 2),
                                   startRadius: 0, endRadius: max(size.width, size.height) * 0.8)
                        .clipShape(.rect(cornerRadius: radius))
                }
                .rotation3DEffect(.degrees(-6 * position.y), axis: (1, 0, 0), perspective: 0.35)
                .rotation3DEffect(.degrees(6 * position.x), axis: (0, 1, 0), perspective: 0.35)
                .shadow(color: .black.opacity(0.13 * amount), radius: 4, x: -position.x * 2, y: 2 + amount)
                .animation(.easeOut(duration: 0.14), value: position)
        } else {
            content
        }
    }
}
