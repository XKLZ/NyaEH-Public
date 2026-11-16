// 本文件提供 DateCoding 支撑工具，承载格式化、环境值、缓存或本地化等横切逻辑。

import Foundation

enum DateCoding {
    private static func makeFormatter() -> ISO8601DateFormatter {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }

    static func string(from date: Date) -> String {
        makeFormatter().string(from: date)
    }

    static func date(from string: String) -> Date {
        makeFormatter().date(from: string) ?? Date(timeIntervalSince1970: 0)
    }
}
