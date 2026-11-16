import CoreGraphics
import Testing
@testable import NyaEHCore

@Suite("Reading models")
struct ReadingModelsTests {
    @Test("reader cache prefetches nearby pages and releases distant pages")
    func windowedCachePolicy() throws {
        #expect(ReaderPageCachePolicy.loadRange(center: 100, totalPages: 5_000, layout: .singlePage) == 98...102)
        #expect(ReaderPageCachePolicy.loadRange(center: 100, totalPages: 5_000, layout: .doublePage) == 98...103)
        #expect(ReaderPageCachePolicy.loadRange(center: 1, totalPages: 5_000, layout: .continuous) == 0...4)

        let retained = ReaderPageCachePolicy.retainedIndices(0..<5_000, center: 2_500, layout: .continuous)
        #expect(retained.count == 13)
        #expect(retained.contains(2_494))
        #expect(retained.contains(2_506))
        #expect(!retained.contains(0))
        #expect(!retained.contains(4_999))

        #expect(ReaderPageCachePolicy.costLimit(physicalMemory: 1_024) == ReaderPageCachePolicy.minimumCostLimit)
        #expect(ReaderPageCachePolicy.costLimit(physicalMemory: UInt64.max) == ReaderPageCachePolicy.maximumCostLimit)
        let evicted = ReaderPageCachePolicy.evictedIndices(
            costs: [98: 80, 99: 80, 100: 80, 101: 80],
            center: 100,
            visibleIndices: [100],
            costLimit: 160
        )
        #expect(evicted.contains(98))
        #expect(!evicted.contains(100))
    }

    @Test("reading progress reports completion and normalized percentage")
    func progressSummary() {
        let state = BookReadingState(
            bookID: 1,
            currentPageIndex: 94,
            totalPages: 100,
            updatedAt: 1,
            completedAt: 1
        )
        #expect(state.progress == 0.95)
        #expect(state.isCompleted)
    }

