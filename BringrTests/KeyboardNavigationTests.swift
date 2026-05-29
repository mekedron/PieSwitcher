import XCTest
@testable import Bringr

/// Pure unit tests for the optional keyboard-navigation building blocks (Bringr-93j.71): the
/// persistence helpers behind the Preferences toggles, the per-summon resolved config, the
/// hardware-key-code mapping, and the wrapping / digit→index math. The ring-driven behaviour
/// (focus, drill-in, commit) is covered separately in `RadialNavigatorKeyboardTests`.
final class KeyboardNavigationTests: XCTestCase {

    // MARK: - Settings defaults

    func testTopLevelToggleDefaultsOff() {
        XCTAssertFalse(KeyboardNavigation.enabledDefault)
        XCTAssertFalse(KeyboardNavigation.isEnabled(from: makeDefaults()))
    }

    func testSubTogglesDefaultOnExceptConfirmation() {
        let defaults = makeDefaults()
        XCTAssertTrue(KeyboardNavigation.arrowsEnabled(from: defaults))
        XCTAssertTrue(KeyboardNavigation.numbersEnabled(from: defaults))
        XCTAssertFalse(KeyboardNavigation.requiresConfirmation(from: defaults))
    }

    func testSubTogglesReadStoredValue() {
        let defaults = makeDefaults()
        defaults.set(false, forKey: KeyboardNavigation.arrowsKey)
        defaults.set(false, forKey: KeyboardNavigation.numbersKey)
        defaults.set(true, forKey: KeyboardNavigation.confirmKey)
        XCTAssertFalse(KeyboardNavigation.arrowsEnabled(from: defaults))
        XCTAssertFalse(KeyboardNavigation.numbersEnabled(from: defaults))
        XCTAssertTrue(KeyboardNavigation.requiresConfirmation(from: defaults))
    }

    func testDefaultsKeysAreStable() {
        XCTAssertEqual(KeyboardNavigation.enabledKey, "keyboardNav.enabled")
        XCTAssertEqual(KeyboardNavigation.arrowsKey, "keyboardNav.arrows")
        XCTAssertEqual(KeyboardNavigation.numbersKey, "keyboardNav.numbers")
        XCTAssertEqual(KeyboardNavigation.confirmKey, "keyboardNav.requireConfirmation")
    }

    // MARK: - Resolved config

    func testConfigDisabledWhenNavigationOff() {
        let defaults = makeDefaults()
        // Even with the sub-options explicitly on, the top-level switch gates them all.
        defaults.set(false, forKey: KeyboardNavigation.enabledKey)
        defaults.set(true, forKey: KeyboardNavigation.arrowsKey)
        defaults.set(true, forKey: KeyboardNavigation.numbersKey)
        let config = KeyboardNavigationConfig.current(from: defaults)
        XCTAssertEqual(config, .disabled)
        XCTAssertFalse(config.arrowsEnabled)
        XCTAssertFalse(config.numbersEnabled)
    }

    func testConfigReflectsSubTogglesWhenNavigationOn() {
        let defaults = makeDefaults()
        defaults.set(true, forKey: KeyboardNavigation.enabledKey)
        defaults.set(true, forKey: KeyboardNavigation.arrowsKey)
        defaults.set(false, forKey: KeyboardNavigation.numbersKey)
        defaults.set(true, forKey: KeyboardNavigation.confirmKey)
        let config = KeyboardNavigationConfig.current(from: defaults)
        XCTAssertTrue(config.isEnabled)
        XCTAssertTrue(config.arrowsEnabled)
        XCTAssertFalse(config.numbersEnabled)
        XCTAssertTrue(config.requiresConfirmation)
    }

    func testConfigArrowsAndNumbersCanBothBeOn() {
        let defaults = makeDefaults()
        defaults.set(true, forKey: KeyboardNavigation.enabledKey)
        let config = KeyboardNavigationConfig.current(from: defaults)
        XCTAssertTrue(config.arrowsEnabled)
        XCTAssertTrue(config.numbersEnabled, "arrow and number navigation are independent toggles")
    }

    // MARK: - Key-code mapping

    func testArrowKeyCodes() {
        XCTAssertEqual(KeyboardNavKey(keyCode: 123), .arrow(.left))
        XCTAssertEqual(KeyboardNavKey(keyCode: 124), .arrow(.right))
        XCTAssertEqual(KeyboardNavKey(keyCode: 125), .arrow(.down))
        XCTAssertEqual(KeyboardNavKey(keyCode: 126), .arrow(.up))
    }

    func testConfirmAndEscapeKeyCodes() {
        XCTAssertEqual(KeyboardNavKey(keyCode: 36), .confirm) // Return
        XCTAssertEqual(KeyboardNavKey(keyCode: 76), .confirm) // keypad Enter
        XCTAssertEqual(KeyboardNavKey(keyCode: 53), .escape)
    }

    func testNumberRowKeyCodesMapToDigits() {
        let expected: [Int64: Int] = [18: 1, 19: 2, 20: 3, 21: 4, 23: 5, 22: 6, 26: 7, 28: 8, 25: 9, 29: 0]
        for (code, digit) in expected {
            XCTAssertEqual(KeyboardNavKey(keyCode: code), .digit(digit), "key code \(code)")
        }
    }

    func testKeypadKeyCodesMapToDigits() {
        let expected: [Int64: Int] = [83: 1, 84: 2, 85: 3, 86: 4, 87: 5, 88: 6, 89: 7, 91: 8, 92: 9, 82: 0]
        for (code, digit) in expected {
            XCTAssertEqual(KeyboardNavKey(keyCode: code), .digit(digit), "keypad code \(code)")
        }
    }

    func testUnmappedKeyCodeIsNil() {
        XCTAssertNil(KeyboardNavKey(keyCode: 0))   // 'a'
        XCTAssertNil(KeyboardNavKey(keyCode: 49))  // space
    }

    // MARK: - Wrapping math

    func testWrapStaysInRange() {
        XCTAssertEqual(KeyboardNavMath.wrap(0, count: 3), 0)
        XCTAssertEqual(KeyboardNavMath.wrap(2, count: 3), 2)
    }

    func testWrapPastEndsWrapsAround() {
        XCTAssertEqual(KeyboardNavMath.wrap(3, count: 3), 0, "right past the last slice lands on 0")
        XCTAssertEqual(KeyboardNavMath.wrap(-1, count: 3), 2, "left past 0 lands on the last slice")
    }

    func testWrapZeroCountIsSafe() {
        XCTAssertEqual(KeyboardNavMath.wrap(5, count: 0), 0)
    }

    // MARK: - Digit → index

    func testDigitToIndex() {
        XCTAssertEqual(KeyboardNavMath.index(forDigit: 1), 0)
        XCTAssertEqual(KeyboardNavMath.index(forDigit: 9), 8)
        XCTAssertEqual(KeyboardNavMath.index(forDigit: 0), 9, "0 is the tenth item")
    }

    /// An isolated `UserDefaults` suite so persistence tests never touch the real domain.
    private func makeDefaults() -> UserDefaults {
        let suiteName = "KeyboardNavigationTests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            fatalError("could not create a test UserDefaults suite")
        }
        return defaults
    }
}
