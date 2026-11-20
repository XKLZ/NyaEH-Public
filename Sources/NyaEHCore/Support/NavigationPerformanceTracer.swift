// 本文件提供 NavigationPerformanceTracer 支撑工具，承载格式化、环境值、缓存或本地化等横切逻辑。

import Foundation
import OSLog
import CoreGraphics

enum BookOpenSource: String, Sendable {
    case home
    case search
    case library
    case workDetail
    case characterDetail
    case collectionDetail
    case management
    case bookDetail

    var usesAnimatedBookDetailTransition: Bool {
        self != .bookDetail
    }
}

@MainActor
enum NavigationPerformanceTracer {
    private struct Session {
        let source: BookOpenSource
        let bookID: String
        let startedAt: ContinuousClock.Instant
        let signpostState: OSSignpostIntervalState
    }

    private static let subsystem = Bundle.main.bundleIdentifier ?? "NyaEH"
    private static let logger = Logger(subsystem: subsystem, category: "NavigationPerformance")
    private static let signposter = OSSignposter(subsystem: subsystem, category: "NavigationPerformance")
    private static let clock = ContinuousClock()
    private static let processStartedAt = clock.now
    private static var activeSession: Session?
    private static var openStallTask: Task<Void, Never>?

    static func openBookStarted(source: BookOpenSource, bookID: String, returnDestinationID: String) {
        openStallTask?.cancel()
        openStallTask = nil
        let signpostID = signposter.makeSignpostID()
        let signpostState = signposter.beginInterval(
            "OpenBook",
            id: signpostID,
            "source=\(source.rawValue, privacy: .public) book=\(bookID, privacy: .public)"
        )
        activeSession = Session(
            source: source,
            bookID: bookID,
            startedAt: clock.now,
            signpostState: signpostState
        )
        logger.info(
            "openBook start source=\(source.rawValue, privacy: .public) book=\(bookID, privacy: .public) return=\(returnDestinationID, privacy: .public)"
        )
    }

    static func selectedBookDidSet(bookID: String) {
        logEvent("selectedBookID set", bookID: bookID)
    }

    static func destinationWillChange(bookID: String, destinationID: String) {
        logEvent("destination will change", bookID: bookID, extra: "destination=\(destinationID)")
    }

    static func destinationDidChange(bookID: String, destinationID: String) {
        logEvent("destination did change", bookID: bookID, extra: "destination=\(destinationID)")
        scheduleOpenStallWatchdog(bookID: bookID)
    }

    static func workDetailDidDisappear(tagID: Tag.DatabaseID) {
        guard let session = activeSession else {
            logger.info("workDetail disappear tag=\(tagID, privacy: .public) noActiveSession=true")
            return
        }
        logger.info(
            "workDetail disappear source=\(session.source.rawValue, privacy: .public) book=\(session.bookID, privacy: .public) tag=\(tagID, privacy: .public) elapsed=\(elapsedText(since: session.startedAt), privacy: .public)"
        )
    }

    static func characterDetailDidDisappear(tagID: Tag.DatabaseID) {
        guard let session = activeSession else {
            logger.info("characterDetail disappear tag=\(tagID, privacy: .public) noActiveSession=true")
            return
        }
        logger.info(
            "characterDetail disappear source=\(session.source.rawValue, privacy: .public) book=\(session.bookID, privacy: .public) tag=\(tagID, privacy: .public) elapsed=\(elapsedText(since: session.startedAt), privacy: .public)"
        )
    }

    static func workDetailShellDidAppear(tagID: Tag.DatabaseID) {
        logger.info("workDetail shell appear tag=\(tagID, privacy: .public)")
    }

    static func workDetailContentReady(tagID: Tag.DatabaseID, sectionCount: Int) {
        logger.info("workDetail content ready tag=\(tagID, privacy: .public) sections=\(sectionCount, privacy: .public)")
    }

    static func workTopicShelfVisibility(workID: Tag.DatabaseID, characterID: Tag.DatabaseID, visible: Bool) {
        logger.info("work topic shelf work=\(workID, privacy: .public) character=\(characterID, privacy: .public) visible=\(visible, privacy: .public)")
    }

    static func bookDetailDidAppear(bookID: String) {
        guard let session = activeSession, session.bookID == bookID else {
            logger.info("bookDetail appear book=\(bookID, privacy: .public) noMatchingSession=true")
            return
        }
        openStallTask?.cancel()
        openStallTask = nil
        logger.info(
            "bookDetail appear source=\(session.source.rawValue, privacy: .public) book=\(bookID, privacy: .public) elapsed=\(elapsedText(since: session.startedAt), privacy: .public)"
        )
        signposter.endInterval(
            "OpenBook",
            session.signpostState,
            "source=\(session.source.rawValue, privacy: .public) book=\(bookID, privacy: .public)"
        )
    }

    static func bookDetailDidDisappear(bookID: String) {
        logEvent("bookDetail disappear", bookID: bookID)
        guard let session = activeSession, session.bookID == bookID else {
            return
        }
        openStallTask?.cancel()
        openStallTask = nil
        activeSession = nil
    }

