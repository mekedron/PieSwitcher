import XCTest
@testable import PieSwitcher

/// Exercises the chord detection state machine in isolation from the live event stream:
/// every test drives `MouseChordDetector` with synthetic value events and asserts the
/// disposition it returns. Bringr-93j.96 generalised the L+R chord into a multi-method
/// matcher with a configurable hold delay, so most tests now pass a `methods:` set
/// explicitly and assert with `holdDelay = 0` (the immediate-summon path).
final class MouseChordTests: XCTestCase {
    private let leftRight: Set<MouseActivationMethod> = [.leftRight]

    // MARK: - Match completion → summon (delay = 0)

    func testLeftThenRightSummonsImmediatelyWhenDelayIsZero() {
        var detector = MouseChordDetector(pursuitTimeout: 0.12)
        XCTAssertEqual(detector.handle(down(.left, at: 0), methods: leftRight), .hold)
        XCTAssertEqual(detector.handle(down(.right, at: 0.05), methods: leftRight), .summon)
        XCTAssertTrue(detector.isChordActive)
    }

    func testRightThenLeftSummonsImmediatelyWhenDelayIsZero() {
        var detector = MouseChordDetector(pursuitTimeout: 0.12)
        XCTAssertEqual(detector.handle(down(.right, at: 0), methods: leftRight), .hold)
        XCTAssertEqual(detector.handle(down(.left, at: 0.05), methods: leftRight), .summon)
    }

    // MARK: - Match completion with a non-zero hold delay → caller drives the timer

    func testFullMatchHoldsRatherThanSummonsWhenHoldDelayIsNonZero() {
        var detector = MouseChordDetector(pursuitTimeout: 0.12)
        XCTAssertEqual(detector.handle(down(.left, at: 0), methods: leftRight, holdDelay: 0.2), .hold)
        XCTAssertEqual(
            detector.handle(down(.right, at: 0.05), methods: leftRight, holdDelay: 0.2),
            .hold,
            "delay > 0 means the monitor drives the timer; the detector just stays in pursuit"
        )
        XCTAssertEqual(detector.matchedMethod, .leftRight, "full match is visible to the caller")
        XCTAssertFalse(detector.isChordActive, "not chord-active until the monitor calls chordSummoned()")

        detector.chordSummoned()
        XCTAssertTrue(detector.isChordActive)
    }

    // MARK: - Disposition of single clicks (irrelevant or partial-match)

    func testFirstPressIsDeferredNotDelivered() {
        var detector = MouseChordDetector(pursuitTimeout: 0.12)
        XCTAssertEqual(
            detector.handle(down(.left, at: 0), methods: leftRight), .hold,
            "the first press of a multi-button method is held, never passed straight through"
        )
    }

    func testSingleLeftClickIsReplayedAsANormalClick() {
        var detector = MouseChordDetector(pursuitTimeout: 0.12)
        XCTAssertEqual(detector.handle(down(.left, at: 0), methods: leftRight), .hold)
        XCTAssertEqual(detector.handle(up(.left, at: 0.04), methods: leftRight), .releaseHeldWithCurrent)
    }

    func testSingleRightClickIsReplayedAsANormalClick() {
        var detector = MouseChordDetector(pursuitTimeout: 0.12)
        XCTAssertEqual(detector.handle(down(.right, at: 0), methods: leftRight), .hold)
        XCTAssertEqual(detector.handle(up(.right, at: 0.04), methods: leftRight), .releaseHeldWithCurrent)
    }

    func testPressAndHoldBeyondPursuitTimeoutReplaysViaTimeout() {
        var detector = MouseChordDetector(pursuitTimeout: 0.12)
        _ = detector.handle(down(.left, at: 0), methods: leftRight)
        XCTAssertFalse(detector.handleTimeout(at: 0.05), "still within the timeout — keep waiting")
        XCTAssertTrue(detector.handleTimeout(at: 0.12), "timeout elapsed — replay as a normal press")
    }

    func testTimeoutWhenIdleDoesNothing() {
        var detector = MouseChordDetector(pursuitTimeout: 0.12)
        XCTAssertFalse(detector.handleTimeout(at: 1.0))
    }

