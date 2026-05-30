import XCTest
@testable import PieSwitcher

/// Covers the persisted mouse-activation config (Bringr-93j.96): methods bitmask round-trips,
/// the default set, the "stored 0 vs absent key" distinction for the methods key, the hold
/// delay shape, and the blocking toggle. Split from `MouseChordTests.swift` so the detector
/// state-machine tests stay under the 400-line file cap once Bringr-93j.100's effective-delay
/// tests were added.
final class MouseActivationConfigTests: XCTestCase {

    func testDefaultMethodsIsLeftRight() {
        XCTAssertEqual(MouseActivationConfig.defaultMethods, [.leftRight])
    }

    func testMethodsDefaultsKeyIsStable() {
        XCTAssertEqual(MouseActivationConfig.methodsDefaultsKey, "activation.mouse.methods")
    }

    func testMethodsDefaultWhenUnset() {
        XCTAssertEqual(MouseActivationConfig.methods(from: makeDefaults()), [.leftRight])
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

    func testDefaultMillisecondsIsZero() {
        XCTAssertEqual(MouseActivationHoldDelay.defaultMilliseconds, 0)
    }

    func testDefaultsKeyIsStable() {
        XCTAssertEqual(MouseActivationHoldDelay.defaultsKey, "activation.mouse.holdDelayMilliseconds")
    }

    func testCurrentDefaultsToZeroWhenUnset() {
        XCTAssertEqual(MouseActivationHoldDelay.milliseconds(from: makeDefaults()), 0)
        XCTAssertEqual(MouseActivationHoldDelay.current(from: makeDefaults()), 0, accuracy: 1e-9)
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
