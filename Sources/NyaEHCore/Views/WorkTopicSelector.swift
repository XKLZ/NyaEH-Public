import AppKit
import SwiftUI

/// Only the avatar list scrolls. The actions remain in the detail column's safe area.
struct WorkTopicSelector: View {
    static let height: CGFloat = 106
    static let cardSize = CGSize(width: 64, height: 88)

    let characters: [TagDisplaySummary]
    let selectedCharacterID: Tag.DatabaseID?
    let unclassifiedCount: Int
    let isShowingUnclassified: Bool
    let assetURL: (String) -> URL?
    let localizer: AppLocalizer
    let position: WorkTopicScrollMemory
    let motion: WorkTopicMotionCoordinator
    let onSelect: (Tag.DatabaseID) -> Void
    let onUnclassified: () -> Void
    let onManage: () -> Void

    @Environment(\.workTopicSidebarUnderlap) private var sidebarUnderlap
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOver
    @Environment(\.appearsActive) private var windowActive
    @Environment(\.browsingFocusEffectHidden) private var hidesBrowsingFocus
    @Environment(FocusAppearanceManager.self) private var focusAppearance: FocusAppearanceManager?
    @State private var scrollPosition = ScrollPosition()
    @State private var needsRestore = true
    @FocusState private var focusedCharacterID: Tag.DatabaseID?

    var body: some View {
        selectorContent
            .onChange(of: voiceOver) { _, _ in motion.cancelHover() }
            .onChange(of: windowActive) { _, active in if !active { motion.cancelHover() } }
            .onDisappear {
                motion.cancelHover()
                needsRestore = true
            }
    }

    private var selectorContent: some View {
        HStack(spacing: 10) {
            GeometryReader { safeColumn in
                GeometryReader { extended in
                    let underlap = max(sidebarUnderlap, extended.size.width - safeColumn.size.width)
                    scrollingAvatars(visibleWidth: max(0, extended.size.width - underlap), leadingUnderlap: underlap)
                }
                .clipped()
                .ignoresSafeArea(.container, edges: .leading)
                .onChange(of: safeColumn.frame(in: .named(WorkTopicLayoutSpace.page)).insetLeading(sidebarUnderlap), initial: true) { _, frame in
                    motion.selectorViewport = frame
                }
            }

            if unclassifiedCount > 0 {
                Button {
                    motion.cancelHover()
                    onUnclassified()
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "tray")
                        Text(unclassifiedCount, format: .number)
                            .monospacedDigit()
                    }
                    .frame(width: Self.cardSize.width, height: Self.cardSize.height)
                    .modifier(SelectorGlass(selected: isShowingUnclassified))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(localizer.string(.workTopicUnclassified))
                .accessibilityValue(localizer.workDetailBookCount(unclassifiedCount))
                .accessibilityAddTraits(isShowingUnclassified ? .isSelected : [])
                .help(localizer.string(.workTopicUnclassified))
            }
            Button {
                motion.cancelHover()
                onManage()
            } label: {
                Image(systemName: "person.crop.rectangle.stack")
                    .frame(width: Self.cardSize.width, height: Self.cardSize.height)
                    .modifier(SelectorGlass(selected: false))
            }
            .buttonStyle(.plain)
            .accessibilityLabel(localizer.string(.workCharacterManage))
            .help(localizer.string(.workCharacterManage))
        }
        .padding(.trailing, 16)
        .frame(height: Self.height)
    }

    // The scroll viewport extends under the sidebar, but the initial items and the
    // center of a short list belong to the unobstructed portion of the detail column.
    private func scrollingAvatars(visibleWidth: CGFloat, leadingUnderlap: CGFloat) -> some View {
        ScrollViewReader { reader in
            ScrollView(.horizontal) {
                LazyHStack(spacing: 10) {
                    ForEach(characters) { character in
                        WorkTopicAvatarButton(character: character, assetURL: assetURL, motion: motion,
                                              selected: selectedCharacterID == character.id && !isShowingUnclassified,
                                              hoverEnabled: !voiceOver && windowActive,
                                              requestFocus: { focusedCharacterID = character.id },
                                              onSelect: { onSelect(character.id) })
                            .focused($focusedCharacterID, equals: character.id)
                            .focusEffectDisabled(hidesBrowsingFocus)
                            .id(character.id)
                    }
                }
                .padding(.horizontal, 12)
                .frame(minWidth: visibleWidth)
                .padding(.leading, leadingUnderlap)
                .frame(height: Self.height)
                .background {
                    WorkTopicWheelBridge(onWheel: motion.wheelMoved)
                }
            }
            .scrollIndicators(.hidden)
            .scrollPosition($scrollPosition)
            .onScrollGeometryChange(for: ScrollBounds.self) { geometry in
                ScrollBounds(offset: geometry.contentOffset.x,
                             limit: max(0, geometry.contentSize.width - geometry.containerSize.width))
            } action: { _, bounds in
                trackScroll(bounds)
            }
            .onScrollPhaseChange { _, phase in
                motion.setScrolling(phase != .idle)
            }
            .onKeyPress(.leftArrow) { moveFocus(by: -1, reader: reader) }
            .onKeyPress(.rightArrow) { moveFocus(by: 1, reader: reader) }
        }
    }

    private struct ScrollBounds: Equatable {
        let offset: CGFloat
        let limit: CGFloat
    }

    private func trackScroll(_ bounds: ScrollBounds) {
        guard bounds.limit > 0 else { return }
        if needsRestore {
            needsRestore = false
            let target = min(position.offset, bounds.limit)
            if abs(bounds.offset - target) > 1 {
                scrollPosition.scrollTo(x: target)
                return
            }
        } else if abs(bounds.offset - position.offset) > 0.5 {
            motion.wheelMoved()
        }
        position.offset = min(max(0, bounds.offset), bounds.limit)
    }

    private func moveFocus(by step: Int, reader: ScrollViewProxy) -> KeyPress.Result {
        guard let focusedCharacterID,
              let index = characters.firstIndex(where: { $0.id == focusedCharacterID }) else {
            return .ignored
        }
        focusAppearance?.receive(.directionalNavigation)
        motion.confirmByInput()
        let target = index + step
        guard characters.indices.contains(target) else { return .handled }
        let character = characters[target]
        onSelect(character.id)
        reader.scrollTo(character.id)
        self.focusedCharacterID = character.id
        return .handled
    }
}

