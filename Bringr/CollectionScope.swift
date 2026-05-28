import CoreGraphics
import Foundation

/// A resolved per-level collection scope (Bringr-93j.48): the concrete inputs the
/// `WindowEnumerator` needs to decide which windows one menu level collects.
///
/// `screenBounds` is the display to restrict to — already reduced to `nil` when the user
/// chose "all screens" (or when no display could be resolved), the whole-desktop signal
/// the enumerator's screen filter already understands. `allSpaces` spans every Space
/// (virtual desktop) versus only the current one; the enumerator forwards it to its
/// source, which is the only layer that can widen the underlying window query.
struct CollectionScope: Equatable, Sendable {
    let screenBounds: CGRect?
    let allSpaces: Bool

    /// Every display, current Space only — the unscoped basis (the old `onScreen: nil`,
    /// `.optionOnScreenOnly` behaviour). The fallback when no display resolves, and what
    /// the menu-bar and test entry points use.
    static let allScreensCurrentSpace = CollectionScope(screenBounds: nil, allSpaces: false)
}

/// The persisted "where to collect from" settings (Bringr-93j.48): one pair of toggles
/// per menu level — whether the apps ring and each app's windows sub-wheel span all
/// displays / all Spaces, or stay on the display and Space the menu was summoned on.
///
/// Mirrors `RadialAppearance` — a pure value type bundling several `UserDefaults`-backed
/// flags behind one `current(from:)`, read fresh at each summon so a Preferences change
/// applies on the next open without a relaunch. Every flag defaults to `false` (stay on
/// the current screen/Space), preserving the screen-scoped behaviour Bringr-93j.30
/// introduced; `bool(forKey:)` already yields that default for an absent key, so no
/// unset guard is needed.
struct CollectionPreferences: Equatable, Sendable {
    /// The first-level apps ring: span every display? every Space?
    let appsAllScreens: Bool
    let appsAllSpaces: Bool
    /// The second-level windows sub-wheel: span every display? every Space?
    let windowsAllScreens: Bool
    let windowsAllSpaces: Bool

    /// `UserDefaults` keys — the single source of truth shared by the Preferences
    /// `@AppStorage` bindings and `current(from:)` so the two cannot drift.
    static let appsAllScreensDefaultsKey = "collection.apps.allScreens"
    static let appsAllSpacesDefaultsKey = "collection.apps.allSpaces"
    static let windowsAllScreensDefaultsKey = "collection.windows.allScreens"
    static let windowsAllSpacesDefaultsKey = "collection.windows.allSpaces"

    /// The apps ring's scope, resolved against the summon `display`: that display unless
    /// "all screens" is on, when it becomes `nil` (span every display).
    func appsScope(forDisplay display: CGRect?) -> CollectionScope {
        CollectionScope(screenBounds: appsAllScreens ? nil : display, allSpaces: appsAllSpaces)
    }

    /// The windows sub-wheel's scope, resolved against the summon `display`, mirroring
    /// `appsScope(forDisplay:)` so the two levels can be scoped independently.
    func windowsScope(forDisplay display: CGRect?) -> CollectionScope {
        CollectionScope(screenBounds: windowsAllScreens ? nil : display, allSpaces: windowsAllSpaces)
    }

    /// The persisted preferences, each flag read fresh and defaulting to `false`
    /// (stay on the summon screen/Space).
    static func current(from defaults: UserDefaults = .standard) -> CollectionPreferences {
        CollectionPreferences(
            appsAllScreens: defaults.bool(forKey: appsAllScreensDefaultsKey),
            appsAllSpaces: defaults.bool(forKey: appsAllSpacesDefaultsKey),
            windowsAllScreens: defaults.bool(forKey: windowsAllScreensDefaultsKey),
            windowsAllSpaces: defaults.bool(forKey: windowsAllSpacesDefaultsKey)
        )
    }
}
