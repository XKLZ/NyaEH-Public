// 本文件实现作品详情页，呈现作品介绍、角色选择和当前角色的书架。

import AppKit
import SwiftUI

struct WorkDetailView: View {
    @Bindable var store: TagDiscoveryStore
    let tagID: Tag.DatabaseID
    let isTagTranslationEnabled: Bool
    let titleDisplayMode: BookTitleDisplayMode
    let browsing: WorkTopicBrowsingState
    let usesExternalTransitionShell: Bool
    let localizer: AppLocalizer
    let onSelectBook: (LibraryBook) -> Void
    let onSelectCharacter: (TagDisplaySummary) -> Void
    let onSearchWork: (TagDisplaySummary) -> Void
    @State private var hasRequestedDetailLoad = false
    @State private var isManagingClaims = false
    @State var motion = WorkTopicMotionCoordinator()
    @Environment(\.displayScale) private var displayScale
    @Environment(\.bookCardFields) private var cardFields
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var detail: WorkDetail? {
        store.catalog.workDetail(tagID: tagID)
    }

    private var renderPhase: WorkDetailRenderPhase {
        WorkDetailRenderPhase.resolve(
            hasDetail: detail != nil,
            isLoading: store.catalog.isLoadingWorkDetail(tagID: tagID),
            hasRequestedLoad: hasRequestedDetailLoad,
            hasError: store.catalog.workDetailError(tagID: tagID) != nil
        )
    }

