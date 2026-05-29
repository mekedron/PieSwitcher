import CoreGraphics
import XCTest
@testable import PieSwitcher

/// Exercises the US-012 commit and pre-highlight behaviour of `RadialNavigator`
/// against a fake window system, a stub enumerator, and an ephemeral selection
/// store — the same pure-core testing the hover navigation (RadialNavigatorTests)
/// uses, kept in its own file so each stays within the lint length limits.
///
/// `FakeWindowSystem` (WindowControlTests) and `StubEnumerationSource`
/// (MenuModelTests) are reused as the doubles; the store is always backed by a
/// throwaway suite so remember/pre-highlight never touch `.standard`.
@MainActor
final class RadialNavigatorCommitTests: XCTestCase {

    // MARK: - AC1/AC2/AC3: commit a window — focus, restore, remember

    func testCommittingAWindowRaisesItRestoresOthersClearsAndRemembers() {
        let fixture = makeFixture()
        fixture.navigator.open(appNodes: fixture.appNodes)
        fixture.navigator.updateHover(.slice(level: 0, index: 0)) // Chrome isolated
        fixture.navigator.updateHover(.slice(level: 1, index: 1)) // Docs isolated (Inbox hidden)

        let committed = fixture.navigator.commit(.slice(level: 1, index: 1))

        // AC1: the chosen window is returned, raised, focused, its app active.
        XCTAssertEqual(committed, .window(WindowID(app: AppID(pid: 10), token: 12)))
        XCTAssertEqual(fixture.fake.focusedWindow, WindowID(app: AppID(pid: 10), token: 12))
        XCTAssertEqual(fixture.fake.frontmost, AppID(pid: 10))
        // AC2: the other apps are restored; no window-level reveal parks/minimizes
        // siblings now, so the app's other window stayed on-screen throughout.
        XCTAssertFalse(fixture.fake.isHidden(AppID(pid: 20)))
        XCTAssertFalse(fixture.fake.isHidden(AppID(pid: 30)))
        XCTAssertFalse(fixture.fake.isMinimized(WindowID(app: AppID(pid: 10), token: 11)))
        // The wheel is cleared and the session ended.
        XCTAssertTrue(fixture.navigator.rings.isEmpty)
        XCTAssertNil(fixture.navigator.expandedAppIndex)
        XCTAssertNil(fixture.navigator.expandedWindowIndex)
        XCTAssertEqual(fixture.navigator.hovered, .none)
        // AC3: the choice is remembered for Chrome for the next summon.
        XCTAssertEqual(fixture.store.remembered(forAppName: "Chrome"),
                       RememberedSelection(title: "Docs", index: 1))
    }

    func testCommittingAWindowWithoutHavingIsolatedItStillFocusesAndRemembers() {
        // Pre-highlight path: the sub-wheel is open but the cursor never isolated a
        // window — commit straight on the remembered slice.
        let fixture = makeFixture()
        fixture.navigator.open(appNodes: fixture.appNodes)
        fixture.navigator.updateHover(.slice(level: 0, index: 0)) // Chrome, no window isolated

        let committed = fixture.navigator.commit(.slice(level: 1, index: 0))

        XCTAssertEqual(committed, .window(WindowID(app: AppID(pid: 10), token: 11)))
        XCTAssertEqual(fixture.fake.focusedWindow, WindowID(app: AppID(pid: 10), token: 11))
        XCTAssertEqual(fixture.store.remembered(forAppName: "Chrome"),
                       RememberedSelection(title: "Inbox", index: 0))
    }

    func testCommittingAnAppSliceActivatesTheAppWithoutRememberingWindow() {
        let fixture = makeFixture()
        fixture.navigator.open(appNodes: fixture.appNodes)
        fixture.navigator.updateHover(.slice(level: 0, index: 1)) // Ghostty expanded
        fixture.fake.clearLog()

        let committed = fixture.navigator.commit(.slice(level: 0, index: 1))
        let operations = fixture.fake.operationLog

        XCTAssertEqual(committed, .app(AppID(pid: 20)))
        XCTAssertEqual(fixture.fake.frontmost, AppID(pid: 20))
        XCTAssertEqual(fixture.fake.focusedWindow, WindowID(app: AppID(pid: 20), token: 21))
        XCTAssertFalse(fixture.fake.isHidden(AppID(pid: 10)))
        XCTAssertFalse(fixture.fake.isHidden(AppID(pid: 30)))
        XCTAssertNil(fixture.store.remembered(forAppName: "Ghostty"))
        XCTAssertTrue(fixture.navigator.rings.isEmpty)
        XCTAssertFalse(fixture.fake.activationLog.contains(AppID(pid: 10)))
        XCTAssertTrue(fixture.fake.activationLog.allSatisfy { $0 == AppID(pid: 20) })
        // Bringr-93j.86 (blink fix): target activation now comes BEFORE unhiding the
        // other apps. Restoring first was the cause of the visible flash on every commit
        // — every hidden app appeared for a frame before the chosen one was raised. With
        // the new order the chosen window is already on top when others reappear behind
        // it. Correctness (the chosen app still wins) is covered by the frontmost +
        // activationLog assertions above; this guards the new order so a regression that
        // re-introduces the blink also flips this assertion.
        XCTAssertLessThan(
            operations.firstIndex(of: .activate(AppID(pid: 20))) ?? -1,
            operations.firstIndex(of: .setHidden(AppID(pid: 10), false)) ?? -1,
            "post-Bringr-93j.86: target activation must precede unhiding the hidden apps"
        )
    }

