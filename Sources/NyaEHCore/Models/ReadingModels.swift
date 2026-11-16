// 本文件定义持久化阅读进度与阅读器展示偏好；原始 archive 页面仍按需加载。

import Foundation

struct BookReadingState: Equatable, Sendable {
    var bookID: LibraryBook.DatabaseID
    var currentPageIndex: Int
    var totalPages: Int
    var updatedAt: Int64
    var completedAt: Int64?

    var isCompleted: Bool {
        completedAt != nil
    }

    var progress: Double {
        guard totalPages > 0 else { return 0 }
        return min(max(Double(currentPageIndex + 1) / Double(totalPages), 0), 1)
    }

    static func initial(bookID: LibraryBook.DatabaseID, totalPages: Int = 0) -> BookReadingState {
        BookReadingState(
            bookID: bookID,
            currentPageIndex: 0,
            totalPages: max(totalPages, 0),
            updatedAt: Timestamp.nowMilliseconds(),
            completedAt: nil
        )
    }
}

enum ReaderLayoutMode: String, CaseIterable, Identifiable, Sendable {
    case singlePage
    case continuous
    case doublePage

    var id: String { rawValue }
}

enum ReaderFitMode: String, CaseIterable, Identifiable, Sendable {
    case fitWidth
    case fitHeight
    case actualSize
    case custom

    var id: String { rawValue }
}

struct ReaderDisplayPreferences: Equatable, Sendable {
    static let minimumZoom = 0.25
    static let maximumZoom = 3.0
    static let defaultValue = ReaderDisplayPreferences(
        layoutMode: .singlePage,
        fitMode: .fitHeight,
        zoom: 1,
        showsThumbnails: false
    )

    var layoutMode: ReaderLayoutMode
    var fitMode: ReaderFitMode
    var zoom: Double
    var showsThumbnails: Bool

    init(
        layoutMode: ReaderLayoutMode,
        fitMode: ReaderFitMode,
        zoom: Double,
        showsThumbnails: Bool = false
    ) {
        self.layoutMode = layoutMode
        self.fitMode = fitMode
        self.zoom = Self.normalizedZoom(zoom)
        self.showsThumbnails = showsThumbnails
    }

    func normalized() -> ReaderDisplayPreferences {
        ReaderDisplayPreferences(
            layoutMode: layoutMode,
            fitMode: fitMode,
            zoom: zoom,
            showsThumbnails: showsThumbnails
        )
    }

    static func normalizedZoom(_ zoom: Double) -> Double {
        guard zoom.isFinite else {
            return defaultValue.zoom
        }
        return min(max(zoom, minimumZoom), maximumZoom)
    }
}

enum ReaderNavigationDirection: Equatable, Sendable {
    case previous
    case next
}

enum ReaderCommand: Equatable, Sendable {
    case navigate(ReaderNavigationDirection)
    case firstPage
    case lastPage
    case setLayout(ReaderLayoutMode)
    case setFit(ReaderFitMode)
    case zoomIn
    case zoomOut
    case resetZoom
    case toggleThumbnails
    case toggleFullscreen
    case close
}

enum ReaderKeyboardKey: Equatable, Sendable {
    case leftArrow
    case rightArrow
    case upArrow
    case downArrow
    case pageUp
    case pageDown
    case home
    case end
    case space
    case escape
    case character(Character)
}

struct ReaderKeyboardModifiers: OptionSet, Equatable, Sendable {
    let rawValue: Int

    static let shift = ReaderKeyboardModifiers(rawValue: 1 << 0)
    static let control = ReaderKeyboardModifiers(rawValue: 1 << 1)
    static let option = ReaderKeyboardModifiers(rawValue: 1 << 2)
    static let command = ReaderKeyboardModifiers(rawValue: 1 << 3)
}