    @Test("reader display preferences normalize zoom limits")
    func readerDisplayPreferencesNormalizeZoomLimits() {
        #expect(ReaderDisplayPreferences.defaultValue.layoutMode == .singlePage)
        #expect(ReaderDisplayPreferences.defaultValue.fitMode == .fitHeight)
        #expect(ReaderDisplayPreferences.defaultValue.zoom == 1)
        #expect(!ReaderDisplayPreferences.defaultValue.showsThumbnails)
        #expect(
            ReaderDisplayPreferences(
                layoutMode: .continuous,
                fitMode: .custom,
                zoom: 0.1,
                showsThumbnails: true
            ).zoom == ReaderDisplayPreferences.minimumZoom
        )
        #expect(
            ReaderDisplayPreferences(
                layoutMode: .continuous,
                fitMode: .custom,
                zoom: 1,
                showsThumbnails: true
            ).normalized().showsThumbnails
        )
        #expect(
            ReaderDisplayPreferences(
                layoutMode: .doublePage,
                fitMode: .custom,
                zoom: 8
            ).zoom == ReaderDisplayPreferences.maximumZoom
        )
        #expect(ReaderDisplayPreferences.normalizedZoom(.nan) == 1)
        #expect(ReaderDisplayPreferences.normalizedZoom(.infinity) == 1)
    }

    @Test("reader navigation aligns spreads and clamps boundaries")
    func readerNavigationPolicy() {
        #expect(ReaderNavigationPolicy.alignedIndex(3, totalPages: 28, layout: .doublePage) == 2)
        #expect(ReaderNavigationPolicy.alignedIndex(27, totalPages: 28, layout: .doublePage) == 26)
        #expect(ReaderNavigationPolicy.lastPageIndex(totalPages: 27, layout: .doublePage) == 26)
        #expect(
            ReaderNavigationPolicy.targetIndex(
                from: 26,
                direction: .next,
                totalPages: 28,
                layout: .doublePage
            ) == 26
        )
        #expect(
            ReaderNavigationPolicy.targetIndex(
                from: 2,
                direction: .previous,
                totalPages: 28,
                layout: .doublePage
            ) == 0
        )
        #expect(
            ReaderNavigationPolicy.visiblePageRange(
                currentIndex: 26,
                totalPages: 28,
                layout: .doublePage
            ) == 26...27
        )
    }

    @Test("reader keyboard policy maps navigation display and zoom commands")
    func readerKeyboardPolicy() {
        #expect(ReaderKeyboardCommandPolicy.command(for: .leftArrow) == .navigate(.previous))
        #expect(ReaderKeyboardCommandPolicy.command(for: .space) == .navigate(.next))
        #expect(
            ReaderKeyboardCommandPolicy.command(for: .space, modifiers: .shift) == .navigate(.previous)
        )
        #expect(ReaderKeyboardCommandPolicy.command(for: .home) == .firstPage)
        #expect(ReaderKeyboardCommandPolicy.command(for: .end) == .lastPage)
        #expect(ReaderKeyboardCommandPolicy.command(for: .character("1")) == .setLayout(.singlePage))
        #expect(ReaderKeyboardCommandPolicy.command(for: .character("2")) == .setLayout(.doublePage))
        #expect(ReaderKeyboardCommandPolicy.command(for: .character("3")) == .setLayout(.continuous))
        #expect(ReaderKeyboardCommandPolicy.command(for: .character("w")) == .setFit(.fitWidth))
        #expect(ReaderKeyboardCommandPolicy.command(for: .character("H")) == .setFit(.fitHeight))
        #expect(ReaderKeyboardCommandPolicy.command(for: .character("+"), modifiers: .shift) == .zoomIn)
        #expect(ReaderKeyboardCommandPolicy.command(for: .character("-")) == .zoomOut)
        #expect(ReaderKeyboardCommandPolicy.command(for: .character("0")) == .resetZoom)
        #expect(ReaderKeyboardCommandPolicy.command(for: .character("f")) == .toggleFullscreen)
        #expect(
            ReaderKeyboardCommandPolicy.command(
                for: .character("s"),
                modifiers: [.option, .command]
            ) == .toggleThumbnails
        )
        #expect(
            ReaderKeyboardCommandPolicy.command(
                for: .character("S"),
                modifiers: [.option, .command]
            ) == .toggleThumbnails
        )
        #expect(
            ReaderKeyboardCommandPolicy.command(
                for: .character("s"),
                modifiers: .command
            ) == nil
        )
        #expect(ReaderKeyboardCommandPolicy.command(for: .escape) == .close)
        #expect(ReaderKeyboardCommandPolicy.command(for: .leftArrow, isEditingText: true) == nil)
        #expect(ReaderKeyboardCommandPolicy.command(for: .escape, isEditingText: true) == nil)
        #expect(ReaderKeyboardCommandPolicy.command(for: .space, isEditingText: true) == nil)
        #expect(ReaderKeyboardCommandPolicy.command(for: .character("2"), isEditingText: true) == nil)
        #expect(
            ReaderKeyboardCommandPolicy.command(
                for: .character("s"),
                modifiers: [.option, .command],
                isEditingText: true
            ) == nil
        )
        #expect(
            ReaderKeyboardCommandPolicy.command(for: .character("f"), modifiers: .command) == nil
        )
    }

    @Test("reader scroll paging distinguishes trackpads mouse wheels and continuous layout")
    func readerScrollPaging() {
        var accumulator = ReaderScrollPagingAccumulator()
        #expect(
            accumulator.consume(
                ReaderScrollSample(
                    deltaX: 0,
                    deltaY: 10,
                    isPrecise: true,
                    phase: .began,
                    isMomentum: false
                ),
                timestamp: 1
            ) == nil
        )
        #expect(
            accumulator.consume(
                ReaderScrollSample(
                    deltaX: 0,
                    deltaY: 16,
                    isPrecise: true,
                    phase: .changed,
                    isMomentum: false
                ),
                timestamp: 1.01
            ) == .next
        )
        #expect(
            accumulator.consume(
                ReaderScrollSample(
                    deltaX: 0,
                    deltaY: 100,
                    isPrecise: true,
                    phase: .changed,
                    isMomentum: false
                ),
                timestamp: 1.02
            ) == nil
        )
        #expect(
            accumulator.consume(
                ReaderScrollSample(
                    deltaX: 0,
                    deltaY: 5,
                    isPrecise: true,
                    phase: .ended,
                    isMomentum: true
                ),
                timestamp: 1.03
            ) == nil
        )

        let mouseDown = ReaderScrollSample(
            deltaX: 0,
            deltaY: 1,
            isPrecise: false,
            phase: .none,
            isMomentum: false
        )
        let mouseUp = ReaderScrollSample(
            deltaX: 0,
            deltaY: -1,
            isPrecise: false,
            phase: .none,
            isMomentum: false
        )
        #expect(accumulator.consume(mouseDown, timestamp: 2) == .next)
        #expect(accumulator.consume(mouseDown, timestamp: 2.05) == nil)
        #expect(accumulator.consume(mouseUp, timestamp: 2.2) == .previous)

        #expect(ReaderInputPolicy.pagesWithScroll(layout: .singlePage, isPointerOverControls: false))
        #expect(ReaderInputPolicy.pagesWithScroll(layout: .doublePage, isPointerOverControls: false))
        #expect(!ReaderInputPolicy.pagesWithScroll(layout: .continuous, isPointerOverControls: false))
        #expect(!ReaderInputPolicy.pagesWithScroll(layout: .singlePage, isPointerOverControls: true))
        #expect(
            !ReaderInputPolicy.pagesWithScroll(
                layout: .singlePage,
                isPointerOverControls: false,
                isPointerOverThumbnailSidebar: true
            )
        )
        #expect(
            ReaderThumbnailSidebarHitTestPolicy.contains(
                windowX: 120,
                contentWidth: 1_000
            )
        )
        #expect(
            !ReaderThumbnailSidebarHitTestPolicy.contains(
                windowX: 240,
                contentWidth: 1_000
            )
        )
        #expect(
            !ReaderThumbnailSidebarHitTestPolicy.contains(
                windowX: .nan,
                contentWidth: 1_000
            )
        )
    }

    @Test("reader window placement uses most of the display and recovers offscreen frames")
    func readerWindowPlacement() {
        let visibleFrame = CGRect(x: 100, y: 50, width: 1_000, height: 800)
        let initial = ReaderWindowPlacementPolicy.initialFrame(in: visibleFrame)
        #expect(initial == CGRect(x: 175, y: 110, width: 850, height: 680))

        let restored = ReaderWindowPlacementPolicy.restoredFrame(
            CGRect(x: 900, y: 700, width: 500, height: 400),
            visibleFrames: [visibleFrame],
            fallbackVisibleFrame: visibleFrame
        )
        #expect(restored == CGRect(x: 380, y: 290, width: 720, height: 560))

        let recovered = ReaderWindowPlacementPolicy.restoredFrame(
            CGRect(x: 5_000, y: 5_000, width: 900, height: 700),
            visibleFrames: [visibleFrame],
            fallbackVisibleFrame: visibleFrame
        )
        #expect(recovered == initial)
    }

    @Test("reader page jumps clamp and align double-page spreads")
    func readerPageJumpPolicy() {
        #expect(ReaderPageJumpPolicy.targetIndex(pageNumber: -4, totalPages: 28, layout: .singlePage) == 0)
        #expect(ReaderPageJumpPolicy.targetIndex(pageNumber: 99, totalPages: 28, layout: .singlePage) == 27)
        #expect(ReaderPageJumpPolicy.targetIndex(pageNumber: 4, totalPages: 28, layout: .doublePage) == 2)
        #expect(ReaderPageJumpPolicy.targetIndex(pageNumber: 28, totalPages: 28, layout: .doublePage) == 26)
        #expect(ReaderPageJumpPolicy.targetIndex(pageNumber: 27, totalPages: 27, layout: .doublePage) == 26)
    }

    @Test("reader window frame codec rejects damaged values and fullscreen persistence")
    func readerWindowFramePreferences() {
        let frame = CGRect(x: -120.5, y: 48.25, width: 1_180, height: 760)
        let encoded = ReaderWindowFramePreferenceCodec.encode(frame)
        #expect(encoded != nil)
        #expect(encoded.flatMap(ReaderWindowFramePreferenceCodec.decode) == frame)
        #expect(ReaderWindowFramePreferenceCodec.decode("broken") == nil)
        #expect(ReaderWindowFramePreferenceCodec.decode("0,0,nan,600") == nil)
        #expect(ReaderWindowFramePreferenceCodec.decode("0,0,0,600") == nil)
        #expect(ReaderWindowFramePersistencePolicy.shouldSave(isFullScreen: false))
        #expect(!ReaderWindowFramePersistencePolicy.shouldSave(isFullScreen: true))
    }

    @Test("reader thumbnail cache prefetches locally and evicts distant images by cost")
    func readerThumbnailCachePolicy() {
        #expect(
            ReaderThumbnailCachePolicy.loadIndices(
                around: 5,
                totalPages: 10,
                cachedIndices: [],
                loadingIndices: []
            ) == [5, 4, 6, 3, 7, 2, 8]
        )
        #expect(
            ReaderThumbnailCachePolicy.loadIndices(
                around: 0,
                totalPages: 10,
                cachedIndices: [0, 1],
                loadingIndices: [2]
            ) == [3]
        )
        #expect(
            ReaderThumbnailCachePolicy.loadIndices(
                around: 99,
                totalPages: 3,
                cachedIndices: [],
                loadingIndices: []
            ) == [2, 1, 0]
        )

        let evicted = ReaderThumbnailCachePolicy.evictedIndices(
            costs: [0: 80, 1: 80, 2: 80, 3: 80],
            center: 2,
            visibleIndices: [2],
            costLimit: 160
        )
        #expect(evicted.count == 2)
        #expect(evicted.contains(0))
        #expect(!evicted.contains(2))
    }
}
