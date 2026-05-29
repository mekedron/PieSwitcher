import CoreGraphics
import XCTest
@testable import PieSwitcher

/// Exercises the hover-driven navigation core (US-010) against a fake window
/// system and a stub enumerator, with no AppKit overlay — the same pure-core
/// testing the other state machines use. `FakeWindowSystem` (WindowControlTests)
/// and `StubEnumerationSource` (MenuModelTests) are reused as the doubles.
@MainActor
final class RadialNavigatorTests: XCTestCase {

    // MARK: - open

    func testOpenShowsAppsRingWithNothingExpanded() {
        let fixture = makeFixture()
        fixture.navigator.open(appNodes: fixture.appNodes)

        XCTAssertEqual(fixture.navigator.rings.count, 1)
        XCTAssertEqual(fixture.navigator.rings[0].level, 0)
        XCTAssertEqual(fixture.navigator.rings[0].nodes.map(\.title), ["Chrome", "Ghostty"])
        XCTAssertNil(fixture.navigator.expandedAppIndex)
        XCTAssertEqual(fixture.navigator.hovered, .none)
        // Opening reveals nothing — every app stays visible.
        XCTAssertFalse(fixture.fake.isHidden(AppID(pid: 10)))
        XCTAssertFalse(fixture.fake.isHidden(AppID(pid: 20)))
        XCTAssertFalse(fixture.fake.isHidden(AppID(pid: 30)))
    }

    // MARK: - AC1 + AC2: isolate the hovered app, open its window sub-wheel

    func testHoveringAppIsolatesItAndOpensWindowSubWheel() {
        let fixture = makeFixture()
        fixture.navigator.open(appNodes: fixture.appNodes)

        fixture.navigator.updateHover(.slice(level: 0, index: 0)) // Chrome

        // AC1: every non-target app is hidden; the target stays visible.
        XCTAssertFalse(fixture.fake.isHidden(AppID(pid: 10)))
        XCTAssertTrue(fixture.fake.isHidden(AppID(pid: 20)))
        XCTAssertTrue(fixture.fake.isHidden(AppID(pid: 30)))
        // AC2: a level-2 sub-wheel of exactly Chrome's windows opens.
        XCTAssertEqual(fixture.navigator.rings.count, 2)
        XCTAssertEqual(fixture.navigator.rings[1].level, 1)
        XCTAssertEqual(fixture.navigator.rings[1].nodes.map(\.title), ["Inbox", "Docs"])
        XCTAssertEqual(fixture.navigator.expandedAppIndex, 0)
    }

    // MARK: - AC3: re-target on moving to a different app

    func testMovingToADifferentAppReTargetsAndRebuildsSubWheel() {
        let fixture = makeFixture()
        fixture.navigator.open(appNodes: fixture.appNodes)
        fixture.navigator.updateHover(.slice(level: 0, index: 0)) // Chrome

        fixture.navigator.updateHover(.slice(level: 0, index: 1)) // Ghostty

        XCTAssertTrue(fixture.fake.isHidden(AppID(pid: 10)))
        XCTAssertFalse(fixture.fake.isHidden(AppID(pid: 20)))
        XCTAssertTrue(fixture.fake.isHidden(AppID(pid: 30)))
        XCTAssertEqual(fixture.navigator.rings.count, 2)
        XCTAssertEqual(fixture.navigator.rings[1].nodes.map(\.title), ["Terminal"])
        XCTAssertEqual(fixture.navigator.expandedAppIndex, 1)
    }

    // MARK: - AC4: moving back out restores the other apps

    func testMovingBackOutRestoresTheOtherApps() {
        let fixture = makeFixture()
        fixture.navigator.open(appNodes: fixture.appNodes)
        fixture.navigator.updateHover(.slice(level: 0, index: 0)) // Chrome isolated

        fixture.navigator.updateHover(.none) // back out to the dead zone

        XCTAssertFalse(fixture.fake.isHidden(AppID(pid: 10)))
        XCTAssertFalse(fixture.fake.isHidden(AppID(pid: 20)))
        XCTAssertFalse(fixture.fake.isHidden(AppID(pid: 30)))
        XCTAssertEqual(fixture.navigator.rings.count, 1)
        XCTAssertNil(fixture.navigator.expandedAppIndex)
    }

