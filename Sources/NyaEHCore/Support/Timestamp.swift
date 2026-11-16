// 本文件提供 Timestamp 支撑工具，承载格式化、环境值、缓存或本地化等横切逻辑。

import Foundation

enum Timestamp {
    static func nowMilliseconds() -> Int64 {
        Int64((Date().timeIntervalSince1970 * 1000).rounded())
    }
}
