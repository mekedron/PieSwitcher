import CoreGraphics
import XCTest
@testable import Bringr

/// Exercises the optional second-level cursor lock (Bringr-93j.29) in `RadialNavigator`:
/// the engage-on-entering-the-sub-wheel / release-on-returning-to-the-parent state, and
/// the pure confinement geometry the controller warps the pointer against. Driven against
/// the same `FakeWindowSystem` + `StubEnumerationSource` doubles as `RadialNavigatorTests`.
@MainActor
final class RadialNavigatorCursorLockTests: XCTestCase {

    // MARK: - Engage / release state

    func testEnteringWindowSubWheelEngagesTheLockWhenEnabled() {
        let fixture = makeFixture()
        fixture.navigator.setCursorLockEnabled(true)
        fixture.navigator.open(appNodes: fixture.appNodes)

        fixture.navigator.updateHover(.slice(level: 0, index: 0)) // Chrome — apps ring
        XCTAssertFalse(fixture.navigator.cursorLockEngaged, "still on the apps ring — not yet locked")

        fixture.navigator.updateHover(.slice(level: 1, index: 0)) // a Chrome window
        XCTAssertTrue(fixture.navigator.cursorLockEngaged, "entering the sub-wheel engages the lock")
    }

    func testLockNeverEngagesWhenDisabled() {
        let fixture = makeFixture()
        fixture.navigator.setCursorLockEnabled(false)
        fixture.navigator.open(appNodes: fixture.appNodes)

        fixture.navigator.updateHover(.slice(level: 0, index: 0))
        fixture.navigator.updateHover(.slice(level: 1, index: 0))

        XCTAssertFalse(fixture.navigator.cursorLockEngaged, "the cursor moves freely when the setting is off")
    }

    func testReturningToTheParentAppArcReleasesTheLock() {
        let fixture = makeFixture()
        fixture.navigator.setCursorLockEnabled(true)
        fixture.navigator.open(appNodes: fixture.appNodes)
        fixture.navigator.updateHover(.slice(level: 0, index: 0))
        fixture.navigator.updateHover(.slice(level: 1, index: 0)) // locked
        XCTAssertTrue(fixture.navigator.cursorLockEngaged)

        fixture.navigator.updateHover(.slice(level: 0, index: 0)) // back onto the parent app arc

        XCTAssertFalse(fixture.navigator.cursorLockEngaged, "reaching the parent app arc releases the lock")
    }

    func testDisablingMidFlightClearsEngagement() {
        let fixture = makeFixture()
        fixture.navigator.setCursorLockEnabled(true)
        fixture.navigator.open(appNodes: fixture.appNodes)
        fixture.navigator.updateHover(.slice(level: 0, index: 0))
        fixture.navigator.updateHover(.slice(level: 1, index: 0))
        XCTAssertTrue(fixture.navigator.cursorLockEngaged)

        fixture.navigator.setCursorLockEnabled(false)

        XCTAssertFalse(fixture.navigator.cursorLockEngaged, "turning the lock off frees the pointer at once")
    }

    func testOpenAndCloseResetEngagement() {
        let fixture = makeFixture()
        fixture.navigator.setCursorLockEnabled(true)
        fixture.navigator.open(appNodes: fixture.appNodes)
        fixture.navigator.updateHover(.slice(level: 0, index: 0))
        fixture.navigator.updateHover(.slice(level: 1, index: 0))
        XCTAssertTrue(fixture.navigator.cursorLockEngaged)

        fixture.navigator.close()
        XCTAssertFalse(fixture.navigator.cursorLockEngaged, "close clears the lock")

        fixture.navigator.open(appNodes: fixture.appNodes)
        XCTAssertFalse(fixture.navigator.cursorLockEngaged, "a fresh summon starts unlocked")
    }

    // MARK: - Confinement geometry

    func testConfinementRegionAllowsWindowSlicesAndTheParentArcOnly() {
        let fixture = makeFixture()
        fixture.navigator.setCursorLockEnabled(true)
        fixture.navigator.open(appNodes: fixture.appNodes)
        fixture.navigator.updateHover(.slice(level: 0, index: 0)) // Chrome → [Inbox, Docs] sub-wheel

        let mid0 = fixture.navigator.ringGeometry(forLevel: 0).midRadius
        let mid1 = fixture.navigator.ringGeometry(forLevel: 1).midRadius
        let nav = fixture.navigator

        // Allowed: both window slices (level 1) and the parent app arc (level 0, Chrome).
        XCTAssertTrue(nav.offsetWithinCursorLockRegion(CGPoint(x: 0, y: -mid1)), "window 0 (up)")
        XCTAssertTrue(nav.offsetWithinCursorLockRegion(CGPoint(x: 0, y: mid1)), "window 1 (down)")
        XCTAssertTrue(nav.offsetWithinCursorLockRegion(CGPoint(x: 0, y: -mid0)), "parent app arc (Chrome, up)")

        // Rejected: another app arc, the dead centre, and outside every ring.
        XCTAssertFalse(nav.offsetWithinCursorLockRegion(CGPoint(x: 0, y: mid0)), "the other app arc (Ghostty, down)")
        XCTAssertFalse(nav.offsetWithinCursorLockRegion(.zero), "the dead zone")
        XCTAssertFalse(nav.offsetWithinCursorLockRegion(CGPoint(x: 0, y: -10000)), "outside the rings")
    }

    // MARK: - Fixtures

    private struct Fixture {
        let navigator: RadialNavigator
        let fake: FakeWindowSystem
        let appNodes: [MenuNode]
    }

    private func makeFixture() -> Fixture {
        let source = StubEnumerationSource(selfPID: 1, windows: [
            raw(number: 11, pid: 10, name: "Chrome", title: "Inbox"),
            raw(number: 12, pid: 10, name: "Chrome", title: "Docs"),
            raw(number: 21, pid: 20, name: "Ghostty", title: "Terminal")
        ])
        let appNodes = WindowSwitcherMenu(enumerator: WindowEnumerator(source: source))
            .makeRoot().resolvedChildren()
        let fake = FakeWindowSystem(
            apps: [
                FakeWindowSystem.AppState(id: AppID(pid: 10), hidden: false,
                                          windows: [win(10, 11), win(10, 12)]),
                FakeWindowSystem.AppState(id: AppID(pid: 20), hidden: false,
                                          windows: [win(20, 21)])
            ],
            frontmost: AppID(pid: 10)
        )
        let navigator = RadialNavigator(windowControl: WindowController(system: fake))
        return Fixture(navigator: navigator, fake: fake, appNodes: appNodes)
    }

    private func win(_ pid: pid_t, _ token: Int) -> FakeWindowSystem.WindowState {
        FakeWindowSystem.WindowState(id: WindowID(app: AppID(pid: pid), token: token), minimized: false)
    }

    private func raw(number: Int, pid: pid_t, name: String, title: String = "") -> RawWindow {
        RawWindow(
            windowNumber: number, ownerPID: pid, ownerName: name, title: title,
            layer: 0, alpha: 1, bounds: CGRect(x: 0, y: 0, width: 800, height: 600)
        )
    }
}
