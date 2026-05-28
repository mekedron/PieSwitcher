import AppKit
import XCTest
@testable import Bringr

/// Covers the curated "My Apps" model (Bringr-93j.37): the ordered list's round-trip
/// through `UserDefaults` read fresh at summon (mirroring `RevealStrategy`), the
/// empty-when-unset first-run default, and the bundle-id resolution helpers. The
/// persistence tests use an ephemeral defaults suite (never `.standard`); the
/// resolution tests touch Launch Services against Finder — a system app guaranteed to
/// be installed and running in any GUI session — since these helpers are thin wrappers
/// the acceptance criteria explicitly verify against a known bundle id.
final class CuratedAppsTests: XCTestCase {

    // MARK: - Persistence round-trip (AC: ordered list round-trips; empty when unset)

    func testCurrentReturnsEmptyWhenUnset() {
        XCTAssertEqual(CuratedApps.current(from: makeDefaults()), [])
    }

    func testListRoundTripsThroughDefaults() {
        let defaults = makeDefaults()
        let apps = [
            CuratedApp(bundleIdentifier: "com.apple.Safari", name: "Safari"),
            CuratedApp(bundleIdentifier: "com.apple.Terminal", name: "Terminal")
        ]

        CuratedApps.save(apps, to: defaults)

        XCTAssertEqual(CuratedApps.current(from: defaults), apps)
    }

    func testRoundTripPreservesUserOrder() {
        let defaults = makeDefaults()
        let apps = [
            CuratedApp(bundleIdentifier: "com.c.app", name: "C"),
            CuratedApp(bundleIdentifier: "com.a.app", name: "A"),
            CuratedApp(bundleIdentifier: "com.b.app", name: "B")
        ]

        CuratedApps.save(apps, to: defaults)

        XCTAssertEqual(CuratedApps.current(from: defaults).map(\.bundleIdentifier),
                       ["com.c.app", "com.a.app", "com.b.app"],
                       "the manual order is the whole point of the list and must survive the round-trip")
    }

    func testSavingAnEmptyListClearsToEmpty() {
        let defaults = makeDefaults()
        CuratedApps.save([CuratedApp(bundleIdentifier: "com.x.app", name: "X")], to: defaults)

        CuratedApps.save([], to: defaults)

        XCTAssertEqual(CuratedApps.current(from: defaults), [])
    }

    func testCurrentFallsBackToEmptyOnUndecodableData() {
        let defaults = makeDefaults()
        defaults.set(Data("not json".utf8), forKey: CuratedApps.defaultsKey)

        XCTAssertEqual(CuratedApps.current(from: defaults), [])
    }

    func testDefaultsKeyIsStable() {
        XCTAssertEqual(CuratedApps.defaultsKey, "myApps.list")
    }

    func testIdentityIsTheBundleIdentifier() {
        let app = CuratedApp(bundleIdentifier: "com.apple.Safari", name: "Safari")
        XCTAssertEqual(app.id, "com.apple.Safari")
    }

    // MARK: - "Show all other running apps" toggle (Bringr-93j.42)

    func testShowsOtherRunningAppsDefaultsToTrueWhenUnset() {
        XCTAssertTrue(CuratedApps.showsOtherRunningApps(from: makeDefaults()),
                      "unset → ON, so an empty list reproduces the full wheel with no regression")
    }

    func testShowsOtherRunningAppsReadsPersistedFalse() {
        let defaults = makeDefaults()
        defaults.set(false, forKey: CuratedApps.showOtherRunningAppsDefaultsKey)

        XCTAssertFalse(CuratedApps.showsOtherRunningApps(from: defaults),
                       "an explicit false must survive — not be mistaken for the unset ON default")
    }

    func testShowsOtherRunningAppsReadsPersistedTrue() {
        let defaults = makeDefaults()
        defaults.set(true, forKey: CuratedApps.showOtherRunningAppsDefaultsKey)

        XCTAssertTrue(CuratedApps.showsOtherRunningApps(from: defaults))
    }

    func testShowOtherRunningAppsDefaultsKeyIsStable() {
        XCTAssertEqual(CuratedApps.showOtherRunningAppsDefaultsKey, "myApps.showOtherRunningApps")
    }

    // MARK: - Resolution helpers (AC: known bundle id → bundle URL and running app)

    func testKnownBundleIdResolvesToABundleURL() throws {
        let finder = CuratedApp(bundleIdentifier: Self.finderBundleID, name: "Finder")
        let url = try XCTUnwrap(finder.bundleURL)
        XCTAssertEqual(url.pathExtension, "app")
    }