    var body: some View {
        ZStack {
            switch renderPhase {
            case .loadingShell:
                WorkDetailTransitionShell(detail: nil, browsing: browsing, fallbackTitle: localizer.string(.detailWorks), localizer: localizer)
                    .transition(renderPhaseTransition)
                    .onAppear {
                        NavigationPerformanceTracer.workDetailShellDidAppear(tagID: tagID)
                    }
            case .error:
                let error = store.catalog.workDetailError(tagID: tagID) ?? localizer.string(.workDetailUnavailableDescription)
                ContentUnavailableView(
                    localizer.string(.workDetailUnavailable),
                    systemImage: "exclamationmark.triangle",
                    description: Text(error)
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .transition(renderPhaseTransition)
            case .content:
                if let detail {
                    detailContent(detail)
                        .transition(renderPhaseTransition)
                }
            case .unavailable:
                ContentUnavailableView(
                    localizer.string(.workDetailUnavailable),
                    systemImage: "rectangle.stack",
                    description: Text(localizer.string(.workDetailUnavailableDescription))
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .transition(renderPhaseTransition)
            }
        }
        .animation(renderPhaseAnimation, value: renderPhase)
        .navigationTitle(detail?.work.displayText ?? localizer.string(.detailWorks))
        .task(id: "\(tagID)-\(isTagTranslationEnabled)-\(store.catalog.workDetailRevision)") {
            // WorkDetail 数据由 Store 缓存并按标签翻译开关区分；视图只声明需要，不直接拼 repository 查询。
            hasRequestedDetailLoad = true
            store.catalog.reloadWorkDetail(
                tagID: tagID,
                isTagTranslationEnabled: isTagTranslationEnabled
            )
        }
        .onDisappear {
            motion.clear()
            NavigationPerformanceTracer.workDetailDidDisappear(tagID: tagID)
        }
        .workTopicAssignmentFeedback(store: store, workID: tagID, localizer: localizer, onManage: { isManagingClaims = true })
        .sheet(isPresented: $isManagingClaims) {
            WorkCharacterManagementSheet(
                store: store,
                workID: tagID,
                isTagTranslationEnabled: isTagTranslationEnabled,
                localizer: localizer
            )
        }
    }

    private var renderPhaseTransition: AnyTransition {
        usesExternalTransitionShell ? .identity : .opacity
    }

    private var renderPhaseAnimation: Animation? {
        usesExternalTransitionShell ? nil : .easeInOut(duration: 0.18)
    }

    private func detailContent(_ detail: WorkDetail) -> some View {
        let selection = WorkTopicSelection.resolved(browsing.selection, in: detail)
        let section = selection.flatMap { value -> WorkCharacterBookSection? in
            guard case let .character(id) = value else { return nil }
            return detail.section(for: id)
        }
        let portrait = section.flatMap(portraitRequest)
        return WorkTopicLayout(browsing: browsing) { presentation, expand in
            WorkDetailHero(
                detail: detail, presentation: presentation, browsing: browsing,
                assetURL: store.catalog.tagVisualAssetURL(relativePath:),
                localizer: localizer, onImportTagImage: importDroppedTagImage,
                onDropError: { store.catalog.loadError = $0 },
                onSearchWork: { onSearchWork(detail.work) }, onExpand: expand
            )
        } selector: {
            WorkTopicSelector(
                characters: detail.characters,
                selectedCharacterID: section?.character?.id,
                unclassifiedCount: detail.unclassifiedBooks.count,
                isShowingUnclassified: selection == .unclassified,
                assetURL: store.catalog.tagVisualAssetURL(relativePath:),
                localizer: localizer, position: browsing.selector, motion: motion,
                onSelect: { id in
                    if let next = detail.section(for: id) {
                        show(next, request: portraitRequest(for: next), restore: false)
                    }
                },
                onUnclassified: {
                    motion.clear()
                    browsing.selection = .unclassified
                },
                onManage: { isManagingClaims = true }
            )
        } content: {
            switch selection {
            case .character:
                if let section {
                    WorkCharacterShelf(
                        section: section, shelfSection: motion.shelfID.flatMap(detail.section),
                        shelfPosition: motion.shelfID.map(browsing.shelf),
                        titleDisplayMode: titleDisplayMode, localizer: localizer,
                        onImportTagImage: importDroppedTagImage, onDropError: { store.catalog.loadError = $0 },
                        onSelectCharacter: onSelectCharacter, onSelectBook: onSelectBook,
                        workID: tagID, motion: motion
                    )
                }
            case .unclassified:
                WorkTopicUnclassifiedView(
                    books: detail.unclassifiedBooks, characters: detail.characters, workID: tagID, store: store,
                    titleDisplayMode: titleDisplayMode, isTagTranslationEnabled: isTagTranslationEnabled,
                    localizer: localizer, onSelectBook: onSelectBook
                )
                .modifier(WorkTopicReadableContent())
            case nil:
                ContentUnavailableView(
                    localizer.string(.workDetailNoBooks), systemImage: "books.vertical",
                    description: Text(localizer.string(.workDetailNoBooksDescription))
                )
                .frame(maxWidth: .infinity, minHeight: 260)
                .modifier(WorkTopicReadableContent())
            }
        }
        .workTopicFlightOverlay(motion) { character in
            WorkTopicCharacterNameplate(character: character, bookCount: detail.section(for: character.id)?.bookCount ?? 0,
                                       localizer: localizer, onSelectCharacter: onSelectCharacter)
        }
        .background {
            WorkDetailBackground(work: detail.work,
                                 fallbackHex: TagVisualAssetService.effectiveBackgroundHex(for: detail.work),
                                 paletteLoader: store.catalog.tagVisualBackgroundPalette(relativeBackgroundPath:))
        }
        .onChange(of: PortraitSelection(stored: browsing.selection, resolved: selection, request: portrait), initial: true) { _, current in
            if let section, let character = section.character {
                // A committed click already has its image. In particular, leave a newer
                // queued click alone when SwiftUI observes the earlier route selection.
                if current.stored != nil && current.stored != current.resolved { motion.clear() }
                if motion.active?.character.id != character.id || motion.active?.request != current.request {
                    show(section, request: current.request, restore: current.stored != nil)
                }
            } else {
                motion.clear()
                browsing.selection = current.resolved
            }
        }
        .onAppear { NavigationPerformanceTracer.workDetailContentReady(tagID: tagID, sectionCount: detail.sections.count) }
    }

    private struct PortraitSelection: Equatable {
        let stored: WorkTopicSelection?
        let resolved: WorkTopicSelection?
        let request: WorkTopicAvatarRequest?
    }

    private func portraitRequest(for section: WorkCharacterBookSection) -> WorkTopicAvatarRequest? {
        guard let profile = section.character?.visualProfile, let path = profile.foregroundAssetPath,
              let url = store.catalog.tagVisualAssetURL(relativePath: path) else { return nil }
        let longEdge = max(WorkTopicStageLayout.maximumPortraitWidth, WorkTopicStageLayout.panelHeight(fields: cardFields))
        return WorkTopicAvatarRequest(url: url, revision: profile.updatedAt, pixels: Int(ceil(longEdge * displayScale)))
    }

    private func show(_ section: WorkCharacterBookSection, request: WorkTopicAvatarRequest?, restore: Bool) {
        guard let character = section.character else { return }
        motion.show(character, request: request, restore: restore, reduceMotion: reduceMotion) { [browsing] id in
            browsing.selection = .character(id)
        }
    }

    private func importDroppedTagImage(
        kind: TagVisualDropImportKind,
        imageData: Data,
        tag: TagVisualAssetTarget
    ) {
        store.catalog.importDroppedTagImage(kind: kind, imageData: imageData, tag: tag)
    }
}

struct CharacterDetailView: View {
    let store: TagDiscoveryStore
    let tagID: Tag.DatabaseID
    let isTagTranslationEnabled: Bool
    let titleDisplayMode: BookTitleDisplayMode
    let initialScrollOffset: CGFloat?
    let usesExternalTransitionShell: Bool
    let localizer: AppLocalizer
    let onScrollOffsetChange: (CGFloat) -> Void
    let onSelectBook: (LibraryBook) -> Void
    let onSelectWork: (TagDisplaySummary) -> Void
    let onSearchCharacter: (TagDisplaySummary) -> Void

    @State private var sectionRenderBudget = WorkDetailSectionRenderBudget()
    @State private var visibleSectionIndices: Set<Int> = []
    @State private var visibleSectionRange: ClosedRange<Int>?

    private var detail: CharacterDetail? {
        store.catalog.characterDetail(tagID: tagID)
    }

    private var renderPhase: WorkDetailRenderPhase {
        WorkDetailRenderPhase.resolve(
            hasDetail: detail != nil,
            isLoading: store.catalog.isLoadingCharacterDetail(tagID: tagID),
            hasRequestedLoad: true,
            hasError: store.catalog.characterDetailError(tagID: tagID) != nil
        )
    }

    var body: some View {
        ZStack {
            switch renderPhase {
            case .loadingShell:
                CharacterDetailLoadingShell(localizer: localizer)
                    .transition(renderPhaseTransition)
            case .error:
                let error = store.catalog.characterDetailError(tagID: tagID) ?? localizer.string(.workDetailUnavailableDescription)
                ContentUnavailableView(
                    localizer.string(.workDetailUnavailable),
                    systemImage: "person.crop.square",
                    description: Text(error)
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .transition(renderPhaseTransition)
            case .unavailable:
                ContentUnavailableView(
                    localizer.string(.workDetailUnavailable),
                    systemImage: "person.crop.square",
                    description: Text(localizer.string(.workDetailUnavailableDescription))
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .transition(renderPhaseTransition)
            case .content:
                if let detail {
                    detailContent(detail)
                        .transition(renderPhaseTransition)
                }
            }
        }
        .animation(renderPhaseAnimation, value: renderPhase)
        .task(id: "\(tagID)-\(isTagTranslationEnabled)-\(store.catalog.characterDetailRevision)") {
            store.catalog.reloadCharacterDetail(
                tagID: tagID,
                isTagTranslationEnabled: isTagTranslationEnabled
            )
        }
        .onChange(of: tagID) { _, _ in
            sectionRenderBudget = WorkDetailSectionRenderBudget()
            visibleSectionIndices = []
            visibleSectionRange = nil
        }
        .onDisappear {
            NavigationPerformanceTracer.characterDetailDidDisappear(tagID: tagID)
        }
    }

    private var renderPhaseTransition: AnyTransition {
        usesExternalTransitionShell ? .identity : .opacity
    }

    private var renderPhaseAnimation: Animation? {
        usesExternalTransitionShell ? nil : .easeInOut(duration: 0.18)
    }

    private func detailContent(_ detail: CharacterDetail) -> some View {
        ZStack(alignment: .top) {
                WorkDetailBackground(
                    work: detail.backgroundTag ?? detail.character,
                    fallbackHex: TagVisualAssetService.effectiveBackgroundHex(for: detail.backgroundTag ?? detail.character),
                    paletteLoader: store.catalog.tagVisualBackgroundPalette(relativeBackgroundPath:)
                )

                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        CharacterDetailHero(
                            detail: detail,
                            assetURL: store.catalog.tagVisualAssetURL(relativePath:),
                            localizer: localizer,
                            onImportTagImage: importDroppedTagImage,
                            onDropError: { store.catalog.loadError = $0 },
                            onSearchCharacter: { onSearchCharacter(detail.character) }
                        )

                        if detail.sections.isEmpty {
                            ContentUnavailableView(
                                localizer.string(.characterDetailNoBooks),
                                systemImage: "books.vertical",
                                description: Text(localizer.string(.characterDetailNoBooksDescription))
                            )
                            .frame(maxWidth: .infinity, minHeight: 260)
                            .padding(.horizontal, 34)
                        } else {
                            LazyVStack(alignment: .leading, spacing: 14) {
                                ForEach(Array(detail.sections.enumerated()), id: \.element.id) { index, section in
                                    if sectionContentWeight(index: index, totalCount: detail.sections.count) == .full {
                                        CharacterWorkShelf(
                                            section: section,
                                            titleDisplayMode: titleDisplayMode,
                                            localizer: localizer,
                                            onSelectWork: onSelectWork,
                                            onSelectBook: onSelectBook
                                        )
                                        .onScrollVisibilityChange(threshold: 0.06) { isVisible in
                                            updateSectionVisibility(
                                                index: index,
                                                isVisible: isVisible,
                                                totalCount: detail.sections.count
                                            )
                                        }
                                        .transition(.opacity.combined(with: .scale(scale: 0.985)))
                                    } else {
                                        CharacterWorkShelfPlaceholder(
                                            usesDoubleRow: WorkCharacterShelfLayout.usesDoubleRow(bookCount: section.bookCount)
                                        )
                                        .onScrollVisibilityChange(threshold: 0.01) { isVisible in
                                            updateSectionVisibility(
                                                index: index,
                                                isVisible: isVisible,
                                                totalCount: detail.sections.count
                                            )
                                        }
                                        .transition(.opacity)
                                    }
                                }
                            }
                            .padding(.horizontal, 34)
                        }
                    }
                    .padding(.top, 34)
                    .padding(.bottom, 34)
                    .frame(maxWidth: 1540, alignment: .topLeading)
                    .frame(maxWidth: .infinity, alignment: .top)
                    .background {
                        WorkDetailScrollOffsetReader(
                            tagID: tagID,
                            initialOffset: initialScrollOffset
                        )
                        .frame(width: 0, height: 0)
                    }
                }
                .onScrollGeometryChange(for: CGFloat.self) { geometry in
                    max(geometry.contentOffset.y, 0)
                } action: { _, newOffset in
                    onScrollOffsetChange(newOffset)
                }
            }
        .animation(.easeInOut(duration: 0.18), value: visibleSectionRange)
        .task(id: "\(tagID)-\(isTagTranslationEnabled)-\(detail.sections.count)") {
            resetSectionRendering()
            await Task.yield()
            _ = sectionRenderBudget.unlockInitial(totalCount: detail.sections.count)
        }
    }

    private func sectionContentWeight(index: Int, totalCount: Int) -> WorkDetailSectionContentWeight {
        WorkDetailSectionViewportPolicy.contentWeight(
            for: index,
            visibleRange: visibleSectionRange,
            totalCount: totalCount
        )
    }

    private func updateSectionVisibility(index: Int, isVisible: Bool, totalCount: Int) {
        if isVisible {
            visibleSectionIndices = visibleSectionIndices.filter { abs($0 - index) <= WorkDetailSectionViewportPolicy.maximumTrackedDistance }
            visibleSectionIndices.insert(index)
        } else {
            visibleSectionIndices.remove(index)
        }

        let nextRange = WorkDetailSectionViewportPolicy.visibleRange(
            afterVisibilityChange: visibleSectionIndices,
            totalCount: totalCount
        )
        guard let nextRange, nextRange != visibleSectionRange else {
            return
        }
        visibleSectionRange = nextRange
    }

    private func resetSectionRendering() {
        sectionRenderBudget.reset()
        visibleSectionIndices = []
        visibleSectionRange = nil
    }

    private func importDroppedTagImage(
        kind: TagVisualDropImportKind,
        imageData: Data,
        tag: TagVisualAssetTarget
    ) {
        store.catalog.importDroppedTagImage(kind: kind, imageData: imageData, tag: tag)
    }
}

private struct WorkDetailScrollOffsetReader: NSViewRepresentable {
    let tagID: Tag.DatabaseID
    let initialOffset: CGFloat?

    func makeNSView(context: Context) -> ObserverView {
        ObserverView(tagID: tagID, initialOffset: initialOffset)
    }

    func updateNSView(_ nsView: ObserverView, context: Context) {
        nsView.tagID = tagID
        nsView.initialOffset = initialOffset
        nsView.attachToNearestScrollViewIfNeeded()
    }

    final class ObserverView: NSView {
        var tagID: Tag.DatabaseID
        var initialOffset: CGFloat?
        private weak var observedScrollView: NSScrollView?
        private var restoredIdentity: String?
        private var restoreRetryCount = 0

        init(tagID: Tag.DatabaseID, initialOffset: CGFloat?) {
            self.tagID = tagID
            self.initialOffset = initialOffset
            super.init(frame: .zero)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            DispatchQueue.main.async { [weak self] in
                self?.attachToNearestScrollViewIfNeeded()
            }
        }

        override func removeFromSuperview() {
            observedScrollView = nil
            super.removeFromSuperview()
        }

        override func viewWillMove(toWindow newWindow: NSWindow?) {
            if newWindow == nil {
                observedScrollView = nil
            }
            super.viewWillMove(toWindow: newWindow)
        }

        func attachToNearestScrollViewIfNeeded() {
            guard let scrollView = nearestScrollView() else {
                return
            }
            if scrollView !== observedScrollView {
                observedScrollView = scrollView
            }

            restoreInitialOffsetIfNeeded(in: scrollView)
        }

        private func nearestScrollView() -> NSScrollView? {
            if let enclosingScrollView {
                return enclosingScrollView
            }

            var view: NSView? = superview
            while let candidate = view {
                if let scrollView = candidate as? NSScrollView {
                    return scrollView
                }
                view = candidate.superview
            }
            return nil
        }

        private func restoreInitialOffsetIfNeeded(in scrollView: NSScrollView) {
            guard let initialOffset else {
                return
            }
            let identity = "\(tagID)-\(initialOffset)"
            guard restoredIdentity != identity else {
                return
            }

            let documentHeight = scrollView.documentView?.bounds.height ?? 0
            let viewportHeight = scrollView.contentView.bounds.height
            let maxOffset = max(documentHeight - viewportHeight, 0)
            if initialOffset > 0, maxOffset == 0, restoreRetryCount < 3 {
                restoreRetryCount += 1
                DispatchQueue.main.async { [weak self, weak scrollView] in
                    guard let self, let scrollView else {
                        return
                    }
                    self.restoreInitialOffsetIfNeeded(in: scrollView)
                }
                return
            }

            let clampedOffset = WorkDetailScrollRestorationPolicy.clampedOffset(
                initialOffset,
                documentHeight: documentHeight,
                viewportHeight: viewportHeight
            )
            // 路由恢复滚动位置必须禁用动画，否则 pop 时会和外层页面转场叠加成二次滑动。
            var transaction = Transaction(animation: nil)
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = 0
                    scrollView.contentView.scroll(
                        to: CGPoint(x: scrollView.contentView.bounds.origin.x, y: clampedOffset)
                    )
                    scrollView.reflectScrolledClipView(scrollView.contentView)
                }
            }
            restoredIdentity = identity
            restoreRetryCount = 0
        }

    }
}

