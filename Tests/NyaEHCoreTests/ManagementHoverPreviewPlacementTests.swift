import CoreGraphics
import Testing
@testable import NyaEHCore

@Suite("Management hover preview placement")
struct ManagementHoverPreviewPlacementTests {
    private let screen = CGRect(x: 100, y: 100, width: 1440, height: 900)

    @Test("left side is preferred, without covering the source card")
    func prefersLeft() {
        let anchor = CGRect(x: 1000, y: 500, width: 350, height: 80)
        let frame = ManagementHoverPreviewPlacement.frame(anchor: anchor, visibleFrame: screen)
        #expect(frame.size == CGSize(width: 360, height: 420))
        #expect(frame.maxX == anchor.minX - 8)
        #expect(!frame.intersects(anchor))
    }

    @Test("right side is used when the source is near the left edge")
    func fallsBackRight() {
        let anchor = CGRect(x: 112, y: 500, width: 350, height: 80)
        let frame = ManagementHoverPreviewPlacement.frame(anchor: anchor, visibleFrame: screen)
        #expect(frame.minX == anchor.maxX + 8)
        #expect(!frame.intersects(anchor))
    }

    @Test("top and bottom edge positions remain inside the screen", arguments: [105.0, 950.0])
    func clampsVertically(y: Double) {
        let frame = ManagementHoverPreviewPlacement.frame(
            anchor: CGRect(x: 1000, y: y, width: 350, height: 80), visibleFrame: screen)
        #expect(screen.insetBy(dx: 12, dy: 12).contains(frame))
    }

    @Test("narrow screens use available space above or below", arguments: [200.0, 700.0])
    func fallsBackVertically(y: Double) {
        let bounds = CGRect(x: 0, y: 0, width: 400, height: 1000)
        let anchor = CGRect(x: 100, y: y, width: 200, height: 80)
        let frame = ManagementHoverPreviewPlacement.frame(
            anchor: anchor, previewSize: CGSize(width: 360, height: 240), visibleFrame: bounds)
        #expect(bounds.insetBy(dx: 12, dy: 12).contains(frame))
        #expect(!frame.intersects(anchor))
    }

    @Test("oversized preview is constrained to a small available screen")
    func constrainsSize() {
        let bounds = CGRect(x: -500, y: -200, width: 300, height: 350)
        let frame = ManagementHoverPreviewPlacement.frame(
            anchor: CGRect(x: -450, y: -100, width: 200, height: 80),
            previewSize: CGSize(width: 500, height: 700), visibleFrame: bounds)
        #expect(frame.size == CGSize(width: 276, height: 326))
        #expect(bounds.insetBy(dx: 12, dy: 12).contains(frame))
    }
}
