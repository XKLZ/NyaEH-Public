// 本文件提供 BookCardMetrics 支撑工具，承载格式化、环境值、缓存或本地化等横切逻辑。

import CoreGraphics

struct BookCardMetrics: Equatable, Sendable {
    static let shelfSpacing: CGFloat = 18
    static let detailCornerRadius: CGFloat = 5
    static let badgeHeight: CGFloat = 16
    static let metadataRowHeight: CGFloat = 24
    static let scoreIconWidth: CGFloat = 20
    static let scorePadding: CGFloat = 4

    static func metadataSpacing(width: CGFloat) -> CGFloat { width < 128 ? 6 : 8 }

    // Linear sRGB luminance at which black and white have equal WCAG contrast.
    static func prefersDarkInk(linearRed: Float, green: Float, blue: Float) -> Bool {
        0.2126 * linearRed + 0.7152 * green + 0.0722 * blue > 0.17913
    }

    static let defaultWidth = 144
    static let minimumWidth = 112
    static let maximumWidth = 176
    static let step = 8

    static let `default` = BookCardMetrics(width: defaultWidth)

    enum Appearance: Hashable, Sendable { case standard, unified }

    let width: Int
    var appearance: Appearance = .unified

    var contentInset: CGFloat {
        guard appearance == .unified else { return 0 }
        return width < 128 ? 4 : 6
    }

    var contentWidth: CGFloat { max(0, cardWidth - 2 * contentInset) }
    var bottomInset: CGFloat { appearance == .unified ? 6 : 0 }
    var metadataOuterSpacing: CGFloat { appearance == .unified && width < 128 ? 0 : 4 }

    var cardWidth: CGFloat {
        CGFloat(width)
    }

    var coverHeight: CGFloat {
        appearance == .unified ? cardWidth * 5 / 4 : cardWidth * 180 / 128
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
        Self.badgeHeight
    }

    let infoSpacing: CGFloat = 8
    let readButtonWidth: CGFloat = 30
    let readButtonGap: CGFloat = 12

    var metadataHeight: CGFloat { Self.metadataRowHeight }

    var ratingHeight: CGFloat {
        Self.badgeHeight
    }

    // The related-book strips still use the one-line title metric.
    var regularTitleHeight: CGFloat { 38 }

    var cardHeight: CGFloat { cardHeight(for: .all) }

    func cardHeight(for fields: BookCardFields) -> CGFloat {
        let rows = [
            fields.isDisjoint(with: .metadata) ? 0 : metadataHeight,
            showsRatingRow(for: fields) ? ratingHeight : 0,
            fields.isDisjoint(with: .reading) ? 0 : infoRowHeight
        ].filter { $0 > 0 }
        return bottomInset + coverHeight + regularTitleHeight + contentSpacing + rows.reduce(0, +)
            + (rows.isEmpty ? 0 : contentSpacing + CGFloat(rows.count - 1) * infoSpacing)
    }

    var metadataTop: CGFloat { coverHeight + regularTitleHeight + contentSpacing * 2 }

    func showsRatingRow(for fields: BookCardFields) -> Bool {
        fields.contains(.rating) || (fields.contains(.directRead) && fields.isDisjoint(with: .reading))
    }

    func footerHeight(for fields: BookCardFields) -> CGFloat {
        let reading = !fields.isDisjoint(with: .reading)
        return (showsRatingRow(for: fields) ? ratingHeight + (reading ? infoSpacing : 0) : 0)
            + (reading ? infoRowHeight : 0)
    }

    static func pageLabelPosition(width: CGFloat, fill: CGFloat?, numberWidth: CGFloat) -> (x: CGFloat, onFill: Bool) {
        let boundary = min(width, max(0, fill ?? 0))
        let onFill = fill != nil && boundary >= numberWidth + 8
        let origin = onFill ? boundary - numberWidth - 4 : boundary + 4
        return (max(0, min(origin, width - numberWidth - 4)), onFill)
    }

    static func progressLabel(page: Int) -> String { "P" + String(page) }

    static func normalizedWidth(_ value: Int) -> Int {
        let clamped = min(max(value, minimumWidth), maximumWidth)
        let offset = clamped - minimumWidth
        let roundedSteps = Int((Double(offset) / Double(step)).rounded())
        return min(max(minimumWidth + roundedSteps * step, minimumWidth), maximumWidth)
    }
}
