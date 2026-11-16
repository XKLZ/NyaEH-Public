// 本文件提供显式启用的 Search 连续滚动基准配置与 signpost；正常运行不会启用任何自动滚动。

import Foundation
import OSLog

enum SearchScrollBenchmarkConfiguration {
    static let environmentKey = "NYAEH_SEARCH_SCROLL_BENCHMARK"
    static let defaultDurationSeconds = 15.0

    static var isEnabled: Bool {
        ProcessInfo.processInfo.environment[environmentKey] == "1"
    }
}

@MainActor
enum SearchScrollBenchmarkTracer {
    private static let subsystem = Bundle.main.bundleIdentifier ?? "NyaEH"
    private static let logger = Logger(subsystem: subsystem, category: "SearchScrollBenchmark")
    private static let signposter = OSSignposter(subsystem: subsystem, category: "SearchScrollBenchmark")

    static func begin(itemCount: Int, layout: SearchResultLayout) -> OSSignpostIntervalState {
        logger.info(
            "continuous scroll begin items=\(itemCount, privacy: .public) layout=\(layout.rawValue, privacy: .public)"
        )
        return signposter.beginInterval(
            "ContinuousScroll",
            "items=\(itemCount, privacy: .public) layout=\(layout.rawValue, privacy: .public)"
        )
    }

    static func end(_ state: OSSignpostIntervalState) {
        signposter.endInterval("ContinuousScroll", state)
        logger.info("continuous scroll end")
    }
}
