import CoreGraphics
import XCTest
@testable import PieSwitcher

/// Covers the reveal-strategy setting (US-013): the persistence helpers behind the
/// Preferences picker (AC1, AC4, AC5 default) and `WindowController`'s mapping of
/// each strategy onto its window-control primitives at both the app and window
/// levels (AC2, AC3), driven against `FakeWindowSystem`.
@MainActor
final class RevealStrategyTests: XCTestCase {

    // MARK: - Persistence helpers (AC1, AC4, AC5 default)

    func testDefaultStrategyIsHideOthers() {
        // Bringr-93j.113: the fresh-install default flipped from `.raiseToFront` to
        // `.hideOthers` to match the converged "best combination" — the strongest
        // isolation, so the wheel acts as a visual filter that makes the choice
        // unambiguous before committing. Users who prefer the lowest-disruption option
        // can switch back to `.raiseToFront` in Preferences.
        XCTAssertEqual(RevealStrategy.default, .hideOthers)
    }

    func testDefaultsKeyIsStable() {
        XCTAssertEqual(RevealStrategy.defaultsKey, "revealStrategy")
    }

    func testThereAreExactlyTwoStrategies() {
        XCTAssertEqual(Set(RevealStrategy.allCases), [.raiseToFront, .hideOthers])
    }

    func testCurrentReadsEveryPersistedStrategy() {
        for strategy in RevealStrategy.allCases {
            let defaults = makeDefaults()
            defaults.set(strategy.rawValue, forKey: RevealStrategy.defaultsKey)
            XCTAssertEqual(RevealStrategy.current(from: defaults), strategy)
        }
    }

    func testCurrentFallsBackToDefaultWhenUnset() {
        XCTAssertEqual(RevealStrategy.current(from: makeDefaults()), .default)
    }

    func testCurrentFallsBackToDefaultWhenUnrecognized() {
        let defaults = makeDefaults()
        defaults.set("not-a-strategy", forKey: RevealStrategy.defaultsKey)
        XCTAssertEqual(RevealStrategy.current(from: defaults), .default)
    }

    func testDisplayNamesAreDistinctAndNonEmpty() {
        let names = RevealStrategy.allCases.map(\.displayName)
        XCTAssertFalse(names.contains(where: \.isEmpty))
        XCTAssertEqual(Set(names).count, names.count)
    }

    func testDetailsAreNonEmpty() {
        XCTAssertFalse(RevealStrategy.allCases.map(\.detail).contains(where: \.isEmpty))
    }

    // MARK: - hide-others is the controller's default (proves the wiring, AC5)

    func testUnconfiguredControllerHidesOthers() {
        // Bringr-93j.113: the controller's default strategy follows `RevealStrategy.default`,
        // which flipped from `.raiseToFront` to `.hideOthers`. An unconfigured controller
        // therefore hides every non-target app on `revealApp`; the target itself isn't
        // explicitly activated (it becomes the only visible app, which is what the user
        // wants from a "leave only my target on screen" reveal — the existing
        // hide-others tests below confirm the same primitive behaviour).
        let fake = FakeWindowSystem(apps: [makeApp(1), makeApp(2), makeApp(3)], frontmost: AppID(pid: 1))
        let controller = WindowController(system: fake) // no setStrategy → default

        controller.revealApp(AppID(pid: 2))

        XCTAssertTrue(fake.isHidden(AppID(pid: 1)), "hide-others isolates the target by hiding the rest")
        XCTAssertTrue(fake.isHidden(AppID(pid: 3)))
        XCTAssertFalse(fake.isHidden(AppID(pid: 2)), "the target itself stays visible")
    }

    // MARK: - AC2/AC3: raise-to-front at both levels

    func testRaiseToFrontRevealAppActivatesTargetAndHidesNothing() {
        let fake = FakeWindowSystem(apps: [makeApp(1), makeApp(2), makeApp(3)], frontmost: AppID(pid: 1))
        let controller = WindowController(system: fake)
        controller.setStrategy(.raiseToFront)

        controller.revealApp(AppID(pid: 2))

        XCTAssertEqual(fake.frontmost, AppID(pid: 2), "the hovered app is brought to the front")
        XCTAssertFalse(fake.isHidden(AppID(pid: 1)), "raise-to-front hides nothing")
        XCTAssertFalse(fake.isHidden(AppID(pid: 3)))

        controller.restore()
        XCTAssertEqual(fake.frontmost, AppID(pid: 1), "restore re-activates the prior frontmost")
    }