enum WorkDetailRenderPhase: Equatable {
    case loadingShell
    case error
    case content
    case unavailable

    static func resolve(
        hasDetail: Bool,
        isLoading: Bool,
        hasRequestedLoad: Bool,
        hasError: Bool
    ) -> WorkDetailRenderPhase {
        if hasDetail {
            return .content
        }
        if hasError {
            return .error
        }
        if isLoading || !hasRequestedLoad {
            return .loadingShell
        }
        return .unavailable
    }
}

private struct WorkTopicSearchLabel: Layout {
    let fraction: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let icon = subviews[0].sizeThatFits(.unspecified)
        let title = subviews[1].sizeThatFits(.unspecified)
        return .init(width: icon.width + (7 + title.width) * fraction, height: max(icon.height, title.height))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let iconWidth = subviews[0].sizeThatFits(.unspecified).width
        subviews[0].place(at: .init(x: bounds.minX, y: bounds.midY), anchor: .leading, proposal: .unspecified)
        subviews[1].place(at: .init(x: bounds.minX + iconWidth + 7 * fraction, y: bounds.midY),
                          anchor: .leading, proposal: .unspecified)
    }
}

private extension TagDisplaySummary {
    var assetTarget: TagVisualAssetTarget {
        TagVisualAssetTarget(
            tagID: id,
            namespace: namespace,
            name: name,
            rawValue: rawValue
        )
    }
}

struct WorkDetailSectionRenderBudget: Equatable {
    static let initialUnlockedCount = 3
    static let prefetchDistance = 2

    private(set) var unlockedCount = 0

    struct UnlockResult: Equatable {
        let previousCount: Int
        let unlockedCount: Int

        var didUnlock: Bool {
            unlockedCount > previousCount
        }
    }

    func isUnlocked(index: Int) -> Bool {
        index < unlockedCount
    }

    mutating func reset() {
        unlockedCount = 0
    }

    mutating func unlockInitial(totalCount: Int) -> UnlockResult {
        unlock(upTo: Self.initialUnlockedCount, totalCount: totalCount)
    }

    mutating func unlockThroughVisibleIndex(_ index: Int, totalCount: Int) -> UnlockResult {
        unlock(upTo: index + 1 + Self.prefetchDistance, totalCount: totalCount)
    }

    private mutating func unlock(upTo targetCount: Int, totalCount: Int) -> UnlockResult {
        let previousCount = unlockedCount
        unlockedCount = min(max(unlockedCount, targetCount), max(totalCount, 0))
        return UnlockResult(previousCount: previousCount, unlockedCount: unlockedCount)
    }
}

enum WorkCharacterShelfLayout {
    static func usesDoubleRow(bookCount: Int) -> Bool {
        bookCount > 6
    }

    static func columnCount(bookCount: Int, usesDoubleRow: Bool) -> Int {
        guard bookCount > 0 else {
            return 0
        }
        if usesDoubleRow {
            return Int(ceil(Double(bookCount) / 2.0))
        }
        return bookCount
    }

    static func bookRange(forColumn columnIndex: Int, bookCount: Int, usesDoubleRow: Bool) -> Range<Int> {
        guard bookCount > 0 else {
            return 0..<0
        }
        if usesDoubleRow {
            let lowerBound = min(max(columnIndex, 0) * 2, bookCount)
            return lowerBound..<min(lowerBound + 2, bookCount)
        }
        let lowerBound = min(max(columnIndex, 0), bookCount)
        return lowerBound..<min(lowerBound + 1, bookCount)
    }
}

private struct WorkDetailLoadingBackground: View {
    var body: some View {
        MeshGradient(
            width: 3,
            height: 3,
            points: [
                [0, 0], [0.5, 0], [1, 0],
                [0, 0.52], [0.52, 0.46], [1, 0.56],
                [0, 1], [0.48, 1], [1, 1]
            ],
            colors: [
                Color(nsColor: .windowBackgroundColor),
                Color(nsColor: .controlBackgroundColor),
                Color.accentColor.opacity(0.16),
                Color(nsColor: .windowBackgroundColor),
                Color.accentColor.opacity(0.10),
                Color(nsColor: .controlBackgroundColor),
                Color(nsColor: .windowBackgroundColor),
                Color(nsColor: .windowBackgroundColor),
                Color(nsColor: .controlBackgroundColor)
            ]
        )
        .ignoresSafeArea()
    }
}

private struct CharacterDetailLoadingShell: View {
    let localizer: AppLocalizer

    var body: some View {
        ZStack(alignment: .top) {
            WorkDetailLoadingBackground()

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    CharacterDetailLoadingHeroSkeleton(localizer: localizer)

                    LazyVStack(alignment: .leading, spacing: 14) {
                        ForEach(0..<WorkDetailSectionRenderBudget.initialUnlockedCount, id: \.self) { index in
                            CharacterWorkShelfPlaceholder(usesDoubleRow: index == 0)
                        }
                    }
                    .padding(.horizontal, 34)
                }
                .padding(.bottom, 34)
                .frame(maxWidth: 1540, alignment: .topLeading)
                .frame(maxWidth: .infinity, alignment: .top)
            }

            ProgressView()
                .controlSize(.small)
                .padding(12)
                .background(.regularMaterial, in: Capsule())
                .padding(.top, 24)
                .frame(maxWidth: .infinity, alignment: .top)
        }
        .redacted(reason: .placeholder)
    }
}

private struct CharacterDetailLoadingHeroSkeleton: View {
    let localizer: AppLocalizer

    var body: some View {
        CharacterDetailHeroArrangement {
            VStack(alignment: .leading, spacing: 20) {
                Text(localizer.string(.tagNamespaceCharacter))
                    .font(.system(size: 54, weight: .bold))

                HStack(spacing: 10) {
                    WorkDetailPill(text: localizer.characterDetailWorkCount(8), systemImage: "rectangle.stack")
                    WorkDetailPill(text: localizer.workDetailBookCount(48), systemImage: "books.vertical")
                }

                Text(localizer.string(.characterDetailNoIntro))
                    .font(.title3.weight(.medium))
                    .lineLimit(4)
                    .frame(maxWidth: 720, alignment: .leading)
            }
            .frame(maxWidth: CharacterDetailHeroLayoutMetrics.textColumnMaxWidth, alignment: .leading)
        } figure: {
            RoundedRectangle(cornerRadius: 28)
                .fill(.secondary.opacity(0.12))
                .frame(width: 260, height: 540)
        }
        .padding(.horizontal, 34)
    }
}

struct WorkCharacterShelfPlaceholder: View {
    let usesDoubleRow: Bool
    @Environment(\.bookCardFields) private var fields

    var body: some View {
        let metrics = WorkCharacterShelfMetrics.cardMetrics(usesDoubleRow: usesDoubleRow)
        let height = WorkCharacterShelfMetrics.carouselHeight(metrics: metrics, usesDoubleRow: usesDoubleRow, fields: fields)
        WorkCharacterShelfFrame {
            let glass = WorkTopicCharacterGlass(expansion: 1)
            glass.overlay { glass.clippedNameplate { WorkTopicNameplatePlaceholder() } }
        } carousel: { layout in
            Color.clear.overlay(alignment: .topLeading) {
                HStack(alignment: .top, spacing: usesDoubleRow ? 16 : 20) {
                    ForEach(0..<6, id: \.self) { _ in
                        VStack(spacing: WorkCharacterShelfMetrics.doubleRowSpacing) {
                            TopicShelfCardPlaceholder(metrics: metrics, fields: fields)
                            if usesDoubleRow { TopicShelfCardPlaceholder(metrics: metrics, fields: fields) }
                        }
                    }
                }
                .padding(.top, WorkCharacterShelfMetrics.verticalCardPadding / 2)
                .padding(.leading, layout.firstCoverX)
            }
            .frame(height: height)
            .clipped()
        }
        .accessibilityHidden(true)
    }
}

private struct WorkDetailHero: View {
    let detail: WorkDetail
    let presentation: WorkTopicHeaderMetrics
    let browsing: WorkTopicBrowsingState
    let assetURL: (String) -> URL?
    let localizer: AppLocalizer
    let onImportTagImage: (TagVisualDropImportKind, Data, TagVisualAssetTarget) -> Void
    let onDropError: (String) -> Void
    let onSearchWork: () -> Void
    let onExpand: () -> Void

    @State private var foreground: NSImage?

