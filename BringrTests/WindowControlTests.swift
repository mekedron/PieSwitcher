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

    // MARK: - AC3 + AC5: hide other windows and restore

    func testHideOtherWindowsMinimizesAllButTargetAndRestoresOrder() {
        let appA = AppID(pid: 1)
        let fake = FakeWindowSystem(
            apps: [makeApp(1, windowTokens: [10, 11, 12])],
            frontmost: appA
        )
        let controller = WindowController(system: fake)
        let target = WindowID(app: appA, token: 11)

        controller.hideOtherWindows(besides: target)

        XCTAssertTrue(fake.isMinimized(WindowID(app: appA, token: 10)))
        XCTAssertFalse(fake.isMinimized(target))
        XCTAssertTrue(fake.isMinimized(WindowID(app: appA, token: 12)))

        controller.restore()

        XCTAssertFalse(fake.isMinimized(WindowID(app: appA, token: 10)))
        XCTAssertFalse(fake.isMinimized(target))
        XCTAssertFalse(fake.isMinimized(WindowID(app: appA, token: 12)))

        let expectedOrder = [
            WindowID(app: appA, token: 10),
            WindowID(app: appA, token: 11),
            WindowID(app: appA, token: 12)
        ]
        XCTAssertEqual(fake.windows(of: appA), expectedOrder)
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

        XCTAssertFalse(fake.isMinimized(target))
        XCTAssertTrue(fake.isMinimized(WindowID(app: appA, token: 10)))

        controller.restore()

        XCTAssertTrue(fake.isMinimized(target))
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

/// In-memory `WindowControlling` for tests: models app visibility/z-order and
/// per-app window minimized-state/z-order, with no live system dependency.
@MainActor
final class FakeWindowSystem: WindowControlling {
    final class WindowState {
        let id: WindowID
        var minimized: Bool
        init(id: WindowID, minimized: Bool) {
            self.id = id
            self.minimized = minimized
        }
    }

    final class AppState {
        let id: AppID
        var hidden: Bool
        var windows: [WindowState]
        init(id: AppID, hidden: Bool, windows: [WindowState]) {
            self.id = id
            self.hidden = hidden
            self.windows = windows
        }
    }

    var apps: [AppState]
    var frontmost: AppID?
    private(set) var focusedWindow: WindowID?

    init(apps: [AppState], frontmost: AppID?) {
        self.apps = apps
        self.frontmost = frontmost
    }

    private func appState(_ id: AppID) -> AppState? {
        apps.first { $0.id == id }
    }

    private func windowState(_ id: WindowID) -> WindowState? {
        appState(id.app)?.windows.first { $0.id == id }
    }

    func runningApps() -> [AppID] {
        apps.map { $0.id }
    }

    func windows(of app: AppID) -> [WindowID] {
        appState(app)?.windows.map { $0.id } ?? []
    }

    func frontmostApp() -> AppID? {
        frontmost
    }

    func isHidden(_ app: AppID) -> Bool {
        appState(app)?.hidden ?? false
    }

    func setHidden(_ app: AppID, _ hidden: Bool) {
        appState(app)?.hidden = hidden
    }

    func activate(_ app: AppID) {
        frontmost = app
        guard let index = apps.firstIndex(where: { $0.id == app }) else { return }
        let state = apps.remove(at: index)
        apps.insert(state, at: 0)
    }

    func isMinimized(_ window: WindowID) -> Bool {
        windowState(window)?.minimized ?? false
    }

    func setMinimized(_ window: WindowID, _ minimized: Bool) {
        windowState(window)?.minimized = minimized
    }

    func raise(_ window: WindowID) {
        guard let app = appState(window.app),
              let index = app.windows.firstIndex(where: { $0.id == window }) else { return }
        let state = app.windows.remove(at: index)
        app.windows.insert(state, at: 0)
    }

    func focusWindow(_ window: WindowID) {
        focusedWindow = window
    }
}
