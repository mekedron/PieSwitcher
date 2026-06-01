import XCTest
@testable import PieSwitcher

/// Covers the split labels setting (Bringr-93j.110): two independent keys for apps-ring
/// names and windows sub-wheel titles, with a one-time migration from the pre-split
/// `appearance.showsLabels` single key. Split from `RadialAppearanceTests` to keep that
/// class within SwiftLint's `type_body_length` (the class was 252 lines after the new
/// tests were added). Each test runs against an ephemeral `UserDefaults` suite, never
/// `.standard`.
final class RadialAppearanceSplitLabelsTests: XCTestCase {

    // MARK: - Defaults

    func testDefaultsShipAppLabelsOffAndWindowLabelsOnForDiscoverability() {
        // Apps ring keeps the pre-split off default — slices stay icon-only on first launch.
        // Window labels ship on, so a new user sees real titles on the sub-wheel without
        // hunting for the toggle. Defaults round-trip with no keys set.
        XCTAssertFalse(RadialAppearance.default.showsAppLabels)
        XCTAssertTrue(RadialAppearance.default.showsWindowLabels)
        let read = RadialAppearance.current(from: makeDefaults())
        XCTAssertFalse(read.showsAppLabels)
        XCTAssertTrue(read.showsWindowLabels)
    }

    // MARK: - Independence: the two new keys never flip each other

    func testSplitLabelsAreTwoIndependentRoundTrippedKeys() {
        let defaults = makeDefaults()
        defaults.set(true, forKey: RadialAppearance.showsAppLabelsDefaultsKey)
        defaults.set(false, forKey: RadialAppearance.showsWindowLabelsDefaultsKey)
        var read = RadialAppearance.current(from: defaults)
        XCTAssertTrue(read.showsAppLabels)
        XCTAssertFalse(read.showsWindowLabels)

        defaults.set(false, forKey: RadialAppearance.showsAppLabelsDefaultsKey)
        defaults.set(true, forKey: RadialAppearance.showsWindowLabelsDefaultsKey)
        read = RadialAppearance.current(from: defaults)
        XCTAssertFalse(read.showsAppLabels)
        XCTAssertTrue(read.showsWindowLabels)
    }

    // MARK: - Migration from the pre-split `appearance.showsLabels` key

    func testMigrationFromOldLabelsKeyAppliesToBothFieldsWhenSplitKeysUnset() {
        // Old labels=ON → both new settings ON (the user kept names, and gets window
        // titles on now too so the new feature is visible to them).
        let onDefaults = makeDefaults()
        onDefaults.set(true, forKey: RadialAppearance.labelsDefaultsKey)
        let onAppearance = RadialAppearance.current(from: onDefaults)
        XCTAssertTrue(onAppearance.showsAppLabels)
        XCTAssertTrue(onAppearance.showsWindowLabels)

        // Old labels=OFF → both new settings OFF (the user opted out of labels; do not
        // surface window titles uninvited).
        let offDefaults = makeDefaults()
        offDefaults.set(false, forKey: RadialAppearance.labelsDefaultsKey)
        let offAppearance = RadialAppearance.current(from: offDefaults)
        XCTAssertFalse(offAppearance.showsAppLabels)
        XCTAssertFalse(offAppearance.showsWindowLabels)
    }

    func testNewKeysOverrideMigrationWhenBothAreSet() {
        // Once the user touches a new toggle in Preferences, the new key wins and the
        // legacy key no longer flips that field — so the two settings are fully independent
        // even if the old key is still present on disk.
        let defaults = makeDefaults()
        defaults.set(true, forKey: RadialAppearance.labelsDefaultsKey)
        defaults.set(false, forKey: RadialAppearance.showsAppLabelsDefaultsKey)

        let read = RadialAppearance.current(from: defaults)
        XCTAssertFalse(read.showsAppLabels)
        // The other field still migrates from the legacy key since its new key is unset.
        XCTAssertTrue(read.showsWindowLabels)
    }

    func testFreshInstallWithNoLabelKeysSetUsesDefaults() {
        // Neither the old key nor either new key is set — both default values apply, so
        // the user sees window titles (the new feature) but not app names by default.
        let defaults = makeDefaults()
        let read = RadialAppearance.current(from: defaults)
        XCTAssertFalse(read.showsAppLabels)
        XCTAssertTrue(read.showsWindowLabels)
    }

    // MARK: - Fixtures

    /// An isolated `UserDefaults` suite so persistence tests never touch the real
    /// domain; torn down by suite name to stay Sendable-clean. Mirrors the helper in
    /// `RadialAppearanceTests`.
    private func makeDefaults() -> UserDefaults {
        let suite = "RadialAppearanceSplitLabelsTests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else {
            fatalError("could not create a test UserDefaults suite")
        }
        addTeardownBlock { UserDefaults.standard.removePersistentDomain(forName: suite) }
        return defaults
    }
}
