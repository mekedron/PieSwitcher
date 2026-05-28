import XCTest
@testable import Bringr

@MainActor
final class WindowControlTests: XCTestCase {
    // MARK: - AC1: raise and focus

    func testRaiseAndFocusActivatesAppRaisesAndFocusesWindow() {
        let appA = AppID(pid: 1)
        let target = WindowID(app: appA, token: 10)
        let fake = FakeWindowSystem(
            apps: [makeApp(1, windowTokens: [11, 10])],
            frontmost: AppID(pid: 99)
        )
        let controller = WindowController(system: fake)

        controller.raiseAndFocus(target)

        XCTAssertEqual(fake.operationLog, [
            .raise(target),
            .activate(appA),
            .focusWindow(target),
            .raise(target),
            .focusWindow(target)
        ])
        XCTAssertEqual(fake.frontmost, appA)
        XCTAssertEqual(fake.focusedWindow, target)
        XCTAssertEqual(fake.windows(of: appA).first, target)
    }

    // MARK: - AC2 + AC5: hide other apps and restore

    func testHideOtherAppsHidesAllButTargetAndRestores() {
        let fake = FakeWindowSystem(
            apps: [makeApp(1), makeApp(2), makeApp(3)],
            frontmost: AppID(pid: 1)
        )
        let controller = WindowController(system: fake)

        controller.hideOtherApps(besides: AppID(pid: 2))

        XCTAssertTrue(fake.isHidden(AppID(pid: 1)))
        XCTAssertFalse(fake.isHidden(AppID(pid: 2)))
        XCTAssertTrue(fake.isHidden(AppID(pid: 3)))
        XCTAssertTrue(controller.hasActiveSession)

        controller.restore()

        XCTAssertFalse(fake.isHidden(AppID(pid: 1)))
        XCTAssertFalse(fake.isHidden(AppID(pid: 2)))
        XCTAssertFalse(fake.isHidden(AppID(pid: 3)))
        XCTAssertEqual(fake.frontmost, AppID(pid: 1))
        XCTAssertFalse(controller.hasActiveSession)
    }

    func testHideOtherAppsUnhidesTargetThenRestoresItsPriorHiddenState() {
        let fake = FakeWindowSystem(
            apps: [makeApp(1, hidden: true), makeApp(2)],
            frontmost: AppID(pid: 2)
        )
        let controller = WindowController(system: fake)

        controller.hideOtherApps(besides: AppID(pid: 1))

        XCTAssertFalse(fake.isHidden(AppID(pid: 1)))
        XCTAssertTrue(fake.isHidden(AppID(pid: 2)))

        controller.restore()

        XCTAssertTrue(fake.isHidden(AppID(pid: 1)))
        XCTAssertFalse(fake.isHidden(AppID(pid: 2)))
    }

    // MARK: - AC3 + AC5: hide other windows and restore (Bringr-93j.24: park, not minimize)

    func testHideOtherWindowsParksSiblingsOffScreenReTargetsAndRestores() {
        let appA = AppID(pid: 1)
        let fake = FakeWindowSystem(apps: [makeApp(1, windowTokens: [10, 11, 12])], frontmost: appA)
        let controller = WindowController(system: fake)
        let (w10, w11, w12) = (WindowID(app: appA, token: 10),
                               WindowID(app: appA, token: 11),
                               WindowID(app: appA, token: 12))

        controller.hideOtherWindows(besides: w11)

        // Siblings parked off-screen, NOT minimized (Bringr-93j.24); target stays + fronts.
        XCTAssertEqual(fake.position(of: w10), WindowController.offScreenPoint)
        XCTAssertEqual(fake.position(of: w12), WindowController.offScreenPoint)
        XCTAssertFalse(fake.isMinimized(w10))
        XCTAssertEqual(fake.position(of: w11), CGPoint(x: 11, y: 11))
        XCTAssertEqual(fake.windows(of: appA).first, w11)

        // Re-target reuses the one baseline: the new target un-parks, the old one parks.
        controller.hideOtherWindows(besides: w10)
        XCTAssertEqual(fake.position(of: w10), CGPoint(x: 10, y: 10))
        XCTAssertEqual(fake.position(of: w11), WindowController.offScreenPoint)

        controller.restore()

        // Everything back at its captured origin, original z-order restored.
        XCTAssertEqual(fake.position(of: w10), CGPoint(x: 10, y: 10))
        XCTAssertEqual(fake.position(of: w11), CGPoint(x: 11, y: 11))
        XCTAssertEqual(fake.position(of: w12), CGPoint(x: 12, y: 12))
        XCTAssertEqual(fake.windows(of: appA), [w10, w11, w12])
    }

