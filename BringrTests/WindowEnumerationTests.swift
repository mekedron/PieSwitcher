import XCTest
@testable import Bringr

@MainActor
final class WindowEnumerationTests: XCTestCase {
    private let selfPID: pid_t = 1000

    // MARK: - AC1/AC3: returns apps with normal on-screen windows, drops the rest

    func testGroupsWindowsByAppPreservingFrontToBackOrder() {
        let source = FakeWindowEnumerationSource(selfPID: selfPID, windows: [
            raw(number: 1, pid: 10, name: "Chrome"),
            raw(number: 2, pid: 20, name: "Ghostty"),
            raw(number: 3, pid: 10, name: "Chrome")
        ])
        let apps = WindowEnumerator(source: source).enumerate()

        XCTAssertEqual(apps.map(\.id), [AppID(pid: 10), AppID(pid: 20)])
        XCTAssertEqual(apps[0].name, "Chrome")
        XCTAssertEqual(apps[0].windows.map(\.id.token), [1, 3])
        XCTAssertEqual(apps[1].windows.map(\.id.token), [2])
    }

    func testExcludesNonNormalWindows() {
        let source = FakeWindowEnumerationSource(selfPID: selfPID, windows: [
            raw(number: 1, pid: 10, name: "Chrome"),
            raw(number: 2, pid: 10, name: "Chrome", layer: 24),       // menu-bar layer
            raw(number: 3, pid: 10, name: "Chrome", alpha: 0),        // invisible helper
            raw(number: 4, pid: 10, name: "Chrome", width: 4, height: 4) // tiny helper
        ])
        let apps = WindowEnumerator(source: source).enumerate()

        XCTAssertEqual(apps.count, 1)
        XCTAssertEqual(apps[0].windows.map(\.id.token), [1])
    }

    func testAppWithOnlyNonNormalWindowsIsExcluded() {
        let source = FakeWindowEnumerationSource(selfPID: selfPID, windows: [
            raw(number: 1, pid: 30, name: "MenuBarApp", layer: 25), // status-item only
            raw(number: 2, pid: 30, name: "MenuBarApp", layer: 25),
            raw(number: 3, pid: 10, name: "Chrome")
        ])
        let apps = WindowEnumerator(source: source).enumerate()

        XCTAssertEqual(apps.map(\.id), [AppID(pid: 10)])
    }

    func testWindowsWithoutOwnerNameAreExcluded() {
        let source = FakeWindowEnumerationSource(selfPID: selfPID, windows: [
            raw(number: 1, pid: 40, name: ""),
            raw(number: 2, pid: 10, name: "Chrome")
        ])
        let apps = WindowEnumerator(source: source).enumerate()

        XCTAssertEqual(apps.map(\.id), [AppID(pid: 10)])
    }

    // MARK: - AC3: excludes Bringr itself

    func testExcludesOwnWindows() {
        let source = FakeWindowEnumerationSource(selfPID: selfPID, windows: [
            raw(number: 1, pid: selfPID, name: "Bringr"),
            raw(number: 2, pid: 10, name: "Chrome")
        ])
        let apps = WindowEnumerator(source: source).enumerate()

        XCTAssertEqual(apps.map(\.id), [AppID(pid: 10)])
    }

    // MARK: - AC2: stable identifier, title, owning app

    func testStableIdentifierUsesWindowNumberAndCarriesOwningApp() {
        let source = FakeWindowEnumerationSource(selfPID: selfPID, windows: [
            raw(number: 4242, pid: 10, name: "Chrome")
        ])
        let apps = WindowEnumerator(source: source).enumerate()

        let window = apps[0].windows[0]
        XCTAssertEqual(window.id, WindowID(app: AppID(pid: 10), token: 4242))
        XCTAssertEqual(window.app, AppID(pid: 10))
    }

