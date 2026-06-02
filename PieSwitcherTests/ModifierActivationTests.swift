import CoreGraphics
import XCTest
@testable import PieSwitcher

/// Covers the legacy `ModifierCombination` type and bitmask-backed `ModifierActivation`
/// helpers. Bringr-93j.111 retired the live detector/monitor surface tested here in favour
/// of the side-aware `KeyboardShortcut` model (see `KeyboardShortcutTests`); these tests
/// stay because the legacy bitmask remains the migration source.
final class ModifierActivationTests: XCTestCase {

    // MARK: - CGEventFlags → ModifierCombination

    func testEachFlagMapsToItsModifier() {
        XCTAssertEqual(ModifierCombination(cgFlags: .maskSecondaryFn), .function)
        XCTAssertEqual(ModifierCombination(cgFlags: .maskControl), .control)
        XCTAssertEqual(ModifierCombination(cgFlags: .maskAlternate), .option)
        XCTAssertEqual(ModifierCombination(cgFlags: .maskShift), .shift)
        XCTAssertEqual(ModifierCombination(cgFlags: .maskCommand), .command)
    }

    func testCombinedFlagsMapToTheUnion() {
        let flags: CGEventFlags = [.maskSecondaryFn, .maskCommand]
        XCTAssertEqual(ModifierCombination(cgFlags: flags), [.function, .command])
    }

    func testIrrelevantFlagsAreIgnored() {
        // Caps Lock and the numeric-pad bit must not spoil an otherwise-exact match.
        let flags: CGEventFlags = [.maskSecondaryFn, .maskAlphaShift, .maskNumericPad]
        XCTAssertEqual(ModifierCombination(cgFlags: flags), .function)
    }

    func testNoFlagsMapToEmpty() {
        XCTAssertTrue(ModifierCombination(cgFlags: []).isEmpty)
    }

    // MARK: - Persisted combination (defaults & the "cleared vs unset" distinction)

    func testKeyboardDefaultsToFnWhenUnset() {
        XCTAssertEqual(ModifierActivation.keyboard(from: makeDefaults()), .function)
    }

    func testStoredCombinationRoundTrips() {
        let defaults = makeDefaults()
        let combo: ModifierCombination = [.control, .option]
        defaults.set(combo.rawValue, forKey: ModifierActivation.keyboardDefaultsKey)
        XCTAssertEqual(ModifierActivation.keyboard(from: defaults), combo)
    }

    func testClearedKeyboardStaysEmptyAndIsNotTheDefault() {
        // Storing 0 means "the user unchecked every key" — disabled — and must NOT fall
        // back to the Fn default the way an absent key does.
        let defaults = makeDefaults()
        defaults.set(0, forKey: ModifierActivation.keyboardDefaultsKey)
        XCTAssertTrue(ModifierActivation.keyboard(from: defaults).isEmpty)
    }

    func testStrayBitsAreMaskedAway() {
        let defaults = makeDefaults()
        defaults.set(ModifierCombination.function.rawValue | (1 << 20), forKey: ModifierActivation.keyboardDefaultsKey)
        XCTAssertEqual(ModifierActivation.keyboard(from: defaults), .function)
    }

    // MARK: - Names (Preferences caption)

    func testNamesListsSelectedKeysInOrder() {
        XCTAssertEqual(ModifierCombination([.function, .command]).names, "Fn + Command")
        XCTAssertEqual(ModifierCombination.control.names, "Control")
        XCTAssertEqual(ModifierCombination([]).names, "")
    }

    // MARK: - Fixtures

    /// An isolated `UserDefaults` suite so persistence tests never touch the real domain.
    private func makeDefaults() -> UserDefaults {
        let suiteName = "ModifierActivationTests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            fatalError("could not create a test UserDefaults suite")
        }
        return defaults
    }
}

/// Covers the persisted hold delay (Bringr-93j.58): the default, the ms↔seconds readers,
/// the "stored 0 vs absent key" distinction, and clamping — in isolation from any timer.
final class ActivationHoldDelayTests: XCTestCase {

    func testDefaultMillisecondsIs100() {
        XCTAssertEqual(ActivationHoldDelay.defaultMilliseconds, 100)
    }

    func testDefaultsKeyIsStable() {
        XCTAssertEqual(ActivationHoldDelay.defaultsKey, "activation.holdDelayMilliseconds")
    }

    func testCurrentDefaultsTo100msWhenUnset() {
        XCTAssertEqual(ActivationHoldDelay.milliseconds(from: makeDefaults()), 100)
        XCTAssertEqual(ActivationHoldDelay.current(from: makeDefaults()), 0.1, accuracy: 1e-9)
    }

