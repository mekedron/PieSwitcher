import CoreGraphics
import XCTest
@testable import PieSwitcher

/// Exercises the Bringr-93j.39 launch branch of `RadialNavigator.commit`: a curated
/// "My Apps" slice that has no window to focus (it isn't running, or is running with no
/// on-screen windows) starts the app by bundle id instead of activating a front window.
///
/// Kept in its own file (the commit suite is already near the lint type-body limit) and
/// driven against `FakeWindowSystem` plus a recording `FakeAppLauncher`, so the launch
/// is asserted without starting real apps — the same pure-core testing as the sibling
/// commit and hover suites.
@MainActor
final class RadialNavigatorLaunchTests: XCTestCase {

    func testCommittingALaunchSliceStartsTheAppByBundleIDAndReturnsLaunch() {
        let launcher = FakeAppLauncher()
        let fake = FakeWindowSystem(apps: [], frontmost: nil)
        let navigator = RadialNavigator(
            windowControl: WindowController(system: fake),
            store: makeEphemeralStore(),
            appLauncher: launcher
        )
        navigator.open(appNodes: [launchNode(bundleID: "com.example.calendar", title: "Calendar")])
        navigator.updateHover(.slice(level: 0, index: 0)) // not running: empty sub-wheel, no reveal

        let committed = navigator.commit(.slice(level: 0, index: 0))

        XCTAssertEqual(committed, .launch(bundleIdentifier: "com.example.calendar"))
        XCTAssertEqual(launcher.launched, ["com.example.calendar"])
        XCTAssertNil(fake.focusedWindow, "a launch focuses no window")
        XCTAssertTrue(navigator.rings.isEmpty, "the wheel is cleared after a launch commit")
        XCTAssertNil(navigator.expandedAppIndex)
    }

    func testLaunchCommitEndsSessionWithoutRestoringRevealedApps() {
        // Bringr-93j.88: preview = commit. A launch slice ends the session WITHOUT
        // restoring the apps a prior hover revealed — the launched app comes forward
        // on its own, and any reveal state (hidden apps, raised windows) stays as the
        // final state. Only cancel paths call restore now.
        let launcher = FakeAppLauncher()
        let fake = FakeWindowSystem(
            apps: [
                FakeWindowSystem.AppState(id: AppID(pid: 10), hidden: false, windows: [win(10, 11)]),
                FakeWindowSystem.AppState(id: AppID(pid: 20), hidden: false, windows: [win(20, 21)])
            ],
            frontmost: AppID(pid: 10)
        )
        let controller = WindowController(system: fake)
        // Pin `.hideOthers` so the "reveal hid the other app" assertion below still
        // holds — the default flipped to `.raiseToFront` in Bringr-93j.93, which hides
        // nothing on hover.
        controller.setStrategy(.hideOthers)
        let navigator = RadialNavigator(
            windowControl: controller,
            store: makeEphemeralStore(),
            appLauncher: launcher
        )
        navigator.open(appNodes: [
            runningAppNode(pid: 10, title: "Chrome"),
            launchNode(bundleID: "com.example.calendar", title: "Calendar")
        ])
        navigator.updateHover(.slice(level: 0, index: 0)) // reveal Chrome → hide pid 20
        XCTAssertTrue(fake.isHidden(AppID(pid: 20)), "hovering the running app hid the other app")
        navigator.updateHover(.slice(level: 0, index: 1)) // glide onto the not-running launch slice

        let committed = navigator.commit(.slice(level: 0, index: 1))

        XCTAssertEqual(committed, .launch(bundleIdentifier: "com.example.calendar"))
        XCTAssertEqual(launcher.launched, ["com.example.calendar"])
        XCTAssertTrue(fake.isHidden(AppID(pid: 20)),
                      "Bringr-93j.88: launch commit no longer unhides apps the reveal hid")
        XCTAssertTrue(navigator.rings.isEmpty)
    }

    func testCommittingARunningAppStillFocusesEvenWhenItCarriesABundleID() {
        // A curated app that *is* running carries a bundle id but keeps `.expand`; the
        // commit path gates launching on the action, so it focuses rather than relaunches.
        let launcher = FakeAppLauncher()
        let fake = FakeWindowSystem(
            apps: [FakeWindowSystem.AppState(id: AppID(pid: 10), hidden: false, windows: [win(10, 11)])],
            frontmost: AppID(pid: 10)
        )
        let navigator = RadialNavigator(
            windowControl: WindowController(system: fake),
            store: makeEphemeralStore(),
            appLauncher: launcher
        )
        navigator.open(appNodes: [
            runningCuratedAppNode(pid: 10, bundleID: "com.example.chrome", title: "Chrome")
        ])
        navigator.updateHover(.slice(level: 0, index: 0))

        let committed = navigator.commit(.slice(level: 0, index: 0))

        XCTAssertEqual(committed, .app(AppID(pid: 10)))
        XCTAssertTrue(launcher.launched.isEmpty, "a running app focuses; it is never launched")
        XCTAssertEqual(fake.focusedWindow, WindowID(app: AppID(pid: 10), token: 11))
    }

    // MARK: - Builders

    /// An app slice for a curated entry that isn't running: a bundle id and the launch
    /// action, no pid, and (as a not-running app) no windows.
    private func launchNode(bundleID: String, title: String) -> MenuNode {
        MenuNode(
            id: MenuNodeID("app:\(bundleID)"),
            title: title,
            action: .launchApp(bundleIdentifier: bundleID),
            bundleIdentifier: bundleID
        )
    }

    /// A live-enumeration app slice: a pid and the expand action, no bundle id.
    private func runningAppNode(pid: pid_t, title: String) -> MenuNode {
        MenuNode(
            id: MenuNodeID("app:\(pid)"),
            title: title,
            action: .expand,
            representedApp: AppID(pid: pid)
        )
    }

    /// A curated app that is currently running: it carries both a pid and a bundle id but
    /// keeps `.expand`, so it focuses (never launches) on commit.
    private func runningCuratedAppNode(pid: pid_t, bundleID: String, title: String) -> MenuNode {
        MenuNode(
            id: MenuNodeID("app:\(pid)"),
            title: title,
            action: .expand,
            representedApp: AppID(pid: pid),
            bundleIdentifier: bundleID
        )
    }

    private func win(_ pid: pid_t, _ token: Int) -> FakeWindowSystem.WindowState {
        FakeWindowSystem.WindowState(id: WindowID(app: AppID(pid: pid), token: token), minimized: false)
    }

    /// A `LastSelectionStore` over a throwaway suite, torn down after the test, so the
    /// navigator's remember/pre-highlight never touch `.standard`.
    private func makeEphemeralStore() -> LastSelectionStore {
        let suite = "PieSwitcherTests.RadialNavigatorLaunch.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        addTeardownBlock { UserDefaults.standard.removePersistentDomain(forName: suite) }
        return LastSelectionStore(defaults: defaults)
    }
}