    var body: some View {
        ZStack {
            WorkHeroBackground(work: detail.work, assetURL: assetURL)
                .opacity(presentation.artworkOpacity)
                .allowsHitTesting(false)
            WorkHeroDropCaptureOverlay(detail: detail, localizer: localizer,
                                       onImportTagImage: onImportTagImage, onDropError: onDropError)
            if presentation.canExpand {
                Button(action: onExpand) {
                    Color.clear.contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(localizer.string(.workTopicExpandIntroduction))
                .onKeyPress(.return) { onExpand(); return .handled }
            }
            WorkTopicHeroControls(presentation: presentation) {
                identity
                WorkTopicHeroCounts(characterCount: detail.characterCount, bookCount: detail.totalBookCount, localizer: localizer)
                    .allowsHitTesting(false)
                Text(introText)
                    .font(.title3.weight(.medium))
                    .foregroundStyle(.primary.opacity(0.88))
                    .lineSpacing(3)
                    .lineLimit(4)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .clipped()
                    .opacity(presentation.introductionOpacity)
                    .accessibilityHidden(presentation.introductionOpacity == 0)
                    .help(introText)
                    .allowsHitTesting(!presentation.canExpand)
                search
            }
        }
        .task(id: detail.work.foregroundIdentity) {
            foreground = nil
            guard let path = detail.work.visualProfile?.foregroundAssetPath, let url = assetURL(path) else { return }
            let image = await TagVisualImageCache.shared.image(for: url)
            guard !Task.isCancelled else { return }
            foreground = image
        }
    }

    @ViewBuilder
    private var identity: some View {
        if let foreground {
            Button { browsing.prefersTitle.toggle() } label: {
                GeometryReader { proxy in
                    if browsing.prefersTitle {
                        title
                    } else {
                        Image(nsImage: foreground)
                            .resizable().scaledToFit()
                            .scaleEffect(detail.work.visualProfile?.foregroundScale ?? 1)
                            .offset(x: (detail.work.visualProfile?.foregroundOffsetX ?? 0) * proxy.size.width,
                                    y: (detail.work.visualProfile?.foregroundOffsetY ?? 0) * proxy.size.height)
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                    }
                }
                .clipped()
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(detail.work.displayText)
            .help(localizer.string(.workTopicSwitchTitle))
            .accessibilityHint(localizer.string(.workTopicSwitchTitle))
        } else {
            title.allowsHitTesting(false)
        }
    }

    private var title: some View {
        Text(detail.work.displayText)
            .font(.system(size: presentation.interpolate(48, 18), weight: .bold))
            .lineLimit(2)
            .minimumScaleFactor(0.75)
            .multilineTextAlignment(.leading)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .clipped()
    }

    private var search: some View {
        Button(action: onSearchWork) {
            WorkTopicSearchLabel(fraction: presentation.searchLabelSpace) {
                Image(systemName: "magnifyingglass")
                Text(localizer.string(.workDetailSearchWork))
                    .fixedSize()
                    .opacity(presentation.searchLabelOpacity)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipped()
            .contentShape(.capsule)
        }
        .buttonStyle(WorkTopicSearchButtonStyle())
        .onKeyPress(.return) { onSearchWork(); return .handled }
        .help(localizer.string(.workDetailSearchWork))
        .accessibilityLabel(localizer.string(.workDetailSearchWork))
    }

    private var introText: String {
        let trimmed = detail.work.translationIntro?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? localizer.string(.workDetailNoIntro) : trimmed
    }
}

private struct WorkTopicSearchButtonStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.isFocused) private var focused
    @State private var hovered = false

    func makeBody(configuration: Configuration) -> some View {
        let feedback = WorkTopicSearchFeedback(hovered: hovered, focused: focused, pressed: configuration.isPressed)
        // The stationary capsule owns hover and clicks while its visible glass responds to the pointer.
        Color.clear
            .overlay {
                configuration.label
                    .font(.headline)
                    .foregroundStyle(.primary)
                    .glassEffect(.regular, in: .capsule)
                    .overlay {
                        Capsule().strokeBorder(.primary.opacity(feedback.edgeOpacity), lineWidth: 1)
                    }
                    .scaleEffect(feedback.scale(reduceMotion: reduceMotion))
                    .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: feedback)
                    .allowsHitTesting(false)
            }
            .contentShape(.capsule)
            .onHover { hovered = $0 }
    }
}

enum WorkTopicSearchFeedback: Equatable {
    case resting, focused, hovered, pressed

    init(hovered: Bool, focused: Bool, pressed: Bool) {
        if pressed { self = .pressed }
        else if hovered { self = .hovered }
        else if focused { self = .focused }
        else { self = .resting }
    }

    var edgeOpacity: Double {
        switch self {
        case .resting: 0.10
        case .focused, .hovered: 0.34
        case .pressed: 0.48
        }
    }

    func scale(reduceMotion: Bool) -> CGFloat {
        guard !reduceMotion else { return 1 }
        switch self {
        case .resting, .focused: return 1
        case .hovered: return 1.035
        case .pressed: return 0.96
        }
    }
}

struct WorkTopicHeroCounts: View {
    let characterCount: Int
    let bookCount: Int
    let localizer: AppLocalizer

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 10) {
                pill(localizer.workDetailCharacterCount(characterCount), icon: "person.2", horizontalPadding: 9)
                pill(localizer.workDetailBookCount(bookCount), icon: "books.vertical", horizontalPadding: 9)
            }
            HStack(spacing: 8) {
                pill(characterCount.formatted(), icon: "person.2", horizontalPadding: 3)
                pill(bookCount.formatted(), icon: "books.vertical", horizontalPadding: 3)
            }
        }
        .lineLimit(1)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(localizer.workDetailCharacterCount(characterCount) + ", " + localizer.workDetailBookCount(bookCount))
    }

    private func pill(_ text: String, icon: String, horizontalPadding: CGFloat) -> some View {
        Label(text, systemImage: icon)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.primary)
            .padding(.horizontal, horizontalPadding)
            .padding(.vertical, 5)
            .overlay { Capsule().strokeBorder(.secondary.opacity(0.65), lineWidth: 1) }
    }
}

private extension TagDisplaySummary {
    var foregroundIdentity: String {
        "\(id)-\(visualProfile?.foregroundAssetPath ?? "")-\(visualProfile?.updatedAt ?? 0)"
    }
}

private struct CharacterDetailHero: View {
    let detail: CharacterDetail
    let assetURL: (String) -> URL?
    let localizer: AppLocalizer
    let onImportTagImage: (TagVisualDropImportKind, Data, TagVisualAssetTarget) -> Void
    let onDropError: (String) -> Void
    let onSearchCharacter: () -> Void

    @State private var characterImageAvailability = WorkCharacterImageAvailability.pending

    var body: some View {
        CharacterDetailHeroArrangement {
            VStack(alignment: .leading, spacing: 20) {
                Text(detail.character.displayText)
                    .font(.system(size: 54, weight: .bold))
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: 10) {
                    WorkDetailPill(text: localizer.characterDetailWorkCount(detail.workCount), systemImage: "rectangle.stack")
                    WorkDetailPill(text: localizer.workDetailBookCount(detail.totalBookCount), systemImage: "books.vertical")
                    if detail.character.displayText != detail.character.name {
                        WorkDetailPill(text: detail.character.name, systemImage: "tag")
                    }
                }

                Text(introText)
                    .font(.title3.weight(.medium))
                    .foregroundStyle(.primary.opacity(0.74))
                    .lineSpacing(5)
                    .lineLimit(5)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 820, alignment: .leading)

                Button(action: onSearchCharacter) {
                    Label(localizer.string(.characterDetailSearchCharacter), systemImage: "magnifyingglass")
                        .frame(minWidth: 148)
                }
                .controlSize(.large)
                .buttonStyle(.borderedProminent)
            }
            .frame(maxWidth: CharacterDetailHeroLayoutMetrics.textColumnMaxWidth, alignment: .leading)
        } figure: {
            characterFigure
        }
        .padding(.horizontal, 34)
    }

    @ViewBuilder
    private var characterFigure: some View {
        let hasImageLikeAsset = characterImageAvailability.hasImageLikeAsset(
            configured: detail.character.visualProfile?.foregroundAssetPath != nil
        )
        ZStack(alignment: .bottom) {
            if !hasImageLikeAsset {
                Image(systemName: "person.crop.square")
                    .font(.system(size: 52, weight: .medium))
                    .foregroundStyle(.secondary.opacity(0.42))
                    .frame(width: 112, height: 112)
                    .background(.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 24))
                    .padding(.bottom, 110)
            }

            WorkCharacterImage(
                tag: detail.character,
                assetURL: assetURL,
                trimsTransparentMargins: true,
                onImageAvailabilityChange: { isAvailable in
                    characterImageAvailability = isAvailable ? .available : .missing
                }
            )
            .shadow(color: .black.opacity(hasImageLikeAsset ? 0.18 : 0), radius: 22, x: 0, y: 12)
        }
        .background {
            if hasImageLikeAsset {
                RadialGradient(
                    colors: [portraitGlowColor.opacity(0.25), portraitGlowColor.opacity(0.08), .clear],
                    center: .center,
                    startRadius: 0,
                    endRadius: 230
                )
                .frame(width: 450, height: 560)
                .offset(y: -42)
                .allowsHitTesting(false)
            }
        }
        .background(alignment: .bottom) {
            if hasImageLikeAsset {
                Ellipse()
                    .fill(.black.opacity(0.12))
                    .frame(width: 190, height: 20)
                    .blur(radius: 14)
                    .padding(.bottom, 8)
                    .allowsHitTesting(false)
            }
        }
        .contentShape(Rectangle())
        .tagVisualImageDropTarget(
            kind: .foreground,
            localizer: localizer,
            cornerRadius: WorkDetailSurfaceRole.hero.cornerRadius,
            hasExistingAsset: { detail.character.visualProfile?.foregroundAssetPath != nil },
            onImport: { imageData in
                onImportTagImage(.foreground, imageData, detail.character.assetTarget)
            },
            onError: onDropError
        )
        .onChange(of: detail.character.id) { _, _ in
            characterImageAvailability = .pending
        }
    }

    private var introText: String {
        let trimmed = detail.character.translationIntro?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? localizer.string(.characterDetailNoIntro) : trimmed
    }

    private var portraitGlowColor: Color {
        Color(nsColor: NSColor.nyaehColor(hex: TagVisualAssetService.effectiveBackgroundHex(for: detail.character)) ?? .controlAccentColor)
    }
}