    func testStoredValueRoundTripsInBothUnits() {
        let defaults = makeDefaults()
        defaults.set(250.0, forKey: ActivationHoldDelay.defaultsKey)
        XCTAssertEqual(ActivationHoldDelay.milliseconds(from: defaults), 250)
        XCTAssertEqual(ActivationHoldDelay.current(from: defaults), 0.25, accuracy: 1e-9)
    }

    func testStoredZeroStaysZeroAndIsNotTheDefault() {
        // A stored 0 means "no delay — summon on the rising edge", which must NOT fall back
        // to the 100 ms default the way an absent key does (the object-presence guard).
        let defaults = makeDefaults()
        defaults.set(0.0, forKey: ActivationHoldDelay.defaultsKey)
        XCTAssertEqual(ActivationHoldDelay.milliseconds(from: defaults), 0)
        XCTAssertEqual(ActivationHoldDelay.current(from: defaults), 0, accuracy: 1e-9)
    }

    func testValuesAreClampedToRange() {
        let high = makeDefaults()
        high.set(5000.0, forKey: ActivationHoldDelay.defaultsKey)
        XCTAssertEqual(ActivationHoldDelay.milliseconds(from: high), 1000)
        XCTAssertEqual(ActivationHoldDelay.current(from: high), 1.0, accuracy: 1e-9)

        let low = makeDefaults()
        low.set(-25.0, forKey: ActivationHoldDelay.defaultsKey)
        XCTAssertEqual(ActivationHoldDelay.milliseconds(from: low), 0)
    }

    func testClampMillisecondsHelper() {
        XCTAssertEqual(ActivationHoldDelay.clampMilliseconds(1500), 1000)
        XCTAssertEqual(ActivationHoldDelay.clampMilliseconds(-5), 0)
        XCTAssertEqual(ActivationHoldDelay.clampMilliseconds(300), 300)
    }

    private func makeDefaults() -> UserDefaults {
        let suiteName = "ActivationHoldDelayTests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            fatalError("could not create a test UserDefaults suite")
        }
        return defaults
    }
}

/// Covers the pure `ModifierHoldDelayGate` state machine (Bringr-93j.58): arming on the
/// rising edge, delivering only if the hold survives, cancelling a too-short hold, and the
/// stale-timer race guard that makes the live timer safe.
final class ModifierHoldDelayGateTests: XCTestCase {

    func testPressFromIdleArmsAndIsNotReArmed() {
        var gate = ModifierHoldDelayGate()
        XCTAssertTrue(gate.press(), "an idle gate arms the delay")
        XCTAssertFalse(gate.press(), "a second press while pending does not re-arm")
    }

    func testHoldSurvivingDelayDeliversThenReleasePropagates() {
        var gate = ModifierHoldDelayGate()
        XCTAssertTrue(gate.press())
        XCTAssertTrue(gate.delayElapsed(), "the hold survived the delay → deliver the press")
        XCTAssertFalse(gate.delayElapsed(), "the press is delivered once, not again")
        XCTAssertEqual(gate.release(), .propagateRelease, "releasing a delivered press commits/dismisses")
        XCTAssertEqual(gate.release(), .ignore, "no second release once idle")
    }

    func testReleaseBeforeDelayCancelsAndDeliversNothing() {
        var gate = ModifierHoldDelayGate()
        XCTAssertTrue(gate.press())
        XCTAssertEqual(gate.release(), .cancelPendingPress, "a too-short hold cancels the pending press")
        // The race guard: a timer that fires *after* the cancelling release must not deliver.
        XCTAssertFalse(gate.delayElapsed(), "a stale fire after cancel never summons")
    }

    func testReleaseWhenIdleIsIgnored() {
        var gate = ModifierHoldDelayGate()
        XCTAssertEqual(gate.release(), .ignore)
    }

    func testStaleDelayElapsedAfterCancelIsHarmless() {
        var gate = ModifierHoldDelayGate()
        XCTAssertTrue(gate.press())
        XCTAssertEqual(gate.release(), .cancelPendingPress)
        XCTAssertFalse(gate.delayElapsed())
        XCTAssertEqual(gate.release(), .ignore, "still idle after a stale fire")
    }

    func testResetForgetsInFlightHold() {
        var gate = ModifierHoldDelayGate()
        XCTAssertTrue(gate.press())
        XCTAssertTrue(gate.delayElapsed())
        gate.reset()
        // After reset a still-held key presses afresh rather than being seen as delivered.
        XCTAssertTrue(gate.press(), "reset returns the gate to idle so it arms again")
        XCTAssertEqual(gate.release(), .cancelPendingPress, "and the fresh hold is pending, not pressed")
    }
}
