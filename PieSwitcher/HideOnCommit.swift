import Foundation

/// Optional "leave only my selection on screen" behaviour (Bringr-93j.27, Bringr-93j.49).
/// When enabled, committing a selection doesn't just surface it — it hides every OTHER app
/// (Cmd-H), so only the chosen app is left on screen. Hiding never applies within the chosen
/// app: all of its windows stay visible, and a picked window is simply activated rather than
/// minimizing its siblings (Bringr-93j.49 — minimizing is slow and unpleasant):
/// - picking a window keeps all the app's windows and activates the chosen one;
/// - picking an app keeps all the app's windows and activates its front one.
///
/// Off by default — an opt-in setting, so unless the user turns it on a commit behaves
/// exactly as before and nothing extra is hidden. A caseless namespace for the read helper;
/// read fresh at each summon so a Preferences change applies on the next open without a
/// relaunch.
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
