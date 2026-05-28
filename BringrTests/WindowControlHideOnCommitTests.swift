import XCTest
@testable import Bringr

/// Covers the "leave only my selection on screen" behaviour `WindowController.commit`
/// performs when the setting is on (Bringr-93j.27), kept in its own file so
/// `WindowControlTests` stays within the lint length limits. The persistence helper is
/// covered by `HideOnCommitTests`; the navigator wiring by `RadialNavigatorCommitTests`.
@MainActor
final class WindowControlHideOnCommitTests: XCTestCase {

    func testWindowCommitMinimizesSiblingsAndHidesOtherApps() {
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

        // Only the chosen window is left: its app's sibling minimizes, the other app hides.
        XCTAssertTrue(fake.isMinimized(sibling))
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

    func testAppCommitLeavesOnlyTheAppsFrontWindow() {
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

        // App-level commit clears everything else away too, down to the app's front window.
        XCTAssertEqual(fake.focusedWindow, frontWindow)
        XCTAssertEqual(fake.frontmost, appA)
        XCTAssertTrue(fake.isMinimized(otherWindow))
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

    // MARK: - Fixtures

    private func makeApp(_ pid: pid_t, windowTokens: [Int] = []) -> FakeWindowSystem.AppState {
        let appID = AppID(pid: pid)
        let windows = windowTokens.map {
            FakeWindowSystem.WindowState(id: WindowID(app: appID, token: $0), minimized: false,
                                         position: CGPoint(x: CGFloat($0), y: CGFloat($0)))
        }
        return FakeWindowSystem.AppState(id: appID, hidden: false, windows: windows)
    }
}
