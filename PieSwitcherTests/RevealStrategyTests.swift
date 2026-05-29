import CoreGraphics
import XCTest
@testable import PieSwitcher

/// Covers the reveal-strategy setting (US-013): the persistence helpers behind the
/// Preferences picker (AC1, AC4, AC5 default) and `WindowController`'s mapping of
/// each strategy onto its window-control primitives at both the app and window
/// levels (AC2, AC3), driven against `FakeWindowSystem` + `FakeDimmer` doubles.
@MainActor
final class RevealStrategyTests: XCTestCase {

    // MARK: - Persistence helpers (AC1, AC4, AC5 default)

    func testDefaultStrategyIsHideOthers() {
        XCTAssertEqual(RevealStrategy.default, .hideOthers)
    }

    func testDefaultsKeyIsStable() {
        XCTAssertEqual(RevealStrategy.defaultsKey, "revealStrategy")
    }

    func testThereAreExactlyThreeStrategies() {
        XCTAssertEqual(Set(RevealStrategy.allCases), [.raiseToFront, .hideOthers, .dimOthers])
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
        let fake = FakeWindowSystem(apps: [makeApp(1), makeApp(2), makeApp(3)], frontmost: AppID(pid: 1))
        let controller = WindowController(system: fake) // no setStrategy → default

        controller.revealApp(AppID(pid: 2))

        XCTAssertTrue(fake.isHidden(AppID(pid: 1)))
        XCTAssertFalse(fake.isHidden(AppID(pid: 2)))
        XCTAssertTrue(fake.isHidden(AppID(pid: 3)))
    }

    // MARK: - AC2/AC3: raise-to-front at both levels

    func testRaiseToFrontRevealAppActivatesTargetAndHidesNothing() {
        let dimmer = FakeDimmer()
        let fake = FakeWindowSystem(apps: [makeApp(1), makeApp(2), makeApp(3)], frontmost: AppID(pid: 1))
        let controller = WindowController(system: fake, dimmer: dimmer)
        controller.setStrategy(.raiseToFront)

        controller.revealApp(AppID(pid: 2))

        XCTAssertEqual(fake.frontmost, AppID(pid: 2), "the hovered app is brought to the front")
        XCTAssertFalse(fake.isHidden(AppID(pid: 1)), "raise-to-front hides nothing")
        XCTAssertFalse(fake.isHidden(AppID(pid: 3)))
        XCTAssertTrue(dimmer.calls.isEmpty, "raise-to-front never dims")

        controller.restore()
        XCTAssertEqual(fake.frontmost, AppID(pid: 1), "restore re-activates the prior frontmost")
    }

    func testRaiseToFrontRevealWindowRaisesTargetWithoutMinimizing() {
        let appA = AppID(pid: 1)
        let target = WindowID(app: appA, token: 11)
        let dimmer = FakeDimmer()
        let fake = FakeWindowSystem(apps: [makeApp(1, windowTokens: [10, 11, 12])], frontmost: appA)
        let controller = WindowController(system: fake, dimmer: dimmer)
        controller.setStrategy(.raiseToFront)

        controller.revealWindow(target)

        XCTAssertEqual(fake.windows(of: appA).first, target, "the hovered window is raised to the front")
        XCTAssertFalse(fake.isMinimized(WindowID(app: appA, token: 10)), "no sibling is minimized")
        XCTAssertFalse(fake.isMinimized(WindowID(app: appA, token: 12)))
        XCTAssertTrue(dimmer.calls.isEmpty)

        controller.restore()
        XCTAssertEqual(fake.windows(of: appA), [
            WindowID(app: appA, token: 10),
            WindowID(app: appA, token: 11),
            WindowID(app: appA, token: 12)
        ], "restore returns the original front-to-back order")
    }

    func testRaiseToFrontCommitReturnsPreviewedWindowsToTheirOriginalOrder() {
        // Raise-to-front leaves each hovered window raised (nothing parked/hidden), so
        // browsing the sub-wheel drifts the live order. Committing a *different* window
        // must drop the windows hovered along the way back to their pre-summon order
        // behind the choice, not leave them stacked in hover order (Bringr-93j.47).
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

        // Chosen window on top; w10 sits ahead of w12 again — their pre-summon order —
        // rather than w12 staying raised from the preview.
        XCTAssertEqual(fake.windows(of: appA), [w11, w10, w12])
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
        let controller = WindowController(system: fake) // default hide-others

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
        let controller = WindowController(system: fake) // default hide-others

        controller.revealWindow(w11)
        controller.revealWindow(w10) // re-target: raise the new hover; siblings stay put

        XCTAssertEqual(fake.windows(of: appA).first, w10, "re-targeting raises the newly hovered window")
        XCTAssertFalse(fake.isMinimized(w11), "the previously previewed window stays on screen")
    }

