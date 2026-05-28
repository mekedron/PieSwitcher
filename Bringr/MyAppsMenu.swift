import CoreGraphics
import Foundation

/// The top-level wheel composed from the user's curated "My Apps" list
/// (Bringr-93j.41) — the join point of the list model (Bringr-93j.37), the
/// not-running icon (Bringr-93j.38), and the launch action (Bringr-93j.39).
///
/// For each listed app, in the user's manual order, it produces one of two nodes:
/// - running with windows on the summon screen → the same expand-to-windows node the
///   raw wheel builds (`WindowSwitcherMenu.appNode`), so hovering drills into its live
///   windows sub-wheel and committing focuses;
/// - not running, or running with no windows on this screen → a launch node carrying the
///   bundle id, so committing starts/raises the app (Bringr-93j.39) and the slice still
///   shows the on-disk icon (Bringr-93j.38).
///
/// The curated block keeps the user's manual order by default; when the "do not sort my
/// custom list" checkbox is off (Bringr-93j.43), the active `AppSortOrder` reorders the
/// curated apps too, exactly as it already orders the appended others.
///
/// When the "show all other running apps" toggle is on (the default, Bringr-93j.42), the
/// remaining running apps on the summon screen — those not already shown by a curated entry
/// — follow the pinned block as the raw wheel's plain expand-to-windows nodes. When it is
/// off, only the curated apps appear. An empty list with the toggle on falls straight through
/// to the unchanged full wheel, so a user who has curated nothing sees the current behavior.
@MainActor
struct MyAppsMenu: MenuDefinition {
    private let enumerator: WindowEnumerator
    /// The raw all-running-apps wheel, reused for the empty-list fallback.
    private let fallback: WindowSwitcherMenu
    /// The curated list, read through a closure so each summon picks up the persisted
    /// Preferences value fresh (mirroring `WindowEnumerator`'s sort-order closures); tests
    /// inject a fixed list.
    private let curatedApps: () -> [CuratedApp]
    /// Resolves a bundle id to its running instance's pid, behind a closure so the
    /// running-vs-launch decision is unit-testable without a live `NSRunningApplication`
    /// lookup; the default consults the live workspace.
    private let runningPID: (String) -> pid_t?
    /// Whether to append the other running apps after the curated block, read through a
    /// closure so each summon picks up the persisted toggle fresh (like `curatedApps`); tests
    /// inject a fixed value (Bringr-93j.42).
    private let showOtherRunningApps: () -> Bool
    /// Whether the curated block keeps the user's manual order (Bringr-93j.43). When false,
    /// the curated apps are reordered by `appSortOrder` like the appended others; read fresh
    /// per summon through a closure so a Preferences change applies without a relaunch.
    private let keepCuratedOrder: () -> Bool
    /// The active apps sort order, used only when `keepCuratedOrder` is off to reorder the
    /// curated block. Read through a closure (the live default matches the order the
    /// `WindowEnumerator` already applies to `live`, so the two agree in production); tests
    /// inject a fixed order.
    private let appSortOrder: () -> AppSortOrder

    init(
        enumerator: WindowEnumerator,
        curatedApps: @escaping () -> [CuratedApp] = { CuratedApps.current() },
        showOtherRunningApps: @escaping () -> Bool = { CuratedApps.showsOtherRunningApps() },
        keepCuratedOrder: @escaping () -> Bool = { CuratedApps.keepsCuratedOrder() },
        appSortOrder: @escaping () -> AppSortOrder = { AppSortOrder.current() },
        runningPID: @escaping (String) -> pid_t? = {
            CuratedApp.runningApplication(forBundleIdentifier: $0)?.processIdentifier
        }
    ) {
        self.enumerator = enumerator
        self.fallback = WindowSwitcherMenu(enumerator: enumerator)
        self.curatedApps = curatedApps
        self.showOtherRunningApps = showOtherRunningApps
        self.keepCuratedOrder = keepCuratedOrder
        self.appSortOrder = appSortOrder
        self.runningPID = runningPID
    }

