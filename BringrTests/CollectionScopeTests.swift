import XCTest
@testable import Bringr

/// Covers the persisted screens/Spaces collection scope (Bringr-93j.48): the four
/// `UserDefaults` flags round-trip with the documented all-off default, and resolving a
/// stored preference against the summon display yields the right per-level `CollectionScope`
/// — independently for apps and windows.
final class CollectionScopeTests: XCTestCase {
    private let display = CGRect(x: 0, y: 0, width: 1440, height: 900)

    // MARK: - Persistence: defaults and round-trip

    func testEveryFlagDefaultsToFalseWhenUnset() {
        let prefs = CollectionPreferences.current(from: ephemeralDefaults())

        // All off → collection stays on the summon screen/Space (the Bringr-93j.30 behaviour).
        XCTAssertFalse(prefs.appsAllScreens)
        XCTAssertFalse(prefs.appsAllSpaces)
        XCTAssertFalse(prefs.windowsAllScreens)
        XCTAssertFalse(prefs.windowsAllSpaces)
    }

    func testEachFlagRoundTripsIndependently() {
        let defaults = ephemeralDefaults()
        defaults.set(true, forKey: CollectionPreferences.appsAllSpacesDefaultsKey)
        defaults.set(true, forKey: CollectionPreferences.windowsAllScreensDefaultsKey)

        let prefs = CollectionPreferences.current(from: defaults)
        XCTAssertFalse(prefs.appsAllScreens)
        XCTAssertTrue(prefs.appsAllSpaces)
        XCTAssertTrue(prefs.windowsAllScreens)
        XCTAssertFalse(prefs.windowsAllSpaces)
    }

    func testKeysAreDistinct() {
        let keys = Set([
            CollectionPreferences.appsAllScreensDefaultsKey,
            CollectionPreferences.appsAllSpacesDefaultsKey,
            CollectionPreferences.windowsAllScreensDefaultsKey,
            CollectionPreferences.windowsAllSpacesDefaultsKey
        ])
        XCTAssertEqual(keys.count, 4)
    }

    // MARK: - Resolution against the summon display

    func testCurrentScreenScopeUsesTheDisplayBounds() {
        let prefs = CollectionPreferences(
            appsAllScreens: false, appsAllSpaces: false,
            windowsAllScreens: false, windowsAllSpaces: false
        )
        XCTAssertEqual(prefs.appsScope(forDisplay: display).screenBounds, display)
        XCTAssertEqual(prefs.windowsScope(forDisplay: display).screenBounds, display)
    }

    func testAllScreensDropsTheDisplayBoundsToNil() {
        let prefs = CollectionPreferences(
            appsAllScreens: true, appsAllSpaces: false,
            windowsAllScreens: true, windowsAllSpaces: false
        )
        // `nil` is the whole-desktop signal the enumerator's screen filter understands, so
        // "all screens" is expressed by dropping the bound even though a display was passed.
        XCTAssertNil(prefs.appsScope(forDisplay: display).screenBounds)
        XCTAssertNil(prefs.windowsScope(forDisplay: display).screenBounds)
    }

    func testAllSpacesFlagPassesThroughVerbatim() {
        let prefs = CollectionPreferences(
            appsAllScreens: false, appsAllSpaces: true,
            windowsAllScreens: false, windowsAllSpaces: false
        )
        XCTAssertTrue(prefs.appsScope(forDisplay: display).allSpaces)
        XCTAssertFalse(prefs.windowsScope(forDisplay: display).allSpaces)
    }

    func testAppsAndWindowsScopesResolveIndependently() {
        // Apps span every screen but the current Space; windows stay on this screen across
        // every Space — proving the two levels carry separate screen and Space decisions.
        let prefs = CollectionPreferences(
            appsAllScreens: true, appsAllSpaces: false,
            windowsAllScreens: false, windowsAllSpaces: true
        )
        let apps = prefs.appsScope(forDisplay: display)
        let windows = prefs.windowsScope(forDisplay: display)

        XCTAssertNil(apps.screenBounds)
        XCTAssertFalse(apps.allSpaces)
        XCTAssertEqual(windows.screenBounds, display)
        XCTAssertTrue(windows.allSpaces)
    }

    func testAllScreensCurrentSpaceConstant() {
        XCTAssertNil(CollectionScope.allScreensCurrentSpace.screenBounds)
        XCTAssertFalse(CollectionScope.allScreensCurrentSpace.allSpaces)
    }

    private func ephemeralDefaults() -> UserDefaults {
        let suite = "CollectionScopeTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }
}