    func testUsesProvidedTitleTrimmedWhenPresent() {
        let source = FakeWindowEnumerationSource(selfPID: selfPID, windows: [
            raw(number: 1, pid: 10, name: "Chrome", title: "  Inbox — Mail  ")
        ])
        let apps = WindowEnumerator(source: source).enumerate()

        XCTAssertEqual(apps[0].windows[0].title, "Inbox — Mail")
    }

    func testTitleFallsBackToOneBasedIndexWhenEmpty() {
        let source = FakeWindowEnumerationSource(selfPID: selfPID, windows: [
            raw(number: 1, pid: 10, name: "Chrome", title: ""),
            raw(number: 2, pid: 10, name: "Chrome", title: "   ")
        ])
        let apps = WindowEnumerator(source: source).enumerate()

        XCTAssertEqual(apps[0].windows.map(\.title), ["Window 1", "Window 2"])
    }

    // MARK: - AC4: timing recorded; AC1: empty input

    func testLastDurationRecordedOnlyAfterEnumerate() {
        let source = FakeWindowEnumerationSource(selfPID: selfPID, windows: [
            raw(number: 1, pid: 10, name: "Chrome")
        ])
        let enumerator = WindowEnumerator(source: source)

        XCTAssertNil(enumerator.lastDuration)
        _ = enumerator.enumerate()
        XCTAssertNotNil(enumerator.lastDuration)
        XCTAssertGreaterThanOrEqual(enumerator.lastDuration ?? -1, 0)
    }

    func testEmptySourceReturnsNoApps() {
        let source = FakeWindowEnumerationSource(selfPID: selfPID, windows: [])
        XCTAssertTrue(WindowEnumerator(source: source).enumerate().isEmpty)
    }

    // MARK: - Bringr-93j.34: app sort order

    func testAppOrderRecentlyUsedKeepsFrontToBackOrder() {
        let source = FakeWindowEnumerationSource(selfPID: selfPID, windows: [
            raw(number: 1, pid: 20, name: "Ghostty"),
            raw(number: 2, pid: 10, name: "Chrome"),
            raw(number: 3, pid: 30, name: "Mail")
        ])
        let apps = WindowEnumerator(
            source: source, appOrder: { .recentlyUsed }, windowOrder: { .recentlyUsed }
        ).enumerate()

        XCTAssertEqual(apps.map(\.name), ["Ghostty", "Chrome", "Mail"])
    }

    func testAppOrderByNameSortsAlphabeticallyRegardlessOfZOrder() {
        let source = FakeWindowEnumerationSource(selfPID: selfPID, windows: [
            raw(number: 1, pid: 20, name: "Ghostty"),
            raw(number: 2, pid: 10, name: "Chrome"),
            raw(number: 3, pid: 30, name: "Mail")
        ])
        let apps = WindowEnumerator(
            source: source, appOrder: { .name }, windowOrder: { .recentlyUsed }
        ).enumerate()

        XCTAssertEqual(apps.map(\.name), ["Chrome", "Ghostty", "Mail"])
    }

    func testAppOrderByNameIsCaseInsensitive() {
        let source = FakeWindowEnumerationSource(selfPID: selfPID, windows: [
            raw(number: 1, pid: 20, name: "zoom"),
            raw(number: 2, pid: 10, name: "Arc")
        ])
        let apps = WindowEnumerator(
            source: source, appOrder: { .name }, windowOrder: { .recentlyUsed }
        ).enumerate()

        XCTAssertEqual(apps.map(\.name), ["Arc", "zoom"])
    }

    // MARK: - Bringr-93j.34: window sort order

    func testWindowOrderRecentlyUsedKeepsFrontToBackOrder() {
        let source = FakeWindowEnumerationSource(selfPID: selfPID, windows: [
            raw(number: 30, pid: 10, name: "Chrome"),
            raw(number: 10, pid: 10, name: "Chrome"),
            raw(number: 20, pid: 10, name: "Chrome")
        ])
        let apps = WindowEnumerator(
            source: source, appOrder: { .recentlyUsed }, windowOrder: { .recentlyUsed }
        ).enumerate()

        XCTAssertEqual(apps[0].windows.map(\.id.token), [30, 10, 20])
    }