    func testReHoveringTheSameAppIsIdempotent() {
        let fixture = makeFixture()
        fixture.navigator.open(appNodes: fixture.appNodes)
        fixture.navigator.updateHover(.slice(level: 0, index: 0))
        fixture.navigator.updateHover(.slice(level: 0, index: 0))

        XCTAssertEqual(fixture.navigator.expandedAppIndex, 0)
        XCTAssertEqual(fixture.navigator.rings.count, 2)
        XCTAssertFalse(fixture.fake.isHidden(AppID(pid: 10)))
        XCTAssertTrue(fixture.fake.isHidden(AppID(pid: 20)))
    }

    // MARK: - window-ring hover keeps the app expanded (the apps ring stays live)

    func testHoveringWindowRingKeepsAppExpanded() {
        let fixture = makeFixture()
        fixture.navigator.open(appNodes: fixture.appNodes)
        fixture.navigator.updateHover(.slice(level: 0, index: 0)) // Chrome expanded

        fixture.navigator.updateHover(.slice(level: 1, index: 0)) // a Chrome window

        XCTAssertEqual(fixture.navigator.expandedAppIndex, 0)
        XCTAssertEqual(fixture.navigator.rings.count, 2)
        XCTAssertTrue(fixture.fake.isHidden(AppID(pid: 20))) // still isolated
        XCTAssertEqual(fixture.navigator.hovered, .slice(level: 1, index: 0))
    }

    // MARK: - AC1: hovering a window raises it for preview, leaving siblings on screen (Bringr-93j.83)

    func testHoveringWindowRaisesItLeavingTheAppsOtherWindowsOnScreen() {
        let fixture = makeFixture()
        fixture.navigator.open(appNodes: fixture.appNodes)
        fixture.navigator.updateHover(.slice(level: 0, index: 0)) // Chrome → [Inbox, Docs]

        fixture.navigator.updateHover(.slice(level: 1, index: 1)) // Docs

        // Docs is raised to the front for preview; the default hide-others reveal no
        // longer parks/minimizes the app's siblings at the window level (Bringr-93j.83).
        XCTAssertEqual(fixture.fake.windows(of: AppID(pid: 10)).first,
                       WindowID(app: AppID(pid: 10), token: 12))
        assertOnScreen(11, fixture.fake) // Inbox stays on screen, not parked...
        assertOnScreen(12, fixture.fake)
        XCTAssertFalse(fixture.fake.isMinimized(WindowID(app: AppID(pid: 10), token: 11))) // ...nor minimized
        XCTAssertEqual(fixture.navigator.expandedWindowIndex, 1)
    }

    // MARK: - AC2: moving between window slices raises the new target

    func testMovingBetweenWindowSlicesRaisesNewTarget() {
        let fixture = makeFixture()
        fixture.navigator.open(appNodes: fixture.appNodes)
        fixture.navigator.updateHover(.slice(level: 0, index: 0)) // Chrome
        fixture.navigator.updateHover(.slice(level: 1, index: 0)) // Inbox raised

        fixture.navigator.updateHover(.slice(level: 1, index: 1)) // Docs

        // Docs is now front; both windows remain on screen (nothing parked).
        XCTAssertEqual(fixture.fake.windows(of: AppID(pid: 10)).first,
                       WindowID(app: AppID(pid: 10), token: 12))
        assertOnScreen(11, fixture.fake)
        assertOnScreen(12, fixture.fake)
        XCTAssertEqual(fixture.navigator.expandedWindowIndex, 1)
    }

    // MARK: - AC3: leaving the window ring restores the app's other windows

    func testMovingBackToAppsRingRestoresWindowsButKeepsAppIsolated() {
        let fixture = makeFixture()
        fixture.navigator.open(appNodes: fixture.appNodes)
        fixture.navigator.updateHover(.slice(level: 0, index: 0)) // Chrome
        fixture.navigator.updateHover(.slice(level: 1, index: 0)) // Inbox isolated (Docs hidden)

        fixture.navigator.updateHover(.slice(level: 0, index: 0)) // back to the apps ring

        // AC3: both windows are visible again (un-parked)...
        assertOnScreen(11, fixture.fake)
        assertOnScreen(12, fixture.fake)
        XCTAssertNil(fixture.navigator.expandedWindowIndex)
        // ...but the app stays isolated and its sub-wheel stays open.
        XCTAssertTrue(fixture.fake.isHidden(AppID(pid: 20)))
        XCTAssertEqual(fixture.navigator.rings.count, 2)
        XCTAssertEqual(fixture.navigator.expandedAppIndex, 0)
    }

