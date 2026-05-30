import XCTest
@testable import PieSwitcher

/// Exercises the chord detection state machine in isolation from the live event
/// stream (AC5): every test drives `MouseChordDetector` with synthetic value
/// events and asserts the disposition it returns.
final class MouseChordTests: XCTestCase {
    // MARK: - AC1: simultaneous press summons

    func testLeftThenRightWithinThresholdSummons() {
        var detector = MouseChordDetector(threshold: 0.12)
        XCTAssertEqual(detector.handle(down(.left, at: 0)), .hold)
        XCTAssertEqual(detector.handle(down(.right, at: 0.05)), .summon)
    }

    func testRightThenLeftWithinThresholdSummons() {
        var detector = MouseChordDetector(threshold: 0.12)
        XCTAssertEqual(detector.handle(down(.right, at: 0)), .hold)
        XCTAssertEqual(detector.handle(down(.left, at: 0.05)), .summon)
    }

    func testSecondPressOnThresholdBoundarySummons() {
        var detector = MouseChordDetector(threshold: 0.12)
        _ = detector.handle(down(.left, at: 0))
        XCTAssertEqual(detector.handle(down(.right, at: 0.12)), .summon)
    }

    // MARK: - AC1: configurable threshold

    func testThresholdGovernsWhetherAPairIsAChord() {
        var tight = MouseChordDetector(threshold: 0.05)
        _ = tight.handle(down(.left, at: 0))
        XCTAssertEqual(
            tight.handle(down(.right, at: 0.08)), .releaseHeldThenHold,
            "0.08s gap exceeds a 0.05s threshold, so it is not a chord"
        )

        var loose = MouseChordDetector(threshold: 0.20)
        _ = loose.handle(down(.left, at: 0))
        XCTAssertEqual(
            loose.handle(down(.right, at: 0.08)), .summon,
            "0.08s gap is within a 0.20s threshold, so it is a chord"
        )
    }

    // MARK: - AC2: normal single clicks pass through

    func testFirstPressIsDeferredNotDelivered() {
        var detector = MouseChordDetector(threshold: 0.12)
        XCTAssertEqual(
            detector.handle(down(.left, at: 0)), .hold,
            "the first press is held, never passed straight through, so a chord cannot leak"
        )
    }

    func testSingleLeftClickIsReplayedAsANormalClick() {
        var detector = MouseChordDetector(threshold: 0.12)
        XCTAssertEqual(detector.handle(down(.left, at: 0)), .hold)
        XCTAssertEqual(detector.handle(up(.left, at: 0.04)), .releaseHeldWithCurrent)
    }

    func testSingleRightClickIsReplayedAsANormalClick() {
        var detector = MouseChordDetector(threshold: 0.12)
        XCTAssertEqual(detector.handle(down(.right, at: 0)), .hold)
        XCTAssertEqual(detector.handle(up(.right, at: 0.04)), .releaseHeldWithCurrent)
    }

    func testPressAndHoldBeyondThresholdReplaysViaTimeout() {
        var detector = MouseChordDetector(threshold: 0.12)
        _ = detector.handle(down(.left, at: 0))
        XCTAssertFalse(detector.handleTimeout(at: 0.05), "still within the threshold")
        XCTAssertTrue(detector.handleTimeout(at: 0.12), "threshold elapsed — replay as a normal press")
    }

    func testTimeoutWhenIdleDoesNothing() {
        var detector = MouseChordDetector(threshold: 0.12)
        XCTAssertFalse(detector.handleTimeout(at: 1.0))
    }

    func testStrayUpWhenIdlePassesThrough() {
        var detector = MouseChordDetector(threshold: 0.12)
        XCTAssertEqual(detector.handle(up(.left, at: 0)), .pass)
    }

    func testLatePartnerReleasesHeldPressThenHoldsTheNewOne() {
        var detector = MouseChordDetector(threshold: 0.12)
        XCTAssertEqual(detector.handle(down(.left, at: 0)), .hold)
        // Partner arrives too late to be simultaneous: replay the held left, hold right.
        XCTAssertEqual(detector.handle(down(.right, at: 0.30)), .releaseHeldThenHold)
        // The now-held right, released alone, is a normal click.
        XCTAssertEqual(detector.handle(up(.right, at: 0.34)), .releaseHeldWithCurrent)
    }

    // MARK: - AC4: a chord leaks nothing to the focused app

    func testChordConsumesSecondPressAndAllReleases() {
        var detector = MouseChordDetector(threshold: 0.12)
        _ = detector.handle(down(.left, at: 0))
        XCTAssertEqual(detector.handle(down(.right, at: 0.05)), .summon)
        // Both releases of the chord are swallowed, so the app never sees them.
        XCTAssertEqual(detector.handle(up(.left, at: 0.20)), .consume)
        XCTAssertEqual(detector.handle(up(.right, at: 0.22)), .consume)
    }