    func testWindowOrderFixedSortsByWindowNumberAscending() {
        let source = FakeWindowEnumerationSource(selfPID: selfPID, windows: [
            raw(number: 30, pid: 10, name: "Chrome"),
            raw(number: 10, pid: 10, name: "Chrome"),
            raw(number: 20, pid: 10, name: "Chrome")
        ])
        let apps = WindowEnumerator(
            source: source, appOrder: { .recentlyUsed }, windowOrder: { .fixed }
        ).enumerate()

        XCTAssertEqual(apps[0].windows.map(\.id.token), [10, 20, 30])
    }

    func testAppAndWindowOrdersApplyIndependently() {
        let source = FakeWindowEnumerationSource(selfPID: selfPID, windows: [
            raw(number: 5, pid: 20, name: "Ghostty"),
            raw(number: 9, pid: 20, name: "Ghostty"),
            raw(number: 7, pid: 10, name: "Chrome")
        ])
        let apps = WindowEnumerator(
            source: source, appOrder: { .name }, windowOrder: { .fixed }
        ).enumerate()

        XCTAssertEqual(apps.map(\.name), ["Chrome", "Ghostty"])
        XCTAssertEqual(apps[1].windows.map(\.id.token), [5, 9])
    }

    // MARK: - Bringr-93j.34: persisted setting round-trips

    func testAppSortOrderDefaultsToRecentlyUsedWhenUnset() {
        let defaults = ephemeralDefaults()
        XCTAssertEqual(AppSortOrder.current(from: defaults), .recentlyUsed)
    }

    func testAppSortOrderReadsPersistedValue() {
        let defaults = ephemeralDefaults()
        defaults.set(AppSortOrder.name.rawValue, forKey: AppSortOrder.defaultsKey)
        XCTAssertEqual(AppSortOrder.current(from: defaults), .name)
    }

    func testWindowSortOrderDefaultsToRecentlyUsedWhenUnset() {
        let defaults = ephemeralDefaults()
        XCTAssertEqual(WindowSortOrder.current(from: defaults), .recentlyUsed)
    }

    func testWindowSortOrderReadsPersistedValue() {
        let defaults = ephemeralDefaults()
        defaults.set(WindowSortOrder.fixed.rawValue, forKey: WindowSortOrder.defaultsKey)
        XCTAssertEqual(WindowSortOrder.current(from: defaults), .fixed)
    }

