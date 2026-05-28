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
    /// Raise the target to the front and darken everything else with a spotlight
    /// overlay that cuts the target out, so it stays bright while its surroundings
    /// recede.
    case dimOthers

    /// Hide-others is the default: it matches the described v1 experience — only the
    /// target stays visible ("everything else disappears") — which gives the clearest
    /// visual confirmation while drilling through the wheel.
    static let `default`: RevealStrategy = .hideOthers

    /// `UserDefaults` key backing the persisted choice. Single source of truth shared
    /// by the Preferences `@AppStorage` and `current(from:)` so they cannot drift.
    static let defaultsKey = "revealStrategy"

    /// Human-readable name for the Preferences picker.
    var displayName: String {
        switch self {
        case .raiseToFront: return "Raise to front"
        case .hideOthers: return "Hide others"
        case .dimOthers: return "Dim others"
        }
    }

    /// One-line explanation shown under the Preferences picker.
    var detail: String {
        switch self {
        case .raiseToFront:
            return "Bring the hovered app or window to the front, leaving everything else in place."
        case .hideOthers:
            return "Hide everything except the hovered app or window, so only it remains on screen."
        case .dimOthers:
            return "Keep the hovered app or window bright and dim everything else behind a spotlight."
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