    func testStrayUpWhenIdlePassesThrough() {
        var detector = MouseChordDetector(pursuitTimeout: 0.12)
        XCTAssertEqual(detector.handle(up(.left, at: 0), methods: leftRight), .pass)
    }

    // MARK: - Irrelevant buttons pass through (no enabled method uses them)

    func testIrrelevantButtonPassesThrough() {
        var detector = MouseChordDetector(pursuitTimeout: 0.12)
        // No method uses Middle, so a Middle press has nothing to pursue.
        XCTAssertEqual(detector.handle(down(.middle, at: 0), methods: leftRight), .pass)
    }

    // MARK: - Chord aftermath: presses and releases during the active chord are consumed

    func testChordConsumesSecondPressAndAllReleases() {
        var detector = MouseChordDetector(pursuitTimeout: 0.12)
        _ = detector.handle(down(.left, at: 0), methods: leftRight)
        XCTAssertEqual(detector.handle(down(.right, at: 0.05), methods: leftRight), .summon)
        XCTAssertEqual(detector.handle(up(.left, at: 0.20), methods: leftRight), .consume)
        XCTAssertEqual(detector.handle(up(.right, at: 0.22), methods: leftRight), .consume)
    }

    func testExtraPressesDuringAChordAreConsumed() {
        var detector = MouseChordDetector(pursuitTimeout: 0.12)
        _ = detector.handle(down(.left, at: 0), methods: leftRight)
        _ = detector.handle(down(.right, at: 0.05), methods: leftRight)
        XCTAssertEqual(detector.handle(down(.left, at: 0.10), methods: leftRight), .consume)
        XCTAssertEqual(detector.handle(up(.left, at: 0.12), methods: leftRight), .consume)
        XCTAssertEqual(detector.handle(up(.left, at: 0.30), methods: leftRight), .consume)
        XCTAssertEqual(detector.handle(up(.right, at: 0.32), methods: leftRight), .consume)
    }

    // MARK: - Bringr-93j.94: drag while holding releases the buffered press

    func testMotionWhileHoldingFirstPressReleasesTheHold() {
        var detector = MouseChordDetector(pursuitTimeout: 0.12)
        XCTAssertEqual(detector.handle(down(.left, at: 0), methods: leftRight), .hold)
        XCTAssertTrue(
            detector.motionDetected(),
            "a drag during the chord-pursuit window means the user is dragging — release the held press"
        )
        XCTAssertEqual(
            detector.handle(down(.right, at: 0.10), methods: leftRight), .hold,
            "after the release the machine is idle, so the partner is a fresh first press"
        )
    }

    func testMotionWhenIdleDoesNothing() {
        var detector = MouseChordDetector(pursuitTimeout: 0.12)
        XCTAssertFalse(detector.motionDetected())
    }

    func testMotionDuringChordDoesNotReleaseAnything() {
        var detector = MouseChordDetector(pursuitTimeout: 0.12)
        _ = detector.handle(down(.left, at: 0), methods: leftRight)
        _ = detector.handle(down(.right, at: 0.05), methods: leftRight)
        XCTAssertFalse(
            detector.motionDetected(),
            "the chord has already summoned and its presses were consumed — nothing left to release"
        )
        XCTAssertEqual(detector.handle(up(.left, at: 0.20), methods: leftRight), .consume)
        XCTAssertEqual(detector.handle(up(.right, at: 0.22), methods: leftRight), .consume)
    }

    // MARK: - Clean recovery between gestures

    func testAfterAChordANewSingleClickPassesThrough() {
        var detector = MouseChordDetector(pursuitTimeout: 0.12)
        _ = detector.handle(down(.left, at: 0), methods: leftRight)
        _ = detector.handle(down(.right, at: 0.05), methods: leftRight)
        _ = detector.handle(up(.left, at: 0.20), methods: leftRight)
        _ = detector.handle(up(.right, at: 0.22), methods: leftRight)

        XCTAssertEqual(detector.handle(down(.left, at: 0.50), methods: leftRight), .hold)
        XCTAssertEqual(detector.handle(up(.left, at: 0.54), methods: leftRight), .releaseHeldWithCurrent)
    }