    private func ephemeralDefaults() -> UserDefaults {
        let suite = "WindowEnumerationTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    // MARK: - Bringr-93j.30: restrict enumeration to the summon display

    /// Two side-by-side 1440×900 displays in CoreGraphics' global space (the same
    /// space `RawWindow.bounds` lives in): A spans x 0–1440, B spans x 1440–2880.
    private let screenA = CGRect(x: 0, y: 0, width: 1440, height: 900)
    private let screenB = CGRect(x: 1440, y: 0, width: 1440, height: 900)

    func testRestrictsAppsAndWindowsToTheGivenDisplay() {
        let source = FakeWindowEnumerationSource(selfPID: selfPID, windows: [
            raw(number: 1, pid: 10, name: "Chrome", x: 100, y: 100),    // on A
            raw(number: 2, pid: 10, name: "Chrome", x: 1500, y: 100),   // on B
            raw(number: 3, pid: 20, name: "Ghostty", x: 200, y: 200),   // on A
            raw(number: 4, pid: 30, name: "Mail", x: 1600, y: 200)      // on B
        ])
        let apps = WindowEnumerator(source: source).enumerate(onScreen: screenA)

        // Mail (entirely on B) drops out; Chrome keeps only its window living on A.
        XCTAssertEqual(apps.map(\.name), ["Chrome", "Ghostty"])
        XCTAssertEqual(apps[0].windows.map(\.id.token), [1])
        XCTAssertEqual(apps[1].windows.map(\.id.token), [3])
    }

    func testSameAppSplitAcrossDisplaysShowsOnlyEachDisplaysWindows() {
        let source = FakeWindowEnumerationSource(selfPID: selfPID, windows: [
            raw(number: 1, pid: 10, name: "Chrome", x: 100, y: 100),    // on A
            raw(number: 2, pid: 10, name: "Chrome", x: 1500, y: 100)    // on B
        ])

        XCTAssertEqual(
            WindowEnumerator(source: source).enumerate(onScreen: screenA)[0].windows.map(\.id.token),
            [1]
        )
        XCTAssertEqual(
            WindowEnumerator(source: source).enumerate(onScreen: screenB)[0].windows.map(\.id.token),
            [2]
        )
    }

    func testWindowStraddlingBoundaryBelongsToDisplayContainingItsCentre() {
        // width 800 → centre x = x + 400; x = 1040 puts the centre exactly on the A|B
        // seam (x 1440), which CGRect assigns to B (min edge inclusive, max exclusive).
        let source = FakeWindowEnumerationSource(selfPID: selfPID, windows: [
            raw(number: 1, pid: 10, name: "Chrome", x: 1040, y: 100)
        ])

        XCTAssertTrue(WindowEnumerator(source: source).enumerate(onScreen: screenA).isEmpty)
        XCTAssertEqual(
            WindowEnumerator(source: source).enumerate(onScreen: screenB).map(\.name), ["Chrome"]
        )
    }

    func testDisplayWithNoMatchingWindowsYieldsNoApps() {
        let elsewhere = CGRect(x: 5000, y: 5000, width: 100, height: 100)
        let source = FakeWindowEnumerationSource(selfPID: selfPID, windows: [
            raw(number: 1, pid: 10, name: "Chrome", x: 100, y: 100)
        ])

        XCTAssertTrue(WindowEnumerator(source: source).enumerate(onScreen: elsewhere).isEmpty)
    }

    // MARK: - Fixtures

    private func raw(
        number: Int,
        pid: pid_t,
        name: String,
        title: String = "",
        layer: Int = 0,
        alpha: Double = 1,
        x: CGFloat = 0,
        y: CGFloat = 0,
        width: CGFloat = 800,
        height: CGFloat = 600
    ) -> RawWindow {
        RawWindow(
            windowNumber: number,
            ownerPID: pid,
            ownerName: name,
            title: title,
            layer: layer,
            alpha: alpha,
            bounds: CGRect(x: x, y: y, width: width, height: height)
        )
    }
}

/// In-memory `WindowEnumerationSource` for tests: returns a fixed window list and
/// a configurable self-pid, with no live `CGWindowList` dependency.
@MainActor
final class FakeWindowEnumerationSource: WindowEnumerationSource {
    let selfPID: pid_t
    private let windows: [RawWindow]
    /// Windows to return when asked for all Spaces (Bringr-93j.48); `nil` serves the base
    /// `windows` for both modes, so the single-list tests are unaffected.
    private let allSpacesWindows: [RawWindow]?
    /// The `includingAllSpaces` of the most recent call, so a test can assert the
    /// enumerator forwarded the scope's Space flag.
    private(set) var lastIncludedAllSpaces: Bool?

    init(selfPID: pid_t, windows: [RawWindow], allSpacesWindows: [RawWindow]? = nil) {
        self.selfPID = selfPID
        self.windows = windows
        self.allSpacesWindows = allSpacesWindows
    }

    func rawWindows(includingAllSpaces: Bool) -> [RawWindow] {
        lastIncludedAllSpaces = includingAllSpaces
        if includingAllSpaces, let allSpacesWindows { return allSpacesWindows }
        return windows
    }
}
