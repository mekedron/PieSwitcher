import XCTest
@testable import PieSwitcher

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

    // MARK: - restoreWindows: targeted un-isolate that keeps app hiding intact (US-011)

    func testRestoreWindowsUnminimizesOneAppsWindowsButKeepsOtherAppsHidden() {
        // A window-level reveal that captures a window baseline (e.g. a previously
        // minimized window the user hovered, which the reveal surfaced) — leaving the
        // sub-wheel must restore that baseline while keeping the other apps hidden.
        let appA = AppID(pid: 1)
        let fake = FakeWindowSystem(
            apps: [makeApp(1, windowTokens: [10, 11, 12]), makeApp(2)],
            frontmost: appA
        )
        fake.setMinimized(WindowID(app: appA, token: 10), true)
        fake.setMinimized(WindowID(app: appA, token: 12), true)
        let controller = WindowController(system: fake)
        controller.hideOtherApps(besides: appA)                            // app 2 hidden
        controller.revealWindow(WindowID(app: appA, token: 10))            // surfaces 10, captures baseline

        controller.restoreWindows(of: appA)

        // The previously minimized window returns to its baseline...
        XCTAssertTrue(fake.isMinimized(WindowID(app: appA, token: 10)))
        XCTAssertFalse(fake.isMinimized(WindowID(app: appA, token: 11)))
        XCTAssertTrue(fake.isMinimized(WindowID(app: appA, token: 12)))
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

    // MARK: - US-012 commit: raise + focus the target; reveal state IS the final state (Bringr-93j.88)

    func testCommitRaisesAndFocusesTargetAndKeepsRevealStateAsFinal() {
        let appA = AppID(pid: 1)
        let target = WindowID(app: appA, token: 11)
        let fake = FakeWindowSystem(
            apps: [makeApp(1, windowTokens: [10, 11]), makeApp(2)],
            frontmost: appA
        )
        let controller = WindowController(system: fake)
        // A reveal session in flight: app 2 hidden, window 11 raised to preview it.
        controller.hideOtherApps(besides: appA)
        controller.revealWindow(target)
        XCTAssertTrue(fake.isHidden(AppID(pid: 2)))

        controller.commit(target)

        // Bringr-93j.88: preview = commit. App 2 was hidden by the reveal and STAYS
        // hidden; the session ends without unhiding it. Only cancel restores. AC1: the
        // target is raised, focused, and its app active.
        XCTAssertTrue(fake.isHidden(AppID(pid: 2)),
                      "Bringr-93j.88: commit no longer unhides apps the reveal hid")
        XCTAssertFalse(controller.hasActiveSession)
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
        controller.revealWindow(WindowID(app: appA, token: 10))

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
        // Reveal a window of a backgrounded app: hide the prior frontmost, raise 11.
        controller.hideOtherApps(besides: target)
        controller.revealWindow(targetWindow)
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

    func testCommitRaisesTargetBeforeActivatingItsApp() {
        // Bringr-93j.18 race guard: the target window must be AX-raised before app
        // activation, so async activation can't bury the choice. (The earlier .47
        // sibling-restore order assertion no longer applies: under Bringr-93j.88,
        // commit doesn't restore the window baseline — the hover-drift order stays.)
        let appA = AppID(pid: 1)
        let target = WindowID(app: appA, token: 11)
        let fake = FakeWindowSystem(
            apps: [makeApp(1, windowTokens: [10, 11])],
            frontmost: appA
        )
        let controller = WindowController(system: fake)
        controller.revealWindow(target)
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
    }

    // MARK: - Fixtures

    private func makeApp(
        _ pid: pid_t,
        hidden: Bool = false,
        windowTokens: [Int] = []
    ) -> FakeWindowSystem.AppState {
        let appID = AppID(pid: pid)
        let windows = windowTokens.map {
            FakeWindowSystem.WindowState(id: WindowID(app: appID, token: $0), minimized: false)
        }
        return FakeWindowSystem.AppState(id: appID, hidden: hidden, windows: windows)
    }
}