    func testCommitReturnsNilForDeadZoneWithoutTouchingState() {
        let fixture = makeFixture()
        fixture.navigator.open(appNodes: fixture.appNodes)
        fixture.navigator.updateHover(.slice(level: 0, index: 0))

        XCTAssertNil(fixture.navigator.commit(.none))

        XCTAssertNil(fixture.fake.focusedWindow)
        XCTAssertNil(fixture.store.remembered(forAppName: "Chrome"))
        XCTAssertEqual(fixture.navigator.rings.count, 2)
    }

    // MARK: - Bringr-93j.27/.49: "leave only my selection on screen" forwarded through commit

    func testWindowCommitWithHideOnCommitHidesOtherAppsButKeepsSiblings() {
        let fixture = makeFixture()
        fixture.navigator.setHideOnCommitEnabled(true)
        fixture.navigator.open(appNodes: fixture.appNodes)
        fixture.navigator.updateHover(.slice(level: 0, index: 0)) // Chrome isolated
        fixture.navigator.updateHover(.slice(level: 1, index: 1)) // Docs isolated

        let committed = fixture.navigator.commit(.slice(level: 1, index: 1))

        XCTAssertEqual(committed, .window(WindowID(app: AppID(pid: 10), token: 12)))
        XCTAssertEqual(fixture.fake.focusedWindow, WindowID(app: AppID(pid: 10), token: 12))
        // Only the other apps are hidden; Chrome's other window stays on screen (un-parked by
        // the reveal restore) — hiding never reaches within the selected app (Bringr-93j.49).
        XCTAssertTrue(fixture.fake.isHidden(AppID(pid: 20)))
        XCTAssertTrue(fixture.fake.isHidden(AppID(pid: 30)))
        XCTAssertFalse(fixture.fake.isMinimized(WindowID(app: AppID(pid: 10), token: 11)))
        XCTAssertFalse(fixture.fake.isMinimized(WindowID(app: AppID(pid: 10), token: 12)))
    }

    func testAppCommitWithHideOnCommitHidesTheOtherApps() {
        let fixture = makeFixture()
        fixture.navigator.setHideOnCommitEnabled(true)
        fixture.navigator.open(appNodes: fixture.appNodes)
        fixture.navigator.updateHover(.slice(level: 0, index: 1)) // Ghostty expanded

        let committed = fixture.navigator.commit(.slice(level: 0, index: 1))

        XCTAssertEqual(committed, .app(AppID(pid: 20)))
        XCTAssertEqual(fixture.fake.frontmost, AppID(pid: 20))
        XCTAssertTrue(fixture.fake.isHidden(AppID(pid: 10)))
        XCTAssertTrue(fixture.fake.isHidden(AppID(pid: 30)))
        XCTAssertFalse(fixture.fake.isHidden(AppID(pid: 20)))
    }

    // MARK: - AC4: pre-highlight the app's remembered window on expand

    func testExpandingAnAppPreHighlightsItsRememberedWindow() {
        let fixture = makeFixture()
        fixture.store.remember(appName: "Chrome", title: "Docs", index: 1)
        fixture.navigator.open(appNodes: fixture.appNodes)

        fixture.navigator.updateHover(.slice(level: 0, index: 0)) // expand Chrome

        XCTAssertEqual(fixture.navigator.prehighlighted, .slice(level: 1, index: 1))
    }

    func testPreHighlightFollowsTheRememberedTitleWhenWindowsReorder() {
        // Remembered "Inbox" at index 0; if it now sits at index 1 the pre-highlight
        // follows the title, not the stale position.
        let fixture = makeFixture(windows: [
            raw(number: 12, pid: 10, name: "Chrome", title: "Docs"),
            raw(number: 11, pid: 10, name: "Chrome", title: "Inbox"),
            raw(number: 21, pid: 20, name: "Ghostty", title: "Terminal")
        ])
        fixture.store.remember(appName: "Chrome", title: "Inbox", index: 0)
        fixture.navigator.open(appNodes: fixture.appNodes)

        fixture.navigator.updateHover(.slice(level: 0, index: 0))

        XCTAssertEqual(fixture.navigator.prehighlighted, .slice(level: 1, index: 1))
    }

    func testNoPreHighlightWhenNothingRemembered() {
        let fixture = makeFixture()
        fixture.navigator.open(appNodes: fixture.appNodes)

        fixture.navigator.updateHover(.slice(level: 0, index: 0))

        XCTAssertEqual(fixture.navigator.prehighlighted, .none)
    }