    func testRaiseToFrontRevealWindowRaisesTargetWithoutMinimizing() {
        let appA = AppID(pid: 1)
        let target = WindowID(app: appA, token: 11)
        let fake = FakeWindowSystem(apps: [makeApp(1, windowTokens: [10, 11, 12])], frontmost: appA)
        let controller = WindowController(system: fake)
        controller.setStrategy(.raiseToFront)

        controller.revealWindow(target)

        XCTAssertEqual(fake.windows(of: appA).first, target, "the hovered window is raised to the front")
        XCTAssertFalse(fake.isMinimized(WindowID(app: appA, token: 10)), "no sibling is minimized")
        XCTAssertFalse(fake.isMinimized(WindowID(app: appA, token: 12)))

        controller.restore()
        XCTAssertEqual(fake.windows(of: appA), [
            WindowID(app: appA, token: 10),
            WindowID(app: appA, token: 11),
            WindowID(app: appA, token: 12)
        ], "restore returns the original front-to-back order")
    }

    func testRaiseToFrontCommitLeavesPreviewedWindowsInHoverDriftOrder() {
        // Bringr-93j.88: preview = commit. Raise-to-front leaves each hovered window
        // raised (nothing parked/hidden), so browsing the sub-wheel drifts the live
        // order. Commit no longer restores the pre-summon order on top of the choice —
        // the hover-drift order is the final order (the choice raised, then whichever
        // sibling was raised most recently behind it). This obsoletes the .47 "siblings
        // return to original order on commit" behaviour: preview = commit, restore is
        // reserved for cancel paths.
        let appA = AppID(pid: 1)
        let fake = FakeWindowSystem(apps: [makeApp(1, windowTokens: [10, 11, 12])], frontmost: appA)
        let controller = WindowController(system: fake)
        controller.setStrategy(.raiseToFront)
        let (w10, w11, w12) = (WindowID(app: appA, token: 10),
                               WindowID(app: appA, token: 11),
                               WindowID(app: appA, token: 12))

        controller.revealWindow(w11) // preview w11 → [w11, w10, w12]
        controller.revealWindow(w12) // preview w12 → [w12, w11, w10]
        XCTAssertEqual(fake.windows(of: appA), [w12, w11, w10], "hovering raised each previewed window")

        controller.commit(w11)

        // Chosen window on top; w12 stays raised from the preview behind it (hover-
        // drift order), w10 last — the pre-summon order is NOT reinstated.
        XCTAssertEqual(fake.windows(of: appA), [w11, w12, w10])
        XCTAssertEqual(fake.focusedWindow, w11)
    }

    // MARK: - hide-others at the window level just raises for preview (Bringr-93j.83)

    func testHideOthersRevealWindowRaisesTargetAndLeavesSiblingsInPlace() {
        // Hide-others isolates other *apps* (via revealApp), but a window hover must NOT
        // hide/minimize the app's siblings — it only raises the hovered window for
        // preview, like raise-to-front (Bringr-93j.83).
        let appA = AppID(pid: 1)
        let (target, sibling) = (WindowID(app: appA, token: 11), WindowID(app: appA, token: 10))
        let fake = FakeWindowSystem(apps: [makeApp(1, windowTokens: [10, 11])], frontmost: appA)
        let controller = WindowController(system: fake)
        controller.setStrategy(.hideOthers)

        controller.revealWindow(target)

        XCTAssertEqual(fake.windows(of: appA).first, target, "the hovered window is raised to the front")
        XCTAssertFalse(fake.isMinimized(sibling), "the sibling is not minimized")

        controller.restore()
        XCTAssertEqual(fake.windows(of: appA), [sibling, target], "restore returns the original order")
    }

    func testHideOthersRevealWindowReTargetRaisesNewTargetLeavingSiblings() {
        let appA = AppID(pid: 1)
        let (w10, w11) = (WindowID(app: appA, token: 10), WindowID(app: appA, token: 11))
        let fake = FakeWindowSystem(apps: [makeApp(1, windowTokens: [10, 11])], frontmost: appA)
        let controller = WindowController(system: fake)
        controller.setStrategy(.hideOthers)

        controller.revealWindow(w11)
        controller.revealWindow(w10) // re-target: raise the new hover; siblings stay put

        XCTAssertEqual(fake.windows(of: appA).first, w10, "re-targeting raises the newly hovered window")
        XCTAssertFalse(fake.isMinimized(w11), "the previously previewed window stays on screen")
    }

    // MARK: - Fixtures

    private func makeApp(_ pid: pid_t, windowTokens: [Int] = []) -> FakeWindowSystem.AppState {
        let appID = AppID(pid: pid)
        let windows = windowTokens.map {
            FakeWindowSystem.WindowState(id: WindowID(app: appID, token: $0), minimized: false)
        }
        return FakeWindowSystem.AppState(id: appID, hidden: false, windows: windows)
    }

    /// An isolated `UserDefaults` suite so persistence tests never touch the real domain.
    private func makeDefaults() -> UserDefaults {
        let suiteName = "RevealStrategyTests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            fatalError("could not create a test UserDefaults suite")
        }
        return defaults
    }
}
