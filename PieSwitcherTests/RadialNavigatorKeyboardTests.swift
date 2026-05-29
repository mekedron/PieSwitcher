import CoreGraphics
import XCTest
@testable import PieSwitcher

/// Exercises the keyboard-navigation decision logic on `RadialNavigator` (Bringr-93j.71)
/// against a fake window system and a stub enumerator — the same pure-core testing the hover
/// navigation uses. Keyboard focus drives the very same isolate/preview/commit machinery as
/// hover, so these assert focus movement (`hovered`), drill-in/step-back across levels, the
/// number-key app/window rules with and without confirmation, and the commit/close outcomes.
@MainActor
final class RadialNavigatorKeyboardTests: XCTestCase {

    // MARK: - Arrow focus

    func testFirstArrowFocusesTopApp() {
        let fixture = makeFixture()
        fixture.navigator.open(appNodes: fixture.appNodes)

        let outcome = fixture.navigator.keyboardMove(.right)

        XCTAssertEqual(outcome, .handled)
        XCTAssertEqual(fixture.navigator.hovered, .slice(level: 0, index: 0), "the first arrow lands on the top app")
        XCTAssertEqual(fixture.navigator.rings.count, 2, "focusing an app previews it by opening its windows")
    }

    func testArrowRightMovesAndWrapsAcrossApps() {
        let fixture = makeFixture()
        fixture.navigator.open(appNodes: fixture.appNodes)

        _ = fixture.navigator.keyboardMove(.right)               // none → app 0
        XCTAssertEqual(fixture.navigator.keyboardMove(.right), .handled)
        XCTAssertEqual(fixture.navigator.hovered, .slice(level: 0, index: 1)) // → Ghostty
        _ = fixture.navigator.keyboardMove(.right)
        XCTAssertEqual(fixture.navigator.hovered, .slice(level: 0, index: 0), "right past the end wraps to the start")
    }

    func testArrowLeftWrapsAcrossApps() {
        let fixture = makeFixture()
        fixture.navigator.open(appNodes: fixture.appNodes)

        _ = fixture.navigator.keyboardMove(.left)                // none → app 0
        _ = fixture.navigator.keyboardMove(.left)                // left past 0 wraps to the last
        XCTAssertEqual(fixture.navigator.hovered, .slice(level: 0, index: 1))
    }

    func testUpDrillsIntoWindowsAndDownReturns() {
        let fixture = makeFixture()
        fixture.navigator.open(appNodes: fixture.appNodes)
        _ = fixture.navigator.keyboardMove(.right)               // focus Chrome

        _ = fixture.navigator.keyboardMove(.up)                  // into Chrome's windows (Bringr-93j.72)
        XCTAssertEqual(fixture.navigator.hovered, .slice(level: 1, index: 0))
        XCTAssertEqual(fixture.navigator.expandedWindowIndex, 0, "the focused window is isolated/previewed")

        _ = fixture.navigator.keyboardMove(.down)                // back to the app (Bringr-93j.72)
        XCTAssertEqual(fixture.navigator.hovered, .slice(level: 0, index: 0))
        XCTAssertNil(fixture.navigator.expandedWindowIndex, "stepping back restores the window isolation")
        XCTAssertEqual(fixture.navigator.rings.count, 2, "the app stays expanded")
    }

    func testDownAtAppLevelIsNoOp() {
        let fixture = makeFixture()
        fixture.navigator.open(appNodes: fixture.appNodes)
        _ = fixture.navigator.keyboardMove(.right)               // focus an app (top level)

        _ = fixture.navigator.keyboardMove(.down)                // down no longer drills (reversed)

        XCTAssertEqual(fixture.navigator.hovered, .slice(level: 0, index: 0), "down at the apps level does nothing")
        XCTAssertEqual(fixture.navigator.rings.count, 2, "the app stays expanded, no deeper move happened")
    }

