// 本文件提供 BookCardMetrics 支撑工具，承载格式化、环境值、缓存或本地化等横切逻辑。

import CoreGraphics

struct BookCardMetrics: Equatable {
    static let defaultWidth = 128
    static let minimumWidth = 112
    static let maximumWidth = 176
    static let step = 8

    static let `default` = BookCardMetrics(width: defaultWidth)

    let width: Int

    var cardWidth: CGFloat {
        CGFloat(width)
    }

    var coverHeight: CGFloat {
        cardWidth * 180 / 128
    }

    var gridMinimumWidth: CGFloat {
        cardWidth + 14
    }

    var gridMaximumWidth: CGFloat {
        cardWidth + 32
    }

    var contentSpacing: CGFloat {
        4
    }

    var titleHeight: CGFloat {
        22
    }

    var infoRowHeight: CGFloat {
        16
    }

    var ratingHeight: CGFloat {
        16
    }

    var cardHeight: CGFloat {
        coverHeight
            + titleHeight
            + infoRowHeight
            + ratingHeight
            + contentSpacing * 3
    }

    static func normalizedWidth(_ value: Int) -> Int {
        let clamped = min(max(value, minimumWidth), maximumWidth)
        let offset = clamped - minimumWidth
        let roundedSteps = Int((Double(offset) / Double(step)).rounded())
        return min(max(minimumWidth + roundedSteps * step, minimumWidth), maximumWidth)
    }
}