    static func bookDetailBuildStarted(bookID: String) {
        logEvent("bookDetail build start", bookID: bookID)
    }

    static func bookDetailSessionStarted(bookID: String, revision: Int) {
        logEvent("bookDetail session start", bookID: bookID, extra: "revision=\(revision)")
    }

    static func bookDetailSessionEnded(bookID: String, revision: Int) {
        logEvent("bookDetail session end", bookID: bookID, extra: "revision=\(revision)")
    }

    static func bookDetailStaleTaskSkipped(bookID: String, taskName: String) {
        logEvent("bookDetail stale task skipped", bookID: bookID, extra: "task=\(taskName)")
    }

    static func bookDetailScrollObserverAttached(bookID: String) {
        logEvent("bookDetail scrollObserver attach", bookID: bookID)
    }

    static func bookDetailScrollObserverStopped(bookID: String, reason: String) {
        logEvent("bookDetail scrollObserver stop", bookID: bookID, extra: "reason=\(reason)")
    }

    static func bookDetailScrollObserverDeinitialized(bookID: String) {
        logEvent("bookDetail scrollObserver deinit", bookID: bookID)
    }

    static func bookDetailMainColumnFirstFrameReady(bookID: String) {
        logEvent("mainColumn firstFrame ready", bookID: bookID)
    }

    static func bookDetailDeferredSectionsMounted(bookID: String) {
        logEvent("deferred sections mounted", bookID: bookID)
    }

    static func themeColorDidResolve(bookID: String, costMilliseconds: Double, cacheHit: Bool) {
        logEvent(
            "themeColor resolve did finish",
            bookID: bookID,
            extra: "cost=\(millisecondsText(costMilliseconds)) cacheHit=\(cacheHit)"
        )
    }

    static func coverThemeColorSlowResolve(bookID: String, costMilliseconds: Double) {
        guard costMilliseconds >= 16 else {
            return
        }
        logEvent("coverThemeColor slowResolve", bookID: bookID, extra: "cost=\(millisecondsText(costMilliseconds))")
    }

    static func displayTagsWillResolve(bookID: String) -> ContinuousClock.Instant {
        logEvent("displayTags will resolve", bookID: bookID)
        return clock.now
    }

    static func displayTagsDidResolve(
        bookID: String,
        startedAt: ContinuousClock.Instant,
        tagCount: Int
    ) {
        let cost = elapsedText(since: startedAt)
        logEvent("displayTags did resolve", bookID: bookID, extra: "cost=\(cost) tagCount=\(tagCount)")
    }

    static func bookDetailScrollFrame(
        bookID: String,
        offset: CGFloat,
        heroPhase: BookDetailScrollHeroPhase,
        state: inout BookDetailScrollFrameMetrics.State
    ) -> BookDetailScrollFrameMetrics.RecordResult {
        let timestamp = elapsedMilliseconds(since: processStartedAt)
        let result = state.record(offset: offset, timestampMilliseconds: timestamp, heroPhase: heroPhase)

        switch result {
        case .started:
            logEvent("bookDetail scroll start", bookID: bookID, extra: "offset=\(offsetText(offset))")
        case .ignored:
            break
        case .frame(let frame):
            if frame.isSlow {
                logEvent(
                    "bookDetail scroll slowFrame",
                    bookID: bookID,
                    extra: "phase=\(frame.heroPhase.rawValue) interval=\(millisecondsText(frame.intervalMilliseconds)) delta=\(offsetText(frame.offsetDelta)) offset=\(offsetText(offset))"
                )
            }
        }
        return result
    }

    static func bookDetailScrollDidPause(
        bookID: String,
        state: inout BookDetailScrollFrameMetrics.State
    ) {
        guard state.hasFrames else {
            state.reset()
            return
        }

        logEvent(
            "bookDetail scroll summary",
            bookID: bookID,
            extra: "frames=\(state.frameCount) slowFrames=\(state.slowFrameCount) maxInterval=\(millisecondsText(state.maxIntervalMilliseconds)) maxDelta=\(offsetText(state.maxOffsetDelta))"
        )
        state.reset()
    }

    static func heroLayoutWillMeasure() -> ContinuousClock.Instant {
        clock.now
    }

    static func heroLayoutDidMeasure(bookID: String, startedAt: ContinuousClock.Instant) {
        let cost = elapsedMilliseconds(since: startedAt)
        guard BookDetailScrollFrameMetrics.isSlowHeroLayout(milliseconds: cost) else {
            return
        }
        logEvent("bookDetail hero layout slow", bookID: bookID, extra: "cost=\(millisecondsText(cost))")
    }

    private static func logEvent(_ event: String, bookID: String, extra: String = "") {
        guard let session = activeSession, session.bookID == bookID else {
            logger.info("\(event, privacy: .public) book=\(bookID, privacy: .public) noMatchingSession=true \(extra, privacy: .public)")
            return
        }
        logger.info(
            "\(event, privacy: .public) source=\(session.source.rawValue, privacy: .public) book=\(bookID, privacy: .public) elapsed=\(elapsedText(since: session.startedAt), privacy: .public) \(extra, privacy: .public)"
        )
    }