struct CharacterDetailHeroLayoutMetrics: Equatable {
    static let minHeight: CGFloat = 720
    static let horizontalPadding: CGFloat = 58
    static let verticalPadding: CGFloat = 40
    static let columnSpacing: CGFloat = 28
    static let textColumnMaxWidth: CGFloat = 760
    static let minimumInformationWidth: CGFloat = 420
    static let minimumWideContentWidth: CGFloat = 870
    static let figureWidth: CGFloat = 360
    static let figureHeight: CGFloat = 650
    static let narrowFigureHeight: CGFloat = 560

    var containerHeight: CGFloat
    var informationHeight: CGFloat
    var figureHeight: CGFloat
    var verticalPadding: CGFloat

    static func resolve(
        containerHeight: CGFloat = minHeight,
        informationHeight: CGFloat,
        figureHeight: CGFloat = Self.figureHeight,
        verticalPadding: CGFloat = Self.verticalPadding
    ) -> CharacterDetailHeroLayoutMetrics {
        CharacterDetailHeroLayoutMetrics(
            containerHeight: max(containerHeight, 0),
            informationHeight: max(informationHeight, 0),
            figureHeight: max(figureHeight, 0),
            verticalPadding: max(verticalPadding, 0)
        )
    }

    var contentHeight: CGFloat {
        max(containerHeight - verticalPadding * 2, 0)
    }

    var informationTopInset: CGFloat {
        max((contentHeight - informationHeight) / 2, 0)
    }

    var informationBottomInset: CGFloat {
        informationTopInset
    }

    var figureBottomInset: CGFloat {
        verticalPadding
    }
}

struct CharacterDetailHeroArrangement<Information: View, Figure: View>: View {
    let information: Information
    let figure: Figure

    init(@ViewBuilder information: () -> Information, @ViewBuilder figure: () -> Figure) {
        self.information = information()
        self.figure = figure()
    }

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .center, spacing: CharacterDetailHeroLayoutMetrics.columnSpacing) {
                information
                    .frame(minWidth: CharacterDetailHeroLayoutMetrics.minimumInformationWidth, maxWidth: CharacterDetailHeroLayoutMetrics.textColumnMaxWidth, alignment: .leading)
                Spacer(minLength: 0)
                figure
                    .frame(
                        width: CharacterDetailHeroLayoutMetrics.figureWidth,
                        height: CharacterDetailHeroLayoutMetrics.figureHeight,
                        alignment: .bottom
                    )
            }
            .frame(minWidth: CharacterDetailHeroLayoutMetrics.minimumWideContentWidth)

            VStack(alignment: .leading, spacing: 24) {
                information
                    .frame(maxWidth: CharacterDetailHeroLayoutMetrics.textColumnMaxWidth, alignment: .leading)
                figure
                    .frame(
                        width: CharacterDetailHeroLayoutMetrics.figureWidth,
                        height: CharacterDetailHeroLayoutMetrics.narrowFigureHeight,
                        alignment: .bottom
                    )
                    .frame(maxWidth: .infinity)
            }
        }
        .padding(.horizontal, CharacterDetailHeroLayoutMetrics.horizontalPadding)
        .padding(.vertical, CharacterDetailHeroLayoutMetrics.verticalPadding)
        .frame(maxWidth: .infinity, minHeight: CharacterDetailHeroLayoutMetrics.minHeight, alignment: .center)
    }
}

private struct WorkHeroDropCaptureOverlay: View {
    let detail: WorkDetail
    let localizer: AppLocalizer
    let onImportTagImage: (TagVisualDropImportKind, Data, TagVisualAssetTarget) -> Void
    let onDropError: (String) -> Void

    @State private var targetedKind: TagVisualDropImportKind?
    @State private var pendingDrop: WorkHeroPendingVisualDrop?
    @Environment(\.tagVisualDropTargetsEnabled) private var areTagVisualDropTargetsEnabled

    var body: some View {
        GeometryReader { proxy in
            let size = proxy.size
            let routing = WorkHeroVisualDropRouting.resolve(size: size)

            ZStack {
                if areTagVisualDropTargetsEnabled {
                    WorkHeroDropCaptureBridge(
                        size: size,
                        routing: routing,
                        targetedKind: $targetedKind,
                        onDrop: handlePasteboardDrop(_:kind:)
                    )
                    .frame(width: size.width, height: size.height)

                    if let targetedKind,
                       let frame = routing.highlightFrame(for: targetedKind),
                       !frame.isEmpty {
                        TagVisualDropHighlight(
                            kind: targetedKind,
                            cornerRadius: WorkDetailSurfaceRole.hero.cornerRadius
                        )
                        .frame(width: frame.width, height: frame.height)
                        .position(x: frame.midX, y: frame.midY)
                        .allowsHitTesting(false)
                    }
                }
            }
            .onAppear {
                if areTagVisualDropTargetsEnabled {
                    TagVisualDropDiagnostics.log("hero overlay attached width=\(Int(size.width)) height=\(Int(size.height))")
                }
            }
        }
        .animation(.snappy(duration: 0.16), value: targetedKind)
        .confirmationDialog(
            localizer.string(pendingDrop?.kind.replaceConfirmationTitleKey ?? .tagCardReplaceImageConfirmationTitle),
            isPresented: Binding(
                get: { pendingDrop != nil },
                set: { isPresented in
                    if !isPresented {
                        pendingDrop = nil
                    }
                }
            ),
            titleVisibility: .visible
        ) {
            Button(localizer.string(.tagCardReplaceImage), role: .destructive) {
                if let pendingDrop {
                    onImportTagImage(pendingDrop.kind, pendingDrop.data, detail.work.assetTarget)
                    TagVisualDropDiagnostics.log("hero import confirmed route=\(pendingDrop.kind.diagnosticName)")
                }
                pendingDrop = nil
            }

            Button(localizer.string(.cancel), role: .cancel) {
                pendingDrop = nil
            }
        } message: {
            Text(localizer.string(pendingDrop?.kind.replaceConfirmationMessageKey ?? .tagCardReplaceImageConfirmationMessage))
        }
    }

    private func handlePasteboardDrop(_ pasteboard: NSPasteboard, kind: TagVisualDropImportKind) {
        Task {
            do {
                let imageData = try await TagPasteboardImageLoader.imageData(from: pasteboard)
                await MainActor.run {
                    TagVisualDropDiagnostics.log("hero pasteboard load success route=\(kind.diagnosticName)")
                    importOrConfirm(imageData, kind: kind)
                }
            } catch {
                await MainActor.run {
                    TagVisualDropDiagnostics.log("hero pasteboard load failed route=\(kind.diagnosticName)")
                    onDropError("\(localizer.string(.tagCardDropImageFailed)): \(error.localizedDescription)")
                }
            }
        }
    }

    private func importOrConfirm(_ imageData: Data, kind: TagVisualDropImportKind) {
        if hasExistingAsset(kind: kind) {
            pendingDrop = WorkHeroPendingVisualDrop(kind: kind, data: imageData)
        } else {
            onImportTagImage(kind, imageData, detail.work.assetTarget)
            TagVisualDropDiagnostics.log("hero import route=\(kind.diagnosticName)")
        }
    }

    private func hasExistingAsset(kind: TagVisualDropImportKind) -> Bool {
        switch kind {
        case .foreground:
            detail.work.visualProfile?.foregroundAssetPath != nil
        case .background:
            detail.work.visualProfile?.backgroundAssetPath != nil
        }
    }


}

private struct WorkHeroPendingVisualDrop {
    var kind: TagVisualDropImportKind
    var data: Data
}

private struct WorkHeroDropCaptureBridge: NSViewRepresentable {
    let size: CGSize
    let routing: WorkHeroVisualDropRouting
    @Binding var targetedKind: TagVisualDropImportKind?
    let onDrop: (NSPasteboard, TagVisualDropImportKind) -> Void

    func makeNSView(context: Context) -> DropView {
        let view = DropView()
        view.size = size
        view.routing = routing
        view.onTargetedKindChange = { targetedKind = $0 }
        view.onDrop = onDrop
        return view
    }

    func updateNSView(_ nsView: DropView, context: Context) {
        nsView.size = size
        nsView.routing = routing
        nsView.onTargetedKindChange = { targetedKind = $0 }
        nsView.onDrop = onDrop
    }

    final class DropView: NSView {
        var size: CGSize = .zero
        var routing = WorkHeroVisualDropRouting.resolve(size: .zero)
        var onTargetedKindChange: (TagVisualDropImportKind?) -> Void = { _ in }
        var onDrop: (NSPasteboard, TagVisualDropImportKind) -> Void = { _, _ in }
        override var isFlipped: Bool { true }

        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
            registerForDraggedTypes(TagPasteboardImageLoader.readablePasteboardTypes)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) {
            nil
        }

        override func hitTest(_ point: NSPoint) -> NSView? {
            guard TagVisualPasteboardDropHitPolicy.acceptsHit(for: window?.currentEvent?.type) else {
                return nil
            }
            return super.hitTest(point)
        }

