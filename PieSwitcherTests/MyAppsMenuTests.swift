import CoreGraphics
import XCTest
@testable import PieSwitcher

@MainActor
final class MyAppsMenuTests: XCTestCase {

    // MARK: - AC: an empty list reproduces the current full wheel

    func testEmptyCuratedListReproducesTheRawWheel() {
        let source = stub([
            raw(number: 11, pid: 10, name: "Chrome"),
            raw(number: 21, pid: 20, name: "Ghostty")
        ])
        let enumerator = makeEnumerator(source)
        let curated = MyAppsMenu(
            enumerator: enumerator, curatedApps: { [] },
            showOtherRunningApps: { true },
            keepCuratedOrder: { true }, runningPID: { _ in nil }
        )

        let rawWheel = WindowSwitcherMenu(enumerator: enumerator).makeRoot().resolvedChildren()
        let curatedWheel = curated.makeRoot().resolvedChildren()
        XCTAssertEqual(curatedWheel.map(\.title), rawWheel.map(\.title))
        XCTAssertEqual(curatedWheel.map(\.title), ["Chrome", "Ghostty"])
        XCTAssertEqual(curatedWheel.map(\.bundleIdentifier), [nil, nil] as [String?])
    }

    // MARK: - AC: one running + one not-running, both in list order

    func testRunningAndNotRunningAppsShownInUserOrder() {
        let source = stub([
            raw(number: 11, pid: 10, name: "Chrome", title: "Inbox"),
            raw(number: 12, pid: 10, name: "Chrome", title: "Docs")
        ])
        // Mail is listed first but not running; Chrome listed second and running with windows.
        let curated = [
            CuratedApp(bundleIdentifier: "com.apple.Mail", name: "Mail"),
            CuratedApp(bundleIdentifier: "com.google.Chrome", name: "Chrome")
        ]
        let menu = MyAppsMenu(
            enumerator: makeEnumerator(source),
            curatedApps: { curated },
            showOtherRunningApps: { false },
            keepCuratedOrder: { true },
            runningPID: { $0 == "com.google.Chrome" ? 10 : nil }
        )

        let apps = menu.makeRoot().resolvedChildren()
        XCTAssertEqual(apps.map(\.title), ["Mail", "Chrome"], "pinned in user manual order")

        // Mail (not running) → launch node, no sub-wheel, icon by bundle id.
        XCTAssertEqual(apps[0].action, .launchApp(bundleIdentifier: "com.apple.Mail"))
        XCTAssertNil(apps[0].representedApp)
        XCTAssertEqual(apps[0].bundleIdentifier, "com.apple.Mail")
        XCTAssertTrue(apps[0].resolvedChildren().isEmpty)

        // Chrome (running with windows) → expand node carrying both pid and bundle id, with
        // its live windows sub-wheel.
        XCTAssertEqual(apps[1].action, .expand)
        XCTAssertEqual(apps[1].representedApp, AppID(pid: 10))
        XCTAssertEqual(apps[1].bundleIdentifier, "com.google.Chrome")
        XCTAssertEqual(apps[1].resolvedChildren().map(\.title), ["Inbox", "Docs"])
    }

    // MARK: - Toggle OFF: show only the curated apps

    func testShowOthersOffShowsOnlyTheCuratedApps() {
        let source = stub([
            raw(number: 11, pid: 10, name: "Chrome"),
            raw(number: 21, pid: 20, name: "Ghostty")     // running but not curated
        ])
        let menu = MyAppsMenu(
            enumerator: makeEnumerator(source),
            curatedApps: { [CuratedApp(bundleIdentifier: "com.google.Chrome", name: "Chrome")] },
            showOtherRunningApps: { false },
            keepCuratedOrder: { true },
            runningPID: { $0 == "com.google.Chrome" ? 10 : nil }
        )

        XCTAssertEqual(menu.makeRoot().resolvedChildren().map(\.title), ["Chrome"],
                       "with the toggle off, the running-but-not-curated Ghostty is not appended")
    }

    // MARK: - Bringr-93j.30: a running app with no window on the summon screen launches

    func testRunningAppWithNoWindowOnSummonScreenBecomesLaunchNode() {
        let screenA = CGRect(x: 0, y: 0, width: 1440, height: 900)
        let source = stub([raw(number: 11, pid: 10, name: "Chrome", x: 1600, y: 100)])  // off A
        let menu = MyAppsMenu(
            enumerator: makeEnumerator(source),
            curatedApps: { [CuratedApp(bundleIdentifier: "com.google.Chrome", name: "Chrome")] },
            showOtherRunningApps: { false },
            keepCuratedOrder: { true },
            runningPID: { _ in 10 }                         // Chrome IS running...
        )

        // ...but owns no window on screen A, so on A it lists as a launch node.
        let scope = CollectionScope(screenBounds: screenA, allSpaces: false)
        let apps = menu.makeRoot(appsScope: scope, windowsScope: scope).resolvedChildren()
        XCTAssertEqual(apps.map(\.action), [.launchApp(bundleIdentifier: "com.google.Chrome")])
    }

