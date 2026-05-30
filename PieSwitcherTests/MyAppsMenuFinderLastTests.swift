import CoreGraphics
import XCTest
@testable import PieSwitcher

/// Covers the "Keep Finder last" override (Bringr-93j.108) on the `MyAppsMenu` path: when the
/// toggle is on, Finder must land at the absolute end of the wheel regardless of how it was
/// collected — manually curated, Dock-included, or both. A sibling of `MyAppsMenuDockSourceTests`
/// so neither type's body approaches the SwiftLint `type_body_length` limit (same split pattern
/// `MyAppsMenuSortingTests` already follows).
@MainActor
final class MyAppsMenuFinderLastTests: XCTestCase {

    func testKeepFinderLastSendsDockIncludedFinderToTheEndOfTheWheel() {
        // With "Include all apps from the Dock" on, Finder is part of the curated block (it leads
        // the Dock's natural order). "Keep Finder last" must still pin Finder to the end of the
        // wheel — the bug was that the toggle silently no-op'd in this configuration and Finder
        // landed at the start. keepCuratedOrder is the default ON, so the manual / Dock order is
        // preserved otherwise. Append `Ghostty` (a running, non-curated app) to prove Finder ends
        // up after even the others block, exactly matching the WindowEnumerator's behaviour for
        // the fallback path.
        let source = stub([
            raw(number: 11, pid: 10, name: "Chrome"),
            raw(number: 21, pid: 20, name: "Ghostty")
        ])
        let menu = MyAppsMenu(
            enumerator: makeEnumerator(source),
            curatedApps: { [] },
            showOtherRunningApps: { true },
            keepCuratedOrder: { true },
            appSortOrder: { .dockPosition },
            dockOrder: { [DockOrder.finderBundleID, "com.google.Chrome"] },
            keepFinderLast: { true },
            includeAllDockApps: { true },
            dockApps: {
                [
                    CuratedApp(bundleIdentifier: DockOrder.finderBundleID, name: "Finder"),
                    CuratedApp(bundleIdentifier: "com.google.Chrome", name: "Chrome")
                ]
            },
            runningPID: { $0 == "com.google.Chrome" ? 10 : nil }
        )

        XCTAssertEqual(menu.makeRoot().resolvedChildren().map(\.title),
                       ["Chrome", "Ghostty", "Finder"],
                       "Finder is pinned to the absolute end of the wheel, after the others block too")
    }

    func testKeepFinderLastOverridesCuratedManualPlacement() {
        // Finder is manually curated at the START of the user's My Apps list. "Keep Finder last"
        // is a stronger override — the user has explicitly asked for Finder at the end — so it
        // wins over the manual placement. keepCuratedOrder ON otherwise leaves Telegram and Mail
        // in their manual order.
        let source = stub([])
        let menu = MyAppsMenu(
            enumerator: makeEnumerator(source),
            curatedApps: {
                [
                    CuratedApp(bundleIdentifier: DockOrder.finderBundleID, name: "Finder"),
                    CuratedApp(bundleIdentifier: "org.telegram.desktop", name: "Telegram"),
                    CuratedApp(bundleIdentifier: "com.apple.Mail", name: "Mail")
                ]
            },
            showOtherRunningApps: { false },
            keepCuratedOrder: { true },
            appSortOrder: { .dockPosition },
            keepFinderLast: { true },
            includeAllDockApps: { false },
            runningPID: { _ in nil }
        )

        XCTAssertEqual(menu.makeRoot().resolvedChildren().map(\.title),
                       ["Telegram", "Mail", "Finder"],
                       "Keep Finder last overrides the user's manual placement of Finder")
    }

    func testKeepFinderLastOffLeavesFinderInItsCollectedPosition() {
        // The toggle off — Finder stays at whatever position the curated/Dock pipeline put it,
        // exactly as before. Sanity check that the new override only fires under the toggle.
        let source = stub([])
        let menu = MyAppsMenu(
            enumerator: makeEnumerator(source),
            curatedApps: { [] },
            showOtherRunningApps: { false },
            keepCuratedOrder: { true },
            appSortOrder: { .dockPosition },
            keepFinderLast: { false },
            includeAllDockApps: { true },
            dockApps: {
                [
                    CuratedApp(bundleIdentifier: DockOrder.finderBundleID, name: "Finder"),
                    CuratedApp(bundleIdentifier: "com.google.Chrome", name: "Chrome")
                ]
            },
            runningPID: { _ in nil }
        )

        XCTAssertEqual(menu.makeRoot().resolvedChildren().map(\.title),
                       ["Finder", "Chrome"],
                       "with the toggle off, Finder stays at its natural Dock-first slot")
    }

    func testKeepFinderLastOnlyAppliesUnderDockPositionOrder() {
        // The "Keep Finder last" toggle is documented as meaningful only under .dockPosition —
        // Preferences shows the checkbox only then. Under .name, the toggle is ignored even if
        // stored on. Finder still comes from the Dock-include and sits where the curated block
        // (manual order) puts it; the appended `live` is sorted by name, but Finder isn't there
        // (its pid is in `curatedPIDs`).
        let source = stub([])
        let menu = MyAppsMenu(
            enumerator: makeEnumerator(source),
            curatedApps: { [] },
            showOtherRunningApps: { false },
            keepCuratedOrder: { true },
            appSortOrder: { .name },
            keepFinderLast: { true },          // stored on, but order is .name
            includeAllDockApps: { true },
            dockApps: {
                [
                    CuratedApp(bundleIdentifier: DockOrder.finderBundleID, name: "Finder"),
                    CuratedApp(bundleIdentifier: "com.apple.Mail", name: "Mail")
                ]
            },
            runningPID: { _ in nil }
        )

        XCTAssertEqual(menu.makeRoot().resolvedChildren().map(\.title),
                       ["Finder", "Mail"],
                       "under .name, Keep Finder last is ignored — Finder stays at its Dock-first slot")
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
