import Foundation

/// How the top-level apps ring is ordered (Bringr-93j.34). Persisted and chosen in
/// Preferences; read fresh by `WindowEnumerator` at each summon (like `RevealStrategy`
/// and `RadialAppearance`), so a change takes effect on the next summon without a
/// relaunch.
///
/// Both orders come straight from what macOS already reports — the Dock's left-to-right
/// order and the app name — so nothing about recency is tracked or remembered across
/// summons.
enum AppSortOrder: String, CaseIterable, Sendable {
    /// A stable spot per app that doesn't reshuffle as you switch: apps sorted by name
    /// (A → Z), so each keeps the same position in the wheel from one summon to the next.
    case name
    /// Match the Dock: apps ordered by their left-to-right position in the Dock, so the
    /// wheel mirrors the Dock you already know (Bringr-93j.55). Finder, pinned to the
    /// Dock's immovable first slot, leads — unless "Keep Finder last" (`DockOrder`) sends it
    /// to the end instead. Apps running but not pinned trail the pinned block. The order
    /// comes straight from the Dock's own preferences (`DockOrder.current`), so nothing
    /// about Dock position is tracked or remembered by PieSwitcher.
    case dockPosition

    /// Dock position is the default: the wheel mirrors the Dock the user already knows.
    static let `default`: AppSortOrder = .dockPosition

    /// `UserDefaults` key backing the persisted choice. Single source of truth shared
    /// by the Preferences `@AppStorage` and `current(from:)` so they cannot drift.
    static let defaultsKey = "sortOrder.apps"

    /// Human-readable name for the Preferences picker.
    var displayName: String {
        switch self {
        case .name: return "By name (A → Z)"
        case .dockPosition: return "By Dock position"
        }
    }

    /// One-line explanation shown under the Preferences picker.
    var detail: String {
        switch self {
        case .name:
            return "Sort apps alphabetically, so each keeps a fixed spot in the wheel."
        case .dockPosition:
            return "Order apps to match their position in the Dock, from the top clockwise."
        }
    }

    /// The persisted order, falling back to `.default` when unset or unrecognized.
    static func current(from defaults: UserDefaults = .standard) -> AppSortOrder {
        guard let raw = defaults.string(forKey: defaultsKey),
              let order = AppSortOrder(rawValue: raw) else {
            return .default
        }
        return order
    }
}

/// How an app's windows are ordered in the second-level sub-wheel (Bringr-93j.34).
/// One fixed order — by creation-ordered window number — so a window's position never
/// jumps between summons. Persisted (kept for forward compatibility, see `WindowEnumerator`),
/// but for now the only available choice.
enum WindowSortOrder: String, CaseIterable, Sendable {
    /// A fixed position per window: ascending window number, which macOS assigns in
    /// creation order, so the window opened first stays first and positions never jump.
    case fixed

    /// Fixed position is the only available windows sort (Bringr-93j.90).
    static let `default`: WindowSortOrder = .fixed

    /// `UserDefaults` key backing the persisted choice.
    static let defaultsKey = "sortOrder.windows"

    /// Human-readable name for the Preferences picker.
    var displayName: String {
        switch self {
        case .fixed: return "Fixed position"
        }
    }

    /// One-line explanation shown under the Preferences picker.
    var detail: String {
        switch self {
        case .fixed:
            return "Keep each window in a fixed spot by age — the one opened first stays first."
        }
    }

    /// The persisted order, falling back to `.default` when unset or unrecognized.
    static func current(from defaults: UserDefaults = .standard) -> WindowSortOrder {
        guard let raw = defaults.string(forKey: defaultsKey),
              let order = WindowSortOrder(rawValue: raw) else {
            return .default
        }
        return order
    }
}

/// The Dock's left-to-right app order — the data behind the `.dockPosition` app sort
/// (Bringr-93j.55) — plus the "Keep Finder last" toggle that modifies it. The order is
/// read live from the Dock's own preferences at each summon (like every other setting),
/// and the toggle is persisted here since it only ever reshapes this order.
enum DockOrder {
    /// Finder's bundle id. The Dock pins Finder to its first slot — it can't be moved or
    /// removed — so Finder leads the Dock order unless "Keep Finder last" sends it to the end.
    static let finderBundleID = "com.apple.finder"

    /// `UserDefaults` key for the "Keep Finder last" toggle. Only meaningful when the app
    /// sort order is `.dockPosition`; Preferences shows the checkbox only then.
    static let keepFinderLastKey = "sortOrder.apps.keepFinderLast"

