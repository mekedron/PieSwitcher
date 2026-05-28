import Foundation

/// The optional second-level cursor lock (Bringr-93j.29). When enabled, the moment the
/// cursor enters an app's windows sub-wheel the pointer is confined to that sub-wheel
/// and the arc of the app that opened it, so a stray flick can't slide onto another app
/// or out of the wheel; moving back onto the parent app arc releases the confinement and
/// the cursor moves freely again.
///
/// Off by default — an opt-in setting, so unless the user turns it on the cursor behaves
/// exactly as before. A caseless namespace for the read helper, mirroring `CuratedApps`;
/// read fresh at each summon so a Preferences change applies on the next open without a
/// relaunch.
enum CursorLock {
    /// `UserDefaults` key backing the toggle. Single source of truth shared by the
    /// Preferences `@AppStorage` and `isEnabled(from:)` so the two cannot drift.
    static let defaultsKey = "cursorLock.secondLevel"

    /// Default: OFF. Because the default is false, `bool(forKey:)` — which returns `false`
    /// for an absent key — already yields the intended default, so no explicit unset check
    /// is needed (unlike the true-default toggles in `CuratedApps`/`RadialAppearance`).
    static let `default` = false

    /// Whether the second-level cursor lock is enabled. Read fresh at each summon.
    static func isEnabled(from defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: defaultsKey)
    }
}