    private static func scheduleOpenStallWatchdog(bookID: String) {
        openStallTask?.cancel()
        openStallTask = Task {
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else {
                return
            }

            await MainActor.run {
                guard let session = activeSession, session.bookID == bookID else {
                    return
                }
                logger.info(
                    "bookDetail open stall source=\(session.source.rawValue, privacy: .public) book=\(bookID, privacy: .public) elapsed=\(elapsedText(since: session.startedAt), privacy: .public) stage=beforeAppear"
                )
            }
        }
    }

    private static func elapsedText(since start: ContinuousClock.Instant) -> String {
        millisecondsText(elapsedMilliseconds(since: start))
    }

    private static func elapsedMilliseconds(since start: ContinuousClock.Instant) -> Double {
        let components = start.duration(to: clock.now).components
        return Double(components.seconds) * 1_000
            + Double(components.attoseconds) / 1_000_000_000_000_000
    }

    private static func millisecondsText(_ value: Double) -> String {
        String(format: "%.1fms", value)
    }

    private static func offsetText(_ value: CGFloat) -> String {
        String(format: "%.1f", Double(value))
    }
}

enum BookDetailScrollFrameMetrics {
    static let slowFrameThresholdMilliseconds = 33.0
    static let heroLayoutSlowThresholdMilliseconds = 8.0
    static let minimumTrackedOffsetDelta: CGFloat = 1.0

    struct Frame: Equatable {
        let intervalMilliseconds: Double
        let offsetDelta: CGFloat
        let heroPhase: BookDetailScrollHeroPhase
        let isSlow: Bool
    }

    enum RecordResult: Equatable {
        case started
        case ignored
        case frame(Frame)

        var shouldScheduleSummary: Bool {
            if case .frame = self {
                return true
            }
            return false
        }
    }

    struct State: Equatable {
        private(set) var lastTimestampMilliseconds: Double?
        private(set) var lastOffset: CGFloat?
        private(set) var frameCount = 0
        private(set) var slowFrameCount = 0
        private(set) var maxIntervalMilliseconds = 0.0
        private(set) var maxOffsetDelta: CGFloat = 0

        var hasFrames: Bool {
            frameCount > 0
        }

        mutating func record(
            offset: CGFloat,
            timestampMilliseconds: Double,
            heroPhase: BookDetailScrollHeroPhase
        ) -> RecordResult {
            guard let lastOffset, let lastTimestampMilliseconds else {
                self.lastOffset = offset
                self.lastTimestampMilliseconds = timestampMilliseconds
                return .started
            }

            let interval = max(timestampMilliseconds - lastTimestampMilliseconds, 0)
            let offsetDelta = abs(offset - lastOffset)
            self.lastTimestampMilliseconds = timestampMilliseconds

            guard shouldTrackOffsetDelta(offsetDelta) else {
                return .ignored
            }

            self.lastOffset = offset
            let isSlow = BookDetailScrollFrameMetrics.isSlowFrame(intervalMilliseconds: interval)
            frameCount += 1
            if isSlow {
                slowFrameCount += 1
            }
            maxIntervalMilliseconds = max(maxIntervalMilliseconds, interval)
            maxOffsetDelta = max(maxOffsetDelta, offsetDelta)
            return .frame(Frame(
                intervalMilliseconds: interval,
                offsetDelta: offsetDelta,
                heroPhase: heroPhase,
                isSlow: isSlow
            ))
        }

        mutating func reset() {
            lastTimestampMilliseconds = nil
            lastOffset = nil
            frameCount = 0
            slowFrameCount = 0
            maxIntervalMilliseconds = 0
            maxOffsetDelta = 0
        }
    }

    static func isSlowFrame(intervalMilliseconds: Double) -> Bool {
        intervalMilliseconds >= slowFrameThresholdMilliseconds
    }

    static func isSlowHeroLayout(milliseconds: Double) -> Bool {
        milliseconds >= heroLayoutSlowThresholdMilliseconds
    }

    static func shouldTrackOffsetDelta(_ delta: CGFloat) -> Bool {
        delta >= minimumTrackedOffsetDelta
    }
}

enum BookDetailScrollOffsetCoalescer {
    struct State: Equatable {
        var pendingOffset: CGFloat?
        var isPublishScheduled = false
    }

    enum Action: Equatable {
        case schedule
        case updatePendingOnly
    }

    static func record(offset: CGFloat, state: inout State) -> Action {
        state.pendingOffset = offset
        guard !state.isPublishScheduled else {
            return .updatePendingOnly
        }
        state.isPublishScheduled = true
        return .schedule
    }

    static func flush(state: inout State) -> CGFloat? {
        state.isPublishScheduled = false
        defer {
            state.pendingOffset = nil
        }
        return state.pendingOffset
    }

    static func reset(state: inout State) {
        state.pendingOffset = nil
        state.isPublishScheduled = false
    }
}

enum BookDetailScrollHeroPhase: String, Equatable {
    case expanded
    case collapsing
    case collapsed
}
