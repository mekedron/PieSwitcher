import XCTest
@testable import PieSwitcher

/// Covers the "leave only my selection on screen" behaviour `WindowController.commit`
/// performs when the setting is on (Bringr-93j.27, Bringr-93j.49), kept in its own file so
/// `WindowControlTests` stays within the lint length limits. The persistence helper is
/// covered by `HideOnCommitTests`; the navigator wiring by `RadialNavigatorCommitTests`.
@MainActor
final class WindowControlHideOnCommitTests: XCTestCase {

    func testWindowCommitHidesOtherAppsButKeepsSiblingsVisible() {
        let appA = AppID(pid: 1)
        let target = WindowID(app: appA, token: 11)
        let sibling = WindowID(app: appA, token: 10)
        let fake = FakeWindowSystem(
            apps: [makeApp(1, windowTokens: [10, 11]), makeApp(2, windowTokens: [20])],
            frontmost: appA
        )
        let controller = WindowController(system: fake)
        controller.setHideOnCommit(true)

        controller.commit(target)

        // The other app hides, but the chosen app's sibling stays on screen — hiding never
        // applies within the selected app; only it is activated (Bringr-93j.49).
        XCTAssertFalse(fake.isMinimized(sibling))
        XCTAssertTrue(fake.isHidden(AppID(pid: 2)))
        // The selection itself is surfaced, focused, and frontmost — never minimized/hidden.
        XCTAssertFalse(fake.isMinimized(target))
        XCTAssertEqual(fake.focusedWindow, target)
        XCTAssertEqual(fake.frontmost, appA)
        XCTAssertFalse(fake.isHidden(appA))
    }

    func testWindowCommitWithSettingOffLeavesEverythingElseInPlace() {
        let appA = AppID(pid: 1)
        let target = WindowID(app: appA, token: 11)
        let sibling = WindowID(app: appA, token: 10)
        let fake = FakeWindowSystem(
            apps: [makeApp(1, windowTokens: [10, 11]), makeApp(2, windowTokens: [20])],
            frontmost: appA
        )
        let controller = WindowController(system: fake)
        // Default off: a commit behaves exactly as before — nothing extra is hidden.

        controller.commit(target)

        XCTAssertFalse(fake.isMinimized(sibling))
        XCTAssertFalse(fake.isHidden(AppID(pid: 2)))
        XCTAssertEqual(fake.focusedWindow, target)
    }

    func testAppCommitHidesOtherAppsButKeepsAllItsWindowsVisible() {
        let appA = AppID(pid: 1)
        let frontWindow = WindowID(app: appA, token: 10)
        let otherWindow = WindowID(app: appA, token: 11)
        let fake = FakeWindowSystem(
            apps: [makeApp(1, windowTokens: [10, 11]), makeApp(2, windowTokens: [20])],
            frontmost: AppID(pid: 2)
        )
        let controller = WindowController(system: fake)
        controller.setHideOnCommit(true)

        controller.commit(appA)

        // App-level commit hides the other apps but keeps ALL of the chosen app's windows on
        // screen, activating its front one — nothing within the app minimizes (Bringr-93j.49).
        XCTAssertEqual(fake.focusedWindow, frontWindow)
        XCTAssertEqual(fake.frontmost, appA)
        XCTAssertFalse(fake.isMinimized(otherWindow))
        XCTAssertTrue(fake.isHidden(AppID(pid: 2)))
        XCTAssertFalse(fake.isMinimized(frontWindow))
    }

    func testAppCommitWithNoWindowsStillHidesOtherApps() {
        let appA = AppID(pid: 1)
        let fake = FakeWindowSystem(
            apps: [makeApp(1), makeApp(2, windowTokens: [20])],
            frontmost: AppID(pid: 2)
        )
        let controller = WindowController(system: fake)
        controller.setHideOnCommit(true)

        controller.commit(appA)

        // No window to keep, but the other app is still cleared off so only app 1 remains.
        XCTAssertEqual(fake.frontmost, appA)
        XCTAssertTrue(fake.isHidden(AppID(pid: 2)))
        XCTAssertFalse(fake.isHidden(appA))
    }

    // MARK: - Bringr-93j.61: a windowless app commit reopens (opens a new window)

    func testAppCommitWithNoWindowsReopensTheAppInsteadOfBareActivate() {
        // An app picked from the wheel that currently has no window (e.g. Calendar closed to
        // the menu bar) must get a fresh window like a Dock click, not just be activated.
        let appA = AppID(pid: 1)
        let fake = FakeWindowSystem(
            apps: [makeApp(1), makeApp(2, windowTokens: [20])],
            frontmost: AppID(pid: 2)
        )
        let controller = WindowController(system: fake)

        controller.commit(appA)

        XCTAssertTrue(fake.operationLog.contains(.reopen(appA)),
                      "committing a windowless app reopens it to make a new window")
        XCTAssertEqual(fake.frontmost, appA, "the reopened app comes to the front")
    }

    func testAppCommitWithAWindowFocusesItAndNeverReopens() {
        // The other side of the branch: an app that still has a window focuses it through the
        // normal path and never posts a reopen, so no spurious extra window is made.
        let appA = AppID(pid: 1)
        let window = WindowID(app: appA, token: 10)
        let fake = FakeWindowSystem(
            apps: [makeApp(1, windowTokens: [10]), makeApp(2, windowTokens: [20])],
            frontmost: AppID(pid: 2)
        )
        let controller = WindowController(system: fake)

        controller.commit(appA)

        XCTAssertEqual(fake.focusedWindow, window)
        XCTAssertFalse(fake.operationLog.contains(.reopen(appA)),
                       "an app with a window focuses it; it is never reopened")
    }

    // MARK: - Fixtures

    private func makeApp(_ pid: pid_t, windowTokens: [Int] = []) -> FakeWindowSystem.AppState {
        let appID = AppID(pid: pid)
        let windows = windowTokens.map {
            FakeWindowSystem.WindowState(id: WindowID(app: appID, token: $0), minimized: false)
        }
        return FakeWindowSystem.AppState(id: appID, hidden: false, windows: windows)
    }
}