enum ReaderKeyboardCommandPolicy {
    static func command(
        for key: ReaderKeyboardKey,
        modifiers: ReaderKeyboardModifiers = [],
        isEditingText: Bool = false
    ) -> ReaderCommand? {
        guard !isEditingText else { return nil }

        if case let .character(character) = key,
           Character(String(character).lowercased()) == "s",
           modifiers == [.option, .command] {
            return .toggleThumbnails
        }

        guard modifiers.intersection([.control, .option, .command]).isEmpty else { return nil }

        switch key {
        case .leftArrow, .upArrow, .pageUp:
            return modifiers.isEmpty ? .navigate(.previous) : nil
        case .rightArrow, .downArrow, .pageDown:
            return modifiers.isEmpty ? .navigate(.next) : nil
        case .home:
            return modifiers.isEmpty ? .firstPage : nil
        case .end:
            return modifiers.isEmpty ? .lastPage : nil
        case .space:
            if modifiers.isEmpty {
                return .navigate(.next)
            }
            return modifiers == .shift ? .navigate(.previous) : nil
        case .escape:
            return modifiers.isEmpty ? .close : nil
        case let .character(character):
            let value = Character(String(character).lowercased())
            switch value {
            case "1": return modifiers.isEmpty ? .setLayout(.singlePage) : nil
            case "2": return modifiers.isEmpty ? .setLayout(.doublePage) : nil
            case "3": return modifiers.isEmpty ? .setLayout(.continuous) : nil
            case "w": return modifiers.isEmpty ? .setFit(.fitWidth) : nil
            case "h": return modifiers.isEmpty ? .setFit(.fitHeight) : nil
            case "a": return modifiers.isEmpty ? .setFit(.actualSize) : nil
            case "f": return modifiers.isEmpty ? .toggleFullscreen : nil
            case "-", "−": return modifiers.isEmpty ? .zoomOut : nil
            case "0": return modifiers.isEmpty ? .resetZoom : nil
            case "+": return modifiers == .shift || modifiers.isEmpty ? .zoomIn : nil
            case "=": return modifiers.isEmpty || modifiers == .shift ? .zoomIn : nil
            default: return nil
            }
        }
    }
}

enum ReaderNavigationPolicy {
    static func alignedIndex(_ index: Int, totalPages: Int, layout: ReaderLayoutMode) -> Int {
        guard totalPages > 0 else { return 0 }
        let clamped = min(max(index, 0), totalPages - 1)
        guard layout == .doublePage else { return clamped }
        return min((clamped / 2) * 2, lastPageIndex(totalPages: totalPages, layout: layout))
    }

    static func targetIndex(
        from currentIndex: Int,
        direction: ReaderNavigationDirection,
        totalPages: Int,
        layout: ReaderLayoutMode
    ) -> Int {
        guard totalPages > 0 else { return 0 }
        let current = alignedIndex(currentIndex, totalPages: totalPages, layout: layout)
        let step = layout == .doublePage ? 2 : 1
        switch direction {
        case .previous:
            return max(current - step, 0)
        case .next:
            return min(current + step, lastPageIndex(totalPages: totalPages, layout: layout))
        }
    }

    static func lastPageIndex(totalPages: Int, layout: ReaderLayoutMode) -> Int {
        guard totalPages > 0 else { return 0 }
        let lastIndex = totalPages - 1
        return layout == .doublePage ? (lastIndex / 2) * 2 : lastIndex
    }

    static func visiblePageRange(
        currentIndex: Int,
        totalPages: Int,
        layout: ReaderLayoutMode
    ) -> ClosedRange<Int>? {
        guard totalPages > 0 else { return nil }
        let lowerBound = alignedIndex(currentIndex, totalPages: totalPages, layout: layout)
        let upperBound = layout == .doublePage ? min(lowerBound + 1, totalPages - 1) : lowerBound
        return lowerBound...upperBound
    }
}

enum ReaderPageJumpPolicy {
    static func targetIndex(
        pageNumber: Int,
        totalPages: Int,
        layout: ReaderLayoutMode
    ) -> Int {
        ReaderNavigationPolicy.alignedIndex(
            pageNumber - 1,
            totalPages: totalPages,
            layout: layout
        )
    }
}

enum ReaderInputPolicy {
    static func pagesWithScroll(
        layout: ReaderLayoutMode,
        isPointerOverControls: Bool,
        isPointerOverThumbnailSidebar: Bool = false
    ) -> Bool {
        layout != .continuous
            && !isPointerOverControls
            && !isPointerOverThumbnailSidebar
    }
}

enum ReaderThumbnailSidebarHitTestPolicy {
    static let leadingPadding = 16.0
    static let sidebarWidth = 184.0

    static func contains(
        windowX: Double,
        contentWidth: Double
    ) -> Bool {
        guard windowX.isFinite, contentWidth.isFinite, contentWidth > 0 else {
            return false
        }
        let interactiveWidth = min(leadingPadding + sidebarWidth, contentWidth)
        return windowX >= 0 && windowX <= interactiveWidth
    }
}

enum ReaderScrollPhase: Equatable, Sendable {
    case none
    case mayBegin
    case began
    case changed
    case ended
    case cancelled
}

