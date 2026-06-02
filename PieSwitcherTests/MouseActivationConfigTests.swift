import XCTest
@testable import PieSwitcher

/// Covers the persisted mouse-activation config (Bringr-93j.96): methods bitmask round-trips,
/// the default set, the "stored 0 vs absent key" distinction for the methods key, the hold
/// delay shape, and the blocking toggle. Split from `MouseChordTests.swift` so the detector
/// state-machine tests stay under the 400-line file cap once Bringr-93j.100's effective-delay
/// tests were added.
final class MouseActivationConfigTests: XCTestCase {

    func testDefaultMethodsIsMiddle() {
        // Bringr-93j.113: flipped from `{leftRight}` to `{middle}`. Left and Right are
        // too easy to fire by accident during normal app use; Middle has no scroll
        // behaviour and only a couple of niche bindings (close tab / open in new tab in
        // browsers), so capturing it is the least disruptive default.
        XCTAssertEqual(MouseActivationConfig.defaultMethods, [.middle])
    }

    func testMethodsDefaultsKeyIsStable() {
        XCTAssertEqual(MouseActivationConfig.methodsDefaultsKey, "activation.mouse.methods")
    }

    func testMethodsDefaultWhenUnset() {
        XCTAssertEqual(MouseActivationConfig.methods(from: makeDefaults()), [.middle])
        XCTAssertTrue(MouseActivationConfig.isEnabled(from: makeDefaults()))
    }

    func testStoredZeroDisablesEverything() {
        // Storing 0 (the user unchecked every method) must NOT fall back to the default the
        // way an absent key does.
        let defaults = makeDefaults()
        defaults.set(0, forKey: MouseActivationConfig.methodsDefaultsKey)
        XCTAssertTrue(MouseActivationConfig.methods(from: defaults).isEmpty)
        XCTAssertFalse(MouseActivationConfig.isEnabled(from: defaults))
    }

    func testEncodeDecodeRoundTrip() {
        let methods: Set<MouseActivationMethod> = [.leftRight, .middle, .forwardBackward]
        let bitmask = MouseActivationConfig.encodeMethods(methods)
        XCTAssertEqual(MouseActivationConfig.decodeMethods(bitmask: bitmask), methods)
    }

    func testStrayBitsAreMaskedAway() {
        // A future or corrupted bitmask must not produce a phantom case.
        let stray = MouseActivationConfig.encodeMethods([.middle]) | (1 << 30)
        XCTAssertEqual(MouseActivationConfig.decodeMethods(bitmask: stray), [.middle])
    }

    func testEveryMethodHasUniqueBit() {
        var seenBits: Set<Int> = []
        for method in MouseActivationMethod.allCases {
            XCTAssertFalse(seenBits.contains(method.bit), "bit collision for \(method)")
            seenBits.insert(method.bit)
        }
    }

    func testRequiredButtonsAreConsistent() {
        XCTAssertEqual(MouseActivationMethod.leftRight.requiredButtons, [.left, .right])
        XCTAssertEqual(MouseActivationMethod.middle.requiredButtons, [.middle])
        XCTAssertEqual(MouseActivationMethod.middleLeft.requiredButtons, [.middle, .left])
        XCTAssertEqual(MouseActivationMethod.middleRight.requiredButtons, [.middle, .right])
        XCTAssertEqual(MouseActivationMethod.forward.requiredButtons, [.forward])
        XCTAssertEqual(MouseActivationMethod.backward.requiredButtons, [.backward])
        XCTAssertEqual(MouseActivationMethod.forwardBackward.requiredButtons, [.forward, .backward])
    }

    // MARK: Blocking toggle

    func testBlockingDefaultIsOn() {
        // Default ON: a stray click from an activation button is suppressed during the hold delay
        // (Bringr-93j.94's drag replay means blocking no longer reintroduces the drag stutter).
        XCTAssertTrue(MouseActivationConfig.defaultBlocking)
        XCTAssertTrue(MouseActivationConfig.blocking(from: makeDefaults()))
    }

    func testBlockingStoredValueRoundTrips() {
        for value in [true, false] {
            let defaults = makeDefaults()
            defaults.set(value, forKey: MouseActivationConfig.blockingDefaultsKey)
            XCTAssertEqual(MouseActivationConfig.blocking(from: defaults), value)
        }
    }

    // MARK: Lock toggle (Bringr-93j.103)