    func testArrowWrapsAcrossWindows() {
        let fixture = makeFixture()
        fixture.navigator.open(appNodes: fixture.appNodes)
        _ = fixture.navigator.keyboardMove(.right)               // Chrome
        _ = fixture.navigator.keyboardMove(.up)                  // window 0 (Inbox)

        _ = fixture.navigator.keyboardMove(.right)
        XCTAssertEqual(fixture.navigator.hovered, .slice(level: 1, index: 1)) // Docs
        _ = fixture.navigator.keyboardMove(.right)
        XCTAssertEqual(fixture.navigator.hovered, .slice(level: 1, index: 0), "right past the last window wraps")
    }

    func testMoveOnEmptyWheelIsIgnored() {
        let fixture = makeFixture()
        fixture.navigator.open(appNodes: [])

        XCTAssertEqual(fixture.navigator.keyboardMove(.right), .ignored)
    }

    // MARK: - Escape

    func testEscapeFromWindowStepsBackToApp() {
        let fixture = makeFixture()
        fixture.navigator.open(appNodes: fixture.appNodes)
        _ = fixture.navigator.keyboardMove(.right)               // Chrome
        _ = fixture.navigator.keyboardMove(.up)                  // a Chrome window (Inbox raised)

        let outcome = fixture.navigator.keyboardEscape()

        XCTAssertEqual(outcome, .handled, "Escape from a window steps back, it does not close")
        XCTAssertEqual(fixture.navigator.hovered, .slice(level: 0, index: 0))
        XCTAssertNil(fixture.navigator.expandedWindowIndex)
        assertOnScreen(12, fixture.fake) // the previewed window's sibling stays on-screen
    }

    func testEscapeFromAppLevelRequestsClose() {
        let fixture = makeFixture()
        fixture.navigator.open(appNodes: fixture.appNodes)
        _ = fixture.navigator.keyboardMove(.right)               // focus an app (top level)

        XCTAssertEqual(fixture.navigator.keyboardEscape(), .close)
    }

    // MARK: - Number keys

    func testNumberOnMultiWindowAppDropsIntoWindows() {
        let fixture = makeFixture()
        fixture.navigator.open(appNodes: fixture.appNodes)

        let outcome = fixture.navigator.keyboardNumber(1, requireConfirmation: false) // Chrome (2 windows)

        XCTAssertEqual(outcome, .handled)
        XCTAssertEqual(fixture.navigator.hovered, .slice(level: 1, index: 0), "a multi-window app drops into windows")
        XCTAssertEqual(fixture.navigator.rings.count, 2)
    }

    func testNumberOnSingleWindowAppCommitsItsWindow() {
        let fixture = makeFixture()
        fixture.navigator.open(appNodes: fixture.appNodes)

        let outcome = fixture.navigator.keyboardNumber(2, requireConfirmation: false) // Ghostty (1 window)

        XCTAssertEqual(outcome, .committed(.window(WindowID(app: AppID(pid: 20), token: 21))))
        XCTAssertEqual(fixture.fake.focusedWindow, WindowID(app: AppID(pid: 20), token: 21))
        XCTAssertTrue(fixture.navigator.rings.isEmpty, "committing clears the wheel")
    }

    func testNumberOnSingleWindowAppWithConfirmationFocusesInstead() {
        let fixture = makeFixture()
        fixture.navigator.open(appNodes: fixture.appNodes)

        let outcome = fixture.navigator.keyboardNumber(2, requireConfirmation: true) // Ghostty

        XCTAssertEqual(outcome, .handled, "confirmation turns instant activation into a preview")
        XCTAssertEqual(fixture.navigator.hovered, .slice(level: 1, index: 0))
        XCTAssertEqual(fixture.navigator.pendingConfirmation, .slice(level: 1, index: 0), "the window is armed")
        XCTAssertNil(fixture.fake.focusedWindow, "nothing is committed until confirmed")
    }