    // MARK: - AC2/AC3: dim-others at both levels

    func testDimOthersRevealAppRaisesTargetAndDimsExcludingItsWindows() {
        let dimmer = FakeDimmer()
        let fake = FakeWindowSystem(
            apps: [makeApp(1), makeApp(2, windowTokens: [20, 21]), makeApp(3)],
            frontmost: AppID(pid: 1)
        )
        fake.frames[WindowID(app: AppID(pid: 2), token: 20)] = rect(20)
        fake.frames[WindowID(app: AppID(pid: 2), token: 21)] = rect(21)
        let controller = WindowController(system: fake, dimmer: dimmer)
        controller.setStrategy(.dimOthers)

        controller.revealApp(AppID(pid: 2))

        XCTAssertEqual(fake.frontmost, AppID(pid: 2), "the target app is raised so its windows fill the cutout")
        XCTAssertFalse(fake.isHidden(AppID(pid: 1)), "dim hides nothing — it darkens with an overlay")
        XCTAssertFalse(fake.isHidden(AppID(pid: 3)))
        XCTAssertEqual(dimmer.lastDimHoles, [rect(20), rect(21)], "the target app's windows are cut out")
    }

    func testDimOthersRevealWindowRaisesTargetAndDimsExcludingItsFrame() {
        let appA = AppID(pid: 1)
        let target = WindowID(app: appA, token: 11)
        let dimmer = FakeDimmer()
        let fake = FakeWindowSystem(apps: [makeApp(1, windowTokens: [10, 11])], frontmost: appA)
        fake.frames[WindowID(app: appA, token: 10)] = rect(10)
        fake.frames[target] = rect(11)
        let controller = WindowController(system: fake, dimmer: dimmer)
        controller.setStrategy(.dimOthers)

        controller.revealWindow(target)

        XCTAssertEqual(fake.windows(of: appA).first, target, "the target window is raised into the cutout")
        XCTAssertFalse(fake.isMinimized(WindowID(app: appA, token: 10)), "siblings stay visible, just dimmed")
        XCTAssertEqual(dimmer.lastDimHoles, [rect(11)], "only the target window is cut out")
    }

    func testDimOthersRevealWindowWithoutAFrameDimsUniformly() {
        let appA = AppID(pid: 1)
        let target = WindowID(app: appA, token: 11)
        let dimmer = FakeDimmer()
        let fake = FakeWindowSystem(apps: [makeApp(1, windowTokens: [10, 11])], frontmost: appA)
        // No frame fixtured for the target → graceful fallback to a hole-less dim.
        let controller = WindowController(system: fake, dimmer: dimmer)
        controller.setStrategy(.dimOthers)

        controller.revealWindow(target)

        XCTAssertEqual(dimmer.lastDimHoles, [], "an unresolved frame falls back to a uniform dim")
        XCTAssertEqual(fake.windows(of: appA).first, target, "the target is still raised, so it reads as frontmost")
    }

    func testDimOthersRestoreClearsTheSpotlight() {
        let dimmer = FakeDimmer()
        let fake = FakeWindowSystem(apps: [makeApp(1), makeApp(2)], frontmost: AppID(pid: 1))
        let controller = WindowController(system: fake, dimmer: dimmer)
        controller.setStrategy(.dimOthers)
        controller.revealApp(AppID(pid: 2))
        XCTAssertEqual(dimmer.clearCount, 0)

        controller.restore()

        XCTAssertEqual(dimmer.clearCount, 1, "restore tears the spotlight down")
    }

    func testDimOthersLeavingWindowSubWheelReDimsAtAppLevel() {
        let appA = AppID(pid: 1)
        let dimmer = FakeDimmer()
        let fake = FakeWindowSystem(apps: [makeApp(1, windowTokens: [10, 11])], frontmost: appA)
        fake.frames[WindowID(app: appA, token: 10)] = rect(10)
        fake.frames[WindowID(app: appA, token: 11)] = rect(11)
        let controller = WindowController(system: fake, dimmer: dimmer)
        controller.setStrategy(.dimOthers)
        controller.revealApp(appA)                          // app-level: cut out [10, 11]
        controller.revealWindow(WindowID(app: appA, token: 11)) // window-level: cut out [11]
        XCTAssertEqual(dimmer.lastDimHoles, [rect(11)])

        controller.restoreWindows(of: appA)                 // leave the sub-wheel

        XCTAssertEqual(dimmer.lastDimHoles, [rect(10), rect(11)],
                       "returning to the app level re-cuts the dim to all of the app's windows")
    }

    // MARK: - Fixtures

    private func rect(_ seed: Int) -> CGRect {
        CGRect(x: CGFloat(seed), y: CGFloat(seed), width: 100, height: 80)
    }

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