    func testLockDefaultIsOff() {
        // Lock is the stronger "drop the click entirely" toggle introduced in .103. It defaults
        // OFF because it would noticeably break Left/Right click behaviour (link arming, text
        // selection, context menu) — only Middle benefits from it, and only for users who
        // explicitly opt in.
        XCTAssertFalse(MouseActivationConfig.defaultLock)
        XCTAssertFalse(MouseActivationConfig.lock(from: makeDefaults()))
    }

    func testLockStoredValueRoundTrips() {
        for value in [true, false] {
            let defaults = makeDefaults()
            defaults.set(value, forKey: MouseActivationConfig.lockDefaultsKey)
            XCTAssertEqual(MouseActivationConfig.lock(from: defaults), value)
        }
    }

    func testLockDefaultsKeyIsStable() {
        XCTAssertEqual(MouseActivationConfig.lockDefaultsKey, "activation.mouse.lock")
    }

    private func makeDefaults() -> UserDefaults {
        let suiteName = "MouseActivationConfigTests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            fatalError("could not create a test UserDefaults suite")
        }
        return defaults
    }
}

/// Covers the persisted mouse hold delay (Bringr-93j.96 + Bringr-93j.100): the 0 ms default,
/// the ms↔seconds readers, the "stored 0 vs absent key" guard, clamping, and the single-button
/// effective-delay floor.
final class MouseActivationHoldDelayTests: XCTestCase {

    func testDefaultMillisecondsIs150() {
        // Bringr-93j.113: bumped from 0 ms to 150 ms. The 0 ms default suited the prior
        // `{leftRight}` chord (two-button simultaneity is itself an intentional signal);
        // with the new fresh-install default `{middle}` a delay is what separates a
        // normal middle-click from a deliberate summon — without it, picking Middle
        // would silently break normal middle-click. 150 ms is comfortably above the tap
        // envelope while still feeling fast for a deliberate hold.
        XCTAssertEqual(MouseActivationHoldDelay.defaultMilliseconds, 150)
    }

    func testDefaultsKeyIsStable() {
        XCTAssertEqual(MouseActivationHoldDelay.defaultsKey, "activation.mouse.holdDelayMilliseconds")
    }

    func testCurrentDefaultsTo150WhenUnset() {
        XCTAssertEqual(MouseActivationHoldDelay.milliseconds(from: makeDefaults()), 150)
        XCTAssertEqual(MouseActivationHoldDelay.current(from: makeDefaults()), 0.150, accuracy: 1e-9)
    }

    func testStoredValueRoundTripsInBothUnits() {
        let defaults = makeDefaults()
        defaults.set(250.0, forKey: MouseActivationHoldDelay.defaultsKey)
        XCTAssertEqual(MouseActivationHoldDelay.milliseconds(from: defaults), 250)
        XCTAssertEqual(MouseActivationHoldDelay.current(from: defaults), 0.25, accuracy: 1e-9)
    }

    func testValuesAreClampedToRange() {
        let high = makeDefaults()
        high.set(5000.0, forKey: MouseActivationHoldDelay.defaultsKey)
        XCTAssertEqual(MouseActivationHoldDelay.milliseconds(from: high), 1000)

        let low = makeDefaults()
        low.set(-25.0, forKey: MouseActivationHoldDelay.defaultsKey)
        XCTAssertEqual(MouseActivationHoldDelay.milliseconds(from: low), 0)
    }

    func testClampMillisecondsHelper() {
        XCTAssertEqual(MouseActivationHoldDelay.clampMilliseconds(1500), 1000)
        XCTAssertEqual(MouseActivationHoldDelay.clampMilliseconds(-5), 0)
        XCTAssertEqual(MouseActivationHoldDelay.clampMilliseconds(300), 300)
    }

    // MARK: Bringr-93j.100: single-button effective-delay floor

    func testIsSingleButtonReflectsButtonCount() {
        XCTAssertTrue(MouseActivationMethod.middle.isSingleButton)
        XCTAssertTrue(MouseActivationMethod.forward.isSingleButton)
        XCTAssertTrue(MouseActivationMethod.backward.isSingleButton)
        XCTAssertFalse(MouseActivationMethod.leftRight.isSingleButton)
        XCTAssertFalse(MouseActivationMethod.middleLeft.isSingleButton)
        XCTAssertFalse(MouseActivationMethod.middleRight.isSingleButton)
        XCTAssertFalse(MouseActivationMethod.forwardBackward.isSingleButton)
    }

