import XCTest
@testable import PieSwitcher

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

    func testSubTogglesDefaultPerSourceWhenUnset() {
        // Bringr-93j.93: arrows ship OFF (numbers carry the keyboard-driven flow); numbers ON;
        // confirm OFF (numbers commit instantly).
        let defaults = makeDefaults()
        XCTAssertFalse(KeyboardNavigation.arrowsDefault)
        XCTAssertFalse(KeyboardNavigation.arrowsEnabled(from: defaults))
        XCTAssertTrue(KeyboardNavigation.numbersEnabled(from: defaults))
        XCTAssertFalse(KeyboardNavigation.requiresConfirmation(from: defaults))
    }

    func testCloseOnUnsupportedDefaultsOffAndCommitAppDefaultsOff() {
        // Bringr-93j.93: both off — an unrecognised key passes through (doesn't close the wheel),
        // and a window pick is required for multi-window apps.
        let defaults = makeDefaults()
        XCTAssertFalse(KeyboardNavigation.closeOnUnsupportedDefault)
        XCTAssertFalse(KeyboardNavigation.closesOnUnsupportedKey(from: defaults), "an absent key keeps it off")
        XCTAssertFalse(KeyboardNavigation.commitAppWithoutWindowChoiceDefault)
        XCTAssertFalse(KeyboardNavigation.commitsAppWithoutWindowChoice(from: defaults))
    }

    func testCloseOnUnsupportedAndCommitAppReadStoredValue() {
        let defaults = makeDefaults()
        defaults.set(false, forKey: KeyboardNavigation.closeOnUnsupportedKey)
        defaults.set(true, forKey: KeyboardNavigation.commitAppWithoutWindowChoiceKey)
        XCTAssertFalse(KeyboardNavigation.closesOnUnsupportedKey(from: defaults))
        XCTAssertTrue(KeyboardNavigation.commitsAppWithoutWindowChoice(from: defaults))
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
        XCTAssertEqual(KeyboardNavigation.closeOnUnsupportedKey, "keyboardNav.closeOnUnsupportedKey")
        XCTAssertEqual(KeyboardNavigation.commitAppWithoutWindowChoiceKey, "keyboardNav.commitAppWithoutWindowChoice")
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
        // Arrows ship OFF (Bringr-93j.93), so opt in explicitly to assert independence.
        defaults.set(true, forKey: KeyboardNavigation.arrowsKey)
        let config = KeyboardNavigationConfig.current(from: defaults)
        XCTAssertTrue(config.arrowsEnabled)
        XCTAssertTrue(config.numbersEnabled, "arrow and number navigation are independent toggles")
    }

    func testConfigCloseDefaultsOffAndCommitDefaultsOffWhenNavigationOn() {
        // Bringr-93j.93: both opt-in; the top-level enable doesn't flip these on.
        let defaults = makeDefaults()
        defaults.set(true, forKey: KeyboardNavigation.enabledKey)
        let config = KeyboardNavigationConfig.current(from: defaults)
        XCTAssertFalse(config.closesOnUnsupportedKey, "close-on-unsupported is opt-in")
        XCTAssertFalse(config.commitsAppWithoutWindowChoice, "the no-window-choice commit is opt-in")
    }

    func testConfigGatesNewFlagsOnTopLevelSwitch() {
        let defaults = makeDefaults()
        // Even explicitly on, both gate behind the master switch so neither fires while it is off.
        defaults.set(false, forKey: KeyboardNavigation.enabledKey)
        defaults.set(true, forKey: KeyboardNavigation.closeOnUnsupportedKey)
        defaults.set(true, forKey: KeyboardNavigation.commitAppWithoutWindowChoiceKey)
        let config = KeyboardNavigationConfig.current(from: defaults)
        XCTAssertFalse(config.closesOnUnsupportedKey)
        XCTAssertFalse(config.commitsAppWithoutWindowChoice)
    }

    // MARK: - Key-code mapping

    func testArrowKeyCodes() {
        XCTAssertEqual(KeyboardNavKey(keyCode: 123), .arrow(.left))
        XCTAssertEqual(KeyboardNavKey(keyCode: 124), .arrow(.right))
        XCTAssertEqual(KeyboardNavKey(keyCode: 125), .arrow(.down))
        XCTAssertEqual(KeyboardNavKey(keyCode: 126), .arrow(.up))
    }

    /// Holding Fn (the default summon shortcut) turns the arrow cluster into Home/End/Page Up/
    /// Page Down, so in hold-to-select the arrows arrive as those codes — they must still map to
    /// the matching arrow or arrow navigation is dead while Fn is held (Bringr-93j.80).
    func testFnShiftedArrowClusterMapsToArrows() {
        XCTAssertEqual(KeyboardNavKey(keyCode: 115), .arrow(.left), "Fn+← arrives as Home")
        XCTAssertEqual(KeyboardNavKey(keyCode: 119), .arrow(.right), "Fn+→ arrives as End")
        XCTAssertEqual(KeyboardNavKey(keyCode: 116), .arrow(.up), "Fn+↑ arrives as Page Up")
        XCTAssertEqual(KeyboardNavKey(keyCode: 121), .arrow(.down), "Fn+↓ arrives as Page Down")
    }

    func testConfirmAndEscapeKeyCodes() {
        XCTAssertEqual(KeyboardNavKey(keyCode: 36), .confirm) // Return
        XCTAssertEqual(KeyboardNavKey(keyCode: 76), .confirm) // keypad Enter
        XCTAssertEqual(KeyboardNavKey(keyCode: 49), .confirm) // Space (Bringr-93j.72)
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

    func testUnmappedKeyCodeIsUnsupported() {
        // No longer dropped (Bringr-93j.73): an unrecognised key is classified `.unsupported` so the
        // close-on-unsupported policy can act on it; the monitor still passes it through when off.
        XCTAssertEqual(KeyboardNavKey(keyCode: 0), .unsupported)   // 'a'
        XCTAssertEqual(KeyboardNavKey(keyCode: 48), .unsupported)  // Tab
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
