import AppKit
import XCTest

@MainActor
final class CoverPrivacyHoverUITests: XCTestCase {
    /// Use a running `verify.sh --ui` session with global blur and a one-second delay.
    /// Pass its UUID through TEST_RUNNER_NYAEH_COVER_QA when invoking xcodebuild.
    func testStationaryPointerRevealsPreviewAndExitRestoresProtection() throws {
        continueAfterFailure = false
        guard let session = ProcessInfo.processInfo.environment["NYAEH_COVER_QA"],
              UUID(uuidString: session) != nil else { throw XCTSkip("Requires an isolated cover-privacy QA session") }
        let bundle = "dev.gazelee.NyaEH.qa." + session
        try XCTSkipIf(NSRunningApplication.runningApplications(withBundleIdentifier: bundle).isEmpty,
                      "Start the configured QA app before running this test")
        let app = XCUIApplication(bundleIdentifier: bundle)
        app.activate()
        let settings = app.windows["com_apple_SwiftUI_Settings_window"]
        if !settings.exists { app.buttons["gearshape"].click() }
        defer { settings.buttons[XCUIIdentifierCloseWindow].click() }
        let scroll = settings.scrollViews.firstMatch
        let bar = settings.scrollBars.firstMatch
        for _ in 0..<4 {
            if !bar.exists || (bar.value as? NSNumber)?.doubleValue == 1 { break }
            scroll.scroll(byDeltaX: 0, deltaY: -130)
        }

        let seconds = settings.textFields["coverPrivacy.seconds"]
        XCTAssertEqual(seconds.value as? String, "1")
        let large = settings.descendants(matching: .any)["coverPrivacy.sample.100"].firstMatch
        let small = settings.descendants(matching: .any)["coverPrivacy.sample.48"].firstMatch
        let outside = settings.toolbars.firstMatch.coordinate(withNormalizedOffset: .init(dx: 0.1, dy: 0.5))
        let inside = large.coordinate(withNormalizedOffset: .init(dx: 0.3, dy: 0.4))
        outside.hover()
        let protected = try sample(large)
        let adjacent = try sample(small)
        inside.hover()
        outside.hover()
        Thread.sleep(forTimeInterval: 0.5)
        inside.hover()
        XCTAssertLessThan(try difference(sample(large), protected), 0.004)
        Thread.sleep(forTimeInterval: 1.4)
        XCTAssertGreaterThan(try difference(sample(large), protected), 0.02)
        XCTAssertLessThan(try difference(sample(small), adjacent), 0.004)
        outside.hover()
        Thread.sleep(forTimeInterval: 0.25) // Allow the blur to settle after pointer exit.
        XCTAssertLessThan(try difference(sample(large), protected), 0.004)
    }

    private func sample(_ element: XCUIElement) throws -> [CGFloat] {
        let image = try XCTUnwrap(NSBitmapImageRep(data: element.screenshot().pngRepresentation))
        var samples = [CGFloat]()
        for row in 1...12 {
            for column in 1...12 {
                let color = try XCTUnwrap(image.colorAt(x: image.pixelsWide * column / 13,
                                                        y: image.pixelsHigh * row / 13)?.usingColorSpace(.sRGB))
                samples.append(contentsOf: [color.redComponent, color.greenComponent, color.blueComponent])
            }
        }
        return samples
    }

    private func difference(_ lhs: [CGFloat], _ rhs: [CGFloat]) -> CGFloat {
        zip(lhs, rhs).reduce(0) { $0 + abs($1.0 - $1.1) } / CGFloat(lhs.count)
    }
}
