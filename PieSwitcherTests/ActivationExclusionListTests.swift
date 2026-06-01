import XCTest
@testable import PieSwitcher

/// Covers the activation-exclusion list (Bringr-93j.109): the pure add / remove /
/// dedup logic, the `UserDefaults` round-trip, and the activation gate that the
/// `MouseChordMonitor` / `ModifierHoldMonitor` providers call on every event.
/// Persistence uses an ephemeral suite (never `.standard`), mirroring
/// `CuratedAppsTests`.
final class ActivationExclusionListTests: XCTestCase {

    // MARK: - First-run default

    func testCurrentIsEmptyWhenUnset() {
        XCTAssertTrue(ActivationExclusionList.current(from: makeDefaults()).isEmpty,
                      "first-run default: nothing excluded, every app activates normally")
    }

    func testDefaultsKeyIsStable() {
        XCTAssertEqual(ActivationExclusionList.defaultsKey, "activation.exclusionList")
    }

    // MARK: - Persistence round-trip (AC: list survives quit/relaunch)

    func testListRoundTripsThroughDefaults() {
        let defaults = makeDefaults()
        let apps = [
            CuratedApp(bundleIdentifier: "com.epic.fortnite", name: "Fortnite"),
            CuratedApp(bundleIdentifier: "com.adobe.photoshop", name: "Photoshop")
        ]

        ActivationExclusionList.save(apps, to: defaults)

        XCTAssertEqual(ActivationExclusionList.current(from: defaults).apps, apps,
                       "the exclusion list must survive a write-then-read so a relaunch finds it")
    }

    func testSavingAnEmptyListClearsToEmpty() {
        let defaults = makeDefaults()
        ActivationExclusionList.save([CuratedApp(bundleIdentifier: "com.x.app", name: "X")], to: defaults)

        ActivationExclusionList.save([], to: defaults)

        XCTAssertTrue(ActivationExclusionList.current(from: defaults).isEmpty)
    }

    func testCurrentFallsBackToEmptyOnUndecodableData() {
        let defaults = makeDefaults()
        defaults.set(Data("not json".utf8), forKey: ActivationExclusionList.defaultsKey)

        XCTAssertTrue(ActivationExclusionList.current(from: defaults).isEmpty,
                      "a corrupted blob must read as empty so a stray UserDefaults edit can't brick activation")
    }

    // MARK: - Matching (AC: case-insensitive bundle-id compare, nil bundle id is never excluded)

    func testExcludesMatchesBundleIDCaseInsensitively() {
        let list = ActivationExclusionList(apps: [
            CuratedApp(bundleIdentifier: "com.epic.Fortnite", name: "Fortnite")
        ])
        XCTAssertTrue(list.excludes(bundleID: "com.epic.fortnite"),
                      "bundle ids are case-insensitive in the matching path")
        XCTAssertTrue(list.excludes(bundleID: "COM.EPIC.FORTNITE"))
    }

    func testExcludesIsFalseForUnlistedApp() {
        let list = ActivationExclusionList(apps: [
            CuratedApp(bundleIdentifier: "com.epic.fortnite", name: "Fortnite")
        ])
        XCTAssertFalse(list.excludes(bundleID: "com.apple.Safari"),
                       "an unlisted bundle id is never excluded, so Safari still activates the wheel")
    }

    func testExcludesIsFalseForNilBundleID() {
        let list = ActivationExclusionList(apps: [
            CuratedApp(bundleIdentifier: "com.epic.fortnite", name: "Fortnite")
        ])
        XCTAssertFalse(list.excludes(bundleID: nil),
                       "system UI (menu-bar, no-app focus) has no bundle id; never exclude there")
    }

    func testEmptyListExcludesNothing() {
        let list = ActivationExclusionList(apps: [])
        XCTAssertTrue(list.isEmpty)
        XCTAssertFalse(list.excludes(bundleID: "com.epic.fortnite"))
    }

    // MARK: - Adding (AC: add via picker, dedup, skip non-bundles)

    func testAddingAppendsResolvedBundlesAfterExistingOnes() throws {
        let url = try XCTUnwrap(CuratedApp.bundleURL(forBundleIdentifier: Self.finderBundleID))
        let existing = [CuratedApp(bundleIdentifier: "com.example.a", name: "A")]

        let merged = ActivationExclusionList.adding(bundlesAt: [url], to: existing)

        XCTAssertEqual(merged.map(\.bundleIdentifier), ["com.example.a", Self.finderBundleID],
                       "new exclusions append after existing ones so the user's order is preserved")
    }

    func testAddingTheSameAppTwiceIsANoOp() throws {
        let url = try XCTUnwrap(CuratedApp.bundleURL(forBundleIdentifier: Self.finderBundleID))
        let existing = [CuratedApp(bundleIdentifier: Self.finderBundleID, name: "Finder")]

        let merged = ActivationExclusionList.adding(bundlesAt: [url], to: existing)

        XCTAssertEqual(merged, existing,
                       "re-adding an already-excluded app is a no-op — the list never shows duplicates")
    }

