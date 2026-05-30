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
    /// Whether to also gather currently-minimized windows (Bringr-93j.50). Off → minimized
    /// windows are left out, the prior behaviour. `.optionOnScreenOnly` already drops them,
    /// so turning this on widens the underlying query (see `WindowEnumerator`).
    let includeMinimized: Bool
    /// Whether to also gather windows of hidden apps — Cmd-H'd, including those PieSwitcher's own
    /// "hide everything else" hid (Bringr-93j.50). Off → such windows are left out, the prior
    /// behaviour. Like `includeMinimized`, turning it on widens the query.
    let includeHidden: Bool
    /// Whether on-screen windows must be validated as real, focusable windows before being
    /// collected (Bringr-93j.60). Off (the default) trusts every on-screen record, because the
    /// screen filter culls the off-display phantom backing surfaces Chrome/Ghostty keep. On —
    /// set exactly when `screenBounds` is `nil` (spanning all displays) — there is no screen
    /// filter to fall back on, so an on-screen record is kept only if it is on a managed Space;
    /// a phantom surface is not. Without this, "all screens" surfaced those phantoms in the wheel.
    let validatesOnscreen: Bool

    init(
        screenBounds: CGRect?,
        allSpaces: Bool,
        includeMinimized: Bool = false,
        includeHidden: Bool = false,
        validatesOnscreen: Bool = false
    ) {
        self.screenBounds = screenBounds
        self.allSpaces = allSpaces
        self.includeMinimized = includeMinimized
        self.includeHidden = includeHidden
        self.validatesOnscreen = validatesOnscreen
    }

    /// Every display, current Space only — the unscoped basis (the old `onScreen: nil`,
    /// `.optionOnScreenOnly` behaviour). The fallback when no display resolves, and what
    /// the menu-bar and test entry points use.
    static let allScreensCurrentSpace = CollectionScope(screenBounds: nil, allSpaces: false)
}

/// The persisted "where to collect from" settings: one pair of toggles per menu level
/// (Bringr-93j.48) — whether the apps ring and each app's windows sub-wheel span all
/// displays / all Spaces, or stay on the display and Space the menu was summoned on —
/// plus two global flags (Bringr-93j.50) for whether to also gather minimized and hidden
/// windows at both levels.
///
/// Mirrors `RadialAppearance` — a pure value type bundling several `UserDefaults`-backed
/// flags behind one `current(from:)`, read fresh at each summon so a Preferences change
/// applies on the next open without a relaunch. The four ON-by-default flags
/// (Bringr-93j.93) each check `object(forKey:) != nil` explicitly so an absent key reads
/// as ON, not as the implicit `false` `bool(forKey:)` would otherwise return.
struct CollectionPreferences: Equatable, Sendable {
    /// The first-level apps ring: span every display? every Space?
    let appsAllScreens: Bool
    let appsAllSpaces: Bool
    /// The second-level windows sub-wheel: span every display? every Space?
    let windowsAllScreens: Bool
    let windowsAllSpaces: Bool
    /// Global across both levels (Bringr-93j.50), unlike the per-level screen/Space flags
    /// above: whether collection also gathers minimized windows and windows of hidden apps.
    /// Both default `true` (Bringr-93j.93). Resolved into both `appsScope` and
    /// `windowsScope`, so the apps ring and windows sub-wheel honour them alike.
    let includeMinimized: Bool
    let includeHidden: Bool
    /// Whether the wheel additionally includes every app in the user's Dock, even those that
    /// aren't currently running and have no windows (Bringr-93j.98). Off by default — Docks
    /// often hold many apps, so the wheel can fill up; turning it on makes every Dock app a
    /// pickable slice, with not-running apps launching like a Dock click on commit
    /// (Bringr-93j.39). Independent of `MyApps` and the existing Dock-only filter
    /// (Bringr-93j.51) — this is about the *source* of apps, not the order or ignore list.
    /// Read by `MyAppsMenu` via `CollectionPreferences.includesAllDockApps` rather than
    /// resolving into a `CollectionScope`, since it isn't a per-level screen/Space decision.
    let includeAllDockApps: Bool

    /// `UserDefaults` keys — the single source of truth shared by the Preferences
    /// `@AppStorage` bindings and `current(from:)` so the two cannot drift.
    static let appsAllScreensDefaultsKey = "collection.apps.allScreens"
    static let appsAllSpacesDefaultsKey = "collection.apps.allSpaces"
    static let windowsAllScreensDefaultsKey = "collection.windows.allScreens"
    static let windowsAllSpacesDefaultsKey = "collection.windows.allSpaces"
    static let includeMinimizedDefaultsKey = "collection.includeMinimized"
    static let includeHiddenDefaultsKey = "collection.includeHidden"
    static let includeAllDockAppsDefaultsKey = "collection.includeAllDockApps"

