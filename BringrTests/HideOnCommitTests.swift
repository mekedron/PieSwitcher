import XCTest
@testable import Bringr

/// Covers the "leave only my selection on screen" setting (Bringr-93j.27): the persistence
/// helper behind the Preferences toggle. The clear-on-commit *behaviour* lives in
/// `WindowController` and is covered by `WindowControlTests` (and end-to-end through the
/// navigator in `RadialNavigatorCommitTests`).
final class HideOnCommitTests: XCTestCase {

    func testDefaultIsOff() {
        XCTAssertFalse(HideOnCommit.default)
    }

    func testDefaultsKeyIsStable() {
        XCTAssertEqual(HideOnCommit.defaultsKey, "hideOnCommit")
    }

    func testIsEnabledFallsBackToOffWhenUnset() {
        XCTAssertFalse(HideOnCommit.isEnabled(from: makeDefaults()))
    }

    func testIsEnabledReadsTheStoredValue() {
        for value in [true, false] {
            let defaults = makeDefaults()
            defaults.set(value, forKey: HideOnCommit.defaultsKey)
            XCTAssertEqual(HideOnCommit.isEnabled(from: defaults), value)
        }
    }

    /// An isolated `UserDefaults` suite so persistence tests never touch the real domain.
    private func makeDefaults() -> UserDefaults {
        let suiteName = "HideOnCommitTests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            fatalError("could not create a test UserDefaults suite")
        }
        return defaults
    }
}