    func testAddingDeduplicatesWithinASingleBatch() throws {
        let url = try XCTUnwrap(CuratedApp.bundleURL(forBundleIdentifier: Self.finderBundleID))

        let merged = ActivationExclusionList.adding(bundlesAt: [url, url], to: [])

        XCTAssertEqual(merged.map(\.bundleIdentifier), [Self.finderBundleID],
                       "the same bundle picked twice in one panel run is added once")
    }

    func testAddingSkipsUnresolvableURLs() {
        let existing = [CuratedApp(bundleIdentifier: "com.example.a", name: "A")]

        let merged = ActivationExclusionList.adding(bundlesAt: [URL(fileURLWithPath: "/etc/hosts")], to: existing)

        XCTAssertEqual(merged, existing,
                       "a panel pick that isn't an app bundle leaves the list unchanged — no crash, no junk row")
    }

    // MARK: - Removing (AC: remove via per-row delete)

    /// The Preferences editor removes a row by id with `apps.removeAll { $0.id == id }`
    /// and re-saves; this test exercises the same shape against the model to confirm the
    /// list survives the round-trip without the removed entry.
    func testRemovingByIDPersistsTheNewShorterList() {
        let defaults = makeDefaults()
        var apps = [
            CuratedApp(bundleIdentifier: "com.a", name: "A"),
            CuratedApp(bundleIdentifier: "com.b", name: "B"),
            CuratedApp(bundleIdentifier: "com.c", name: "C")
        ]
        ActivationExclusionList.save(apps, to: defaults)

        apps.removeAll { $0.id == "com.b" }
        ActivationExclusionList.save(apps, to: defaults)

        XCTAssertEqual(ActivationExclusionList.current(from: defaults).apps.map(\.bundleIdentifier),
                       ["com.a", "com.c"],
                       "removing a row writes a list without that bundle id; the rest survive in order")
    }

    // MARK: - Activation gate (AC: gate uses frontmost-app lookup)

    func testActivationProceedsWhenListIsEmpty() {
        let defaults = makeDefaults()
        // Nothing persisted → empty list → never suppress, no matter what the frontmost id is.
        XCTAssertFalse(
            ActivationExclusionList.shouldSuppressActivation(
                frontmostBundleID: "com.epic.fortnite", from: defaults
            ),
            "empty list → behaviour identical to the current build (no regressions on first run)"
        )
        XCTAssertFalse(
            ActivationExclusionList.shouldSuppressActivation(frontmostBundleID: nil, from: defaults)
        )
    }

    func testActivationSuppressedWhenFrontmostAppIsListed() {
        let defaults = makeDefaults()
        ActivationExclusionList.save([
            CuratedApp(bundleIdentifier: "com.epic.fortnite", name: "Fortnite")
        ], to: defaults)

        XCTAssertTrue(
            ActivationExclusionList.shouldSuppressActivation(
                frontmostBundleID: "com.epic.fortnite", from: defaults
            ),
            "frontmost = listed app → suppress so the held middle button passes through to the game"
        )
    }

    func testActivationProceedsWhenFrontmostAppIsNotListed() {
        let defaults = makeDefaults()
        ActivationExclusionList.save([
            CuratedApp(bundleIdentifier: "com.epic.fortnite", name: "Fortnite")
        ], to: defaults)

        XCTAssertFalse(
            ActivationExclusionList.shouldSuppressActivation(
                frontmostBundleID: "com.apple.Safari", from: defaults
            ),
            "a non-listed frontmost app means the wheel works normally — the gate is per-app"
        )
    }

    func testActivationProceedsWhenFrontmostIsNilEvenWithAListedApp() {
        let defaults = makeDefaults()
        ActivationExclusionList.save([
            CuratedApp(bundleIdentifier: "com.epic.fortnite", name: "Fortnite")
        ], to: defaults)

        XCTAssertFalse(
            ActivationExclusionList.shouldSuppressActivation(frontmostBundleID: nil, from: defaults),
            "no frontmost app (e.g. menu-bar interaction) → wheel still works, matching current build"
        )
    }

    func testActivationGateUsesCaseInsensitiveBundleIDMatch() {
        let defaults = makeDefaults()
        ActivationExclusionList.save([
            CuratedApp(bundleIdentifier: "com.epic.Fortnite", name: "Fortnite")
        ], to: defaults)

        XCTAssertTrue(
            ActivationExclusionList.shouldSuppressActivation(
                frontmostBundleID: "COM.EPIC.FORTNITE", from: defaults
            ),
            "the case the system reports for the frontmost bundle id shouldn't change the answer"
        )
    }

    // MARK: - Fixtures

    private static let finderBundleID = "com.apple.finder"

    /// An isolated `UserDefaults` suite so persistence tests never touch the real domain.
    private func makeDefaults() -> UserDefaults {
        let suiteName = "ActivationExclusionListTests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            fatalError("could not create a test UserDefaults suite")
        }
        return defaults
    }
}