    func testHideOtherWindowsRevealsTargetThenRestoresItsPriorMinimizedState() {
        let appA = AppID(pid: 1)
        let fake = FakeWindowSystem(
            apps: [makeApp(1, windowTokens: [10, 11])],
            frontmost: appA
        )
        // Target starts minimized; isolating it should reveal it.
        fake.setMinimized(WindowID(app: appA, token: 11), true)
        let controller = WindowController(system: fake)
        let target = WindowID(app: appA, token: 11)

        controller.hideOtherWindows(besides: target)

        XCTAssertFalse(fake.isMinimized(target), "the target is surfaced")
        XCTAssertEqual(fake.position(of: WindowID(app: appA, token: 10)), WindowController.offScreenPoint,
                       "the sibling is parked off-screen, not minimized")
        XCTAssertFalse(fake.isMinimized(WindowID(app: appA, token: 10)))

        controller.restore()

        XCTAssertTrue(fake.isMinimized(target), "the target returns to its prior minimized state")
        XCTAssertFalse(fake.isMinimized(WindowID(app: appA, token: 10)))
    }

    // MARK: - restoreWindows: targeted un-isolate that keeps app hiding intact (US-011)

    func testRestoreWindowsRevealsOneAppsWindowsButKeepsOtherAppsHidden() {
        let appA = AppID(pid: 1)
        let fake = FakeWindowSystem(
            apps: [makeApp(1, windowTokens: [10, 11, 12]), makeApp(2)],
            frontmost: appA
        )
        let controller = WindowController(system: fake)
        controller.hideOtherApps(besides: appA)                              // app 2 hidden
        controller.hideOtherWindows(besides: WindowID(app: appA, token: 11)) // 10, 12 minimized

        controller.restoreWindows(of: appA)

        // The app's windows are all back...
        XCTAssertFalse(fake.isMinimized(WindowID(app: appA, token: 10)))
        XCTAssertFalse(fake.isMinimized(WindowID(app: appA, token: 11)))
        XCTAssertFalse(fake.isMinimized(WindowID(app: appA, token: 12)))
        // ...but app 2 stays hidden and the session is still open for a later restore.
        XCTAssertTrue(fake.isHidden(AppID(pid: 2)))
        XCTAssertTrue(controller.hasActiveSession)

        controller.restore()
        XCTAssertFalse(fake.isHidden(AppID(pid: 2)))
    }

    func testRestoreWindowsIsNoOpForAnAppThatWasNeverIsolated() {
        let appA = AppID(pid: 1)
        let fake = FakeWindowSystem(apps: [makeApp(1, windowTokens: [10, 11])], frontmost: appA)
        let controller = WindowController(system: fake)

        controller.restoreWindows(of: appA) // no session, no baseline to replay

        XCTAssertFalse(controller.hasActiveSession)
        XCTAssertFalse(fake.isMinimized(WindowID(app: appA, token: 10)))
    }

    // MARK: - AC4: capture happens once; restore returns to the original baseline