struct ReaderScrollSample: Equatable, Sendable {
    var deltaX: Double
    var deltaY: Double
    var isPrecise: Bool
    var phase: ReaderScrollPhase
    var isMomentum: Bool
}

struct ReaderScrollPagingAccumulator: Equatable, Sendable {
    static let preciseThreshold = 24.0
    static let discreteCooldown = 0.12

    private(set) var accumulatedPreciseDelta = 0.0
    private(set) var didPageDuringPreciseGesture = false
    private(set) var lastDiscretePageTimestamp: TimeInterval?

    mutating func consume(
        _ sample: ReaderScrollSample,
        timestamp: TimeInterval
    ) -> ReaderNavigationDirection? {
        if sample.isPrecise {
            return consumePrecise(sample)
        }
        return consumeDiscrete(sample, timestamp: timestamp)
    }

    private mutating func consumePrecise(
        _ sample: ReaderScrollSample
    ) -> ReaderNavigationDirection? {
        if sample.phase == .mayBegin || sample.phase == .began {
            accumulatedPreciseDelta = 0
            didPageDuringPreciseGesture = false
        }
        if sample.phase == .ended || sample.phase == .cancelled {
            accumulatedPreciseDelta = 0
            didPageDuringPreciseGesture = false
            return nil
        }
        guard !sample.isMomentum, !didPageDuringPreciseGesture else { return nil }

        accumulatedPreciseDelta += dominantDelta(in: sample)
        guard abs(accumulatedPreciseDelta) >= Self.preciseThreshold else { return nil }
        didPageDuringPreciseGesture = true
        return direction(for: accumulatedPreciseDelta)
    }

    private mutating func consumeDiscrete(
        _ sample: ReaderScrollSample,
        timestamp: TimeInterval
    ) -> ReaderNavigationDirection? {
        let delta = dominantDelta(in: sample)
        guard abs(delta) >= 0.1 else { return nil }
        if let lastDiscretePageTimestamp,
           timestamp - lastDiscretePageTimestamp < Self.discreteCooldown {
            return nil
        }
        lastDiscretePageTimestamp = timestamp
        return direction(for: delta)
    }

    private func dominantDelta(in sample: ReaderScrollSample) -> Double {
        abs(sample.deltaY) >= abs(sample.deltaX) ? sample.deltaY : sample.deltaX
    }

    private func direction(for delta: Double) -> ReaderNavigationDirection {
        delta > 0 ? .next : .previous
    }
}

enum ReaderWindowFramePreferenceCodec {
    static func encode(_ frame: CGRect) -> String? {
        guard isValid(frame) else { return nil }
        return [frame.origin.x, frame.origin.y, frame.size.width, frame.size.height]
            .map { String(format: "%.17g", locale: Locale(identifier: "en_US_POSIX"), $0) }
            .joined(separator: ",")
    }

    static func decode(_ value: String) -> CGRect? {
        let components = value.split(separator: ",", omittingEmptySubsequences: false)
        guard components.count == 4 else { return nil }
        let numbers = components.compactMap { Double($0) }
        guard numbers.count == 4 else { return nil }
        let frame = CGRect(
            x: numbers[0],
            y: numbers[1],
            width: numbers[2],
            height: numbers[3]
        )
        return isValid(frame) ? frame : nil
    }

    private static func isValid(_ frame: CGRect) -> Bool {
        frame.origin.x.isFinite
            && frame.origin.y.isFinite
            && frame.size.width.isFinite
            && frame.size.height.isFinite
            && frame.size.width > 0
            && frame.size.height > 0
    }
}

enum ReaderWindowFramePersistencePolicy {
    static func shouldSave(isFullScreen: Bool) -> Bool {
        !isFullScreen
    }
}

enum ReaderWindowPlacementPolicy {
    static let defaultScale = 0.85
    static let minimumSize = CGSize(width: 720, height: 560)

    static func initialFrame(
        in visibleFrame: CGRect,
        scale: Double = defaultScale,
        minimumSize: CGSize = minimumSize
    ) -> CGRect {
        let width = min(max(visibleFrame.width * scale, minimumSize.width), visibleFrame.width)
        let height = min(max(visibleFrame.height * scale, minimumSize.height), visibleFrame.height)
        return CGRect(
            x: visibleFrame.midX - width / 2,
            y: visibleFrame.midY - height / 2,
            width: width,
            height: height
        )
    }

