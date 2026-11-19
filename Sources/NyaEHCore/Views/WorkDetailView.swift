// 本文件实现作品详情页，使用作品-角色索引、背景资产和分段延迟渲染来支撑大书库浏览。

import AppKit
import SwiftUI

struct WorkDetailView: View {
    @Bindable var store: TagDiscoveryStore
    let tagID: Tag.DatabaseID
    let isTagTranslationEnabled: Bool
    let titleDisplayMode: BookTitleDisplayMode
    let initialScrollOffset: CGFloat?
    let usesExternalTransitionShell: Bool
    let localizer: AppLocalizer
    let onScrollOffsetChange: (CGFloat) -> Void
    let onSelectBook: (LibraryBook) -> Void
    let onSelectCharacter: (TagDisplaySummary) -> Void
    let onSearchWork: (TagDisplaySummary) -> Void
    // 大作品页只解锁可见窗口附近的角色分区；其余分区保留等高占位，保证滚动和返回动画稳定。
    @State private var sectionRenderBudget = WorkDetailSectionRenderBudget()
    @State private var visibleSectionIndices: Set<Int> = []
    @State private var visibleSectionRange: ClosedRange<Int>?
    @State private var loggedContentReadyTagID: Tag.DatabaseID?
    @State private var hasRequestedDetailLoad = false
    @State private var isManagingClaims = false

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
                WorkDetailLoadingShell(localizer: localizer)
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
        .onChange(of: tagID) { _, _ in
            resetSectionRendering()
        }
        .onChange(of: isTagTranslationEnabled) { _, _ in
            resetSectionRendering()
        }
        .onDisappear {
            NavigationPerformanceTracer.workDetailDidDisappear(tagID: tagID)
        }
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
        ZStack(alignment: .top) {
                WorkDetailBackground(
                    work: detail.work,
                    fallbackHex: TagVisualAssetService.effectiveBackgroundHex(for: detail.work),
                    paletteLoader: store.catalog.tagVisualBackgroundPalette(relativeBackgroundPath:)
                )

                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        WorkDetailHero(
                            detail: detail,
                            assetURL: store.catalog.tagVisualAssetURL(relativePath:),
                            blurAssetURL: store.catalog.tagVisualHeroBlurAssetURL(relativeBackgroundPath:),
                            localizer: localizer,
                            onImportTagImage: importDroppedTagImage,
                            onDropError: { store.catalog.loadError = $0 },
                            onSearchWork: { onSearchWork(detail.work) }
                        )

                        HStack {
                            Spacer()
                            Button {
                                isManagingClaims = true
                            } label: {
                                Label(localizer.string(.workCharacterManage), systemImage: "person.crop.rectangle.stack")
                            }
                            .help(localizer.string(.workCharacterManage))
                        }
                        .padding(.horizontal, 34)

                        if detail.sections.isEmpty {
                            ContentUnavailableView(
                                localizer.string(.workDetailNoBooks),
                                systemImage: "books.vertical",
                                description: Text(localizer.string(.workDetailNoBooksDescription))
                            )
                            .frame(maxWidth: .infinity, minHeight: 260)
                            .padding(.horizontal, 34)
                        } else {
                            LazyVStack(alignment: .leading, spacing: 14) {
                                ForEach(Array(detail.sections.enumerated()), id: \.element.id) { index, section in
                                    if sectionContentWeight(index: index, totalCount: detail.sections.count) == .full {
                                        WorkCharacterShelf(
                                            section: section,
                                            titleDisplayMode: titleDisplayMode,
                                            localizer: localizer,
                                            assetURL: store.catalog.tagVisualAssetURL(relativePath:),
                                            onImportTagImage: importDroppedTagImage,
                                            onDropError: { store.catalog.loadError = $0 },
                                            onSelectCharacter: onSelectCharacter,
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
                                        WorkDetailLazySectionPlaceholder(
                                            usesDoubleRow: WorkCharacterShelfLayout.usesDoubleRow(
                                                bookCount: section.books.count,
                                                threshold: WorkCharacterShelf.doubleRowThreshold
                                            )
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
            .onAppear {
                logContentReadyIfNeeded(sectionCount: detail.sections.count)
            }
            .task(id: "\(tagID)-\(isTagTranslationEnabled)-\(detail.sections.count)") {
                resetSectionRendering()
                await Task.yield()
                unlockInitialSections(totalCount: detail.sections.count)
            }
    }

    private func resetSectionRendering() {
        sectionRenderBudget.reset()
        visibleSectionIndices = []
        visibleSectionRange = nil
        loggedContentReadyTagID = nil
        hasRequestedDetailLoad = false
    }

    private func logContentReadyIfNeeded(sectionCount: Int) {
        guard loggedContentReadyTagID != tagID else {
            return
        }
        loggedContentReadyTagID = tagID
        NavigationPerformanceTracer.workDetailContentReady(tagID: tagID, sectionCount: sectionCount)
    }

    private func unlockInitialSections(totalCount: Int) {
        let result = sectionRenderBudget.unlockInitial(totalCount: totalCount)
        guard result.didUnlock else {
            return
        }
        NavigationPerformanceTracer.workDetailSectionUnlocked(
            tagID: tagID,
            triggerIndex: 0,
            totalCount: totalCount,
            unlockedCount: sectionRenderBudget.unlockedCount
        )
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
        guard let nextRange else {
            return
        }
        guard nextRange != visibleSectionRange else {
            return
        }
        visibleSectionRange = nextRange
        NavigationPerformanceTracer.workDetailSectionUnlocked(
            tagID: tagID,
            triggerIndex: index,
            totalCount: totalCount,
            unlockedCount: visibleSectionIndices.count
        )
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
                                        WorkDetailLazySectionPlaceholder(
                                            usesDoubleRow: WorkCharacterShelfLayout.usesDoubleRow(
                                                bookCount: section.books.count,
                                                threshold: WorkCharacterShelf.doubleRowThreshold
                                            )
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
    static func usesDoubleRow(bookCount: Int, threshold: Int) -> Bool {
        bookCount > threshold
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

private struct WorkDetailLoadingShell: View {
    let localizer: AppLocalizer

    var body: some View {
        ZStack(alignment: .top) {
            WorkDetailLoadingBackground()

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    WorkDetailLoadingHeroSkeleton(localizer: localizer)

                    LazyVStack(alignment: .leading, spacing: 14) {
                        ForEach(0..<WorkDetailSectionRenderBudget.initialUnlockedCount, id: \.self) { index in
                            WorkDetailLazySectionPlaceholder(usesDoubleRow: index == 0)
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

private struct WorkDetailLoadingHeroSkeleton: View {
    let localizer: AppLocalizer

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            RoundedRectangle(cornerRadius: 18)
                .fill(.secondary.opacity(0.16))
                .frame(width: 330, height: 185)

            Text(localizer.string(.detailWorks))
                .font(.system(size: 54, weight: .bold))

            HStack(spacing: 10) {
                WorkDetailPill(text: localizer.workDetailCharacterCount(12), systemImage: "person.2")
                WorkDetailPill(text: localizer.workDetailBookCount(48), systemImage: "books.vertical")
            }

            Text(localizer.string(.workDetailNoIntro))
                .font(.title3.weight(.medium))
                .lineLimit(4)
                .frame(maxWidth: 720, alignment: .leading)
        }
        .frame(maxWidth: 920, alignment: .leading)
        .padding(.horizontal, 58)
        .padding(.top, 58)
        .padding(.bottom, 54)
        .frame(maxWidth: .infinity, minHeight: 520, alignment: .bottomLeading)
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

private struct WorkDetailLazySectionPlaceholder: View {
    let usesDoubleRow: Bool

    private var metrics: BookCardMetrics {
        WorkCharacterShelfMetrics.cardMetrics(usesDoubleRow: usesDoubleRow)
    }

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
            .zIndex(1)

            HStack(alignment: .top, spacing: usesDoubleRow ? 16 : 20) {
                ForEach(0..<5, id: \.self) { _ in
                    VStack(spacing: usesDoubleRow ? WorkCharacterShelfMetrics.doubleRowSpacing : 0) {
                        cardPlaceholder
                        if usesDoubleRow {
                            cardPlaceholder
                        }
                    }
                }
            }
            .padding(.vertical, WorkCharacterShelfMetrics.verticalCardPadding / 2)
            .padding(.leading, 28)
            .padding(.trailing, 18)
            .frame(height: WorkCharacterShelfMetrics.carouselHeight(metrics: metrics, usesDoubleRow: usesDoubleRow))
        }
        .frame(maxWidth: .infinity, minHeight: usesDoubleRow ? 590 : 520, alignment: .bottomLeading)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: WorkDetailSurfaceRole.shelf.cornerRadius, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: WorkDetailSurfaceRole.shelf.cornerRadius, style: .continuous)
                .stroke(.white.opacity(0.12), lineWidth: 1)
                .allowsHitTesting(false)
        }
        .shadow(color: .black.opacity(0.035), radius: 12, x: 0, y: 5)
        .padding(.vertical, 8)
        .padding(.horizontal, 12)
        .redacted(reason: .placeholder)
    }

    private var cardPlaceholder: some View {
        VStack(alignment: .leading, spacing: metrics.contentSpacing) {
            RoundedRectangle(cornerRadius: 8)
                .fill(.secondary.opacity(0.16))
                .frame(width: metrics.cardWidth, height: metrics.coverHeight)
            RoundedRectangle(cornerRadius: 6)
                .fill(.secondary.opacity(0.18))
                .frame(width: metrics.cardWidth * 0.86, height: metrics.titleHeight)
            RoundedRectangle(cornerRadius: 5)
                .fill(.secondary.opacity(0.12))
                .frame(width: metrics.cardWidth * 0.72, height: metrics.infoRowHeight)
            RoundedRectangle(cornerRadius: 5)
                .fill(.secondary.opacity(0.14))
                .frame(width: metrics.cardWidth * 0.64, height: metrics.ratingHeight)
        }
        .frame(width: metrics.cardWidth, height: metrics.cardHeight, alignment: .topLeading)
    }
}

private struct WorkDetailHero: View {
    let detail: WorkDetail
    let assetURL: (String) -> URL?
    let blurAssetURL: (String) async -> URL?
    let localizer: AppLocalizer
    let onImportTagImage: (TagVisualDropImportKind, Data, TagVisualAssetTarget) -> Void
    let onDropError: (String) -> Void
    let onSearchWork: () -> Void

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            WorkHeroBackground(
                work: detail.work,
                assetURL: assetURL,
                blurAssetURL: blurAssetURL
            )

            VStack(alignment: .leading, spacing: 20) {
                WorkVisualImage(
                    tag: detail.work,
                    kind: .foreground,
                    assetURL: assetURL,
                    fallbackSystemImage: "rectangle.stack.fill"
                )
                .frame(width: 330, height: 185)
                .shadow(color: .black.opacity(0.22), radius: 22, x: 0, y: 12)

                Text(detail.work.displayText)
                    .font(.system(size: 54, weight: .bold))
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: 10) {
                    WorkDetailPill(text: localizer.workDetailCharacterCount(detail.characterCount), systemImage: "person.2")
                    WorkDetailPill(text: localizer.workDetailBookCount(detail.totalBookCount), systemImage: "books.vertical")
                    if detail.work.displayText != detail.work.name {
                        WorkDetailPill(text: detail.work.name, systemImage: "tag")
                    }
                }

                Text(introText)
                    .font(.title3.weight(.medium))
                    .foregroundStyle(.primary.opacity(0.74))
                    .lineSpacing(5)
                    .lineLimit(5)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 820, alignment: .leading)

                Button(action: onSearchWork) {
                    Label(localizer.string(.workDetailSearchWork), systemImage: "magnifyingglass")
                        .frame(minWidth: 148)
                }
                .controlSize(.large)
                .buttonStyle(.borderedProminent)
            }
            .frame(maxWidth: 920, alignment: .leading)
            .padding(.horizontal, 58)
            .padding(.top, 58)
            .padding(.bottom, 54)
            .contentShape(Rectangle())
            .zIndex(2)
        }
        .frame(maxWidth: .infinity, minHeight: 520, alignment: .bottomLeading)
        .workDetailGlassSurface(.hero)
        .overlay {
            WorkHeroDropCaptureOverlay(
                detail: detail,
                localizer: localizer,
                onImportTagImage: onImportTagImage,
                onDropError: onDropError
            )
        }
        .padding(.horizontal, 34)
    }

    private var introText: String {
        let trimmed = detail.work.translationIntro?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? localizer.string(.workDetailNoIntro) : trimmed
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
    @State private var loggedAttachedSize: CGSize = .zero
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
                logAttachedIfNeeded(size)
            }
            .onChange(of: size) { _, newSize in
                logAttachedIfNeeded(newSize)
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

    private func logAttachedIfNeeded(_ size: CGSize) {
        guard areTagVisualDropTargetsEnabled, size != loggedAttachedSize else {
            return
        }
        loggedAttachedSize = size
        TagVisualDropDiagnostics.log(
            "hero overlay attached width=\(Int(size.width)) height=\(Int(size.height))"
        )
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
            return self
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
    let titleDisplayMode: BookTitleDisplayMode
    let localizer: AppLocalizer
    let assetURL: (String) -> URL?
    let onImportTagImage: (TagVisualDropImportKind, Data, TagVisualAssetTarget) -> Void
    let onDropError: (String) -> Void
    let onSelectCharacter: (TagDisplaySummary) -> Void
    let onSelectBook: (LibraryBook) -> Void

    @State private var anchorIndex = 0
    @State private var isHoveringCarousel = false
    @State private var isHoveringCharacter = false
    @State private var characterImageAvailability = WorkCharacterImageAvailability.pending

    private let scrollStep = 3
    static let doubleRowThreshold = 6

    private var usesDoubleRow: Bool {
        WorkCharacterShelfLayout.usesDoubleRow(
            bookCount: section.books.count,
            threshold: Self.doubleRowThreshold
        )
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
        usesDoubleRow ? 6 : 5
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
        GeometryReader { shelfProxy in
            let layout = WorkCharacterShelfSplitMetrics.resolve(containerSize: shelfProxy.size)

            HStack(spacing: 0) {
                characterPanel(
                    regionWidth: layout.characterColumnWidth,
                    shelfHeight: shelfProxy.size.height,
                    capsuleInsets: layout.capsuleInsets
                )
                .frame(width: layout.characterColumnWidth, height: shelfProxy.size.height, alignment: .bottom)

                carouselLayer(
                    contentWidth: layout.contentColumnWidth,
                    fadeWidth: layout.viewportFadeWidth
                )
                .frame(width: layout.contentColumnWidth, height: shelfProxy.size.height, alignment: .bottomLeading)
            }
            .frame(width: shelfProxy.size.width, height: shelfProxy.size.height, alignment: .leading)
            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: WorkDetailSurfaceRole.shelf.cornerRadius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: WorkDetailSurfaceRole.shelf.cornerRadius, style: .continuous)
                    .stroke(.white.opacity(0.12), lineWidth: 1)
                    .allowsHitTesting(false)
            }
            .shadow(color: .black.opacity(0.035), radius: 12, x: 0, y: 5)
        }
        .frame(height: usesDoubleRow ? 590 : 520, alignment: .bottomLeading)
        .frame(maxWidth: .infinity, alignment: .bottomLeading)
        .padding(.horizontal, 12)
        .padding(.vertical, 14)
    }

    private func carouselLayer(contentWidth: CGFloat, fadeWidth: CGFloat) -> some View {
        ScrollViewReader { proxy in
            let maskMetrics = WorkCharacterShelfViewportMaskMetrics.resolve(
                size: CGSize(width: contentWidth, height: carouselHeight),
                preferredFadeWidth: fadeWidth
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
                    .padding(.leading, 18)
                    .padding(.trailing, 18)
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
                .padding(.leading, 20)
                .padding(.trailing, 6)
                .animation(.easeInOut(duration: 0.16), value: showsBackwardArrow)
                .animation(.easeInOut(duration: 0.16), value: showsForwardArrow)
            }
            .frame(width: contentWidth, height: carouselHeight, alignment: .center)
            .contentShape(Rectangle())
            .onHover { isHoveringCarousel = $0 }
            .onChange(of: columnIDs) { _, _ in
                clampAnchorIndex()
            }
        }
    }

    @ViewBuilder
    private func characterPanel(regionWidth: CGFloat, shelfHeight: CGFloat, capsuleInsets: EdgeInsets) -> some View {
        let visualState = WorkCharacterShelfVisualState.resolve(
            hasForegroundAsset: characterImageAvailability.hasImageLikeAsset(
                configured: hasConfiguredCharacterForeground
            )
        )
        let imageMaxWidth = max(regionWidth - 28, 0)
        let imageMaxHeight = max(shelfHeight - 18, 0)
        let infoCardWidth = max(regionWidth - capsuleInsets.leading - capsuleInsets.trailing, 0)

        Group {
            if let character = section.character {
                Button {
                    onSelectCharacter(character)
                } label: {
                    characterPanelContent(
                        visualState: visualState,
                        imageMaxWidth: imageMaxWidth,
                        imageMaxHeight: imageMaxHeight,
                        infoCardWidth: infoCardWidth,
                        shelfHeight: shelfHeight,
                        regionWidth: regionWidth,
                        insets: capsuleInsets
                    )
                }
                .buttonStyle(.plain)
                .onHover { isHoveringCharacter = $0 }
                .help(localizer.string(.workDetailOpenCharacter))
                .accessibilityLabel("\(localizer.string(.workDetailOpenCharacter)): \(character.displayText), \(localizer.workDetailBookCount(section.bookCount))")
            } else {
                characterPanelContent(
                    visualState: visualState,
                    imageMaxWidth: imageMaxWidth,
                    imageMaxHeight: imageMaxHeight,
                    infoCardWidth: infoCardWidth,
                    shelfHeight: shelfHeight,
                    regionWidth: regionWidth,
                    insets: capsuleInsets
                )
            }
        }
        .tagVisualImageDropTarget(
            kind: .foreground,
            localizer: localizer,
            isEnabled: section.character != nil,
            cornerRadius: WorkDetailSurfaceRole.shelf.cornerRadius,
            hasExistingAsset: { section.character?.visualProfile?.foregroundAssetPath != nil },
            onImport: { imageData in
                guard let character = section.character else {
                    return
                }
                onImportTagImage(.foreground, imageData, character.assetTarget)
            },
            onError: onDropError
        )
        .onChange(of: section.id) { _, _ in
            characterImageAvailability = .pending
            isHoveringCharacter = false
        }
    }

    private func characterPanelContent(
        visualState: WorkCharacterShelfVisualState,
        imageMaxWidth: CGFloat,
        imageMaxHeight: CGFloat,
        infoCardWidth: CGFloat,
        shelfHeight: CGFloat,
        regionWidth: CGFloat,
        insets: EdgeInsets
    ) -> some View {
        ZStack(alignment: .bottomLeading) {
            if visualState.showsPlaceholder {
                characterPlaceholder
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                    .padding(.bottom, 96)
            }

            WorkCharacterImage(
                tag: section.character,
                assetURL: assetURL,
                onImageAvailabilityChange: { isAvailable in
                    characterImageAvailability = isAvailable ? .available : .missing
                }
            )
            .frame(maxWidth: imageMaxWidth, maxHeight: imageMaxHeight)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
            .shadow(
                color: .black.opacity(visualState.characterShadowOpacity),
                radius: visualState.characterShadowRadius,
                x: 0,
                y: visualState.characterShadowYOffset
            )

            characterInfoCard(width: infoCardWidth)
                .padding(insets)
        }
        .frame(width: regionWidth, height: shelfHeight, alignment: .bottomLeading)
        .contentShape(Rectangle())
    }

    private func characterInfoCard(width: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(section.character?.displayText ?? localizer.string(.workDetailUntaggedCharacter))
                .font(.title3.weight(.semibold))
                .foregroundStyle(.primary)
                .lineLimit(2)
                .multilineTextAlignment(.leading)

            HStack(spacing: 4) {
                Text(localizer.workDetailBookCount(section.bookCount))
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)

                Spacer(minLength: 0)

                if section.character != nil {
                    Image(systemName: "arrow.up.right")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 20, height: 20)
                        .offset(x: isHoveringCharacter ? 2 : 0, y: isHoveringCharacter ? -2 : 0)
                        .accessibilityHidden(true)
                }
            }
        }
        .padding(.horizontal, width < 180 ? 9 : 16)
        .padding(.vertical, 12)
        .frame(width: width, alignment: .leading)
        .workDetailCharacterGlassRegion()
        .scaleEffect(isHoveringCharacter ? 1.015 : 1, anchor: .bottomLeading)
        .animation(.easeOut(duration: 0.16), value: isHoveringCharacter)
    }

    private var hasConfiguredCharacterForeground: Bool {
        section.character?.visualProfile?.foregroundAssetPath != nil
    }

    private var characterPlaceholder: some View {
        VStack(alignment: .center, spacing: 12) {
            Image(systemName: "person.crop.square")
                .font(.system(size: 44, weight: .medium))
                .foregroundStyle(.secondary.opacity(0.42))
                .frame(width: 86, height: 86)
                .background(.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 18))

            RoundedRectangle(cornerRadius: 999)
                .fill(.secondary.opacity(0.12))
                .frame(width: 180, height: 5)
        }
        .frame(maxWidth: .infinity)
        .allowsHitTesting(false)
    }

    private func scroll(by offset: Int, proxy: ScrollViewProxy) {
        let upperBound = offset > 0 ? maxForwardIndex : max(columnCount - 1, 0)
        let newIndex = min(max(anchorIndex + offset, 0), upperBound)
        guard (0..<columnCount).contains(newIndex) else {
            return
        }

        anchorIndex = newIndex
        withAnimation(.snappy(duration: 0.32)) {
            proxy.scrollTo(columnID(at: newIndex), anchor: .leading)
        }
    }

    private func clampAnchorIndex() {
        anchorIndex = min(max(anchorIndex, 0), maxForwardIndex)
    }

    private func columnID(at columnIndex: Int) -> LibraryBook.ID {
        let range = WorkCharacterShelfLayout.bookRange(
            forColumn: columnIndex,
            bookCount: section.books.count,
            usesDoubleRow: usesDoubleRow
        )
        return section.books[range.lowerBound].id
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
        WorkCharacterShelfLayout.usesDoubleRow(
            bookCount: section.books.count,
            threshold: WorkCharacterShelf.doubleRowThreshold
        )
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
                        cardPlaceholder
                        if usesDoubleRow {
                            cardPlaceholder
                        }
                    }
                }
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 18)
        .frame(maxWidth: .infinity, minHeight: usesDoubleRow ? 430 : 340, alignment: .leading)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: WorkDetailSurfaceRole.shelf.cornerRadius, style: .continuous))
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .redacted(reason: .placeholder)
    }

    private var cardPlaceholder: some View {
        VStack(alignment: .leading, spacing: metrics.contentSpacing) {
            RoundedRectangle(cornerRadius: 8)
                .fill(.secondary.opacity(0.16))
                .frame(width: metrics.cardWidth, height: metrics.coverHeight)
            RoundedRectangle(cornerRadius: 6)
                .fill(.secondary.opacity(0.18))
                .frame(width: metrics.cardWidth * 0.86, height: metrics.titleHeight)
            RoundedRectangle(cornerRadius: 5)
                .fill(.secondary.opacity(0.12))
                .frame(width: metrics.cardWidth * 0.72, height: metrics.infoRowHeight)
            RoundedRectangle(cornerRadius: 5)
                .fill(.secondary.opacity(0.14))
                .frame(width: metrics.cardWidth * 0.64, height: metrics.ratingHeight)
        }
        .frame(width: metrics.cardWidth, height: metrics.cardHeight, alignment: .topLeading)
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

enum WorkCharacterShelfSplitLayout {
    static let minCharacterColumnWidth: CGFloat = 300
    static let maxCharacterColumnWidth: CGFloat = 420
    static let characterColumnRatio: CGFloat = 0.30
    static let minimumContentWidth: CGFloat = 300
    static let capsuleHorizontalInset: CGFloat = 18
    static let capsuleBottomInset: CGFloat = 16

    static func keepsContentOutsideCharacterColumn(
        characterColumnWidth: CGFloat,
        contentColumnWidth: CGFloat,
        containerWidth: CGFloat
    ) -> Bool {
        characterColumnWidth >= minCharacterColumnWidth
            && contentColumnWidth >= minimumContentWidth
            && characterColumnWidth + contentColumnWidth <= containerWidth + 0.5
    }
}

struct WorkCharacterShelfSplitMetrics: Equatable {
    var containerSize: CGSize
    var characterColumnWidth: CGFloat
    var contentColumnWidth: CGFloat
    var capsuleInsets: EdgeInsets
    var viewportFadeWidth: CGFloat

    static func resolve(containerSize: CGSize) -> WorkCharacterShelfSplitMetrics {
        let width = max(containerSize.width, 0)
        let height = max(containerSize.height, 0)
        let proposedCharacterWidth = width * WorkCharacterShelfSplitLayout.characterColumnRatio
        let cappedCharacterWidth = min(
            max(proposedCharacterWidth, WorkCharacterShelfSplitLayout.minCharacterColumnWidth),
            WorkCharacterShelfSplitLayout.maxCharacterColumnWidth
        )
        let maxCharacterWidthForContent = max(width - WorkCharacterShelfSplitLayout.minimumContentWidth, 0)
        let characterColumnWidth = min(cappedCharacterWidth, maxCharacterWidthForContent)
        let contentColumnWidth = max(width - characterColumnWidth, 0)
        let viewportFadeWidth = width > 0 ? min(max(width * 0.022, 18), 32) : 0

        return WorkCharacterShelfSplitMetrics(
            containerSize: CGSize(width: width, height: height),
            characterColumnWidth: characterColumnWidth,
            contentColumnWidth: contentColumnWidth,
            capsuleInsets: EdgeInsets(
                top: 0,
                leading: WorkCharacterShelfSplitLayout.capsuleHorizontalInset,
                bottom: WorkCharacterShelfSplitLayout.capsuleBottomInset,
                trailing: WorkCharacterShelfSplitLayout.capsuleHorizontalInset
            ),
            viewportFadeWidth: viewportFadeWidth
        )
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

struct WorkCharacterShelfVisualState: Equatable {
    var showsPlaceholder: Bool
    var characterShadowOpacity: Double
    var characterShadowRadius: CGFloat
    var characterShadowYOffset: CGFloat

    static func resolve(hasForegroundAsset: Bool) -> WorkCharacterShelfVisualState {
        WorkCharacterShelfVisualState(
            showsPlaceholder: !hasForegroundAsset,
            characterShadowOpacity: hasForegroundAsset ? 0.18 : 0,
            characterShadowRadius: hasForegroundAsset ? 20 : 0,
            characterShadowYOffset: hasForegroundAsset ? 12 : 0
        )
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

    var strokeOpacity: Double {
        switch self {
        case .hero:
            0.18
        case .shelf:
            0.17
        }
    }

    var shadowOpacity: Double {
        switch self {
        case .hero:
            0.055
        case .shelf:
            0.042
        }
    }

    var shadowRadius: CGFloat {
        switch self {
        case .hero:
            18
        case .shelf:
            16
        }
    }

    var shadowYOffset: CGFloat {
        switch self {
        case .hero:
            8
        case .shelf:
            7
        }
    }

    var material: Material {
        switch self {
        case .hero:
            .regularMaterial
        case .shelf:
            .regularMaterial
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
    let blurAssetURL: (String) async -> URL?

    @State private var image: NSImage?
    @State private var blurredImage: NSImage?

    var body: some View {
        GeometryReader { proxy in
            let layout = WorkHeroBackgroundLayout.resolve(size: proxy.size)

            ZStack(alignment: .topLeading) {
                if let blurredImage {
                    heroImage(
                        blurredImage,
                        layout: layout,
                        opacity: 0.22,
                        saturation: 1.0,
                        extraBleed: layout.edgeFadeWidth * 0.72,
                        featherScale: 1.35
                    )
                }

                if let image {
                    heroImage(
                        image,
                        layout: layout,
                        opacity: 0.82,
                        saturation: 1.06,
                        extraBleed: 0,
                        featherScale: 1.0
                    )
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
            .clipped()
        }
        .allowsHitTesting(false)
        .task(id: backgroundAssetIdentity) {
            guard let backgroundAssetPath,
                  let backgroundURL = assetURL(backgroundAssetPath) else {
                image = nil
                blurredImage = nil
                return
            }
            let loadedImage = await TagVisualImageCache.shared.image(for: backgroundURL)
            var loadedBlurredImage: NSImage?
            if let blurURL = await blurAssetURL(backgroundAssetPath) {
                loadedBlurredImage = await TagVisualImageCache.shared.image(for: blurURL)
            }
            if let loadedImage {
                withAnimation(.easeInOut(duration: 0.18)) {
                    image = loadedImage
                    blurredImage = loadedBlurredImage
                }
            }
        }
    }

    private var backgroundAssetPath: String? {
        work.visualProfile?.backgroundAssetPath
    }

    private var backgroundAssetIdentity: String {
        "\(backgroundAssetPath ?? "none"):\(work.visualProfile?.updatedAt ?? 0)"
    }

    private func heroImage(
        _ nsImage: NSImage,
        layout: WorkHeroBackgroundLayout,
        opacity: Double,
        saturation: Double,
        extraBleed: CGFloat,
        featherScale: CGFloat
    ) -> some View {
        let imageFrame = layout.imageFrame.insetBy(dx: -extraBleed, dy: -extraBleed)
        let scale = work.visualProfile?.backgroundScale ?? 1
        let offsetX = (work.visualProfile?.backgroundOffsetX ?? 0) * layout.imageFrame.width
        let offsetY = (work.visualProfile?.backgroundOffsetY ?? 0) * layout.imageFrame.height
        let featherMetrics = WorkHeroFeatherMaskMetrics.resolve(
            size: imageFrame.size,
            baseFadeWidth: layout.edgeFadeWidth * featherScale
        )

        return Image(nsImage: nsImage)
            .resizable()
            .scaledToFill()
            .scaleEffect(scale)
            .offset(x: offsetX, y: offsetY)
            .frame(width: imageFrame.width, height: imageFrame.height)
            .saturation(saturation)
            .opacity(opacity)
            .clipped()
            .mask {
                WorkHeroFeatherMask(metrics: featherMetrics)
            }
            .position(x: imageFrame.midX, y: imageFrame.midY)
    }
}

struct WorkHeroBackgroundLayout: Equatable {
    var imageFrame: CGRect
    var edgeFadeWidth: CGFloat
    var textReadableOverlayWidth: CGFloat

    static func resolve(size: CGSize) -> WorkHeroBackgroundLayout {
        let width = max(size.width, 0)
        let height = max(size.height, 0)
        let imageWidthRatio = width >= 980 ? 0.55 : 0.50
        let imageWidth = max(width * imageWidthRatio, min(width, 380))
        let imageFrame = CGRect(
            x: max(width - imageWidth - 18, 0),
            y: max(height * 0.06, 0),
            width: min(imageWidth, width),
            height: max(height * 0.88, 0)
        )
        let edgeFadeWidth = min(max(width * 0.085, 68), 180)
        let textReadableOverlayWidth = min(max(imageFrame.minX + edgeFadeWidth, width * 0.42), width)

        return WorkHeroBackgroundLayout(
            imageFrame: imageFrame,
            edgeFadeWidth: edgeFadeWidth,
            textReadableOverlayWidth: textReadableOverlayWidth
        )
    }
}

struct WorkHeroVisualDropRouting: Equatable {
    var foregroundFrame: CGRect
    var backgroundFrame: CGRect

    static func resolve(size: CGSize) -> WorkHeroVisualDropRouting {
        let width = max(size.width, 0)
        let height = max(size.height, 0)
        let backgroundLayout = WorkHeroBackgroundLayout.resolve(size: size)
        let horizontalInset = min(max(width * 0.04, 34), 58)
        let verticalInset = min(max(height * 0.08, 34), 58)
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

struct WorkHeroFeatherMaskMetrics: Equatable {
    var size: CGSize
    var fadeWidth: CGFloat
    var centerRect: CGRect

    static func resolve(size: CGSize, baseFadeWidth: CGFloat) -> WorkHeroFeatherMaskMetrics {
        let width = max(size.width, 0)
        let height = max(size.height, 0)
        let shortestSide = min(width, height)
        let fadeWidth = min(
            max(baseFadeWidth, 24),
            max(shortestSide * 0.42, 0)
        )
        let centerRect = CGRect(
            x: min(fadeWidth, width / 2),
            y: min(fadeWidth, height / 2),
            width: max(width - fadeWidth * 2, 0),
            height: max(height - fadeWidth * 2, 0)
        )

        return WorkHeroFeatherMaskMetrics(
            size: CGSize(width: width, height: height),
            fadeWidth: fadeWidth,
            centerRect: centerRect
        )
    }
}

private struct WorkHeroFeatherMask: View {
    let metrics: WorkHeroFeatherMaskMetrics

    var body: some View {
        let fade = metrics.fadeWidth
        let width = metrics.size.width
        let height = metrics.size.height

        Rectangle()
            .fill(.white)
            .mask {
                HStack(spacing: 0) {
                    LinearGradient(colors: [.clear, .white], startPoint: .leading, endPoint: .trailing)
                        .frame(width: min(fade, width / 2))
                    Rectangle()
                        .fill(.white)
                    LinearGradient(colors: [.white, .clear], startPoint: .leading, endPoint: .trailing)
                        .frame(width: min(fade, width / 2))
                }
            }
            .mask {
                VStack(spacing: 0) {
                    LinearGradient(colors: [.clear, .white], startPoint: .top, endPoint: .bottom)
                        .frame(height: min(fade, height / 2))
                    Rectangle()
                        .fill(.white)
                    LinearGradient(colors: [.white, .clear], startPoint: .top, endPoint: .bottom)
                        .frame(height: min(fade, height / 2))
                }
            }
        .allowsHitTesting(false)
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
            guard let foregroundURL else {
                image = nil
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
            if let loadedImage {
                image = loadedImage
            } else {
                image = nil
            }
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

private enum WorkVisualImageKind {
    case foreground
    case background
}

private struct WorkVisualImage: View {
    let tag: TagDisplaySummary?
    let kind: WorkVisualImageKind
    let assetURL: (String) -> URL?
    let fallbackSystemImage: String

    @State private var image: NSImage?

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                if let image {
                    Image(nsImage: image)
                        .resizable()
                        .scaledToFit()
                        .scaleEffect(tag.map(scale(for:)) ?? 1)
                        .offset(
                            x: (tag.map(offsetX(for:)) ?? 0) * proxy.size.width,
                            y: (tag.map(offsetY(for:)) ?? 0) * proxy.size.height
                        )
                        .frame(width: proxy.size.width, height: proxy.size.height)
                } else {
                    Image(systemName: fallbackSystemImage)
                        .font(.system(size: 46, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.78))
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
            .clipped()
        }
        .task(id: assetIdentity) {
            guard let resolvedURL else {
                image = nil
                return
            }
            if let loadedImage = await TagVisualImageCache.shared.image(for: resolvedURL) {
                image = loadedImage
            }
        }
    }

    private var resolvedURL: URL? {
        guard let tag,
              let assetPath = assetPath(for: tag) else {
            return nil
        }
        return assetURL(assetPath)
    }

    private var assetIdentity: String {
        guard let tag else {
            return "none"
        }
        return "\(assetPath(for: tag) ?? "none"):\(tag.visualProfile?.updatedAt ?? 0)"
    }

    private func assetPath(for tag: TagDisplaySummary) -> String? {
        switch kind {
        case .foreground:
            tag.visualProfile?.foregroundAssetPath
        case .background:
            tag.visualProfile?.backgroundAssetPath
        }
    }

    private func scale(for tag: TagDisplaySummary) -> Double {
        switch kind {
        case .foreground:
            tag.visualProfile?.foregroundScale ?? 1
        case .background:
            tag.visualProfile?.backgroundScale ?? 1
        }
    }

    private func offsetX(for tag: TagDisplaySummary) -> Double {
        switch kind {
        case .foreground:
            tag.visualProfile?.foregroundOffsetX ?? 0
        case .background:
            tag.visualProfile?.backgroundOffsetX ?? 0
        }
    }

    private func offsetY(for tag: TagDisplaySummary) -> Double {
        switch kind {
        case .foreground:
            tag.visualProfile?.foregroundOffsetY ?? 0
        case .background:
            tag.visualProfile?.backgroundOffsetY ?? 0
        }
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
        .help(help)
    }
}

private extension View {
    func workDetailGlassSurface(_ role: WorkDetailSurfaceRole) -> some View {
        modifier(WorkDetailSurfaceModifier(role: role))
    }

    @ViewBuilder
    func workDetailBackgroundExtension() -> some View {
        if #available(macOS 26.0, *) {
            backgroundExtensionEffect(isEnabled: true)
        } else {
            self
        }
    }

    @ViewBuilder
    func workDetailCharacterGlassRegion() -> some View {
        let shape = RoundedRectangle(cornerRadius: 14, style: .continuous)

        if #available(macOS 26.0, *) {
            glassEffect(.regular, in: shape)
        } else {
            background(.regularMaterial, in: shape)
                .overlay {
                    shape
                        .stroke(.white.opacity(0.16), lineWidth: 1)
                }
                .shadow(color: .black.opacity(0.03), radius: 10, x: 0, y: 4)
        }
    }

}

private struct WorkDetailSurfaceModifier: ViewModifier {
    let role: WorkDetailSurfaceRole

    @ViewBuilder
    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: role.cornerRadius, style: .continuous)

        if role == .shelf {
            content
        } else if #available(macOS 26.0, *), role == .hero {
            content
                .glassEffect(.regular, in: shape)
        } else {
            content
                .background(role.material, in: shape)
                .overlay {
                    shape
                        .stroke(.white.opacity(role.strokeOpacity), lineWidth: 1)
                }
                .shadow(
                    color: .black.opacity(role.shadowOpacity),
                    radius: role.shadowRadius,
                    x: 0,
                    y: role.shadowYOffset
                )
        }
    }
}
