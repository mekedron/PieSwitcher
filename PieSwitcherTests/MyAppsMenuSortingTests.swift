import CoreGraphics
import XCTest
@testable import PieSwitcher

/// Covers the "do not sort my custom list" checkbox (Bringr-93j.43): the curated block
/// keeps its manual order when the checkbox is on (the default), and is reordered by the
/// active `AppSortOrder` when it is off — by name for every entry, or by the live
/// front-to-back order for the running ones. A sibling of `MyAppsMenuTests` so neither
/// type's body approaches the SwiftLint `type_body_length` limit.
@MainActor
final class MyAppsMenuSortingTests: XCTestCase {

    // MARK: - Off + by name: every curated entry sorts alphabetically

    func testNotKeepingOrderSortsCuratedAppsByName() {
        // Only Chrome is running; Mail and Telegram are launch nodes — yet all three sort by
        // name, proving the not-running entries are reordered too (name is their only key).
        let source = stub([raw(number: 11, pid: 10, name: "Chrome")])
        let curated = [
            CuratedApp(bundleIdentifier: "org.telegram.desktop", name: "Telegram"),
            CuratedApp(bundleIdentifier: "com.google.Chrome", name: "Chrome"),
            CuratedApp(bundleIdentifier: "com.apple.Mail", name: "Mail")
        ]
        let menu = MyAppsMenu(
            enumerator: makeEnumerator(source, appOrder: .name),
            curatedApps: { curated },
            showOtherRunningApps: { false },
            keepCuratedOrder: { false },
            appSortOrder: { .name },
            runningPID: { $0 == "com.google.Chrome" ? 10 : nil }
        )

        XCTAssertEqual(menu.makeRoot().resolvedChildren().map(\.title), ["Chrome", "Mail", "Telegram"])
    }

    // MARK: - Off + Dock position: curated entries sort by their slot in the Dock

    func testNotKeepingOrderSortsCuratedAppsByDockPosition() {
        // None running: `.dockPosition` sorts every entry by its bundle id's Dock slot, so
        // the manual order (Telegram, Chrome, Mail) becomes the Dock order (Chrome, Mail,
        // Telegram) regardless of running state.
        let enumerator = WindowEnumerator(
            source: stub([]), appOrder: { .dockPosition }, windowOrder: { .fixed },
            dockOrder: { [] }, keepFinderLast: { false }, appBundleID: { _ in nil }
        )
        let curated = [
            CuratedApp(bundleIdentifier: "org.telegram.desktop", name: "Telegram"),
            CuratedApp(bundleIdentifier: "com.google.Chrome", name: "Chrome"),
            CuratedApp(bundleIdentifier: "com.apple.Mail", name: "Mail")
        ]
        let menu = MyAppsMenu(
            enumerator: enumerator,
            curatedApps: { curated },
            showOtherRunningApps: { false },
            keepCuratedOrder: { false },
            appSortOrder: { .dockPosition },
            dockOrder: { [DockOrder.finderBundleID, "com.google.Chrome", "com.apple.Mail", "org.telegram.desktop"] },
            keepFinderLast: { false },
            runningPID: { _ in nil }
        )

        XCTAssertEqual(menu.makeRoot().resolvedChildren().map(\.title), ["Chrome", "Mail", "Telegram"])
    }

    // MARK: - On (the default): the Apps sort order is ignored for the curated block

    func testKeepingOrderIgnoresAppSortOrder() {
        let source = stub([])
        let curated = [
            CuratedApp(bundleIdentifier: "org.telegram.desktop", name: "Telegram"),
            CuratedApp(bundleIdentifier: "com.apple.Mail", name: "Mail")
        ]
        let menu = MyAppsMenu(
            enumerator: makeEnumerator(source, appOrder: .name),
            curatedApps: { curated },
            showOtherRunningApps: { false },
            keepCuratedOrder: { true },        // checkbox on → keep manual order...
            appSortOrder: { .name },           // ...even though the order is by-name
            runningPID: { _ in nil }
        )

        XCTAssertEqual(menu.makeRoot().resolvedChildren().map(\.title), ["Telegram", "Mail"],
                       "with the checkbox on, the by-name order does not touch the curated block")
    }

    // MARK: - Off: the other running apps still trail the (now-sorted) curated block

    func testNotKeepingOrderStillAppendsOthersAfterTheSortedCuratedBlock() {
        let source = stub([
            raw(number: 11, pid: 10, name: "Chrome"),
            raw(number: 21, pid: 20, name: "Ghostty")     // running, not curated
        ])
        let curated = [
            CuratedApp(bundleIdentifier: "org.telegram.desktop", name: "Telegram"),   // not running
            CuratedApp(bundleIdentifier: "com.google.Chrome", name: "Chrome")          // running
        ]
        let menu = MyAppsMenu(
            enumerator: makeEnumerator(source, appOrder: .name),
            curatedApps: { curated },
            showOtherRunningApps: { true },
            keepCuratedOrder: { false },
            appSortOrder: { .name },
            runningPID: { $0 == "com.google.Chrome" ? 10 : nil }
        )

        XCTAssertEqual(menu.makeRoot().resolvedChildren().map(\.title), ["Chrome", "Telegram", "Ghostty"],
                       "curated block sorts by name (Chrome, Telegram); the non-curated Ghostty follows")
    }

    // MARK: - Fixtures

    private func makeEnumerator(
        _ source: StubEnumerationSource, appOrder: AppSortOrder = .dockPosition
    ) -> WindowEnumerator {
        WindowEnumerator(source: source, appOrder: { appOrder }, windowOrder: { .fixed })
    }

    private func stub(_ windows: [RawWindow], selfPID: pid_t = 1) -> StubEnumerationSource {
        StubEnumerationSource(selfPID: selfPID, windows: windows)
    }

    private func raw(number: Int, pid: pid_t, name: String, title: String = "") -> RawWindow {
        RawWindow(
            windowNumber: number, ownerPID: pid, ownerName: name, title: title,
            layer: 0, alpha: 1, bounds: CGRect(x: 0, y: 0, width: 800, height: 600)
        )
    }
}