private struct SelectorGlass: ViewModifier {
    let selected: Bool

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: 15, style: .continuous)
        content
            .glassEffect(.regular.interactive(), in: shape)
            .overlay {
                if selected {
                    shape.strokeBorder(Color.accentColor, lineWidth: 2)
                        .allowsHitTesting(false)
                }
            }
            .contentShape(shape)
    }
}

private struct WorkTopicAvatarButton: View {
    let character: TagDisplaySummary
    let assetURL: (String) -> URL?
    let motion: WorkTopicMotionCoordinator
    let selected: Bool
    let hoverEnabled: Bool
    let requestFocus: () -> Void
    let onSelect: () -> Void

    @Environment(\.displayScale) private var displayScale
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var image: CGImage?
    @State private var source = WorkTopicCardSource()

    private var request: WorkTopicAvatarRequest? {
        guard let profile = character.visualProfile, let path = profile.foregroundAssetPath,
              let url = assetURL(path) else { return nil }
        return .init(url: url, revision: profile.updatedAt,
                     pixels: max(1, Int(ceil(WorkTopicSelector.cardSize.height * displayScale))))
    }

    var body: some View {
        let id = character.id
        let lifted = source.isLifted && !reduceMotion
        let shape = RoundedRectangle(cornerRadius: 15, style: .continuous)
        let request = request
        Button {
            motion.confirmByInput(keepLift: true)
            requestFocus()
            onSelect()
        } label: {
            WorkTopicCharacterCard(character: character, image: source.returnedImage ?? image, expansion: 0) { EmptyView() }
                .frame(width: WorkTopicSelector.cardSize.width, height: WorkTopicSelector.cardSize.height)
                .opacity(source.isVacant ? 0 : 1)
                .offset(y: lifted ? -4 : 0)
                .animation(reduceMotion ? nil : .snappy(duration: 0.13, extraBounce: 0), value: lifted)
                .contentShape(shape)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(character.displayText)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .help(character.displayText)
        .onAppear { motion.mount(source, id: id) }
        .onDisappear { motion.unmount(source, id: id) }
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(WorkTopicLayoutSpace.page)) } action: {
            source.bounds = $0
        }
        .onHover { inside in
            if inside && hoverEnabled {
                motion.enter(id, select: onSelect)
            } else {
                motion.leave(id)
            }
        }
        .task(id: request) {
            source.returnedImage = nil
            image = nil
            guard let request else { return }
            let result = await WorkTopicAvatarCache.shared.image(for: request)
            guard !Task.isCancelled else { return }
            image = result
        }
    }
}

private extension CGRect {
    func insetLeading(_ amount: CGFloat) -> CGRect {
        .init(x: minX + amount, y: minY, width: max(0, width - amount), height: height)
    }
}

struct WorkTopicCharacterGlass: View {
    let expansion: CGFloat

    var shape: RoundedRectangle { RoundedRectangle(cornerRadius: 15 + 9 * expansion, style: .continuous) }
    var glassOpacity: Double { 1 + (0.68 - 1) * Double(expansion) }

    var body: some View {
        Color.clear.glassEffect(.clear, in: shape).opacity(glassOpacity)
    }
}

/// Selector, exchange and stationary stage share composition, pose, cropping and glass.
struct WorkTopicCharacterCard<Nameplate: View>: View {
    let character: TagDisplaySummary
    let image: CGImage?
    let expansion: CGFloat
    @ViewBuilder let nameplate: () -> Nameplate
    @Environment(\.workTopicPortraitDirection) private var direction

    var body: some View {
        let glass = WorkTopicCharacterGlass(expansion: expansion)
        glass
            .overlay {
                GeometryReader { proxy in
                    let size = proxy.size
                    let pose = CharacterPortraitPlacement(profile: character.visualProfile)
                    if let image {
                        Image(decorative: image, scale: 1)
                            .resizable()
                            .scaledToFit()
                            .scaleEffect(pose.scale)
                            .offset(pose.offset(in: size))
                            .frame(width: size.width, height: size.height, alignment: .bottom)
                    } else {
                        Text(String(character.displayText.prefix(1)))
                            .font(.system(size: min(72, size.width * 0.43), weight: .semibold, design: .rounded))
                            .frame(width: size.width, height: size.height)
                    }
                }
                .padding(.horizontal, 4 * expansion)
                .padding(.top, 6 * expansion)
                .offset(x: direction.width * 2.5, y: direction.height * 2.5)
                .clipShape(glass.shape)
                .accessibilityHidden(true)
            }
            .overlay(alignment: .bottom) {
                if expansion > 0.60 {
                    nameplate()
                        .padding(8)
                        .opacity(min(1, (expansion - 0.60) / 0.32))
                        .offset(x: -direction.width * 1.5, y: -direction.height * 1.5)
                }
            }
    }
}