    func testRunningAppResolvesToARunningInstanceAndPID() {
        // Finder is always running in a logged-in macOS session.
        let finder = CuratedApp(bundleIdentifier: Self.finderBundleID, name: "Finder")
        XCTAssertNotNil(finder.runningApplication)
        XCTAssertEqual(finder.runningPID, finder.runningApplication?.processIdentifier)
        if let pid = finder.runningPID {
            XCTAssertGreaterThan(pid, 0)
        }
    }

    func testStaticAndInstanceResolutionAgree() {
        let finder = CuratedApp(bundleIdentifier: Self.finderBundleID, name: "Finder")
        XCTAssertEqual(finder.bundleURL, CuratedApp.bundleURL(forBundleIdentifier: Self.finderBundleID))
        XCTAssertEqual(finder.runningPID,
                       CuratedApp.runningApplication(forBundleIdentifier: Self.finderBundleID)?.processIdentifier)
    }

    func testUnknownBundleIdResolvesToNothing() {
        let bogus = CuratedApp(bundleIdentifier: "com.bringr.definitely.not.installed.\(UUID().uuidString)",
                               name: "Nope")
        XCTAssertNil(bogus.bundleURL)
        XCTAssertNil(bogus.runningApplication)
        XCTAssertNil(bogus.runningPID)
    }

    // MARK: - Building entries from a bundle on disk (Bringr-93j.40 picker/drop)

    func testBuildingAnEntryFromAKnownBundleURL() throws {
        let url = try XCTUnwrap(CuratedApp.bundleURL(forBundleIdentifier: Self.finderBundleID))

        let app = try XCTUnwrap(CuratedApp(bundleAt: url))

        XCTAssertEqual(app.bundleIdentifier, Self.finderBundleID)
        XCTAssertEqual(app.name, "Finder", "the entry takes the bundle's Finder display name, sans .app")
    }

    func testBuildingAnEntryFromANonBundleURLFails() {
        XCTAssertNil(CuratedApp(bundleAt: URL(fileURLWithPath: "/etc/hosts")),
                     "a plain file is not an app bundle and yields no entry")
    }

    // MARK: - Merging picked/dropped bundles (Bringr-93j.40 add path)

    func testAddingAppendsResolvedBundlesAfterExistingOnes() throws {
        let url = try XCTUnwrap(CuratedApp.bundleURL(forBundleIdentifier: Self.finderBundleID))
        let existing = [CuratedApp(bundleIdentifier: "com.example.a", name: "A")]

        let merged = CuratedApps.adding(bundlesAt: [url], to: existing)

        XCTAssertEqual(merged.map(\.bundleIdentifier), ["com.example.a", Self.finderBundleID],
                       "new apps append after existing ones so the manual order is preserved")
    }

    func testAddingSkipsBundlesAlreadyInTheList() throws {
        let url = try XCTUnwrap(CuratedApp.bundleURL(forBundleIdentifier: Self.finderBundleID))
        let existing = [CuratedApp(bundleIdentifier: Self.finderBundleID, name: "Finder")]

        let merged = CuratedApps.adding(bundlesAt: [url], to: existing)

        XCTAssertEqual(merged, existing, "re-adding an already-listed app is a no-op")
    }

    func testAddingDeduplicatesWithinASingleBatch() throws {
        let url = try XCTUnwrap(CuratedApp.bundleURL(forBundleIdentifier: Self.finderBundleID))

        let merged = CuratedApps.adding(bundlesAt: [url, url], to: [])

        XCTAssertEqual(merged.map(\.bundleIdentifier), [Self.finderBundleID],
                       "the same bundle dropped twice in one batch is added once")
    }

    func testAddingSkipsUnresolvableURLs() {
        let existing = [CuratedApp(bundleIdentifier: "com.example.a", name: "A")]

        let merged = CuratedApps.adding(bundlesAt: [URL(fileURLWithPath: "/etc/hosts")], to: existing)

        XCTAssertEqual(merged, existing, "a drop that isn't an app bundle leaves the list unchanged")
    }

    // MARK: - Fixtures

    private static let finderBundleID = "com.apple.finder"

    /// An isolated `UserDefaults` suite so persistence tests never touch the real domain.
    private func makeDefaults() -> UserDefaults {
        let suiteName = "CuratedAppsTests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            fatalError("could not create a test UserDefaults suite")
        }
        return defaults
    }
}
