import XCTest
@testable import Bringr

/// Covers the second-level cursor-lock setting (Bringr-93j.29): the persistence helper
/// behind the Preferences toggle. The engage/release and confinement *geometry* live in
/// `RadialNavigator` and are covered by `RadialNavigatorCursorLockTests`.
final class CursorLockTests: XCTestCase {

    func testDefaultIsOff() {
        XCTAssertFalse(CursorLock.default)
    }

    func testDefaultsKeyIsStable() {
        XCTAssertEqual(CursorLock.defaultsKey, "cursorLock.secondLevel")
    }

    func testIsEnabledFallsBackToOffWhenUnset() {
        XCTAssertFalse(CursorLock.isEnabled(from: makeDefaults()))
    }

    func testIsEnabledReadsTheStoredValue() {
        for value in [true, false] {
            let defaults = makeDefaults()
            defaults.set(value, forKey: CursorLock.defaultsKey)
            XCTAssertEqual(CursorLock.isEnabled(from: defaults), value)
        }
    }

    /// An isolated `UserDefaults` suite so persistence tests never touch the real domain.
    private func makeDefaults() -> UserDefaults {
        let suiteName = "CursorLockTests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            fatalError("could not create a test UserDefaults suite")
        }
        return defaults
    }
}
