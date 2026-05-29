import CoreGraphics
import XCTest
@testable import Bringr

/// Covers the configurable keyboard-shortcut activation (Bringr-93j.35, Bringr-93j.69): the
/// `CGEventFlags` reduction, the persisted modifier-combination reader, the armed-set
/// computation, and the pure `ModifierHoldDetector` edge logic — all in isolation from the
/// live event tap.
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

    // MARK: - Armed combinations

    func testArmedByDefaultIsKeyboardFnOnly() {
        // Fresh install: the keyboard shortcut defaults to Fn, so Fn is the one armed combo;
        // the mouse uses left+right click, which is not a modifier combination.
        XCTAssertEqual(ModifierActivation.armedCombinations(from: makeDefaults()), [.function])
    }

    func testChosenKeyboardComboIsArmed() {
        // Bringr-93j.69: one unified keyboard combination, so the armed set is exactly it.
        let defaults = makeDefaults()
        defaults.set(ModifierCombination([.command, .option]).rawValue, forKey: ModifierActivation.keyboardDefaultsKey)
        XCTAssertEqual(ModifierActivation.armedCombinations(from: defaults), [[.command, .option]])
    }

    func testClearedKeyboardDisarmsEverything() {
        // Unchecking every key (stored 0) disables the keyboard path entirely, so nothing is
        // armed — the mouse's left+right click is then the only remaining trigger.
        let defaults = makeDefaults()
        defaults.set(0, forKey: ModifierActivation.keyboardDefaultsKey)
        XCTAssertTrue(ModifierActivation.armedCombinations(from: defaults).isEmpty)
    }

    // MARK: - Detector: rising/falling edges

    func testHoldingAnArmedComboPressesThenReleases() {
        var detector = ModifierHoldDetector()
        XCTAssertEqual(detector.handle(held: .function, armed: [.function]), .press)
        XCTAssertEqual(detector.handle(held: .function, armed: [.function]), .none, "no re-press while still held")
        XCTAssertEqual(detector.handle(held: [], armed: [.function]), .release)
        XCTAssertEqual(detector.handle(held: [], armed: [.function]), .none, "no re-release once idle")
    }

    func testMatchingIsExactSoExtraModifiersDoNotPress() {
        var detector = ModifierHoldDetector()
        XCTAssertEqual(detector.handle(held: [.function, .shift], armed: [.function]), .none,
                       "holding Fn+Shift is not exactly Fn")
    }

    func testAddingAModifierToAnActiveComboReleasesIt() {
        var detector = ModifierHoldDetector()
        XCTAssertEqual(detector.handle(held: .command, armed: [.command]), .press)
        XCTAssertEqual(detector.handle(held: [.command, .shift], armed: [.command]), .release,
                       "⌘⇧ is no longer the armed ⌘, so the menu gets out of the way")
    }

    func testCombinationRequiresEveryKey() {
        let armed: [ModifierCombination] = [[.function, .control]]
        var detector = ModifierHoldDetector()
        XCTAssertEqual(detector.handle(held: .function, armed: armed), .none, "Fn alone is not the full combo")
        XCTAssertEqual(detector.handle(held: [.function, .control], armed: armed), .press)
        XCTAssertEqual(detector.handle(held: .function, armed: armed), .release, "dropping Control ends it")
    }

    func testStaysActiveAcrossDistinctArmedCombos() {
        // With two armed combos, sliding from one to the other never re-fires: it stays
        // active until no armed combo is held.
        let armed: [ModifierCombination] = [.function, [.command, .option]]
        var detector = ModifierHoldDetector()
        XCTAssertEqual(detector.handle(held: .function, armed: armed), .press)
        XCTAssertEqual(detector.handle(held: [.command, .option], armed: armed), .none,
                       "moved to the other armed combo while still matching — no second press")
        XCTAssertEqual(detector.handle(held: [], armed: armed), .release)
    }

    func testNoArmedCombosNeverPresses() {
        var detector = ModifierHoldDetector()
        XCTAssertEqual(detector.handle(held: .function, armed: []), .none)
        XCTAssertEqual(detector.handle(held: [.command, .shift], armed: []), .none)
    }

    func testEmptyArmedEntryIsIgnored() {
        var detector = ModifierHoldDetector()
        // An empty armed combination can never be "held" — releasing all keys must not
        // be read as matching it.
        XCTAssertEqual(detector.handle(held: [], armed: [[]]), .none)
    }

    func testResetClearsLatchedActivation() {
        var detector = ModifierHoldDetector()
        XCTAssertEqual(detector.handle(held: .function, armed: [.function]), .press)
        detector.reset()
        // After reset the prior hold is forgotten: still holding Fn presses afresh rather
        // than being treated as already-active.
        XCTAssertEqual(detector.handle(held: .function, armed: [.function]), .press)
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