    func testWindowNumberCommitsThatWindow() {
        let fixture = makeFixture()
        fixture.navigator.open(appNodes: fixture.appNodes)
        _ = fixture.navigator.keyboardNumber(1, requireConfirmation: false) // into Chrome's windows

        let outcome = fixture.navigator.keyboardNumber(2, requireConfirmation: false) // window 2 (Docs)

        XCTAssertEqual(outcome, .committed(.window(WindowID(app: AppID(pid: 10), token: 12))))
        XCTAssertEqual(fixture.fake.focusedWindow, WindowID(app: AppID(pid: 10), token: 12))
    }

    func testWindowNumberWithConfirmationFocusesInstead() {
        let fixture = makeFixture()
        fixture.navigator.open(appNodes: fixture.appNodes)
        _ = fixture.navigator.keyboardNumber(1, requireConfirmation: true) // into Chrome's windows

        let outcome = fixture.navigator.keyboardNumber(2, requireConfirmation: true) // window 2 (Docs)

        XCTAssertEqual(outcome, .handled)
        XCTAssertEqual(fixture.navigator.hovered, .slice(level: 1, index: 1))
        XCTAssertEqual(fixture.navigator.pendingConfirmation, .slice(level: 1, index: 1), "the window is armed")
        XCTAssertNil(fixture.fake.focusedWindow)
    }

    func testNumberOutOfRangeIsConsumedNoOp() {
        let fixture = makeFixture()
        fixture.navigator.open(appNodes: fixture.appNodes)

        let outcome = fixture.navigator.keyboardNumber(3, requireConfirmation: false) // only two apps exist

        XCTAssertEqual(outcome, .handled, "an out-of-range number is consumed but does nothing")
        XCTAssertEqual(fixture.navigator.hovered, .none)
        XCTAssertEqual(fixture.navigator.rings.count, 1)
    }

    // MARK: - Confirm (Return)

    func testConfirmCommitsFocusedWindow() {
        let fixture = makeFixture()
        fixture.navigator.open(appNodes: fixture.appNodes)
        _ = fixture.navigator.keyboardMove(.right)               // Chrome
        _ = fixture.navigator.keyboardMove(.up)                  // window 0 (Inbox)

        let outcome = fixture.navigator.keyboardConfirm()

        XCTAssertEqual(outcome, .committed(.window(WindowID(app: AppID(pid: 10), token: 11))))
        XCTAssertEqual(fixture.fake.focusedWindow, WindowID(app: AppID(pid: 10), token: 11))
    }

    func testConfirmCommitsFocusedApp() {
        let fixture = makeFixture()
        fixture.navigator.open(appNodes: fixture.appNodes)
        _ = fixture.navigator.keyboardMove(.right)               // focus Chrome at the app level

        let outcome = fixture.navigator.keyboardConfirm()

        XCTAssertEqual(outcome, .committed(.app(AppID(pid: 10))))
        XCTAssertEqual(fixture.fake.frontmost, AppID(pid: 10))
    }

    func testConfirmWithNothingFocusedIsNoOp() {
        let fixture = makeFixture()
        fixture.navigator.open(appNodes: fixture.appNodes)

        let outcome = fixture.navigator.keyboardConfirm()

        XCTAssertEqual(outcome, .handled, "Return over nothing is consumed, not leaked")
        XCTAssertNil(fixture.fake.focusedWindow)
        XCTAssertEqual(fixture.navigator.rings.count, 1, "the wheel stays open")
    }

    // MARK: - Confirmation extras (Bringr-93j.72)