    static func restoredFrame(
        _ frame: CGRect,
        visibleFrames: [CGRect],
        fallbackVisibleFrame: CGRect
    ) -> CGRect {
        guard frame.width > 0, frame.height > 0 else {
            return initialFrame(in: fallbackVisibleFrame)
        }
        guard let targetVisibleFrame = visibleFrames.max(by: {
            intersectionArea(frame, $0) < intersectionArea(frame, $1)
        }), intersectionArea(frame, targetVisibleFrame) > 0 else {
            return initialFrame(in: fallbackVisibleFrame)
        }

        let width = min(max(frame.width, minimumSize.width), targetVisibleFrame.width)
        let height = min(max(frame.height, minimumSize.height), targetVisibleFrame.height)
        let minX = targetVisibleFrame.minX
        let maxX = targetVisibleFrame.maxX - width
        let minY = targetVisibleFrame.minY
        let maxY = targetVisibleFrame.maxY - height
        return CGRect(
            x: min(max(frame.minX, minX), maxX),
            y: min(max(frame.minY, minY), maxY),
            width: width,
            height: height
        )
    }

    private static func intersectionArea(_ lhs: CGRect, _ rhs: CGRect) -> Double {
        let intersection = lhs.intersection(rhs)
        guard !intersection.isNull else { return 0 }
        return intersection.width * intersection.height
    }
}

enum ReaderPageCachePolicy {
    static let minimumCostLimit = 128 * 1_024 * 1_024
    static let maximumCostLimit = 384 * 1_024 * 1_024

    static func costLimit(physicalMemory: UInt64 = ProcessInfo.processInfo.physicalMemory) -> Int {
        let proportional = Int(min(UInt64(Int.max), physicalMemory / 20))
        return min(max(proportional, minimumCostLimit), maximumCostLimit)
    }

    static func loadRange(center: Int, totalPages: Int, layout: ReaderLayoutMode) -> ClosedRange<Int>? {
        guard totalPages > 0 else { return nil }
        let radius = layout == .continuous ? 3 : 2
        let lowerBound = max(center - radius, 0)
        let upperBound = min(center + radius + (layout == .doublePage ? 1 : 0), totalPages - 1)
        return lowerBound...upperBound
    }

    static func retainedIndices<S: Sequence>(
        _ indices: S,
        center: Int,
        layout: ReaderLayoutMode
    ) -> Set<Int> where S.Element == Int {
        let radius = layout == .continuous ? 6 : 4
        return Set(indices.filter { abs($0 - center) <= radius })
    }

    static func evictedIndices(
        costs: [Int: Int],
        center: Int,
        visibleIndices: Set<Int>,
        costLimit: Int
    ) -> Set<Int> {
        var total = costs.values.reduce(0, +)
        guard total > costLimit else { return [] }
        var evicted: Set<Int> = []
        for index in costs.keys
            .filter({ !visibleIndices.contains($0) })
            .sorted(by: { abs($0 - center) > abs($1 - center) }) {
            evicted.insert(index)
            total -= costs[index] ?? 0
            if total <= costLimit { break }
        }
        return evicted
    }
}

enum ReaderThumbnailCachePolicy {
    static let maximumPixelSize = 320
    static let costLimit = 32 * 1_024 * 1_024
    static let prefetchRadius = 3
    static let maximumBatchSize = 7

    static func loadIndices(
        around center: Int,
        totalPages: Int,
        cachedIndices: Set<Int>,
        loadingIndices: Set<Int>
    ) -> [Int] {
        guard totalPages > 0 else { return [] }
        let clampedCenter = min(max(center, 0), totalPages - 1)
        let lowerBound = max(clampedCenter - prefetchRadius, 0)
        let upperBound = min(clampedCenter + prefetchRadius, totalPages - 1)
        return (lowerBound...upperBound)
            .filter { !cachedIndices.contains($0) && !loadingIndices.contains($0) }
            .sorted {
                let leftDistance = abs($0 - clampedCenter)
                let rightDistance = abs($1 - clampedCenter)
                return leftDistance == rightDistance ? $0 < $1 : leftDistance < rightDistance
            }
            .prefix(maximumBatchSize)
            .map(\.self)
    }

    static func evictedIndices(
        costs: [Int: Int],
        center: Int,
        visibleIndices: Set<Int>,
        costLimit: Int = costLimit
    ) -> Set<Int> {
        var total = costs.values.reduce(0, +)
        guard total > costLimit else { return [] }
        var evicted: Set<Int> = []
        for index in costs.keys
            .filter({ !visibleIndices.contains($0) })
            .sorted(by: { abs($0 - center) > abs($1 - center) }) {
            evicted.insert(index)
            total -= costs[index] ?? 0
            if total <= costLimit { break }
        }
        return evicted
    }
}