    /// Default for "Keep Finder last": on (Bringr-93j.93), so Finder is sent to the end of
    /// the wheel rather than monopolising the always-first 12-o'clock slot it would otherwise
    /// hold by virtue of its pinned-first Dock position.
    static let keepFinderLastDefault = true

    /// The persisted "Keep Finder last" flag, falling back to the default when unset.
    static func keepsFinderLast(from defaults: UserDefaults = .standard) -> Bool {
        guard defaults.object(forKey: keepFinderLastKey) != nil else { return keepFinderLastDefault }
        return defaults.bool(forKey: keepFinderLastKey)
    }

    /// The Dock's app order as bundle identifiers, left to right: Finder first (its pinned,
    /// immovable first slot), then the Dock's persistent (pinned) apps in order. Read live
    /// from the `com.apple.dock` `persistent-apps` preference — the same data the Dock lays
    /// itself out from — so nothing about Dock order is tracked by PieSwitcher. Falls back to just
    /// `[finderBundleID]` if those prefs can't be read (every other app then trails as "not
    /// pinned", a harmless degradation). This is the untestable live shell; the pure ordering
    /// in `sorted(_:bundleID:dockOrder:keepFinderLast:)` is unit-tested with injected orders.
    static func current() -> [String] {
        let pinned = UserDefaults(suiteName: "com.apple.dock")?
            .array(forKey: "persistent-apps") as? [[String: Any]] ?? []
        let pinnedIDs = pinned.compactMap { entry in
            (entry["tile-data"] as? [String: Any])?["bundle-identifier"] as? String
        }
        return [finderBundleID] + pinnedIDs
    }

    /// The Dock's apps as `CuratedApp` entries — bundle id from `current()` plus the on-disk
    /// display name (Bringr-93j.98). The shape `MyAppsMenu` already understands, so the
    /// "include all Dock apps" option reuses the same launch/expand logic the curated list
    /// rides on. Apps whose bundle id no longer resolves on disk (uninstalled but still
    /// pinned) are skipped — a launchable entry needs a real on-disk URL. The untestable
    /// live shell of `current()` plus a Launch Services lookup; tests inject fixed
    /// `[CuratedApp]` via `MyAppsMenu`'s `dockApps` closure.
    static func currentApps() -> [CuratedApp] {
        current().compactMap { bundleID in
            guard let url = CuratedApp.bundleURL(forBundleIdentifier: bundleID) else { return nil }
            return CuratedApp(
                bundleIdentifier: bundleID,
                name: CuratedApp.displayName(forBundleAt: url)
            )
        }
    }

    /// Sort `items` to match the Dock order. Each item resolves to a bundle id via `bundleID`;
    /// items whose id is in `dockOrder` sort by that position, and items not in the Dock
    /// (running but not pinned) trail at the end in their original relative order — a stable
    /// sort, so equal ranks keep their incoming arrangement. `keepFinderLast` overrides
    /// Finder's natural first slot, sending it to the very end (after even the unpinned apps),
    /// for users who don't want the always-first Finder tile hogging twelve o'clock. Pure, so
    /// it's unit-tested directly; `WindowEnumerator` and `MyAppsMenu` feed it the live order.
    static func sorted<Item>(
        _ items: [Item],
        bundleID: (Item) -> String?,
        dockOrder: [String],
        keepFinderLast: Bool
    ) -> [Item] {
        let rankByID = Dictionary(
            dockOrder.enumerated().map { ($0.element, $0.offset) },
            uniquingKeysWith: { first, _ in first }
        )
        func rank(_ item: Item) -> Int {
            guard let id = bundleID(item) else { return notPinnedRank }
            if keepFinderLast && id == finderBundleID { return finderLastRank }
            return rankByID[id] ?? notPinnedRank
        }
        return items.enumerated().sorted { lhs, rhs in
            let lhsRank = rank(lhs.element)
            let rhsRank = rank(rhs.element)
            return lhsRank == rhsRank ? lhs.offset < rhs.offset : lhsRank < rhsRank
        }.map(\.element)
    }

    /// Apps not pinned to the Dock trail after the pinned block...
    private static let notPinnedRank = Int.max - 1
    /// ...and Finder, when "Keep Finder last" is on, goes after even those.
    private static let finderLastRank = Int.max
}