    func testExtraPressesDuringAChordAreConsumed() {
        var detector = MouseChordDetector(threshold: 0.12)
        _ = detector.handle(down(.left, at: 0))
        _ = detector.handle(down(.right, at: 0.05))
        XCTAssertEqual(detector.handle(down(.left, at: 0.10)), .consume)
        XCTAssertEqual(detector.handle(up(.left, at: 0.12)), .consume)
        XCTAssertEqual(detector.handle(up(.left, at: 0.30)), .consume)
        XCTAssertEqual(detector.handle(up(.right, at: 0.32)), .consume)
    }

    // MARK: - Bringr-93j.94: drag while holding releases the buffered press

    func testMotionWhileHoldingFirstPressReleasesTheHold() {
        var detector = MouseChordDetector(threshold: 0.12)
        XCTAssertEqual(detector.handle(down(.left, at: 0)), .hold)
        XCTAssertTrue(
            detector.motionDetected(),
            "a drag during the chord-pursuit window means the user is dragging — release the held press"
        )
        // After the release the machine is idle, so a partner that lands later is treated as a
        // fresh first press, never as the back half of a stale chord.
        XCTAssertEqual(detector.handle(down(.right, at: 0.10)), .hold)
    }

    func testMotionWhenIdleDoesNothing() {
        var detector = MouseChordDetector(threshold: 0.12)
        XCTAssertFalse(
            detector.motionDetected(),
            "no press is buffered — motion is the live tap's pass-through case"
        )
    }

    func testMotionDuringChordDoesNotReleaseAnything() {
        var detector = MouseChordDetector(threshold: 0.12)
        _ = detector.handle(down(.left, at: 0))
        _ = detector.handle(down(.right, at: 0.05))
        XCTAssertFalse(
            detector.motionDetected(),
            "the chord has already summoned and its presses were consumed — nothing left to release"
        )
        // The chord is still latched: the chord buttons keep being consumed until both go up.
        XCTAssertEqual(detector.handle(up(.left, at: 0.20)), .consume)
        XCTAssertEqual(detector.handle(up(.right, at: 0.22)), .consume)
    }

    // MARK: - Clean recovery between gestures

    func testAfterAChordANewSingleClickPassesThrough() {
        var detector = MouseChordDetector(threshold: 0.12)
        _ = detector.handle(down(.left, at: 0))
        _ = detector.handle(down(.right, at: 0.05))
        _ = detector.handle(up(.left, at: 0.20))
        _ = detector.handle(up(.right, at: 0.22))

        // The machine is back to idle: the next press is held like any other.
        XCTAssertEqual(detector.handle(down(.left, at: 0.50)), .hold)
        XCTAssertEqual(detector.handle(up(.left, at: 0.54)), .releaseHeldWithCurrent)
    }

    func testResetClearsAHeldPress() {
        var detector = MouseChordDetector(threshold: 0.12)
        _ = detector.handle(down(.left, at: 0))
        detector.reset()
        // After reset the partner is treated as a fresh first press, not a chord.
        XCTAssertEqual(detector.handle(down(.right, at: 0.02)), .hold)
    }

    // MARK: - Helpers

    private func down(_ button: MouseButton, at timestamp: TimeInterval) -> MouseButtonEvent {
        MouseButtonEvent(button: button, phase: .down, timestamp: timestamp)
    }

    private func up(_ button: MouseButton, at timestamp: TimeInterval) -> MouseButtonEvent {
        MouseButtonEvent(button: button, phase: .up, timestamp: timestamp)
    }
}

/// Covers the persisted left+right-click trigger toggle (Bringr-93j.67): its ON default,
/// the stable key, and the "stored false vs absent key" distinction that keeps the
/// default ON. The chord is now independent of the modifier-hold trigger, so toggling it
/// off must not touch the modifier path (verified in `ModifierActivationTests`).
final class MouseChordActivationTests: XCTestCase {

    func testDefaultIsEnabled() {
        XCTAssertTrue(MouseChordActivation.default)
    }

    func testDefaultsKeyIsStable() {
        XCTAssertEqual(MouseChordActivation.defaultsKey, "activation.mouse.leftRightClick")
    }

    func testEnabledByDefaultWhenUnset() {
        // A fresh install summons with the click combo (US-007), so an absent key reads ON.
        XCTAssertTrue(MouseChordActivation.isEnabled(from: makeDefaults()))
    }

    func testStoredValueRoundTrips() {
        for value in [true, false] {
            let defaults = makeDefaults()
            defaults.set(value, forKey: MouseChordActivation.defaultsKey)
            XCTAssertEqual(MouseChordActivation.isEnabled(from: defaults), value)
        }
    }

    func testStoredFalseStaysOffAndIsNotTheDefault() {
        // Storing false means "the user turned the click combo off" — it must NOT fall back
        // to the ON default the way an absent key does.
        let defaults = makeDefaults()
        defaults.set(false, forKey: MouseChordActivation.defaultsKey)
        XCTAssertFalse(MouseChordActivation.isEnabled(from: defaults))
    }

    private func makeDefaults() -> UserDefaults {
        let suiteName = "MouseChordActivationTests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            fatalError("could not create a test UserDefaults suite")
        }
        return defaults
    }
}