    func makeRoot(appsScope: CollectionScope, windowsScope: CollectionScope) -> MenuNode {
        let curated = curatedApps()
        let showOthers = showOtherRunningApps()
        // Empty list + show-others (the default) → the current full wheel, unchanged (AC:
        // "an empty list reproduces the current wheel"). The general path below would build
        // the same nodes, but routing this documented case straight through the fallback keeps
        // the no-regression guarantee literal. Empty list + others-off intentionally yields an
        // empty ring — "show only the curated apps", of which there are none.
        if curated.isEmpty && showOthers {
            return fallback.makeRoot(appsScope: appsScope, windowsScope: windowsScope)
        }

        let enumerator = self.enumerator
        let runningPID = self.runningPID
        let keepCuratedOrder = self.keepCuratedOrder
        let appSortOrder = self.appSortOrder
        // The ring reads at `appsScope`; each app node carries `windowsScope` for its
        // sub-wheel, so the two levels stay independently scoped (Bringr-93j.48), matching
        // the raw wheel.
        return MenuNode(
            id: MenuNodeID("root:apps"),
            title: "Applications",
            action: .expand,
            children: .dynamic {
                // The one summon-time read, before any reveal, so it records the
                // recent-use order; hover sub-wheels re-read without recording (Bringr-93j.46).
                let live = enumerator.enumerate(
                    onScreen: appsScope.screenBounds, allSpaces: appsScope.allSpaces, recordingRecency: true
                )
                // Keep the manual order (the default), or let the active Apps sort order
                // reorder the curated block when the user turned that off (Bringr-93j.43).
                let orderedCurated = keepCuratedOrder()
                    ? curated
                    : Self.ordered(curated, live: live, runningPID: runningPID, by: appSortOrder())
                let curatedNodes = orderedCurated.map {
                    Self.node(
                        for: $0, live: live, windowsScope: windowsScope,
                        enumerator: enumerator, runningPID: runningPID
                    )
                }
                guard showOthers else { return curatedNodes }
                // Append every other running app in the apps scope — those whose pid no curated
                // entry already represents. A curated app running with windows resolves to a
                // live pid (and an expand node above), so excluding those pids avoids listing
                // it twice; a curated launch node owns no live window here, so it never
                // collides. The appended nodes are the raw wheel's app nodes (no bundle id).
                let curatedPIDs = Set(curated.compactMap { runningPID($0.bundleIdentifier) })
                let others = live
                    .filter { !curatedPIDs.contains($0.id.pid) }
                    .map { WindowSwitcherMenu.appNode($0, windowsScope: windowsScope, enumerator: enumerator) }
                return curatedNodes + others
            }
        )
    }

    /// One curated entry's node: the running-with-windows app node when its running pid
    /// owns at least one window in the apps-scoped `live` enumeration, otherwise a launch
    /// node. Resolving against `live` (already filtered to the apps scope) means an app
    /// running only outside that scope becomes a launch node here — consistent with the
    /// rest of the scoped wheel (Bringr-93j.30 / Bringr-93j.48). The matched node carries
    /// `windowsScope` for its sub-wheel.
    private static func node(
        for app: CuratedApp, live: [AppWindows], windowsScope: CollectionScope,
        enumerator: WindowEnumerator, runningPID: (String) -> pid_t?
    ) -> MenuNode {
        if let pid = runningPID(app.bundleIdentifier),
           let appWindows = live.first(where: { $0.id.pid == pid }) {
            return WindowSwitcherMenu.appNode(
                appWindows, windowsScope: windowsScope, enumerator: enumerator,
                bundleIdentifier: app.bundleIdentifier
            )
        }
        return MenuNode(
            id: MenuNodeID("launch:\(app.bundleIdentifier)"),
            title: app.name,
            action: .launchApp(bundleIdentifier: app.bundleIdentifier),
            bundleIdentifier: app.bundleIdentifier
        )
    }

    /// Reorder the curated entries by the active Apps sort order, for when the user turned
    /// the "do not sort my custom list" checkbox off (Bringr-93j.43). `.name` sorts every
    /// entry alphabetically — the only key a not-running app has. `.recentlyUsed` follows the
    /// front-to-back order the screen-scoped enumeration already imposes: each running entry
    /// takes its position in `live`, and entries with no window on this screen (not running,
    /// or running on another display — no `live` position) fall to the end. Both branches
    /// break ties by the entry's original index, so the sort is stable and equal keys keep
    /// the user's manual arrangement.
    private static func ordered(
        _ curated: [CuratedApp], live: [AppWindows], runningPID: (String) -> pid_t?,
        by order: AppSortOrder
    ) -> [CuratedApp] {
        switch order {
        case .name:
            return curated.enumerated().sorted { lhs, rhs in
                switch lhs.element.name.localizedCaseInsensitiveCompare(rhs.element.name) {
                case .orderedAscending: return true
                case .orderedDescending: return false
                case .orderedSame: return lhs.offset < rhs.offset
                }
            }.map(\.element)
        case .recentlyUsed:
            let position = Dictionary(uniqueKeysWithValues: live.enumerated().map { ($1.id.pid, $0) })
            func rank(_ app: CuratedApp) -> Int {
                guard let pid = runningPID(app.bundleIdentifier) else { return Int.max }
                return position[pid] ?? Int.max
            }
            return curated.enumerated().sorted { lhs, rhs in
                let lhsRank = rank(lhs.element)
                let rhsRank = rank(rhs.element)
                return lhsRank == rhsRank ? lhs.offset < rhs.offset : lhsRank < rhsRank
            }.map(\.element)
        }
    }
}