    // MARK: - The node kind is recomputed from live state on each resolve

    func testNodeKindFollowsLiveStateOnEachResolve() {
        let source = stub([])                               // nothing running yet
        var chromePID: pid_t?
        let menu = MyAppsMenu(
            enumerator: makeEnumerator(source),
            curatedApps: { [CuratedApp(bundleIdentifier: "com.google.Chrome", name: "Chrome")] },
            showOtherRunningApps: { false },
            keepCuratedOrder: { true },
            runningPID: { _ in chromePID }
        )
        let root = menu.makeRoot()

        XCTAssertEqual(root.resolvedChildren().map(\.action),
                       [.launchApp(bundleIdentifier: "com.google.Chrome")])

        // Chrome launches: now running with a window. Re-resolving the same root flips it
        // to an expand node with the live sub-wheel.
        chromePID = 10
        source.windows = [raw(number: 11, pid: 10, name: "Chrome", title: "Inbox")]
        let apps = root.resolvedChildren()
        XCTAssertEqual(apps.map(\.action), [.expand])
        XCTAssertEqual(apps[0].resolvedChildren().map(\.title), ["Inbox"])
    }

    // MARK: - Toggle ON (default): append the other running apps after the curated block

    func testShowOthersAppendsNonCuratedRunningAppsAfterTheCuratedBlock() {
        let source = stub([
            raw(number: 11, pid: 10, name: "Chrome"),
            raw(number: 21, pid: 20, name: "Ghostty"),    // running, not curated
            raw(number: 31, pid: 30, name: "Mail")        // running, not curated
        ])
        let menu = MyAppsMenu(
            enumerator: makeEnumerator(source),
            curatedApps: { [CuratedApp(bundleIdentifier: "com.google.Chrome", name: "Chrome")] },
            showOtherRunningApps: { true },
            keepCuratedOrder: { true },
            runningPID: { $0 == "com.google.Chrome" ? 10 : nil }
        )

        let apps = menu.makeRoot().resolvedChildren()
        XCTAssertEqual(apps.map(\.title), ["Chrome", "Ghostty", "Mail"],
                       "curated Chrome leads; the other running apps follow in enumeration order")
        // The appended apps are the raw wheel's expand nodes — a running pid, no bundle id.
        XCTAssertEqual(apps[1].action, .expand)
        XCTAssertEqual(apps[1].representedApp, AppID(pid: 20))
        XCTAssertNil(apps[1].bundleIdentifier)
        XCTAssertEqual(apps[2].representedApp, AppID(pid: 30))
    }

    func testCuratedRunningAppIsNotDuplicatedInTheOthersBlock() {
        let source = stub([
            raw(number: 11, pid: 10, name: "Chrome"),
            raw(number: 21, pid: 20, name: "Ghostty")
        ])
        let menu = MyAppsMenu(
            enumerator: makeEnumerator(source),
            curatedApps: { [CuratedApp(bundleIdentifier: "com.google.Chrome", name: "Chrome")] },
            showOtherRunningApps: { true },
            keepCuratedOrder: { true },
            runningPID: { $0 == "com.google.Chrome" ? 10 : nil }
        )

        let apps = menu.makeRoot().resolvedChildren()
        XCTAssertEqual(apps.map(\.title), ["Chrome", "Ghostty"])
        XCTAssertEqual(apps.filter { $0.title == "Chrome" }.count, 1,
                       "the curated, running Chrome shows once — not again in the others block")
        XCTAssertEqual(apps[0].bundleIdentifier, "com.google.Chrome",
                       "and that single Chrome is the curated node, carrying its bundle id")
    }

    func testEmptyListWithOthersOffYieldsAnEmptyRing() {
        let source = stub([raw(number: 11, pid: 10, name: "Chrome")])
        let menu = MyAppsMenu(
            enumerator: makeEnumerator(source),
            curatedApps: { [] },
            showOtherRunningApps: { false },
            keepCuratedOrder: { true },
            runningPID: { _ in nil }
        )

        XCTAssertTrue(menu.makeRoot().resolvedChildren().isEmpty,
                      "no curated apps and others off → nothing to show")
    }

    // MARK: - Fixtures

    private func makeEnumerator(_ source: StubEnumerationSource) -> WindowEnumerator {
        WindowEnumerator(source: source, appOrder: { .name }, windowOrder: { .fixed })
    }

    private func stub(_ windows: [RawWindow], selfPID: pid_t = 1) -> StubEnumerationSource {
        StubEnumerationSource(selfPID: selfPID, windows: windows)
    }

    private func raw(
        number: Int, pid: pid_t, name: String, title: String = "",
        x: CGFloat = 0, y: CGFloat = 0
    ) -> RawWindow {
        RawWindow(
            windowNumber: number, ownerPID: pid, ownerName: name, title: title,
            layer: 0, alpha: 1, bounds: CGRect(x: x, y: y, width: 800, height: 600)
        )
    }
}
