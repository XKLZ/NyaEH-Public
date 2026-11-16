// 本文件把系统内存压力转换成阅读器可订阅的通知，以便窗口立即丢弃非可见解码页。

import Combine
import Foundation

final class ReaderMemoryPressureMonitor: @unchecked Sendable {
    static let shared = ReaderMemoryPressureMonitor()
    static let notificationName = Notification.Name("NyaEH.ReaderMemoryPressure")

    private let source: DispatchSourceMemoryPressure

    var publisher: NotificationCenter.Publisher {
        NotificationCenter.default.publisher(for: Self.notificationName)
    }

    private init() {
        let source = DispatchSource.makeMemoryPressureSource(
            eventMask: [.warning, .critical],
            queue: .main
        )
        source.setEventHandler {
            NotificationCenter.default.post(name: Self.notificationName, object: nil)
        }
        source.resume()
        self.source = source
    }
}
