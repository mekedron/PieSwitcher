import CoreGraphics
import XCTest
@testable import PieSwitcher

/// Covers the "include all apps from the Dock" Collection option (Bringr-93j.98): the wheel
/// gains every Dock app as a slice, with not-running entries becoming launch nodes that
/// commit by launching like a Dock-icon click (Bringr-93j.39 / Bringr-93j.61). A sibling of
/// `MyAppsMenuTests` so neither type's body approaches the SwiftLint `type_body_length` limit
/// — same split pattern that produced `MyAppsMenuSortingTests`.
@MainActor
final class MyAppsMenuDockSourceTests: XCTestCase {

    // MARK: - Flag off: behaviour unchanged

    func testDockAppsAreNotIncludedWhenFlagOff() {
        // Default behaviour preserved: an empty curated list with the Dock flag off still
        // falls through to the raw all-running-apps wheel — the not-running Mail must not
        // appear, even though it's in the injected Dock list.
        let source = stub([raw(number: 11, pid: 10, name: "Chrome")])
        let menu = MyAppsMenu(
            enumerator: makeEnumerator(source),
            curatedApps: { [] },
            showOtherRunningApps: { true },
            keepCuratedOrder: { true },
            includeAllDockApps: { false },
            dockApps: { [CuratedApp(bundleIdentifier: "com.apple.Mail", name: "Mail")] },
            runningPID: { _ in nil }
        )

        XCTAssertEqual(menu.makeRoot().resolvedChildren().map(\.title), ["Chrome"],
                       "with the Dock-as-source flag off, the not-running Mail must not appear")
    }

    // MARK: - Flag on: Dock apps populate the wheel

    func testDockAppsAreAppendedAsLaunchNodesWhenFlagOn() {
        // Mail and Calendar are in the Dock but neither is running; curated list is empty;
        // showOthers is off so no other-running noise — proving each Dock entry becomes its
        // own launch node, carrying the bundle id so the slice renders the on-disk icon and
        // commit launches like a Dock click (Bringr-93j.39).
        let source = stub([])
        let menu = MyAppsMenu(
            enumerator: makeEnumerator(source),
            curatedApps: { [] },
            showOtherRunningApps: { false },
            keepCuratedOrder: { true },
            includeAllDockApps: { true },
            dockApps: {
                [
                    CuratedApp(bundleIdentifier: "com.apple.Mail", name: "Mail"),
                    CuratedApp(bundleIdentifier: "com.apple.Calendar", name: "Calendar")
                ]
            },
            runningPID: { _ in nil }
        )

        let apps = menu.makeRoot().resolvedChildren()
        XCTAssertEqual(apps.map(\.title), ["Mail", "Calendar"])
        XCTAssertEqual(apps.map(\.action), [
            .launchApp(bundleIdentifier: "com.apple.Mail"),
            .launchApp(bundleIdentifier: "com.apple.Calendar")
        ])
        XCTAssertEqual(apps.map(\.bundleIdentifier), ["com.apple.Mail", "com.apple.Calendar"])
    }

    func testRunningDockAppWithWindowsBecomesExpandNode() {
        // Chrome is in the Dock and IS running with windows — so its slot is an expand node
        // with its live windows sub-wheel, not a launch node. The bundle id rides along too,
        // so the icon comes from the on-disk bundle as for curated entries.
        let source = stub([
            raw(number: 11, pid: 10, name: "Chrome", title: "Inbox"),
            raw(number: 12, pid: 10, name: "Chrome", title: "Docs")
        ])
        let menu = MyAppsMenu(
            enumerator: makeEnumerator(source),
            curatedApps: { [] },
            showOtherRunningApps: { false },
            keepCuratedOrder: { true },
            includeAllDockApps: { true },
            dockApps: { [CuratedApp(bundleIdentifier: "com.google.Chrome", name: "Chrome")] },
            runningPID: { $0 == "com.google.Chrome" ? 10 : nil }
        )

        let apps = menu.makeRoot().resolvedChildren()
        XCTAssertEqual(apps.map(\.title), ["Chrome"])
        XCTAssertEqual(apps.map(\.action), [.expand])
        XCTAssertEqual(apps[0].representedApp, AppID(pid: 10))
        XCTAssertEqual(apps[0].bundleIdentifier, "com.google.Chrome")
        XCTAssertEqual(apps[0].resolvedChildren().map(\.title), ["Inbox", "Docs"])
    }

    // MARK: - Dedup and exclusion