    /// Per-flag defaults (Bringr-93j.93). The screen / minimized / hidden trio ships ON so
    /// the wheel collects the broadest set out of the box; the Spaces flags ship OFF to
    /// keep collection on the current Space, the safe (non-phantom-prone) behaviour.
    static let appsAllScreensDefault = true
    static let appsAllSpacesDefault = false
    static let windowsAllScreensDefault = true
    static let windowsAllSpacesDefault = false
    static let includeMinimizedDefault = true
    static let includeHiddenDefault = true
    /// Off by default (Bringr-93j.98) — Docks often hold many apps, so opting in is explicit.
    static let includeAllDockAppsDefault = false

    init(
        appsAllScreens: Bool,
        appsAllSpaces: Bool,
        windowsAllScreens: Bool,
        windowsAllSpaces: Bool,
        includeMinimized: Bool = false,
        includeHidden: Bool = false,
        includeAllDockApps: Bool = false
    ) {
        self.appsAllScreens = appsAllScreens
        self.appsAllSpaces = appsAllSpaces
        self.windowsAllScreens = windowsAllScreens
        self.windowsAllSpaces = windowsAllSpaces
        self.includeMinimized = includeMinimized
        self.includeHidden = includeHidden
        self.includeAllDockApps = includeAllDockApps
    }

    /// The apps ring's scope, resolved against the summon `display`: that display unless
    /// "all screens" is on, when it becomes `nil` (span every display). The global
    /// minimized/hidden flags ride along unchanged (Bringr-93j.50).
    func appsScope(forDisplay display: CGRect?) -> CollectionScope {
        CollectionScope(
            screenBounds: appsAllScreens ? nil : display, allSpaces: appsAllSpaces,
            includeMinimized: includeMinimized, includeHidden: includeHidden,
            // Spanning all screens removes the screen filter that otherwise culls off-display
            // phantoms, so on-screen records must be validated as real windows (Bringr-93j.60).
            validatesOnscreen: appsAllScreens
        )
    }

    /// The windows sub-wheel's scope, resolved against the summon `display`, mirroring
    /// `appsScope(forDisplay:)` so the two levels can be scoped independently — while the
    /// global minimized/hidden flags apply identically to both.
    func windowsScope(forDisplay display: CGRect?) -> CollectionScope {
        CollectionScope(
            screenBounds: windowsAllScreens ? nil : display, allSpaces: windowsAllSpaces,
            includeMinimized: includeMinimized, includeHidden: includeHidden,
            validatesOnscreen: windowsAllScreens
        )
    }

    /// The persisted preferences, each flag read fresh and falling back to its per-flag
    /// default (Bringr-93j.93). The four ON-default flags need the explicit unset check
    /// because `bool(forKey:)` returns `false` for an absent key.
    static func current(from defaults: UserDefaults = .standard) -> CollectionPreferences {
        CollectionPreferences(
            appsAllScreens: read(appsAllScreensDefaultsKey, default: appsAllScreensDefault, from: defaults),
            appsAllSpaces: read(appsAllSpacesDefaultsKey, default: appsAllSpacesDefault, from: defaults),
            windowsAllScreens: read(windowsAllScreensDefaultsKey, default: windowsAllScreensDefault, from: defaults),
            windowsAllSpaces: read(windowsAllSpacesDefaultsKey, default: windowsAllSpacesDefault, from: defaults),
            includeMinimized: read(includeMinimizedDefaultsKey, default: includeMinimizedDefault, from: defaults),
            includeHidden: read(includeHiddenDefaultsKey, default: includeHiddenDefault, from: defaults),
            includeAllDockApps: read(
                includeAllDockAppsDefaultsKey, default: includeAllDockAppsDefault, from: defaults
            )
        )
    }

    /// Standalone read of the Dock-as-source flag (Bringr-93j.98), so `MyAppsMenu` can inject
    /// it as a one-line closure without resolving every other collection key on every summon.
    /// Mirrors `CuratedApps.showsOtherRunningApps` / `keepsCuratedOrder` — same shape, same
    /// unset-vs-stored handling.
    static func includesAllDockApps(from defaults: UserDefaults = .standard) -> Bool {
        read(includeAllDockAppsDefaultsKey, default: includeAllDockAppsDefault, from: defaults)
    }

    /// Read a `Bool` key, falling back to the supplied default when the key is unset.
    /// `bool(forKey:)` alone returns `false` for an absent key, which silently flips any
    /// ON default; the presence check guards that, mirroring `MouseChordActivation`.
    private static func read(_ key: String, default fallback: Bool, from defaults: UserDefaults) -> Bool {
        guard defaults.object(forKey: key) != nil else { return fallback }
        return defaults.bool(forKey: key)
    }
}