    func testEffectiveAppliesFloorOnlyForSingleButtonAtZero() {
        let floor = MouseActivationHoldDelay.singleButtonMinimumMilliseconds / 1000
        XCTAssertEqual(MouseActivationHoldDelay.effective(for: .middle, configured: 0), floor, accuracy: 1e-9)
        XCTAssertEqual(MouseActivationHoldDelay.effective(for: .forward, configured: 0), floor, accuracy: 1e-9)
        XCTAssertEqual(MouseActivationHoldDelay.effective(for: .backward, configured: 0), floor, accuracy: 1e-9)
    }

    func testEffectiveRespectsNonZeroConfiguredForSingleButton() {
        // The floor only fires at 0 ms. An explicit non-zero choice — even a tiny one — is
        // the user's decision and is passed through as-is.
        XCTAssertEqual(MouseActivationHoldDelay.effective(for: .middle, configured: 0.05), 0.05, accuracy: 1e-9)
        XCTAssertEqual(MouseActivationHoldDelay.effective(for: .middle, configured: 0.5), 0.5, accuracy: 1e-9)
    }

    func testEffectiveLeavesMultiButtonAlone() {
        XCTAssertEqual(MouseActivationHoldDelay.effective(for: .leftRight, configured: 0), 0, accuracy: 1e-9)
        XCTAssertEqual(MouseActivationHoldDelay.effective(for: .middleLeft, configured: 0), 0, accuracy: 1e-9)
        XCTAssertEqual(
            MouseActivationHoldDelay.effective(for: .forwardBackward, configured: 0.3), 0.3, accuracy: 1e-9
        )
    }

    private func makeDefaults() -> UserDefaults {
        let suiteName = "MouseActivationHoldDelayTests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            fatalError("could not create a test UserDefaults suite")
        }
        return defaults
    }
}

/// Covers the persisted move-threshold knob (Bringr-93j.103): the default, the points↔CGFloat
/// readers, the "stored 0 vs absent key" guard, and clamping. Mirrors the hold-delay tests
/// since both knobs sit next to each other in the same persisted config surface.
final class MouseActivationMoveThresholdTests: XCTestCase {

    func testDefaultPointsIsFive() {
        // 5 pt was picked as the default in .103: well above the steady-finger jitter envelope
        // (so a held middle click doesn't get cancelled by a one-pixel twitch) and well below
        // the few-tens-of-pixels a deliberate drag clears in its first frame.
        XCTAssertEqual(MouseActivationMoveThreshold.defaultPoints, 5)
    }

    func testDefaultsKeyIsStable() {
        XCTAssertEqual(MouseActivationMoveThreshold.defaultsKey, "activation.mouse.moveThresholdPoints")
    }

    func testCurrentDefaultsToFiveWhenUnset() {
        XCTAssertEqual(MouseActivationMoveThreshold.points(from: makeDefaults()), 5)
        XCTAssertEqual(MouseActivationMoveThreshold.current(from: makeDefaults()), 5, accuracy: 1e-9)
    }

    func testStoredValueRoundTrips() {
        let defaults = makeDefaults()
        defaults.set(12.0, forKey: MouseActivationMoveThreshold.defaultsKey)
        XCTAssertEqual(MouseActivationMoveThreshold.points(from: defaults), 12)
        XCTAssertEqual(MouseActivationMoveThreshold.current(from: defaults), 12, accuracy: 1e-9)
    }

    func testStoredZeroIsRespected() {
        // 0 = "restore the old any-movement-cancels behaviour" — distinct from "never set".
        let defaults = makeDefaults()
        defaults.set(0.0, forKey: MouseActivationMoveThreshold.defaultsKey)
        XCTAssertEqual(MouseActivationMoveThreshold.points(from: defaults), 0)
    }

    func testValuesAreClampedToRange() {
        let high = makeDefaults()
        high.set(500.0, forKey: MouseActivationMoveThreshold.defaultsKey)
        XCTAssertEqual(MouseActivationMoveThreshold.points(from: high), 50)

        let low = makeDefaults()
        low.set(-3.0, forKey: MouseActivationMoveThreshold.defaultsKey)
        XCTAssertEqual(MouseActivationMoveThreshold.points(from: low), 0)
    }

    func testClampPointsHelper() {
        XCTAssertEqual(MouseActivationMoveThreshold.clampPoints(75), 50)
        XCTAssertEqual(MouseActivationMoveThreshold.clampPoints(-1), 0)
        XCTAssertEqual(MouseActivationMoveThreshold.clampPoints(25), 25)
    }

    private func makeDefaults() -> UserDefaults {
        let suiteName = "MouseActivationMoveThresholdTests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            fatalError("could not create a test UserDefaults suite")
        }
        return defaults
    }
}
