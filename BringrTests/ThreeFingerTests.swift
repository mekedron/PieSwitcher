import XCTest
@testable import Bringr

/// Exercises the three-finger press recogniser in isolation from the trackpad and
/// the private MultitouchSupport framework (AC4): every test drives
/// `ThreeFingerPressDetector` with synthetic finger counts and asserts the
/// reaction it returns.
final class ThreeFingerTests: XCTestCase {
    // MARK: - AC1: a three-finger press summons

    func testThreeFingersPress() {
        var detector = ThreeFingerPressDetector()
        XCTAssertEqual(detector.handle(fingerCount: 3), .press)
    }

    func testThreeFingersFromRampUpPressesOnReachingThree() {
        var detector = ThreeFingerPressDetector()
        XCTAssertEqual(detector.handle(fingerCount: 1), .none)
        XCTAssertEqual(detector.handle(fingerCount: 2), .none)
        XCTAssertEqual(detector.handle(fingerCount: 3), .press)
    }

    // MARK: - AC2: one- and two-finger gestures are unaffected

    func testOneFingerDoesNotPress() {
        var detector = ThreeFingerPressDetector()
        XCTAssertEqual(detector.handle(fingerCount: 1), .none)
    }

    func testTwoFingersDoNotPress() {
        var detector = ThreeFingerPressDetector()
        XCTAssertEqual(detector.handle(fingerCount: 1), .none)
        XCTAssertEqual(detector.handle(fingerCount: 2), .none)
    }

    func testFourOrMoreFingersFromIdleDoNotPress() {
        var detector = ThreeFingerPressDetector()
        XCTAssertEqual(detector.handle(fingerCount: 4), .none, "four fingers is not exactly the required three")
        XCTAssertEqual(detector.handle(fingerCount: 5), .none)
    }

    // MARK: - The press is an edge, fired once

    func testPressFiresOnceWhileFingersRemainDown() {
        var detector = ThreeFingerPressDetector()
        XCTAssertEqual(detector.handle(fingerCount: 3), .press)
        XCTAssertEqual(detector.handle(fingerCount: 3), .none, "still three fingers — do not re-summon every frame")
        XCTAssertEqual(detector.handle(fingerCount: 3), .none)
    }

    // MARK: - Release when the fingers lift

    func testReleaseWhenFingersDropBelowThree() {
        var detector = ThreeFingerPressDetector()
        XCTAssertEqual(detector.handle(fingerCount: 3), .press)
        XCTAssertEqual(detector.handle(fingerCount: 2), .release)
    }

    func testReleaseFiresOnceThenIdle() {
        var detector = ThreeFingerPressDetector()
        _ = detector.handle(fingerCount: 3)
        XCTAssertEqual(detector.handle(fingerCount: 0), .release)
        XCTAssertEqual(detector.handle(fingerCount: 0), .none)
    }

    func testPressLatchesThroughAFourthFinger() {
        var detector = ThreeFingerPressDetector()
        XCTAssertEqual(detector.handle(fingerCount: 3), .press)
        XCTAssertEqual(detector.handle(fingerCount: 4), .none, "adding a finger keeps the press latched")
        XCTAssertEqual(detector.handle(fingerCount: 1), .release, "lifting back below three releases")
    }

    // MARK: - Re-arming between gestures

    func testPressReleaseThenPressAgain() {
        var detector = ThreeFingerPressDetector()
        XCTAssertEqual(detector.handle(fingerCount: 3), .press)
        XCTAssertEqual(detector.handle(fingerCount: 0), .release)
        XCTAssertEqual(detector.handle(fingerCount: 3), .press, "a second three-finger press is recognised cleanly")
    }

    // MARK: - Configurable required count

    func testRequiredFingerCountIsConfigurable() {
        var detector = ThreeFingerPressDetector(requiredFingerCount: 2)
        XCTAssertEqual(detector.handle(fingerCount: 3), .none, "three fingers is not exactly the required two")
        XCTAssertEqual(detector.handle(fingerCount: 2), .press)
        XCTAssertEqual(detector.handle(fingerCount: 1), .release)
    }

    // MARK: - Reset

    func testResetClearsALatchedPress() {
        var detector = ThreeFingerPressDetector()
        _ = detector.handle(fingerCount: 3)
        detector.reset()
        // After reset the press is no longer latched: dropping fingers is not a
        // release, and three fingers presses afresh.
        XCTAssertEqual(detector.handle(fingerCount: 0), .none)
        XCTAssertEqual(detector.handle(fingerCount: 3), .press)
    }
}
