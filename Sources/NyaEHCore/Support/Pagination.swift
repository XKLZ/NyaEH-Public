// 本文件提供 Pagination 支撑工具，承载格式化、环境值、缓存或本地化等横切逻辑。

import Foundation

enum PageSizeOption: Int, CaseIterable, Identifiable, Sendable {
    case twenty = 20
    case thirty = 30
    case fifty = 50
    case hundred = 100

    var id: Int { rawValue }

    static var defaultValue: Int { thirty.rawValue }
    static var allowedValues: [Int] { allCases.map(\.rawValue) }
}

enum Pagination {
    static func pageCount(itemCount: Int, pageSize: Int) -> Int {
        guard pageSize > 0 else {
            return 1
        }
        return max(1, Int(ceil(Double(itemCount) / Double(pageSize))))
    }

    static func clampedPage(_ page: Int, itemCount: Int, pageSize: Int) -> Int {
        min(max(page, 1), pageCount(itemCount: itemCount, pageSize: pageSize))
    }

    static func pageItems<T>(_ items: [T], page: Int, pageSize: Int) -> [T] {
        guard pageSize > 0 else {
            return []
        }

        let clamped = clampedPage(page, itemCount: items.count, pageSize: pageSize)
        let startIndex = (clamped - 1) * pageSize
        guard startIndex < items.count else {
            return []
        }

        let endIndex = min(startIndex + pageSize, items.count)
        return Array(items[startIndex..<endIndex])
    }
}