        override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
            updateTargetedKind(sender, phase: "entered")
        }

        override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
            updateTargetedKind(sender, phase: "updated")
        }

        override func draggingExited(_ sender: NSDraggingInfo?) {
            TagVisualDropDiagnostics.log("hero exited")
            onTargetedKindChange(nil)
        }

        override func draggingEnded(_ sender: NSDraggingInfo) {
            onTargetedKindChange(nil)
        }

        override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
            kind(for: sender) != nil
        }

        override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
            guard let kind = kind(for: sender) else {
                TagVisualDropDiagnostics.log("hero perform route=nil")
                onTargetedKindChange(nil)
                return false
            }
            TagVisualDropDiagnostics.log("hero perform route=\(kind.diagnosticName)")
            onTargetedKindChange(nil)
            onDrop(sender.draggingPasteboard, kind)
            return true
        }

        private func updateTargetedKind(_ sender: NSDraggingInfo, phase: String) -> NSDragOperation {
            guard let kind = kind(for: sender) else {
                TagVisualDropDiagnostics.log("hero \(phase) route=nil")
                onTargetedKindChange(nil)
                return []
            }
            TagVisualDropDiagnostics.log("hero \(phase) route=\(kind.diagnosticName)")
            onTargetedKindChange(kind)
            return .copy
        }

        private func kind(for sender: NSDraggingInfo) -> TagVisualDropImportKind? {
            let localPoint = convert(sender.draggingLocation, from: nil)
            return routing.kind(at: CGPoint(x: localPoint.x, y: localPoint.y))
        }
    }
}

private struct WorkCharacterShelf: View {
    let section: WorkCharacterBookSection
    let shelfSection: WorkCharacterBookSection?
    let shelfPosition: WorkTopicScrollMemory?
    let titleDisplayMode: BookTitleDisplayMode
    let localizer: AppLocalizer
    let onImportTagImage: (TagVisualDropImportKind, Data, TagVisualAssetTarget) -> Void
    let onDropError: (String) -> Void
    let onSelectCharacter: (TagDisplaySummary) -> Void
    let onSelectBook: (LibraryBook) -> Void
    let workID: Tag.DatabaseID
    let motion: WorkTopicMotionCoordinator
    @Environment(\.bookCardFields) private var fields

    private func height(doubleRow: Bool) -> CGFloat {
        WorkCharacterShelfMetrics.carouselHeight(metrics: WorkCharacterShelfMetrics.cardMetrics(usesDoubleRow: doubleRow),
                                                usesDoubleRow: doubleRow, fields: fields)
    }

    var body: some View {
        WorkCharacterShelfFrame {
            if let character = section.character {
                dropTarget(
                    WorkTopicCharacterCard(character: character, image: motion.image(for: character.id), expansion: 1) {
                        WorkTopicCharacterNameplate(character: character, bookCount: section.bookCount, localizer: localizer,
                                                    onSelectCharacter: onSelectCharacter)
                    }
                )
                .workTopicPortraitStage(characterID: character.id, motion: motion)
            }
        } carousel: { layout in
            if let shelfSection, let character = shelfSection.character, let shelfPosition {
                let doubleRow = WorkCharacterShelfLayout.usesDoubleRow(bookCount: shelfSection.bookCount)
                WorkTopicBookCarousel(section: shelfSection, doubleRow: doubleRow, height: height(doubleRow: doubleRow),
                                      layout: layout, position: shelfPosition, titleDisplayMode: titleDisplayMode,
                                      localizer: localizer, onSelectBook: onSelectBook, motion: motion)
                    .onAppear {
                        motion.shelfDidAppear(character.id)
                        NavigationPerformanceTracer.workTopicShelfVisibility(workID: workID, characterID: character.id, visible: true)
                    }
                    .onDisappear {
                        motion.shelfDidDisappear(character.id)
                        NavigationPerformanceTracer.workTopicShelfVisibility(workID: workID, characterID: character.id, visible: false)
                    }
                    .id(character.id)
                    .transition(.identity)
            }
        }
    }

    private func dropTarget<V: View>(_ view: V) -> some View {
        view.tagVisualImageDropTarget(
            kind: .foreground, localizer: localizer, isEnabled: section.character != nil,
            cornerRadius: WorkDetailSurfaceRole.shelf.cornerRadius,
            hasExistingAsset: { section.character?.visualProfile?.foregroundAssetPath != nil },
            onImport: { data in
                if let tag = section.character { onImportTagImage(.foreground, data, tag.assetTarget) }
            }, onError: onDropError
        )
    }
}

private struct WorkTopicBookCarousel: View {
    let section: WorkCharacterBookSection
    let doubleRow: Bool
    let height: CGFloat
    let layout: WorkTopicStageLayout
    let position: WorkTopicScrollMemory
    let titleDisplayMode: BookTitleDisplayMode
    let localizer: AppLocalizer
    let onSelectBook: (LibraryBook) -> Void
    let motion: WorkTopicMotionCoordinator

    @State private var scroll = ScrollPosition(edge: .leading)
    @State private var needsRestore = true
    @State private var edges = (back: false, forward: false)
    @State private var appeared = false
    @State private var entranceFinished = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var metrics: BookCardMetrics { WorkCharacterShelfMetrics.cardMetrics(usesDoubleRow: doubleRow) }

    var body: some View {
        let entering = motion.animateShelfEntrance && !appeared
        let exiting = motion.shelfIsExiting
        ScrollView(.horizontal) {
            LazyHStack(alignment: .top, spacing: doubleRow ? 16 : 20) {
                ForEach(0..<WorkCharacterShelfLayout.columnCount(bookCount: section.bookCount, usesDoubleRow: doubleRow), id: \.self) { column in
                    let range = WorkCharacterShelfLayout.bookRange(forColumn: column, bookCount: section.bookCount, usesDoubleRow: doubleRow)
                    VStack(spacing: WorkCharacterShelfMetrics.doubleRowSpacing) {
                        ForEach(section.slots[range]) { slot in
                            BookCardButton(book: slot.book, titleDisplayMode: titleDisplayMode, localizer: localizer,
                                           metrics: metrics, action: onSelectBook)
                                .overlay(alignment: .topLeading) {
                                    if let claim = slot.claim, claim.source == .automatic {
                                        WorkCharacterClaimBadge(claim: claim, localizer: localizer).padding(5)
                                    }
                                }
                                .workCharacterClaimHint(slot.claim, localizer: localizer)
                        }
                    }
                }
            }
            .padding(.vertical, WorkCharacterShelfMetrics.verticalCardPadding / 2)
            .padding(.leading, layout.firstCoverX)
            .padding(.trailing, layout.trailingInset + WorkTopicStageLayout.cardInset)
            .frame(minHeight: height, alignment: .topLeading)
        }
        .scrollPosition($scroll)
        .scrollIndicators(.hidden)
        .onScrollGeometryChange(for: ShelfScrollGeometry.self) { ShelfScrollGeometry(geometry: $0) } action: { _, value in
            if needsRestore, value.maxOffsetX > 0 {
                needsRestore = false
                let target = min(position.offset, value.maxOffsetX)
                if abs(target - value.offsetX) > 1 {
                    scroll.scrollTo(x: target)
                    return
                }
            }
            if !needsRestore { position.offset = value.offsetX }
            let next = (value.canScrollBackward, value.canScrollForward)
            if edges != next { edges = next }
        }
        .mask { WorkTopicShelfEdge(panelRight: layout.panelRight) }
        .overlay(alignment: .leading) {
            if edges.back {
                arrow(forward: false, viewport: layout.usableShelfWidth)
                    .padding(.leading, layout.backArrowX)
            }
        }
        .overlay(alignment: .trailing) {
            if edges.forward {
                arrow(forward: true, viewport: layout.usableShelfWidth)
                    .padding(.trailing, layout.trailingInset)
            }
        }
        .frame(height: height)
        .scaleEffect(exiting && !reduceMotion ? 0.94 : 1)
        .opacity(exiting || (entering && reduceMotion) ? 0 : 1)
        .animation(.easeInOut(duration: motion.shelfExitDuration), value: exiting)
        .offset(x: entering && !reduceMotion ? layout.width : 0)
        .allowsHitTesting(entranceFinished && !exiting)
        .accessibilityHidden(!entranceFinished || exiting)
        .task {
            if motion.animateShelfEntrance {
                // Keep the initial, off-window position through one layout pass.
                await Task.yield()
                guard !Task.isCancelled else { return }
                withAnimation(reduceMotion ? .easeOut(duration: 0.12) : .easeOut(duration: 0.30)) {
                    appeared = true
                } completion: {
                    entranceFinished = true
                }
            } else {
                appeared = true
                entranceFinished = true
            }
        }
    }

    private func arrow(forward: Bool, viewport: CGFloat) -> some View {
        WorkDetailCarouselArrowButton(systemImage: forward ? "chevron.right" : "chevron.left",
                                     help: localizer.string(forward ? .nextPage : .previousPage)) {
            let distance = max(metrics.cardWidth, viewport - metrics.cardWidth * 0.25)
            withAnimation(.snappy(duration: 0.28)) {
                scroll.scrollTo(x: max(position.offset + (forward ? distance : -distance), 0))
            }
        }
    }
}

private struct CharacterWorkShelf: View {
    let section: CharacterWorkBookSection
    let titleDisplayMode: BookTitleDisplayMode
    let localizer: AppLocalizer
    let onSelectWork: (TagDisplaySummary) -> Void
    let onSelectBook: (LibraryBook) -> Void

    @State private var anchorIndex = 0
    @State private var isHoveringCarousel = false

    private let scrollStep = 4

    private var usesDoubleRow: Bool {
        WorkCharacterShelfLayout.usesDoubleRow(bookCount: section.bookCount)
    }

    @Environment(\.bookCardFields) private var cardFields

    private var metrics: BookCardMetrics {
        WorkCharacterShelfMetrics.cardMetrics(usesDoubleRow: usesDoubleRow)
    }

    private var columnCount: Int {
        WorkCharacterShelfLayout.columnCount(bookCount: section.books.count, usesDoubleRow: usesDoubleRow)
    }

    private var columnIDs: [LibraryBook.ID] {
        (0..<columnCount).map { columnID(at: $0) }
    }

