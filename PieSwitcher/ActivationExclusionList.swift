import AppKit
import Foundation

/// The user's activation-exclusion list (Bringr-93j.109): apps that must NOT trigger
/// the pie menu while they are the frontmost (active) app. The activation input —
/// left+right click, middle-button hold, modifier hold — passes through to the
/// frontmost app untouched, so e.g. a game's held middle button keeps panning the
/// camera instead of summoning the wheel.
///
/// Distinct from `AppIgnoreList`: the ignore list hides apps from the wheel's
/// CONTENTS; this list disables the wheel's ACTIVATION altogether while one of the
/// listed apps owns focus. Persisted as a JSON `[CuratedApp]` (same shape as the
/// curated "My Apps" list, so the editor reuses the bundle-id / icon / display-name
/// resolution helpers) under `defaultsKey` and read fresh by the activation monitors
/// on every event, so an edit in Preferences applies on the next press without a
/// relaunch.
struct ActivationExclusionList: Equatable, Sendable {
    /// The excluded apps in the order the user added them — a list, not a set, so the
    /// Preferences editor shows a stable order the user can scan and edit visually.
    let apps: [CuratedApp]

    /// `UserDefaults` key backing the persisted list. The `activation.` prefix groups it
    /// with the other activation settings (`activation.mouse.*`, `activation.keyboard.*`).
    static let defaultsKey = "activation.exclusionList"

    init(apps: [CuratedApp]) {
        self.apps = apps
    }

    /// Whether anything is excluded — lets callers skip the per-event frontmost lookup
    /// on the common empty-list path (the default).
    var isEmpty: Bool { apps.isEmpty }

    /// The persisted list, or an empty list when nothing has been saved (the first-run
    /// default — nothing excluded) or when the stored blob can't be decoded. Mirrors
    /// `CuratedApps.current` so the activation monitors and the Preferences editor share
    /// one read path.
    static func current(from defaults: UserDefaults = .standard) -> ActivationExclusionList {
        guard let data = defaults.data(forKey: defaultsKey),
              let apps = try? JSONDecoder().decode([CuratedApp].self, from: data) else {
            return ActivationExclusionList(apps: [])
        }
        return ActivationExclusionList(apps: apps)
    }

    /// Persist the list. A no-op if encoding fails (it cannot for these plain string
    /// fields), so a transient error never wipes the saved list. Mirrors `CuratedApps.save`.
    static func save(_ apps: [CuratedApp], to defaults: UserDefaults = .standard) {
        guard let data = try? JSONEncoder().encode(apps) else { return }
        defaults.set(data, forKey: defaultsKey)
    }

    /// Whether a frontmost app with this bundle id is excluded. Matched case-insensitively
    /// on the bundle id (the stable handle); a `nil` bundle id (no frontmost app, or system
    /// UI like a menu-bar interaction) is never excluded so the wheel still works in those
    /// gaps — matching the current build's behaviour.
    func excludes(bundleID: String?) -> Bool {
        guard let bundleID, !apps.isEmpty else { return false }
        let lower = bundleID.lowercased()
        return apps.contains { $0.bundleIdentifier.lowercased() == lower }
    }

    /// Merge bundles picked or dropped in the Preferences editor onto an existing list,
    /// appending in drop order only those whose bundle id isn't already listed — re-adding
    /// an app is a no-op and the user's manual order is preserved. URLs that don't resolve
    /// to an app bundle are skipped, as are duplicates within one drop. Mirrors
    /// `CuratedApps.adding`.
    static func adding(bundlesAt urls: [URL], to existing: [CuratedApp]) -> [CuratedApp] {
        var result = existing
        var seen = Set(existing.map(\.bundleIdentifier))
        for url in urls {
            guard let app = CuratedApp(bundleAt: url),
                  seen.insert(app.bundleIdentifier).inserted else { continue }
            result.append(app)
        }
        return result
    }
}

extension ActivationExclusionList {
    /// Whether activation should be suppressed because the frontmost app is on the
    /// exclusion list. The empty-list short-circuit keeps the no-list-configured path
    /// (the first-run default) near-free, since the activation monitors call this on
    /// every event on the hot path. `frontmostBundleID` is taken as a parameter so the
    /// monitor's default provider can read `NSWorkspace.shared.frontmostApplication`
    /// while tests can pin a value without touching the live workspace.
    static func shouldSuppressActivation(
        frontmostBundleID: String?,
        from defaults: UserDefaults = .standard
    ) -> Bool {
        let list = ActivationExclusionList.current(from: defaults)
        guard !list.isEmpty else { return false }
        return list.excludes(bundleID: frontmostBundleID)
    }
}
