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

    // MARK: - Fixtures

    private func raw(
        number: Int,
        pid: pid_t,
        name: String,
        title: String = "",
        layer: Int = 0,
        alpha: Double = 1,
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
            bounds: CGRect(x: 0, y: 0, width: width, height: height)
        )
    }
}

/// In-memory `WindowEnumerationSource` for tests: returns a fixed window list and
/// a configurable self-pid, with no live `CGWindowList` dependency.
@MainActor
final class FakeWindowEnumerationSource: WindowEnumerationSource {
    let selfPID: pid_t
    private let windows: [RawWindow]

    init(selfPID: pid_t, windows: [RawWindow]) {
        self.selfPID = selfPID
        self.windows = windows
    }

    func rawWindows() -> [RawWindow] { windows }
}