    private var visibleThreshold: Int {
        usesDoubleRow ? 8 : 7
    }

    private var carouselHeight: CGFloat {
        WorkCharacterShelfMetrics.carouselHeight(metrics: metrics, usesDoubleRow: usesDoubleRow, fields: cardFields)
    }

    private var maxForwardIndex: Int {
        max(columnCount - visibleThreshold, 0)
    }

    private var showsBackwardArrow: Bool {
        isHoveringCarousel && anchorIndex > 0
    }

    private var showsForwardArrow: Bool {
        isHoveringCarousel && columnCount > visibleThreshold && anchorIndex < maxForwardIndex
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header

            carouselLayer
                .frame(maxWidth: .infinity, minHeight: carouselHeight, maxHeight: carouselHeight, alignment: .center)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 18)
        .frame(maxWidth: .infinity, minHeight: usesDoubleRow ? 430 : 340, alignment: .center)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: WorkDetailSurfaceRole.shelf.cornerRadius, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: WorkDetailSurfaceRole.shelf.cornerRadius, style: .continuous)
                .stroke(.white.opacity(0.12), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.035), radius: 12, x: 0, y: 5)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(section.work?.displayText ?? localizer.string(.characterDetailUntaggedWork))
                .font(.title2.weight(.semibold))
                .foregroundStyle(.primary)
                .lineLimit(1)
                .minimumScaleFactor(0.78)

            WorkDetailPill(text: localizer.workDetailBookCount(section.bookCount), systemImage: "books.vertical")
                .fixedSize(horizontal: true, vertical: true)

            Spacer(minLength: 0)

            if let work = section.work,
               TagOpenDestinationResolver.destination(for: work) == .workDetail {
                Button {
                    onSelectWork(work)
                } label: {
                    Label(localizer.string(.characterDetailOpenWork), systemImage: "arrow.up.right")
                }
                .buttonStyle(.bordered)
                .help(localizer.string(.characterDetailOpenWork))
                .accessibilityLabel("\(localizer.string(.characterDetailOpenWork)): \(work.displayText)")
            }
        }
    }

    private var carouselLayer: some View {
        ScrollViewReader { proxy in
            GeometryReader { geometry in
                let maskMetrics = WorkCharacterShelfViewportMaskMetrics.resolve(
                    size: CGSize(width: geometry.size.width, height: carouselHeight),
                    preferredFadeWidth: min(max(geometry.size.width * 0.035, 28), 56)
                )

                ZStack {
                    ScrollView(.horizontal, showsIndicators: false) {
                        LazyHStack(alignment: .top, spacing: usesDoubleRow ? 16 : 20) {
                            ForEach(0..<columnCount, id: \.self) { columnIndex in
                                let bookRange = WorkCharacterShelfLayout.bookRange(
                                    forColumn: columnIndex,
                                    bookCount: section.books.count,
                                    usesDoubleRow: usesDoubleRow
                                )
                                VStack(spacing: usesDoubleRow ? WorkCharacterShelfMetrics.doubleRowSpacing : 0) {
                                    ForEach(Array(section.books[bookRange])) { book in
                                        BookCardButton(
                                            book: book,
                                            titleDisplayMode: titleDisplayMode,
                                            localizer: localizer,
                                            metrics: metrics,
                                            action: onSelectBook
                                        )
                                        .overlay(alignment: .topLeading) {
                                            if let bookID = book.databaseID,
                                               let claim = section.claimsByBookID[bookID],
                                               claim.source == .automatic {
                                                WorkCharacterClaimBadge(claim: claim, localizer: localizer)
                                                    .padding(5)
                                            }
                                        }
                                        .workCharacterClaimHint(book.databaseID.flatMap { section.claimsByBookID[$0] }, localizer: localizer)
                                    }
                                    if usesDoubleRow && bookRange.count == 1 {
                                        Spacer(minLength: 0)
                                    }
                                }
                                .id(columnID(at: columnIndex))
                            }
                        }
                        .padding(.vertical, WorkCharacterShelfMetrics.verticalCardPadding / 2)
                        .padding(.horizontal, 18)
                    }
                    .scrollIndicators(.hidden, axes: .horizontal)
                    .mask {
                        WorkCharacterShelfViewportMask(metrics: maskMetrics)
                    }
                    .clipped()

                    HStack {
                        if showsBackwardArrow {
                            WorkDetailCarouselArrowButton(
                                systemImage: "chevron.left",
                                help: localizer.string(.previousPage)
                            ) {
                                scroll(by: -scrollStep, proxy: proxy)
                            }
                            .transition(.opacity.combined(with: .scale(scale: 0.92)))
                        }

                        Spacer()

                        if showsForwardArrow {
                            WorkDetailCarouselArrowButton(
                                systemImage: "chevron.right",
                                help: localizer.string(.nextPage)
                            ) {
                                scroll(by: scrollStep, proxy: proxy)
                            }
                            .transition(.opacity.combined(with: .scale(scale: 0.92)))
                        }
                    }
                    .padding(.horizontal, 6)
                    .animation(.easeInOut(duration: 0.16), value: showsBackwardArrow)
                    .animation(.easeInOut(duration: 0.16), value: showsForwardArrow)
                }
                .frame(width: geometry.size.width, height: carouselHeight, alignment: .center)
                .contentShape(Rectangle())
                .onHover { isHoveringCarousel = $0 }
                .onChange(of: columnIDs) { _, _ in
                    clampAnchorIndex()
                }
            }
        }
    }

    private func scroll(by step: Int, proxy: ScrollViewProxy) {
        let nextIndex = min(max(anchorIndex + step, 0), maxForwardIndex)
        guard nextIndex != anchorIndex else {
            return
        }
        anchorIndex = nextIndex
        withAnimation(.snappy(duration: 0.24)) {
            proxy.scrollTo(columnID(at: nextIndex), anchor: .leading)
        }
    }

    private func clampAnchorIndex() {
        anchorIndex = min(anchorIndex, maxForwardIndex)
    }

    private func columnID(at index: Int) -> LibraryBook.ID {
        let range = WorkCharacterShelfLayout.bookRange(
            forColumn: index,
            bookCount: section.books.count,
            usesDoubleRow: usesDoubleRow
        )
        return section.books[range.lowerBound].id
    }
}

private struct CharacterWorkShelfPlaceholder: View {
    let usesDoubleRow: Bool
    @Environment(\.bookCardFields) private var cardFields

    private var metrics: BookCardMetrics {
        WorkCharacterShelfMetrics.cardMetrics(usesDoubleRow: usesDoubleRow)
    }

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
                    VStack(spacing: usesDoubleRow ? WorkCharacterShelfMetrics.doubleRowSpacing : 0) {
                        TopicShelfCardPlaceholder(metrics: metrics, fields: cardFields)
                        if usesDoubleRow {
                            TopicShelfCardPlaceholder(metrics: metrics, fields: cardFields)
                        }
                    }
                }
            }
            .padding(.vertical, WorkCharacterShelfMetrics.verticalCardPadding / 2)
            .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
            .clipped()
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 18)
        .frame(maxWidth: .infinity, minHeight: usesDoubleRow ? 430 : 340, alignment: .leading)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: WorkDetailSurfaceRole.shelf.cornerRadius, style: .continuous))
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .redacted(reason: .placeholder)
    }
}

private struct TopicShelfCardPlaceholder: View {
    let metrics: BookCardMetrics
    let fields: BookCardFields

    var body: some View {
        VStack(alignment: .leading, spacing: metrics.contentSpacing) {
            RoundedRectangle(cornerRadius: 8)
                .fill(.secondary.opacity(0.16))
                .frame(width: metrics.cardWidth, height: metrics.coverHeight)
            RoundedRectangle(cornerRadius: 6)
                .fill(.secondary.opacity(0.18))
                .frame(width: metrics.cardWidth * 0.86, height: metrics.titleHeight)
                .frame(height: metrics.regularTitleHeight, alignment: .top)
            if !fields.isDisjoint(with: .metadata) {
                RoundedRectangle(cornerRadius: 5)
                    .fill(.secondary.opacity(0.12))
                    .frame(width: metrics.cardWidth * 0.72, height: metrics.infoRowHeight)
            }
            if metrics.showsRatingRow(for: fields) || !fields.isDisjoint(with: .reading) {
                RoundedRectangle(cornerRadius: 5)
                    .fill(.secondary.opacity(0.14))
                    .frame(width: metrics.cardWidth * 0.64, height: metrics.ratingHeight)
            }
        }
        .frame(width: metrics.cardWidth, height: metrics.cardHeight(for: fields), alignment: .topLeading)
    }
}

enum WorkCharacterShelfMetrics {
    static func cardMetrics(usesDoubleRow: Bool) -> BookCardMetrics {
        BookCardMetrics(width: usesDoubleRow ? 136 : 168)
    }

    static let verticalCardPadding: CGFloat = 20
    static let doubleRowSpacing: CGFloat = 12

    static func carouselHeight(metrics: BookCardMetrics, usesDoubleRow: Bool, fields: BookCardFields = .all) -> CGFloat {
        if usesDoubleRow {
            return metrics.cardHeight(for: fields) * 2 + doubleRowSpacing + verticalCardPadding
        }
        return metrics.cardHeight(for: fields) + verticalCardPadding
    }
}

struct WorkCharacterShelfViewportMaskMetrics: Equatable {
    var size: CGSize
    var leftFadeWidth: CGFloat
    var rightFadeWidth: CGFloat
    var opaqueWidth: CGFloat