    func testResetClearsAHeldPress() {
        var detector = MouseChordDetector(pursuitTimeout: 0.12)
        _ = detector.handle(down(.left, at: 0), methods: leftRight)
        detector.reset()
        XCTAssertEqual(detector.handle(down(.right, at: 0.02), methods: leftRight), .hold)
    }

    // MARK: - Bringr-93j.96: new methods — middle, side buttons, multi-button combos

    func testMiddleAloneAtNonZeroDelayMatchesAndSummonsViaChordSummoned() {
        // With a non-zero (user-chosen) hold delay, the live monitor drives the timer; the
        // detector just holds and exposes the matched method until `chordSummoned()` lands.
        var detector = MouseChordDetector(pursuitTimeout: 0.12)
        XCTAssertEqual(detector.handle(down(.middle, at: 0), methods: [.middle], holdDelay: 0.25), .hold)
        XCTAssertEqual(detector.matchedMethod, .middle)
        detector.chordSummoned()
        XCTAssertTrue(detector.isChordActive)
    }

    func testForwardAloneAtNonZeroDelayMatches() {
        var detector = MouseChordDetector(pursuitTimeout: 0.12)
        XCTAssertEqual(detector.handle(down(.forward, at: 0), methods: [.forward], holdDelay: 0.25), .hold)
        XCTAssertEqual(detector.matchedMethod, .forward)
    }

    func testBackwardAloneAtNonZeroDelayMatches() {
        var detector = MouseChordDetector(pursuitTimeout: 0.12)
        XCTAssertEqual(detector.handle(down(.backward, at: 0), methods: [.backward], holdDelay: 0.25), .hold)
        XCTAssertEqual(detector.matchedMethod, .backward)
    }

    func testMiddlePlusLeftSummonsOnFullMatch() {
        var detector = MouseChordDetector(pursuitTimeout: 0.12)
        XCTAssertEqual(detector.handle(down(.middle, at: 0), methods: [.middleLeft]), .hold)
        XCTAssertEqual(detector.handle(down(.left, at: 0.05), methods: [.middleLeft]), .summon)
    }

    func testForwardPlusBackwardSummonsOnFullMatch() {
        var detector = MouseChordDetector(pursuitTimeout: 0.12)
        XCTAssertEqual(detector.handle(down(.forward, at: 0), methods: [.forwardBackward]), .hold)
        XCTAssertEqual(detector.handle(down(.backward, at: 0.05), methods: [.forwardBackward]), .summon)
    }

    // MARK: - Bringr-93j.100: single-button methods need a hold floor at 0 ms

    func testSingleButtonAtZeroDelayHoldsInsteadOfSummoning() {
        // Without the floor, a normal middle/side-button click would be eaten by the detector
        // before the focused app ever saw it — picking a single-button method as activation
        // would silently break the button's normal action (e.g. middle-click opens new tab).
        // The detector must hold and let the monitor's timer (or a quick release) decide.
        for method: MouseActivationMethod in [.middle, .forward, .backward] {
            var detector = MouseChordDetector(pursuitTimeout: 0.12)
            let button = method.requiredButtons.first!  // single-button by definition here
            XCTAssertEqual(
                detector.handle(down(button, at: 0), methods: [method], holdDelay: 0), .hold,
                "\(method) must hold instead of summon at 0 ms"
            )
            XCTAssertEqual(detector.matchedMethod, method)
            XCTAssertFalse(detector.isChordActive)
        }
    }

    func testQuickSingleButtonTapAtZeroDelayReplaysAsNormalClick() {
        // The fix's whole point: tap-then-release for a single-button method at the default
        // 0 ms hold delay falls through as the user's normal click.
        var detector = MouseChordDetector(pursuitTimeout: 0.12)
        XCTAssertEqual(detector.handle(down(.middle, at: 0), methods: [.middle], holdDelay: 0), .hold)
        XCTAssertEqual(
            detector.handle(up(.middle, at: 0.05), methods: [.middle], holdDelay: 0),
            .releaseHeldWithCurrent,
            "release before the floor elapses ⇒ replay buffered press alongside the up as a normal click"
        )
    }

