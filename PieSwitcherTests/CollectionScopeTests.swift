import XCTest
@testable import PieSwitcher

/// Covers the persisted screens/Spaces collection scope (Bringr-93j.48): the four
/// `UserDefaults` flags round-trip with the documented all-off default, and resolving a
/// stored preference against the summon display yields the right per-level `CollectionScope`
/// — independently for apps and windows.
final class CollectionScopeTests: XCTestCase {
    private let display = CGRect(x: 0, y: 0, width: 1440, height: 900)

    // MARK: - Persistence: defaults and round-trip

    func testEveryFlagDefaultsToItsBakedDefault() {
        // Bringr-93j.93: screens/minimized/hidden ship ON so the wheel collects the broadest
        // set out of the box; Spaces flags stay OFF (current Space only is the safe,
        // non-phantom-prone behaviour).
        let prefs = CollectionPreferences.current(from: ephemeralDefaults())

        XCTAssertTrue(prefs.appsAllScreens)
        XCTAssertFalse(prefs.appsAllSpaces)
        XCTAssertTrue(prefs.windowsAllScreens)
        XCTAssertFalse(prefs.windowsAllSpaces)
        XCTAssertTrue(prefs.includeMinimized)
        XCTAssertTrue(prefs.includeHidden)
    }

    func testEachFlagDefaultConstantMatches() {
        // The per-flag constants are the single source of truth for the Preferences
        // `@AppStorage` bindings and the read fallback — keep them visibly correct.
        XCTAssertTrue(CollectionPreferences.appsAllScreensDefault)
        XCTAssertFalse(CollectionPreferences.appsAllSpacesDefault)
        XCTAssertTrue(CollectionPreferences.windowsAllScreensDefault)
        XCTAssertFalse(CollectionPreferences.windowsAllSpacesDefault)
        XCTAssertTrue(CollectionPreferences.includeMinimizedDefault)
        XCTAssertTrue(CollectionPreferences.includeHiddenDefault)
    }

    func testStoredFalseOverridesOnDefault() {
        // Explicit false must round-trip — `bool(forKey:)` returning false for an absent key
        // can't mask a real, persisted false (the unset-vs-stored distinction).
        let defaults = ephemeralDefaults()
        defaults.set(false, forKey: CollectionPreferences.appsAllScreensDefaultsKey)
        defaults.set(false, forKey: CollectionPreferences.windowsAllScreensDefaultsKey)
        defaults.set(false, forKey: CollectionPreferences.includeMinimizedDefaultsKey)
        defaults.set(false, forKey: CollectionPreferences.includeHiddenDefaultsKey)

        let prefs = CollectionPreferences.current(from: defaults)
        XCTAssertFalse(prefs.appsAllScreens)
        XCTAssertFalse(prefs.windowsAllScreens)
        XCTAssertFalse(prefs.includeMinimized)
        XCTAssertFalse(prefs.includeHidden)
    }

    func testMinimizedAndHiddenFlagsRoundTrip() {
        let defaults = ephemeralDefaults()
        defaults.set(true, forKey: CollectionPreferences.includeMinimizedDefaultsKey)
        defaults.set(true, forKey: CollectionPreferences.includeHiddenDefaultsKey)

        let prefs = CollectionPreferences.current(from: defaults)
        XCTAssertTrue(prefs.includeMinimized)
        XCTAssertTrue(prefs.includeHidden)
    }

    func testEachFlagRoundTripsIndependently() {
        // Set every key explicitly so the four ON-default flags don't mask a setter mismatch.
        let defaults = ephemeralDefaults()
        defaults.set(false, forKey: CollectionPreferences.appsAllScreensDefaultsKey)
        defaults.set(true, forKey: CollectionPreferences.appsAllSpacesDefaultsKey)
        defaults.set(true, forKey: CollectionPreferences.windowsAllScreensDefaultsKey)
        defaults.set(false, forKey: CollectionPreferences.windowsAllSpacesDefaultsKey)

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
            CollectionPreferences.windowsAllSpacesDefaultsKey,
            CollectionPreferences.includeMinimizedDefaultsKey,
            CollectionPreferences.includeHiddenDefaultsKey
        ])
        XCTAssertEqual(keys.count, 6)
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
        // With no screen filter to cull off-display phantoms, each level must validate its
        // on-screen records (Bringr-93j.60).
        XCTAssertTrue(prefs.appsScope(forDisplay: display).validatesOnscreen)
        XCTAssertTrue(prefs.windowsScope(forDisplay: display).validatesOnscreen)
    }

    func testCurrentScreenScopeDoesNotValidateOnscreen() {
        // Screen-scoped collection has the screen filter to cull off-display phantoms, so it
        // trusts on-screen records and skips the managed-Space check (Bringr-93j.60).
        let prefs = CollectionPreferences(
            appsAllScreens: false, appsAllSpaces: false,
            windowsAllScreens: false, windowsAllSpaces: false
        )
        XCTAssertFalse(prefs.appsScope(forDisplay: display).validatesOnscreen)
        XCTAssertFalse(prefs.windowsScope(forDisplay: display).validatesOnscreen)
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

    func testMinimizedAndHiddenFlagsRideIntoBothScopes() {
        // The two flags are global, so they resolve identically into the apps ring and the
        // windows sub-wheel — unlike the per-level screen/Space decisions (Bringr-93j.50).
        let prefs = CollectionPreferences(
            appsAllScreens: false, appsAllSpaces: false,
            windowsAllScreens: false, windowsAllSpaces: false,
            includeMinimized: true, includeHidden: true
        )
        for scope in [prefs.appsScope(forDisplay: display), prefs.windowsScope(forDisplay: display)] {
            XCTAssertTrue(scope.includeMinimized)
            XCTAssertTrue(scope.includeHidden)
        }
    }

    func testAllScreensCurrentSpaceConstant() {
        XCTAssertNil(CollectionScope.allScreensCurrentSpace.screenBounds)
        XCTAssertFalse(CollectionScope.allScreensCurrentSpace.allSpaces)
        XCTAssertFalse(CollectionScope.allScreensCurrentSpace.includeMinimized)
        XCTAssertFalse(CollectionScope.allScreensCurrentSpace.includeHidden)
        XCTAssertFalse(CollectionScope.allScreensCurrentSpace.validatesOnscreen)
    }

    private func ephemeralDefaults() -> UserDefaults {
        let suite = "CollectionScopeTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }
}