    static func resolve(size: CGSize, preferredFadeWidth: CGFloat) -> WorkCharacterShelfViewportMaskMetrics {
        let width = max(size.width, 0)
        let height = max(size.height, 0)
        let fadeUpperBound = max(width * 0.12, 0)
        let fadeWidth = width > 0 ? min(max(preferredFadeWidth, 18), 32, fadeUpperBound) : 0

        return WorkCharacterShelfViewportMaskMetrics(
            size: CGSize(width: width, height: height),
            leftFadeWidth: fadeWidth,
            rightFadeWidth: fadeWidth,
            opaqueWidth: max(width - fadeWidth * 2, 0)
        )
    }
}

enum WorkCharacterImageAvailability: Equatable {
    case pending
    case available
    case missing

    func hasImageLikeAsset(configured: Bool) -> Bool {
        switch self {
        case .pending:
            return configured
        case .available:
            return true
        case .missing:
            return false
        }
    }
}

enum WorkDetailSurfaceRole: Equatable {
    case hero
    case shelf

    var cornerRadius: CGFloat {
        switch self {
        case .hero:
            16
        case .shelf:
            15
        }
    }

}

private struct WorkCharacterShelfViewportMask: View {
    let metrics: WorkCharacterShelfViewportMaskMetrics

    var body: some View {
        HStack(spacing: 0) {
            LinearGradient(colors: [.clear, .white], startPoint: .leading, endPoint: .trailing)
                .frame(width: metrics.leftFadeWidth)

            Rectangle()
                .fill(.white)
                .frame(width: metrics.opaqueWidth)

            LinearGradient(colors: [.white, .clear], startPoint: .leading, endPoint: .trailing)
                .frame(width: metrics.rightFadeWidth)
        }
        .frame(width: metrics.size.width, height: metrics.size.height)
        .allowsHitTesting(false)
    }
}

private struct WorkDetailPill: View {
    let text: String
    let systemImage: String

    var body: some View {
        Label(text, systemImage: systemImage)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(.regularMaterial, in: Capsule())
    }
}

private struct WorkHeroBackground: View {
    let work: TagDisplaySummary
    let assetURL: (String) -> URL?
    @State private var image: NSImage?

    var body: some View {
        GeometryReader { proxy in
            let layout = WorkHeroBackgroundLayout.resolve(size: proxy.size)
            let frame = layout.imageFrame
            ZStack(alignment: .trailing) {
                Color.clear
                if let image {
                    Image(nsImage: image)
                        .resizable()
                        .scaledToFill()
                        .scaleEffect(work.visualProfile?.backgroundScale ?? 1)
                        .offset(x: (work.visualProfile?.backgroundOffsetX ?? 0) * frame.width,
                                y: (work.visualProfile?.backgroundOffsetY ?? 0) * frame.height)
                        .frame(width: frame.width, height: frame.height)
                        .clipped()
                        .mask {
                            HStack(spacing: 0) {
                                LinearGradient(colors: [.clear, .white], startPoint: .leading, endPoint: .trailing)
                                    .frame(width: layout.edgeFadeWidth)
                                Rectangle()
                            }
                        }
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
            .mask {
                LinearGradient(stops: [.init(color: .white, location: 0.90), .init(color: .clear, location: 1)],
                               startPoint: .top, endPoint: .bottom)
            }
        }
        .allowsHitTesting(false)
        .task(id: "\(work.id)-\(work.visualProfile?.backgroundAssetPath ?? "")-\(work.visualProfile?.updatedAt ?? 0)") {
            image = nil
            guard let path = work.visualProfile?.backgroundAssetPath, let url = assetURL(path) else { return }
            let loaded = await TagVisualImageCache.shared.image(for: url)
            guard !Task.isCancelled else { return }
            image = loaded
        }
    }
}

struct WorkHeroBackgroundLayout: Equatable {
    var imageFrame: CGRect
    var edgeFadeWidth: CGFloat

    static func resolve(size: CGSize) -> Self {
        let width = max(size.width, 0)
        let frame = CGRect(x: width * 0.4, y: 0, width: width * 0.6, height: max(size.height, 0))
        return Self(imageFrame: frame, edgeFadeWidth: min(width * 0.24, frame.width))
    }
}

struct WorkHeroVisualDropRouting: Equatable {
    var foregroundFrame: CGRect
    var backgroundFrame: CGRect

    static func resolve(size: CGSize) -> WorkHeroVisualDropRouting {
        let width = max(size.width, 0)
        let height = max(size.height, 0)
        let backgroundLayout = WorkHeroBackgroundLayout.resolve(size: size)
        let horizontalInset = min(max(width * 0.04, 16), 58)
        let verticalInset = min(height * 0.12, max(34, height * 0.08))
        let gap: CGFloat = 18
        let foregroundMaxX = min(
            max(backgroundLayout.imageFrame.minX - gap, horizontalInset),
            width - horizontalInset
        )
        let foregroundFrame = CGRect(
            x: horizontalInset,
            y: verticalInset,
            width: max(foregroundMaxX - horizontalInset, 0),
            height: max(height - verticalInset * 2, 0)
        )

        return WorkHeroVisualDropRouting(
            foregroundFrame: foregroundFrame,
            backgroundFrame: backgroundLayout.imageFrame
        )
    }

    func kind(at point: CGPoint) -> TagVisualDropImportKind? {
        if backgroundFrame.contains(point) {
            return .background
        }
        if foregroundFrame.contains(point) {
            return .foreground
        }
        return nil
    }

    func highlightFrame(for kind: TagVisualDropImportKind) -> CGRect? {
        switch kind {
        case .foreground:
            foregroundFrame.isEmpty ? nil : foregroundFrame
        case .background:
            backgroundFrame.isEmpty ? nil : backgroundFrame
        }
    }
}

private struct WorkDetailBackground: View {
    let work: TagDisplaySummary
    let fallbackHex: String
    let paletteLoader: (String) async -> TagVisualBackgroundPalette?

    @State private var palette = WorkDetailBackgroundPalette.white

    var body: some View {
        WorkDetailMeshBackground(palette: palette)
            .ignoresSafeArea()
            .task(id: backgroundAssetIdentity) {
                guard let backgroundAssetPath else {
                    withAnimation(.easeInOut(duration: 0.18)) {
                        palette = .white
                    }
                    return
                }
                let loadedPalette = await paletteLoader(backgroundAssetPath)
                let nextPalette = TagVisualAssetService.backgroundMeshPalette(
                    palette: loadedPalette,
                    fallbackHex: fallbackHex
                )
                withAnimation(.easeInOut(duration: 0.22)) {
                    palette = nextPalette
                }
            }
    }

    private var backgroundAssetPath: String? {
        work.visualProfile?.backgroundAssetPath
    }

    private var backgroundAssetIdentity: String {
        "\(backgroundAssetPath ?? "none"):\(work.visualProfile?.updatedAt ?? 0)"
    }
}

private struct WorkDetailMeshBackground: View {
    let palette: WorkDetailBackgroundPalette
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let baseColor = Color(nsColor: palette.baseColor(colorScheme: colorScheme))
        let colors = palette.meshColors(colorScheme: colorScheme)

        ZStack {
            Rectangle()
                .fill(baseColor)

            if !palette.isWhiteFallback {
                MeshGradient(
                    width: 3,
                    height: 3,
                    points: [
                        .init(0.00, 0.00), .init(0.48, 0.00), .init(1.00, 0.00),
                        .init(0.00, 0.46), .init(0.54, 0.40), .init(1.00, 0.52),
                        .init(0.00, 1.00), .init(0.52, 1.00), .init(1.00, 1.00)
                    ],
                    colors: [
                        meshColor(colors, 0), meshColor(colors, 1), baseColor,
                        meshColor(colors, 2), meshColor(colors, 0), meshColor(colors, 1),
                        baseColor, meshColor(colors, 2), meshColor(colors, 0)
                    ]
                )
            }
        }
    }

    private func meshColor(_ colors: [NSColor], _ index: Int) -> Color {
        Color(nsColor: colors[index % colors.count])
    }
}

private struct WorkCharacterImage: View {
    let tag: TagDisplaySummary?
    let assetURL: (String) -> URL?
    var trimsTransparentMargins = false
    let onImageAvailabilityChange: (Bool) -> Void

    @State private var image: NSImage?

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .bottom) {
                if let image {
                    Image(nsImage: image)
                        .resizable()
                        .scaledToFit()
                        .frame(width: proxy.size.width, height: proxy.size.height, alignment: .bottom)
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
            .clipped()
        }
        .task(id: foregroundAssetIdentity) {
            image = nil
            guard let foregroundURL else {
                onImageAvailabilityChange(false)
                return
            }
            let loadedImage: NSImage?
            if trimsTransparentMargins {
                loadedImage = await TagVisualImageCache.shared.portraitImage(
                    for: foregroundURL,
                    version: tag?.visualProfile?.updatedAt ?? 0
                )
            } else {
                loadedImage = await TagVisualImageCache.shared.image(for: foregroundURL)
            }
            guard !Task.isCancelled else { return }
            image = loadedImage
            onImageAvailabilityChange(loadedImage != nil)
        }
    }

    private var foregroundURL: URL? {
        guard let foregroundAssetPath = tag?.visualProfile?.foregroundAssetPath else {
            return nil
        }
        return assetURL(foregroundAssetPath)
    }

    private var foregroundAssetIdentity: String {
        guard let tag else {
            return "none"
        }
        return "\(tag.visualProfile?.foregroundAssetPath ?? "none"):\(tag.visualProfile?.updatedAt ?? 0)"
    }

}

private struct WorkDetailCarouselArrowButton: View {
    let systemImage: String
    let help: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.title3.weight(.semibold))
                .foregroundStyle(.primary)
                .frame(width: 38, height: 38)
                .background(.regularMaterial, in: Circle())
                .shadow(color: .black.opacity(0.20), radius: 10, x: 0, y: 4)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(help)
        .help(help)
    }
}
