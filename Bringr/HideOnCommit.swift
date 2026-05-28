import Foundation

/// Optional "leave only my selection on screen" behaviour (Bringr-93j.27). When enabled,
/// committing a selection doesn't just surface it — it sweeps every other app and window
/// off the screen so only the chosen one remains:
/// - picking a window leaves only that window (its app's other windows minimize, every
///   other app hides);
/// - picking an app leaves only that app's front window (the same sweep, scoped to it);
/// so the screen is reduced to exactly the selection.
///
/// Off by default — an opt-in setting, so unless the user turns it on a commit behaves
/// exactly as before and nothing extra is hidden. A caseless namespace for the read
/// helper, mirroring `CursorLock`; read fresh at each summon so a Preferences change
/// applies on the next open without a relaunch.
enum HideOnCommit {
    /// `UserDefaults` key backing the toggle. Single source of truth shared by the
    /// Preferences `@AppStorage` and `isEnabled(from:)` so the two cannot drift.
    static let defaultsKey = "hideOnCommit"

    /// Default: OFF. Because the default is false, `bool(forKey:)` — which returns `false`
    /// for an absent key — already yields the intended default, so no explicit unset check
    /// is needed (unlike the true-default toggles in `CuratedApps`/`RadialAppearance`).
    static let `default` = false

    /// Whether "leave only my selection on screen" is enabled. Read fresh at each summon.
    static func isEnabled(from defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: defaultsKey)
    }
}
