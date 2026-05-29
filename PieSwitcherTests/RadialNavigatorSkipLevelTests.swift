import CoreGraphics
import XCTest
@testable import PieSwitcher

/// Covers the skip-single-window-level option (Bringr-93j.75): when on, an app with one
/// window (or none) opens no windows sub-wheel — committing the app acts on its single
/// window directly — while apps with two or more windows still open the sub-wheel. Kept
/// in its own file (like the other navigator topic suites) to stay within the lint length
/// limits. `FakeWindowSystem` / `StubEnumerationSource` are reused as the doubles.
@MainActor
final class RadialNavigatorSkipLevelTests: XCTestCase {

    func testSkipOnSingleWindowAppOpensNoSubWheelButStillRevealsTheApp() {
        let fixture = makeFixture()
        fixture.navigator.setSkipSingleWindowLevel(true)
        fixture.navigator.open(appNodes: fixture.appNodes)

        fixture.navigator.updateHover(.slice(level: 0, index: 1)) // Ghostty — one window

        // No second ring opens, and it counts as settled (not an empty-scan race).
        XCTAssertEqual(fixture.navigator.rings.count, 1)
        XCTAssertFalse(fixture.navigator.hasWindowSubWheel)
        XCTAssertTrue(fixture.navigator.subWheelSuppressed)
        // The app is still revealed/isolated so its single window is previewed.
        XCTAssertTrue(fixture.fake.isHidden(AppID(pid: 10)))
        XCTAssertFalse(fixture.fake.isHidden(AppID(pid: 20)))
        XCTAssertEqual(fixture.navigator.expandedAppIndex, 1)
    }

    func testSkipOnMultiWindowAppStillOpensTheSubWheel() {
        let fixture = makeFixture()
        fixture.navigator.setSkipSingleWindowLevel(true)
        fixture.navigator.open(appNodes: fixture.appNodes)

        fixture.navigator.updateHover(.slice(level: 0, index: 0)) // Chrome — two windows

        XCTAssertEqual(fixture.navigator.rings.count, 2)
        XCTAssertTrue(fixture.navigator.hasWindowSubWheel)
        XCTAssertFalse(fixture.navigator.subWheelSuppressed)
        XCTAssertEqual(fixture.navigator.rings[1].nodes.map(\.title), ["Inbox", "Docs"])
    }

    func testSkipOffSingleWindowAppOpensTheSubWheelAsBefore() {
        let fixture = makeFixture() // skip defaults off
        fixture.navigator.open(appNodes: fixture.appNodes)

        fixture.navigator.updateHover(.slice(level: 0, index: 1)) // Ghostty — one window

        XCTAssertEqual(fixture.navigator.rings.count, 2)
        XCTAssertFalse(fixture.navigator.subWheelSuppressed)
        XCTAssertEqual(fixture.navigator.rings[1].nodes.map(\.title), ["Terminal"])
    }

    func testSkipOnCommittingTheSuppressedAppActsOnIt() {
        let fixture = makeFixture()
        fixture.navigator.setSkipSingleWindowLevel(true)
        fixture.navigator.open(appNodes: fixture.appNodes)
        fixture.navigator.updateHover(.slice(level: 0, index: 1)) // Ghostty suppressed

        let result = fixture.navigator.commit(.slice(level: 0, index: 1))

        XCTAssertEqual(result, .app(AppID(pid: 20)))
        // Bringr-93j.88: preview = commit. The default hide-others reveal hid Chrome
        // (pid 10); commit keeps it hidden — only cancel restores.
        XCTAssertTrue(fixture.fake.isHidden(AppID(pid: 10)),
                      "Bringr-93j.88: commit no longer unhides apps the reveal hid")
        XCTAssertTrue(fixture.navigator.rings.isEmpty)
    }

    func testSkipOnMovingFromSuppressedAppToMultiWindowAppRebuildsSubWheel() {
        let fixture = makeFixture()
        fixture.navigator.setSkipSingleWindowLevel(true)
        fixture.navigator.open(appNodes: fixture.appNodes)
        fixture.navigator.updateHover(.slice(level: 0, index: 1)) // Ghostty suppressed (no ring)

        fixture.navigator.updateHover(.slice(level: 0, index: 0)) // jump to Chrome (two windows)

        XCTAssertEqual(fixture.navigator.rings.count, 2)
        XCTAssertFalse(fixture.navigator.subWheelSuppressed)
        XCTAssertEqual(fixture.navigator.rings[1].nodes.map(\.title), ["Inbox", "Docs"])
        XCTAssertEqual(fixture.navigator.expandedAppIndex, 0)
    }

    /// A one-window app is settled state, so re-hovering it must not re-resolve its windows
    /// — unlike the empty-scan race (Bringr-93j.31), which keeps retrying until it settles.
    func testSkipOnSingleWindowAppIsSuppressedAndNotReResolved() {
        var resolveCount = 0
        let app = MenuNode(
            id: MenuNodeID("app:10"), title: "Chrome", action: .expand,
            representedApp: AppID(pid: 10),
            children: .dynamic {
                resolveCount += 1
                return [MenuNode(id: MenuNodeID("w11"), title: "Inbox",
                                 action: .focusWindow(WindowID(app: AppID(pid: 10), token: 11)))]
            }
        )
        let fake = FakeWindowSystem(
            apps: [FakeWindowSystem.AppState(
                id: AppID(pid: 10), hidden: false,
                windows: [FakeWindowSystem.WindowState(
                    id: WindowID(app: AppID(pid: 10), token: 11), minimized: false)]
            )],
            frontmost: AppID(pid: 10)
        )
        let navigator = RadialNavigator(windowControl: WindowController(system: fake))
        navigator.setSkipSingleWindowLevel(true)
        navigator.open(appNodes: [app])

        navigator.updateHover(.slice(level: 0, index: 0))
        XCTAssertTrue(navigator.subWheelSuppressed)
        XCTAssertEqual(navigator.expandedAppIndex, 0)

        navigator.updateHover(.slice(level: 0, index: 0)) // re-hover must not churn
        XCTAssertEqual(resolveCount, 1)
        XCTAssertTrue(navigator.subWheelSuppressed)
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
