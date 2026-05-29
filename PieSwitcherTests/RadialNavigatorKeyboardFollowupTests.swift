import CoreGraphics
import XCTest
@testable import PieSwitcher

/// Keyboard-navigation follow-ups on `RadialNavigator` (Bringr-93j.73): drilling into an app focuses
/// its *active* (front) window rather than the first slice, and — under "don't require a window
/// choice" — a number that jumps to a multi-window app arms that app so a confirm (or, in the
/// controller, a trigger release) commits it without the user picking a specific window. Split from
/// `RadialNavigatorKeyboardTests`, which is at the file/type-body length caps.
@MainActor
final class RadialNavigatorKeyboardFollowupTests: XCTestCase {

    // MARK: - Active-window focus

    func testArrowDrillInFocusesActiveWindowNotFirstSlice() {
        let fixture = makeFixture()
        // Chrome's active (front) window is Docs (token 12), though the sub-wheel lists Inbox first.
        fixture.fake.apps.first { $0.id == AppID(pid: 10) }?.windows = [win(10, 12), win(10, 11)]
        fixture.navigator.open(appNodes: fixture.appNodes)
        _ = fixture.navigator.keyboardMove(.right) // focus Chrome

        _ = fixture.navigator.keyboardMove(.up) // drill into Chrome's windows

        XCTAssertEqual(fixture.navigator.hovered, .slice(level: 1, index: 1),
                       "focus lands on the active window (Docs), not the first slice")
    }

    func testNumberDrillInFocusesActiveWindow() {
        let fixture = makeFixture()
        fixture.fake.apps.first { $0.id == AppID(pid: 10) }?.windows = [win(10, 12), win(10, 11)]
        fixture.navigator.open(appNodes: fixture.appNodes)

        _ = fixture.navigator.keyboardNumber(1, requireConfirmation: false) // Chrome (multi-window)

        XCTAssertEqual(fixture.navigator.hovered, .slice(level: 1, index: 1),
                       "the number drop previews the app's active window")
    }

    // MARK: - No-window-choice app commit

    func testMultiWindowNumberArmsAppWhenAutoCommitOn() {
        let fixture = makeFixture()
        fixture.navigator.open(appNodes: fixture.appNodes)

        let outcome = fixture.navigator.keyboardNumber(1, requireConfirmation: false, autoCommitsApp: true) // Chrome

        XCTAssertEqual(outcome, .handled)
        XCTAssertEqual(fixture.navigator.pendingAppCommit, 0, "the multi-window app is armed")
        XCTAssertEqual(fixture.navigator.hovered, .slice(level: 1, index: 0), "its active window is previewed")
    }

    func testMultiWindowNumberDoesNotArmWhenAutoCommitOff() {
        let fixture = makeFixture()
        fixture.navigator.open(appNodes: fixture.appNodes)

        _ = fixture.navigator.keyboardNumber(1, requireConfirmation: false, autoCommitsApp: false) // Chrome

        XCTAssertNil(fixture.navigator.pendingAppCommit, "off: dropping into windows arms nothing, as before")
    }

    func testConfirmCommitsArmedAppWithoutWindowChoice() {
        let fixture = makeFixture()
        fixture.navigator.open(appNodes: fixture.appNodes)
        _ = fixture.navigator.keyboardNumber(1, requireConfirmation: false, autoCommitsApp: true) // arm Chrome

        let outcome = fixture.navigator.keyboardConfirm()

        XCTAssertEqual(outcome, .committed(.app(AppID(pid: 10))), "confirm commits the app, not a window")
        XCTAssertEqual(fixture.fake.frontmost, AppID(pid: 10))
        XCTAssertNil(fixture.navigator.pendingAppCommit)
    }

    func testArrowAfterArmingPicksWindowAndCancelsAppCommit() {
        let fixture = makeFixture()
        fixture.navigator.open(appNodes: fixture.appNodes)
        _ = fixture.navigator.keyboardNumber(1, requireConfirmation: false, autoCommitsApp: true) // arm Chrome

        let outcome = fixture.navigator.keyboardMove(.right) // navigate to a specific window instead

        XCTAssertEqual(outcome, .handled)
        XCTAssertNil(fixture.navigator.pendingAppCommit, "picking a window cancels the app auto-commit")
        XCTAssertEqual(fixture.navigator.hovered, .slice(level: 1, index: 1))
    }

    func testWindowNumberAfterArmingCommitsWindowNotApp() {
        let fixture = makeFixture()
        fixture.navigator.open(appNodes: fixture.appNodes)
        _ = fixture.navigator.keyboardNumber(1, requireConfirmation: false, autoCommitsApp: true) // arm Chrome

        let outcome = fixture.navigator.keyboardNumber(2, requireConfirmation: false, autoCommitsApp: true) // window 2

        XCTAssertEqual(outcome, .committed(.window(WindowID(app: AppID(pid: 10), token: 12))))
        XCTAssertNil(fixture.navigator.pendingAppCommit)
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
        let enumerator = WindowEnumerator(
            source: source, appOrder: { .name }, windowOrder: { .fixed }
        )
        let appNodes = WindowSwitcherMenu(enumerator: enumerator).makeRoot().resolvedChildren()
        let fake = FakeWindowSystem(
            apps: [
                FakeWindowSystem.AppState(id: AppID(pid: 10), hidden: false,
                                          windows: [win(10, 11), win(10, 12)]),
                FakeWindowSystem.AppState(id: AppID(pid: 20), hidden: false,
                                          windows: [win(20, 21)])
            ],
            frontmost: AppID(pid: 10)
        )
        let navigator = RadialNavigator(windowControl: WindowController(system: fake), store: makeEphemeralStore())
        return Fixture(navigator: navigator, fake: fake, appNodes: appNodes)
    }

    private func makeEphemeralStore() -> LastSelectionStore {
        let suite = "PieSwitcherTests.RadialNavigatorKeyboardFollowup.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        addTeardownBlock { UserDefaults.standard.removePersistentDomain(forName: suite) }
        return LastSelectionStore(defaults: defaults)
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
