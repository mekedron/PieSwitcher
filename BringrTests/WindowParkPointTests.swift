import CoreGraphics
import XCTest
@testable import Bringr

/// Bringr-93j.32: the hide-others reveal parks an app's other windows off-screen with
/// AX `setPosition`. macOS shrinks a window's HEIGHT when its title bar is moved off the
/// bottom of every screen (the title-bar-reachability clamp), and reapplying the height
/// on restore races that clamp — the intermittent ~50/50 loss. The fix is to never
/// trigger the clamp: park far off-screen on X (the window still fully hides) while
/// keeping Y on the primary screen. This test locks that invariant in so a future change
/// cannot quietly send the park point back off the bottom and reintroduce the height loss.
@MainActor
final class WindowParkPointTests: XCTestCase {
    func testParkPointHidesOnXButKeepsYVerticallyOnScreen() {
        let point = WindowController.offScreenPoint
        XCTAssertGreaterThan(point.x, 10_000, "X is far off every display, so the window fully hides")
        XCTAssertGreaterThanOrEqual(point.y, 0, "Y is not above the screen top")
        XCTAssertLessThan(point.y, 600, "Y stays on the primary screen, so macOS never clamps the height")
    }
}
