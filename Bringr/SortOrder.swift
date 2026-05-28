import Foundation

/// How the top-level apps ring is ordered (Bringr-93j.34). Persisted and chosen in
/// Preferences; read fresh by `WindowEnumerator` at each summon (like `RevealStrategy`
/// and `RadialAppearance`), so a change takes effect on the next summon without a
/// relaunch.
///
/// Both orders come straight from what macOS already reports — the on-screen window
/// z-order and the app name — so nothing about recency is tracked or remembered
/// across summons (the explicit "don't fake it with our own tracking" constraint).
enum AppSortOrder: String, CaseIterable, Sendable {
    /// Most-recently-used first: apps in the front-to-back order macOS stacks their
    /// windows in, the same sequence ⌘-Tab cycles through. The frontmost app lands at
    /// twelve o'clock and the rest follow clockwise. This is the closest match to
    /// ⌘-Tab the public APIs expose without tracking activations ourselves — there is
    /// no public API for the literal switcher order, and window z-order is what
    /// `WindowEnumerator` already groups by.
    case recentlyUsed
    /// A stable spot per app that doesn't reshuffle as you switch: apps sorted by name
    /// (A → Z), so each keeps the same position in the wheel from one summon to the next.
    case name

    /// Recently-used (⌘-Tab order) is the default: a window switcher's whole point is
    /// jumping back to where you just were, so the most recent app should lead.
    static let `default`: AppSortOrder = .recentlyUsed

    /// `UserDefaults` key backing the persisted choice. Single source of truth shared
    /// by the Preferences `@AppStorage` and `current(from:)` so they cannot drift.
    static let defaultsKey = "sortOrder.apps"

    /// Human-readable name for the Preferences picker.
    var displayName: String {
        switch self {
        case .recentlyUsed: return "Recently used (⌘-Tab order)"
        case .name: return "By name (A → Z)"
        }
    }

    /// One-line explanation shown under the Preferences picker.
    var detail: String {
        switch self {
        case .recentlyUsed:
            return "Order apps the way ⌘-Tab does — most recently used first, from the top clockwise."
        case .name:
            return "Sort apps alphabetically, so each keeps a fixed spot in the wheel."
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
/// Persisted and read fresh at each summon, mirroring `AppSortOrder`. Both orders come
/// from what macOS reports — the window z-order and the stable window number — so
/// nothing about per-window usage is tracked ourselves.
enum WindowSortOrder: String, CaseIterable, Sendable {
    /// Most-recently-used first: the app's windows in their front-to-back order, so the
    /// window used last leads.
    case recentlyUsed
    /// A fixed position per window: ascending window number, which macOS assigns in
    /// creation order, so the window opened first stays first and positions never jump.
    case fixed

    /// Recently-used is the default, matching the front-to-back order the sub-wheel has
    /// always shown.
    static let `default`: WindowSortOrder = .recentlyUsed

    /// `UserDefaults` key backing the persisted choice.
    static let defaultsKey = "sortOrder.windows"

    /// Human-readable name for the Preferences picker.
    var displayName: String {
        switch self {
        case .recentlyUsed: return "Recently used"
        case .fixed: return "Fixed position"
        }
    }

    /// One-line explanation shown under the Preferences picker.
    var detail: String {
        switch self {
        case .recentlyUsed:
            return "Order each app's windows front-to-back, most recently used first."
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