    func testArrowConfirmsArmedTargetInsteadOfMoving() {
        let fixture = makeFixture()
        fixture.navigator.open(appNodes: fixture.appNodes)
        _ = fixture.navigator.keyboardNumber(2, requireConfirmation: true) // Ghostty: focus + arm its window
        XCTAssertEqual(fixture.navigator.pendingConfirmation, .slice(level: 1, index: 0))

        let outcome = fixture.navigator.keyboardMove(.down) // an arrow confirms the armed target

        XCTAssertEqual(outcome, .committed(.window(WindowID(app: AppID(pid: 20), token: 21))))
        XCTAssertEqual(fixture.fake.focusedWindow, WindowID(app: AppID(pid: 20), token: 21))
    }

    func testRepeatingTheSameWindowNumberConfirms() {
        let fixture = makeFixture()
        fixture.navigator.open(appNodes: fixture.appNodes)
        _ = fixture.navigator.keyboardNumber(1, requireConfirmation: true) // into Chrome's windows
        _ = fixture.navigator.keyboardNumber(2, requireConfirmation: true) // focus + arm window 2 (Docs)

        let outcome = fixture.navigator.keyboardNumber(2, requireConfirmation: true) // same number again confirms

        XCTAssertEqual(outcome, .committed(.window(WindowID(app: AppID(pid: 10), token: 12))))
        XCTAssertEqual(fixture.fake.focusedWindow, WindowID(app: AppID(pid: 10), token: 12))
    }

    func testConfirmKeyActivatesArmedTarget() {
        let fixture = makeFixture()
        fixture.navigator.open(appNodes: fixture.appNodes)
        _ = fixture.navigator.keyboardNumber(2, requireConfirmation: true) // Ghostty: focus + arm its window

        let outcome = fixture.navigator.keyboardConfirm() // Return / Space / keypad Enter all route here

        XCTAssertEqual(outcome, .committed(.window(WindowID(app: AppID(pid: 20), token: 21))))
        XCTAssertEqual(fixture.fake.focusedWindow, WindowID(app: AppID(pid: 20), token: 21))
    }

    func testArrowStillMovesWhenNothingIsArmed() {
        let fixture = makeFixture()
        fixture.navigator.open(appNodes: fixture.appNodes)
        _ = fixture.navigator.keyboardMove(.right) // focus app 0, nothing armed

        let outcome = fixture.navigator.keyboardMove(.right) // with nothing armed, arrows still move

        XCTAssertEqual(outcome, .handled)
        XCTAssertEqual(fixture.navigator.hovered, .slice(level: 0, index: 1))
        XCTAssertNil(fixture.fake.focusedWindow, "moving did not commit anything")
    }

    func testHoverMoveClearsArmedConfirmation() {
        let fixture = makeFixture()
        fixture.navigator.open(appNodes: fixture.appNodes)
        _ = fixture.navigator.keyboardNumber(2, requireConfirmation: true) // arm Ghostty's window
        XCTAssertNotNil(fixture.navigator.pendingConfirmation)

        fixture.navigator.updateHover(.slice(level: 1, index: 0)) // a hover move (mouse or keyboard)

        XCTAssertNil(fixture.navigator.pendingConfirmation, "any focus move disarms the pending confirmation")
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
                                          windows: [win(20, 21)]),
                FakeWindowSystem.AppState(id: AppID(pid: 30), hidden: false, windows: [])
            ],
            frontmost: AppID(pid: 10)
        )
        let navigator = RadialNavigator(windowControl: WindowController(system: fake), store: makeEphemeralStore())
        return Fixture(navigator: navigator, fake: fake, appNodes: appNodes)
    }

    private func makeEphemeralStore() -> LastSelectionStore {
        let suite = "PieSwitcherTests.RadialNavigatorKeyboard.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        addTeardownBlock { UserDefaults.standard.removePersistentDomain(forName: suite) }
        return LastSelectionStore(defaults: defaults)
    }

    private func assertOnScreen(_ token: Int, _ fake: FakeWindowSystem, line: UInt = #line) {
        XCTAssertFalse(fake.isMinimized(WindowID(app: AppID(pid: 10), token: token)),
                       "window \(token) should be on-screen (not minimized)", line: line)
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