    func testRestoreReturnsToBaselineDespiteReTargeting() {
        let fake = FakeWindowSystem(
            apps: [makeApp(1), makeApp(2), makeApp(3)],
            frontmost: AppID(pid: 1)
        )
        let controller = WindowController(system: fake)

        controller.hideOtherApps(besides: AppID(pid: 2))
        controller.hideOtherApps(besides: AppID(pid: 3))

        // After re-targeting, only app 3 is visible.
        XCTAssertTrue(fake.isHidden(AppID(pid: 1)))
        XCTAssertTrue(fake.isHidden(AppID(pid: 2)))
        XCTAssertFalse(fake.isHidden(AppID(pid: 3)))

        controller.restore()

        // Baseline was: all visible, frontmost app 1.
        XCTAssertFalse(fake.isHidden(AppID(pid: 1)))
        XCTAssertFalse(fake.isHidden(AppID(pid: 2)))
        XCTAssertFalse(fake.isHidden(AppID(pid: 3)))
        XCTAssertEqual(fake.frontmost, AppID(pid: 1))
    }

    func testRestoreWithoutSessionIsNoOp() {
        let fake = FakeWindowSystem(apps: [makeApp(1)], frontmost: AppID(pid: 1))
        let controller = WindowController(system: fake)

        controller.restore()

        XCTAssertFalse(controller.hasActiveSession)
        XCTAssertFalse(fake.isHidden(AppID(pid: 1)))
    }

    // MARK: - US-012 commit: restore everything else, then raise + focus the target

    func testCommitRestoresOthersThenRaisesAndFocusesTarget() {
        let appA = AppID(pid: 1)
        let target = WindowID(app: appA, token: 11)
        let fake = FakeWindowSystem(
            apps: [makeApp(1, windowTokens: [10, 11]), makeApp(2)],
            frontmost: appA
        )
        let controller = WindowController(system: fake)
        // A reveal session in flight: app 2 hidden, window 10 parked off-screen to isolate 11.
        controller.hideOtherApps(besides: appA)
        controller.hideOtherWindows(besides: target)
        XCTAssertTrue(fake.isHidden(AppID(pid: 2)))
        XCTAssertEqual(fake.position(of: WindowID(app: appA, token: 10)), WindowController.offScreenPoint)

        controller.commit(target)

        // AC2: every app/window moved out of the way is restored, session ended.
        XCTAssertFalse(fake.isHidden(AppID(pid: 2)))
        XCTAssertNotEqual(fake.position(of: WindowID(app: appA, token: 10)), WindowController.offScreenPoint,
                          "the parked sibling is brought back on commit")
        XCTAssertFalse(controller.hasActiveSession)
        // AC1: the target is raised, focused, and its app active — over the restore.
        XCTAssertEqual(fake.frontmost, appA)
        XCTAssertEqual(fake.focusedWindow, target)
        XCTAssertEqual(fake.windows(of: appA).first, target)
    }

    func testCommitUnminimizesATargetThatWasMinimizedBeforeSummon() {
        let appA = AppID(pid: 1)
        let target = WindowID(app: appA, token: 11)
        let fake = FakeWindowSystem(apps: [makeApp(1, windowTokens: [10, 11])], frontmost: appA)
        // The chosen window was minimized before any summon, so the captured baseline
        // (and thus restore) would leave it minimized.
        fake.setMinimized(target, true)
        let controller = WindowController(system: fake)
        controller.hideOtherWindows(besides: WindowID(app: appA, token: 10))

        controller.commit(target)

        // The user picked it, so it surfaces and focuses regardless of its prior state.
        XCTAssertFalse(fake.isMinimized(target))
        XCTAssertEqual(fake.focusedWindow, target)
        XCTAssertEqual(fake.windows(of: appA).first, target)
    }

