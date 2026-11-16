import CoreGraphics

/// Screen coordinates, with a bottom-left origin, as used by NSWindow.convertToScreen.
enum ManagementHoverPreviewPlacement {
    static let margin: CGFloat = 12
    static let gap: CGFloat = 8

    static func size(in visibleFrame: CGRect) -> CGSize {
        CGSize(width: min(360, max(1, visibleFrame.width - margin * 2)),
               height: min(420, max(1, visibleFrame.height - margin * 2)))
    }

    static func frame(anchor: CGRect, visibleFrame: CGRect) -> CGRect {
        frame(anchor: anchor, previewSize: size(in: visibleFrame), visibleFrame: visibleFrame)
    }

    static func frame(anchor: CGRect, previewSize: CGSize, visibleFrame: CGRect) -> CGRect {
        let limit = size(in: visibleFrame)
        let size = CGSize(width: min(limit.width, previewSize.width), height: min(limit.height, previewSize.height))
        let bounds = visibleFrame.insetBy(dx: min(margin, visibleFrame.width / 4),
                                         dy: min(margin, visibleFrame.height / 4))
        let left = CGRect(x: anchor.minX - gap - size.width, y: anchor.midY - size.height / 2,
                          width: size.width, height: size.height)
        let right = CGRect(x: anchor.maxX + gap, y: left.minY, width: size.width, height: size.height)
        let above = CGRect(x: anchor.midX - size.width / 2, y: anchor.maxY + gap,
                           width: size.width, height: size.height)
        let below = CGRect(x: above.minX, y: anchor.minY - gap - size.height,
                           width: size.width, height: size.height)
        let candidates = [left, right, above, below]
        // Prefer horizontal placements even when their vertical position needs clamping.
        let preferred = candidates.first { $0.minX >= bounds.minX && $0.maxX <= bounds.maxX &&
            ($0 == left || $0 == right || ($0.minY >= bounds.minY && $0.maxY <= bounds.maxY))
        } ?? candidates.max { intersectionArea($0, bounds) < intersectionArea($1, bounds) } ?? left
        return CGRect(x: min(max(preferred.minX, bounds.minX), max(bounds.minX, bounds.maxX - size.width)),
                      y: min(max(preferred.minY, bounds.minY), max(bounds.minY, bounds.maxY - size.height)),
                      width: size.width, height: size.height)
    }

    private static func intersectionArea(_ rect: CGRect, _ bounds: CGRect) -> CGFloat {
        let overlap = rect.intersection(bounds)
        return overlap.isNull ? 0 : overlap.width * overlap.height
    }
}