    func testReTargetingUpdatesPreHighlightToTheNewApp() {
        let fixture = makeFixture()
        fixture.store.remember(appName: "Chrome", title: "Docs", index: 1)
        fixture.navigator.open(appNodes: fixture.appNodes)
        fixture.navigator.updateHover(.slice(level: 0, index: 0)) // Chrome → pre-highlight
        XCTAssertEqual(fixture.navigator.prehighlighted, .slice(level: 1, index: 1))

        fixture.navigator.updateHover(.slice(level: 0, index: 1)) // Ghostty → no memory

        XCTAssertEqual(fixture.navigator.prehighlighted, .none)
    }

    func testPreHighlightClearsWhenCollapsingToTheAppsRing() {
        let fixture = makeFixture()
        fixture.store.remember(appName: "Chrome", title: "Docs", index: 1)
        fixture.navigator.open(appNodes: fixture.appNodes)
        fixture.navigator.updateHover(.slice(level: 0, index: 0)) // pre-highlight set

        fixture.navigator.updateHover(.none) // collapse to the dead zone

        XCTAssertEqual(fixture.navigator.prehighlighted, .none)
    }

    func testPreHighlightResolvesCorrectNodeIndexUnderFisheye() {
        // Three Chrome windows over two apps overflow into a fisheye; the fisheye
        // changes only slice geometry, never which node is slice i, so a remembered
        // selection still pre-highlights the right window node.
        let fixture = makeFixture(windows: [
            raw(number: 11, pid: 10, name: "Chrome", title: "Inbox"),
            raw(number: 12, pid: 10, name: "Chrome", title: "Docs"),
            raw(number: 13, pid: 10, name: "Chrome", title: "Calendar"),
            raw(number: 21, pid: 20, name: "Ghostty", title: "Terminal")
        ])
        fixture.store.remember(appName: "Chrome", title: "Calendar", index: 2)
        fixture.navigator.open(appNodes: fixture.appNodes)

        fixture.navigator.updateHover(.slice(level: 0, index: 0)) // Chrome overflow

        XCTAssertEqual(fixture.navigator.focusedWindowIndex, 0) // confirms a fisheye is active
        XCTAssertEqual(fixture.navigator.prehighlighted, .slice(level: 1, index: 2))
    }

    // MARK: - AC3 → AC4 end-to-end through one navigator

    func testCommittingTheRememberedWindowPreHighlightsItOnTheNextSummon() {
        let fixture = makeFixture()
        fixture.navigator.open(appNodes: fixture.appNodes)
        fixture.navigator.updateHover(.slice(level: 0, index: 0))
        fixture.navigator.commit(.slice(level: 1, index: 1)) // remember Chrome → Docs

        fixture.navigator.open(appNodes: fixture.appNodes) // next summon
        fixture.navigator.updateHover(.slice(level: 0, index: 0)) // expand Chrome again

        XCTAssertEqual(fixture.navigator.prehighlighted, .slice(level: 1, index: 1))
    }

    // MARK: - Fixtures

    private struct Fixture {
        let navigator: RadialNavigator
        let fake: FakeWindowSystem
        let store: LastSelectionStore
        let appNodes: [MenuNode]
    }

    /// Build a navigator over a fake window system and an ephemeral store, with the
    /// apps ring resolved from `windows`. The fake's tokens match the enumerator's
    /// window numbers so a target carried by a window node resolves to the same
    /// window the controller operates on.
    private func makeFixture(windows: [RawWindow]? = nil) -> Fixture {
        let raws = windows ?? [
            raw(number: 11, pid: 10, name: "Chrome", title: "Inbox"),
            raw(number: 12, pid: 10, name: "Chrome", title: "Docs"),
            raw(number: 21, pid: 20, name: "Ghostty", title: "Terminal")
        ]
        let source = StubEnumerationSource(selfPID: 1, windows: raws)
        // Pin the sort order so these tests stay hermetic — the default `WindowEnumerator`
        // closures read `.standard`, where a developer's persisted Preferences (e.g. a
        // "Fixed position" window order) would otherwise reorder the windows out from under
        // the front-to-back assumptions below.
        let enumerator = WindowEnumerator(
            source: source,
            appOrder: { .recentlyUsed },
            windowOrder: { .recentlyUsed }
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
        let store = makeEphemeralStore()
        let navigator = RadialNavigator(windowControl: WindowController(system: fake), store: store)
        return Fixture(navigator: navigator, fake: fake, store: store, appNodes: appNodes)
    }

    /// A `LastSelectionStore` backed by a throwaway suite, torn down after the test,
    /// so the navigator's remember/pre-highlight never read or write `.standard`.
    private func makeEphemeralStore() -> LastSelectionStore {
        let suite = "PieSwitcherTests.RadialNavigatorCommit.\(UUID().uuidString)"
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