    func testCommitWithoutAnActiveSessionStillRaisesAndFocuses() {
        let appA = AppID(pid: 1)
        let target = WindowID(app: appA, token: 11)
        let fake = FakeWindowSystem(
            apps: [makeApp(1, windowTokens: [10, 11])],
            frontmost: AppID(pid: 99)
        )
        let controller = WindowController(system: fake)

        // No reveal happened (committing the pre-highlighted window straight away):
        // restore is a no-op, but the raise/focus must still run.
        controller.commit(target)

        XCTAssertEqual(fake.frontmost, appA)
        XCTAssertEqual(fake.focusedWindow, target)
        XCTAssertEqual(fake.windows(of: appA).first, target)
    }

    // MARK: - Bringr-93j.18 regression: commit ordering must not race or hit a stale cache

    func testCommitActivatesOnlyTargetAppAndRefreshesItsWindowCache() {
        let target = AppID(pid: 1)
        let priorFrontmost = AppID(pid: 2)
        let targetWindow = WindowID(app: target, token: 11)
        let fake = FakeWindowSystem(
            apps: [makeApp(1, windowTokens: [10, 11]), makeApp(2)],
            frontmost: priorFrontmost
        )
        let controller = WindowController(system: fake)
        // Reveal a window of a backgrounded app: hide the prior frontmost, isolate 11.
        controller.hideOtherApps(besides: target)
        controller.hideOtherWindows(besides: targetWindow)
        fake.clearLog() // ignore setup; assert only on what commit does

        controller.commit(targetWindow)

        // Race fix: commit activates ONLY the target app — never re-activating the
        // prior frontmost, whose async activation could win and bury the choice.
        XCTAssertEqual(fake.activationLog, [target])
        // Cache-miss fix: commit re-enumerates the target app so a stale AX element
        // can't make un-minimize/raise/focus silently no-op.
        XCTAssertTrue(fake.enumerationLog.contains(target))
        // End state: the chosen window is frontmost, focused, and on top of its app.
        XCTAssertEqual(fake.frontmost, target)
        XCTAssertEqual(fake.focusedWindow, targetWindow)
        XCTAssertEqual(fake.windows(of: target).first, targetWindow)
    }

    func testCommitFocusesTargetAfterRestoredFrontSiblingIsRaised() {
        let appA = AppID(pid: 1)
        let frontSibling = WindowID(app: appA, token: 10)
        let target = WindowID(app: appA, token: 11)
        let fake = FakeWindowSystem(
            apps: [makeApp(1, windowTokens: [10, 11])],
            frontmost: appA
        )
        let controller = WindowController(system: fake)
        controller.hideOtherWindows(besides: target)
        fake.clearLog()

        controller.commit(target)

        let operations = fake.operationLog
        XCTAssertEqual(fake.windows(of: appA).first, target)
        XCTAssertEqual(fake.focusedWindow, target)
        XCTAssertEqual(fake.activationLog, [appA])
        XCTAssertEqual(Array(operations.suffix(3)), [
            .focusWindow(target),
            .raise(target),
            .focusWindow(target)
        ])
        XCTAssertLessThan(
            operations.firstIndex(of: .raise(target)) ?? -1,
            operations.firstIndex(of: .activate(appA)) ?? -1,
            "selected window must be AX-raised before app activation"
        )
        XCTAssertLessThan(
            operations.firstIndex(of: .raise(frontSibling)) ?? -1,
            operations.lastIndex(of: .raise(target)) ?? -1,
            "the restored original front sibling must be raised before the chosen window wins"
        )
    }

    // MARK: - Fixtures

    private func makeApp(
        _ pid: pid_t,
        hidden: Bool = false,
        windowTokens: [Int] = []
    ) -> FakeWindowSystem.AppState {
        let appID = AppID(pid: pid)
        // Give each window a distinct token-derived origin so the park/restore of
        // window positions (Bringr-93j.24) can be asserted precisely.
        let windows = windowTokens.map {
            FakeWindowSystem.WindowState(id: WindowID(app: appID, token: $0), minimized: false,
                                         position: CGPoint(x: CGFloat($0), y: CGFloat($0)))
        }
        return FakeWindowSystem.AppState(id: appID, hidden: hidden, windows: windows)
    }
}
