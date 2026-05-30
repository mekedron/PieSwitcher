import Foundation

/// How the menu pushes the "other" apps/windows out of the way when a slice is
/// hovered (US-013). Persisted (AC4) and chosen in Preferences; read fresh at each
/// summon (like `InteractionMode` and `RadialAppearance`) so a change takes effect
/// on the next summon without a relaunch.
///
/// The strategy applies at *both* menu levels (AC2): hovering an app reveals that
/// app against the other apps (US-010), and hovering a window reveals that window
/// against its app's other windows (US-011). `WindowController` maps each case onto
/// its window-control primitives, so the navigator stays strategy-agnostic.
enum RevealStrategy: String, CaseIterable, Sendable {
    /// Bring the target to the front, leaving every other app/window where it is —
    /// the most reversible, lowest-disruption option (nothing is hidden).
    case raiseToFront
    /// Hide every other app / minimise every other window so only the target stays
    /// on screen — the strongest isolation ("everything else disappears").
    case hideOthers

    /// Raise-to-front is the default (Bringr-93j.93): the lowest-disruption choice — the
    /// hovered target comes forward while every other app/window stays where it is, so
    /// drilling through the wheel never strands anything hidden. The user can switch to
    /// `.hideOthers` for stronger isolation if they prefer the "everything else disappears"
    /// experience.
    static let `default`: RevealStrategy = .raiseToFront

    /// `UserDefaults` key backing the persisted choice. Single source of truth shared
    /// by the Preferences `@AppStorage` and `current(from:)` so they cannot drift.
    static let defaultsKey = "revealStrategy"

    /// Human-readable name for the Preferences picker.
    var displayName: String {
        switch self {
        case .raiseToFront: return "Raise to front"
        case .hideOthers: return "Hide others"
        }
    }

    /// One-line explanation shown under the Preferences picker.
    var detail: String {
        switch self {
        case .raiseToFront:
            return "Bring the hovered app or window to the front, leaving everything else in place."
        case .hideOthers:
            return "Hide everything except the hovered app or window, so only it remains on screen."
        }
    }

    /// The persisted strategy, falling back to `.default` when unset or unrecognized.
    static func current(from defaults: UserDefaults = .standard) -> RevealStrategy {
        guard let raw = defaults.string(forKey: defaultsKey),
              let strategy = RevealStrategy(rawValue: raw) else {
            return .default
        }
        return strategy
    }
}