    func testDockAppsAreDedupedAgainstCuratedByBundleID() {
        // Chrome is BOTH curated and in the Dock. With the Dock flag on, it should only
        // appear once — the curated entry wins (it's first in the merged list), and the Dock
        // copy is dropped by bundle-id dedup. Mail is Dock-only and still appears.
        let source = stub([])
        let menu = MyAppsMenu(
            enumerator: makeEnumerator(source),
            curatedApps: { [CuratedApp(bundleIdentifier: "com.google.Chrome", name: "Chrome")] },
            showOtherRunningApps: { false },
            keepCuratedOrder: { true },
            includeAllDockApps: { true },
            dockApps: {
                [
                    CuratedApp(bundleIdentifier: "com.google.Chrome", name: "Chrome"),
                    CuratedApp(bundleIdentifier: "com.apple.Mail", name: "Mail")
                ]
            },
            runningPID: { _ in nil }
        )

        XCTAssertEqual(menu.makeRoot().resolvedChildren().map(\.title), ["Chrome", "Mail"],
                       "Chrome appears once: curated first, then the Dock-only Mail appended")
    }

    func testDockAppsHonourTheIgnoreList() {
        // An excluded Dock app must not appear, mirroring the curated path (Bringr-93j.59).
        let source = stub([])
        let menu = MyAppsMenu(
            enumerator: makeEnumerator(source),
            curatedApps: { [] },
            showOtherRunningApps: { false },
            keepCuratedOrder: { true },
            ignoreList: { AppIgnoreList(entries: ["com.apple.calendar"]) },
            includeAllDockApps: { true },
            dockApps: {
                [
                    CuratedApp(bundleIdentifier: "com.apple.Mail", name: "Mail"),
                    CuratedApp(bundleIdentifier: "com.apple.Calendar", name: "Calendar")
                ]
            },
            runningPID: { _ in nil }
        )

        XCTAssertEqual(menu.makeRoot().resolvedChildren().map(\.title), ["Mail"],
                       "Calendar's bundle id is on the ignore list, so it stays out")
    }

    func testRunningDockAppIsNotDuplicatedInTheOthersBlock() {
        // Chrome is in the Dock AND running. With showOthers on, the others block would
        // normally pick it up; the dedup-by-pid already in place should keep that from
        // duplicating it, since the Dock entry already produced an expand node for the same
        // pid.
        let source = stub([
            raw(number: 11, pid: 10, name: "Chrome"),
            raw(number: 21, pid: 20, name: "Ghostty")
        ])
        let menu = MyAppsMenu(
            enumerator: makeEnumerator(source),
            curatedApps: { [] },
            showOtherRunningApps: { true },
            keepCuratedOrder: { true },
            includeAllDockApps: { true },
            dockApps: { [CuratedApp(bundleIdentifier: "com.google.Chrome", name: "Chrome")] },
            runningPID: { $0 == "com.google.Chrome" ? 10 : nil }
        )

        let apps = menu.makeRoot().resolvedChildren()
        XCTAssertEqual(apps.map(\.title), ["Chrome", "Ghostty"])
        XCTAssertEqual(apps.filter { $0.title == "Chrome" }.count, 1,
                       "Chrome appears once — Dock-sourced expand node, not duplicated by the others block")
        XCTAssertEqual(apps[0].bundleIdentifier, "com.google.Chrome")
    }

    // MARK: - Ordering: curated leads, Dock-only follows

    func testCuratedListPrecedesAppendedDockApps() {
        // The curated block leads; Dock-only apps follow. With keepCuratedOrder ON (default)
        // both blocks stay in their natural order — curated in user order, Dock in Dock order.
        // Pin keepFinderLast OFF so the Bringr-93j.108 override doesn't displace Finder — this
        // test isolates the curated-vs-Dock-only ordering, not the Finder-last rule.
        let source = stub([])
        let menu = MyAppsMenu(
            enumerator: makeEnumerator(source),
            curatedApps: {
                [
                    CuratedApp(bundleIdentifier: "org.telegram.desktop", name: "Telegram"),
                    CuratedApp(bundleIdentifier: "com.apple.Mail", name: "Mail")
                ]
            },
            showOtherRunningApps: { false },
            keepCuratedOrder: { true },
            keepFinderLast: { false },
            includeAllDockApps: { true },
            dockApps: {
                [
                    CuratedApp(bundleIdentifier: "com.apple.finder", name: "Finder"),
                    CuratedApp(bundleIdentifier: "com.apple.Calendar", name: "Calendar")
                ]
            },
            runningPID: { _ in nil }
        )

        XCTAssertEqual(menu.makeRoot().resolvedChildren().map(\.title),
                       ["Telegram", "Mail", "Finder", "Calendar"],
                       "curated apps lead in manual order; Dock-only apps follow in Dock order")
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