    func testSingleButtonAtZeroDelaySummonsAfterChordSummoned() {
        // The monitor's hold-delay timer (scheduled at the effective delay) ultimately calls
        // `chordSummoned()`; the detector then transitions to the active chord state just like
        // the multi-button path.
        var detector = MouseChordDetector(pursuitTimeout: 0.12)
        XCTAssertEqual(detector.handle(down(.middle, at: 0), methods: [.middle], holdDelay: 0), .hold)
        detector.chordSummoned()
        XCTAssertTrue(detector.isChordActive)
        XCTAssertEqual(
            detector.handle(up(.middle, at: 0.30), methods: [.middle], holdDelay: 0), .consume,
            "after the timer summons, the trailing up belongs to the chord teardown — never to the app"
        )
    }

    func testMultiButtonChordStillSummonsAtZeroDelay() {
        // The floor only applies to single-button methods. L+R must still fire instantly on
        // simultaneity at 0 ms — that's exactly the .96 behaviour the floor preserves.
        var detector = MouseChordDetector(pursuitTimeout: 0.12)
        XCTAssertEqual(detector.handle(down(.left, at: 0), methods: leftRight, holdDelay: 0), .hold)
        XCTAssertEqual(detector.handle(down(.right, at: 0.02), methods: leftRight, holdDelay: 0), .summon)
    }

    func testNonZeroHoldDelayForSingleButtonIsRespected() {
        // Explicit non-zero delays bypass the floor — the user asked for that latency.
        var detector = MouseChordDetector(pursuitTimeout: 0.12)
        XCTAssertEqual(detector.handle(down(.middle, at: 0), methods: [.middle], holdDelay: 0.5), .hold)
    }

    func testThirdButtonOutsideAnyMethodEndsPursuit() {
        // L is buffered toward L+R. Forward is in no enabled method's required set, so the
        // pursuit can no longer reach a match — replay L and deliver F alongside it.
        var detector = MouseChordDetector(pursuitTimeout: 0.12)
        XCTAssertEqual(detector.handle(down(.left, at: 0), methods: leftRight), .hold)
        XCTAssertEqual(
            detector.handle(down(.forward, at: 0.05), methods: leftRight),
            .releaseHeldWithCurrent,
            "Forward cannot complete L+R, so the pursuit is abandoned and both events replay in order"
        )
    }

    func testRelevantButPursuitBreakingPressEndsPursuit() {
        // Both L+R and F+B are enabled. L is buffered toward L+R. Pressing F is "relevant"
        // (some method uses F) but adding F to {L} doesn't keep us a subset of L+R (={L,R})
        // OR of F+B (={F,B}) — pursuit can't reach either method, so abandon and replay.
        let methods: Set<MouseActivationMethod> = [.leftRight, .forwardBackward]
        var detector = MouseChordDetector(pursuitTimeout: 0.12)
        XCTAssertEqual(detector.handle(down(.left, at: 0), methods: methods), .hold)
        XCTAssertEqual(
            detector.handle(down(.forward, at: 0.05), methods: methods), .releaseHeldWithCurrent,
            "{L,F} is a subset of neither {L,R} nor {F,B}, so the pursuit cannot be completed"
        )
    }

    func testMethodsAreIndependentlyMatchable() {
        // Both Middle (single button) and Middle+Left enabled. Middle alone matches Middle;
        // Middle+Left matches the combo. Each press is interpreted against the full set.
        // The single-button floor (Bringr-93j.100) means Middle holds at 0 ms instead of
        // summoning immediately, but with a non-zero delay the user-configured value is
        // respected and the detector exposes the match for the monitor's timer to drive.
        let methods: Set<MouseActivationMethod> = [.middle, .middleLeft]
        var detector = MouseChordDetector(pursuitTimeout: 0.12)
        XCTAssertEqual(
            detector.handle(down(.middle, at: 0), methods: methods, holdDelay: 0.25),
            .hold,
            "Middle alone exactly matches the single-button method, so it's the pursuit's matched method"
        )
        XCTAssertEqual(detector.matchedMethod, .middle)
    }

    // MARK: - Helpers

    private func down(_ button: MouseButton, at timestamp: TimeInterval) -> MouseButtonEvent {
        MouseButtonEvent(button: button, phase: .down, timestamp: timestamp)
    }

    private func up(_ button: MouseButton, at timestamp: TimeInterval) -> MouseButtonEvent {
        MouseButtonEvent(button: button, phase: .up, timestamp: timestamp)
    }
}