    func testReHoveringTheSameWindowIsIdempotent() {
        let fixture = makeFixture()
        fixture.navigator.open(appNodes: fixture.appNodes)
        fixture.navigator.updateHover(.slice(level: 0, index: 0))
        fixture.navigator.updateHover(.slice(level: 1, index: 1)) // Docs raised
        fixture.navigator.updateHover(.slice(level: 1, index: 1)) // again

        XCTAssertEqual(fixture.navigator.expandedWindowIndex, 1)
        XCTAssertEqual(fixture.fake.windows(of: AppID(pid: 10)).first,
                       WindowID(app: AppID(pid: 10), token: 12)) // Docs still front
        assertOnScreen(11, fixture.fake)
        assertOnScreen(12, fixture.fake)
    }

    // MARK: - re-targeting a different app from a window restores the old windows

    func testReTargetingAppFromWindowRestoresOldWindowsAndRebuilds() {
        let fixture = makeFixture()
        fixture.navigator.open(appNodes: fixture.appNodes)
        fixture.navigator.updateHover(.slice(level: 0, index: 0)) // Chrome
        fixture.navigator.updateHover(.slice(level: 1, index: 0)) // Inbox isolated

        fixture.navigator.updateHover(.slice(level: 0, index: 1)) // jump to Ghostty

        // Chrome's windows are back on-screen (un-parked)...
        assertOnScreen(11, fixture.fake)
        assertOnScreen(12, fixture.fake)
        XCTAssertNil(fixture.navigator.expandedWindowIndex)
        // ...and Ghostty is now the isolated app with its own sub-wheel.
        XCTAssertFalse(fixture.fake.isHidden(AppID(pid: 20)))
        XCTAssertTrue(fixture.fake.isHidden(AppID(pid: 10)))
        XCTAssertEqual(fixture.navigator.rings[1].nodes.map(\.title), ["Terminal"])
        XCTAssertEqual(fixture.navigator.expandedAppIndex, 1)
    }

    // MARK: - dead zone and close both restore the isolated window

    func testMovingToDeadZoneRestoresWindowsAndApps() {
        let fixture = makeFixture()
        fixture.navigator.open(appNodes: fixture.appNodes)
        fixture.navigator.updateHover(.slice(level: 0, index: 0))
        fixture.navigator.updateHover(.slice(level: 1, index: 0)) // Inbox isolated

        fixture.navigator.updateHover(.none)

        assertOnScreen(11, fixture.fake)
        assertOnScreen(12, fixture.fake)
        XCTAssertFalse(fixture.fake.isHidden(AppID(pid: 20)))
        XCTAssertEqual(fixture.navigator.rings.count, 1)
        XCTAssertNil(fixture.navigator.expandedWindowIndex)
        XCTAssertNil(fixture.navigator.expandedAppIndex)
    }

    func testCloseRestoresTheIsolatedWindow() {
        let fixture = makeFixture()
        fixture.navigator.open(appNodes: fixture.appNodes)
        fixture.navigator.updateHover(.slice(level: 0, index: 0))
        fixture.navigator.updateHover(.slice(level: 1, index: 0)) // Inbox isolated

        fixture.navigator.close()

        assertOnScreen(11, fixture.fake)
        assertOnScreen(12, fixture.fake)
        XCTAssertNil(fixture.navigator.expandedWindowIndex)
    }

    // MARK: - close restores and clears

    func testCloseRestoresAndClears() {
        let fixture = makeFixture()
        fixture.navigator.open(appNodes: fixture.appNodes)
        fixture.navigator.updateHover(.slice(level: 0, index: 0))

        fixture.navigator.close()

        XCTAssertFalse(fixture.fake.isHidden(AppID(pid: 10)))
        XCTAssertFalse(fixture.fake.isHidden(AppID(pid: 20)))
        XCTAssertFalse(fixture.fake.isHidden(AppID(pid: 30)))
        XCTAssertTrue(fixture.navigator.rings.isEmpty)
        XCTAssertNil(fixture.navigator.expandedAppIndex)
        XCTAssertEqual(fixture.navigator.hovered, .none)
    }

    // MARK: - AC5: the sub-wheel is rebuilt from the live US-005 tree

    func testSubWheelReflectsLiveStateWhenReTargeting() {
        let fixture = makeFixture()
        fixture.navigator.open(appNodes: fixture.appNodes)
        fixture.navigator.updateHover(.slice(level: 0, index: 0))
        XCTAssertEqual(fixture.navigator.rings[1].nodes.map(\.title), ["Inbox", "Docs"])

        // A new Chrome window appears; re-targeting Chrome rebuilds from live state
        // through the dynamic provider, not a snapshot taken at open.
        fixture.source.windows.append(raw(number: 13, pid: 10, name: "Chrome", title: "Calendar"))
        fixture.navigator.updateHover(.slice(level: 0, index: 1)) // Ghostty
        fixture.navigator.updateHover(.slice(level: 0, index: 0)) // back to Chrome

        XCTAssertEqual(fixture.navigator.rings[1].nodes.map(\.title), ["Inbox", "Docs", "Calendar"])
    }

    // MARK: - multi-ring hit-testing

    func testRegionHitTestsAcrossConcentricRings() {
        let fixture = makeFixture()
        fixture.navigator.open(appNodes: fixture.appNodes)
        fixture.navigator.updateHover(.slice(level: 0, index: 0)) // two rings now

        let mid0 = fixture.navigator.ringGeometry(forLevel: 0).midRadius
        let mid1 = fixture.navigator.ringGeometry(forLevel: 1).midRadius
        // Slice 0 is centred straight up: (0, -radius) in the y-down layout space.
        XCTAssertEqual(fixture.navigator.region(forOffset: CGPoint(x: 0, y: -mid0)),
                       .slice(level: 0, index: 0))
        XCTAssertEqual(fixture.navigator.region(forOffset: CGPoint(x: 0, y: -mid1)),
                       .slice(level: 1, index: 0))
        XCTAssertEqual(fixture.navigator.region(forOffset: .zero), .none)                   // dead zone
        XCTAssertEqual(fixture.navigator.region(forOffset: CGPoint(x: 0, y: -1000)), .none) // outside
    }

    // MARK: - concentric geometry bands

    func testRingBandsAndOverallDiameter() {
        let navigator = RadialNavigator(
            windowControl: WindowController(system: FakeWindowSystem(apps: [], frontmost: nil)),
            baseGeometry: RadialGeometry(innerRadius: 50, outerRadius: 150),
            maxDepth: 2
        )
        XCTAssertEqual(navigator.ringGeometry(forLevel: 0),
                       RadialGeometry(innerRadius: 50, outerRadius: 150))
        XCTAssertEqual(navigator.ringGeometry(forLevel: 1),
                       RadialGeometry(innerRadius: 150, outerRadius: 250))
        XCTAssertEqual(navigator.overallDiameter, 500, accuracy: 0.0001)
    }

    // MARK: - Fixtures

    private struct Fixture {
        let navigator: RadialNavigator
        let fake: FakeWindowSystem
        let source: StubEnumerationSource
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
        // The fake's window tokens match the enumerator's window numbers (11/12 for
        // Chrome, 21 for Ghostty), so a target carried by a window node resolves to
        // the same window the controller operates on — the US-003↔US-004 reconciliation.
        let fake = FakeWindowSystem(
            apps: [
                FakeWindowSystem.AppState(id: AppID(pid: 10), hidden: false,
                                          windows: [win(10, 11), win(10, 12)]),
                FakeWindowSystem.AppState(id: AppID(pid: 20), hidden: false,
                                          windows: [win(20, 21)]),
                FakeWindowSystem.AppState(id: AppID(pid: 30), hidden: false, windows: [])
            ],
            frontmost: AppID(pid: 10)
        )
        let navigator = RadialNavigator(windowControl: WindowController(system: fake))
        return Fixture(navigator: navigator, fake: fake, source: source, appNodes: appNodes)
    }

    private func win(_ pid: pid_t, _ token: Int) -> FakeWindowSystem.WindowState {
        FakeWindowSystem.WindowState(id: WindowID(app: AppID(pid: pid), token: token), minimized: false)
    }

    /// Every window here belongs to Chrome (pid 10). With no reveal parking windows
    /// at the window level (Bringr-93j.83/.84), the only way a window goes off-screen
    /// during a reveal is to be minimized — assert it isn't.
    private func assertOnScreen(_ token: Int, _ fake: FakeWindowSystem, line: UInt = #line) {
        XCTAssertFalse(fake.isMinimized(WindowID(app: AppID(pid: 10), token: token)),
                       "window \(token) should be on-screen (not minimized)", line: line)
    }

    private func raw(number: Int, pid: pid_t, name: String, title: String = "") -> RawWindow {
        RawWindow(
            windowNumber: number, ownerPID: pid, ownerName: name, title: title,
            layer: 0, alpha: 1, bounds: CGRect(x: 0, y: 0, width: 800, height: 600)
        )
    }
}
