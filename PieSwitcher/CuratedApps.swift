import AppKit
import Foundation

/// One entry in the user's curated "My Apps" list (Bringr-93j.37). Keyed by bundle
/// identifier — the stable handle that survives quits, relaunches, and moves on disk
/// (unlike a pid or a window number), so a listed app can be matched, launched, or
/// icon-rendered whether or not it is running right now. The display name is cached so
/// the wheel and the Preferences editor can label the entry without a disk lookup; the
/// on-disk bundle URL and the running instance are *not* stored — they change as apps
/// move or launch/quit, so they are resolved on demand (see the helpers below).
struct CuratedApp: Codable, Equatable, Sendable, Identifiable {
    /// The app's bundle identifier (e.g. "com.apple.Safari") — the persistent key and,
    /// being unique within a list, the entry's stable identity for SwiftUI editors.
    let bundleIdentifier: String
    /// Cached human-readable name, shown without resolving the bundle from disk.
    var name: String

    var id: String { bundleIdentifier }
}

extension CuratedApp {
    /// On-disk location of the app bundle, resolved fresh from Launch Services for icon
    /// rendering (Bringr-93j.38). `nil` when the app is not installed.
    var bundleURL: URL? {
        Self.bundleURL(forBundleIdentifier: bundleIdentifier)
    }

    /// The running instance of this app, if any — the bridge from a curated entry to a
    /// live pid that `WindowEnumerator` can group windows under (Bringr-93j.41). `nil`
    /// when the app is not running; the first match is returned, as a bundle id normally
    /// has a single running instance.
    var runningApplication: NSRunningApplication? {
        Self.runningApplication(forBundleIdentifier: bundleIdentifier)
    }

    /// The process id of the running instance, if running — the handle that ties a curated
    /// entry back to `AppID`. `nil` when not running.
    var runningPID: pid_t? {
        runningApplication?.processIdentifier
    }

    /// Resolve a bare bundle id to its on-disk bundle URL. Static so callers holding only
    /// an id (e.g. an app `MenuNode`, Bringr-93j.38) share one resolution path.
    static func bundleURL(forBundleIdentifier bundleIdentifier: String) -> URL? {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier)
    }

    /// Resolve a bare bundle id to its running instance, if any.
    static func runningApplication(forBundleIdentifier bundleIdentifier: String) -> NSRunningApplication? {
        NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier).first
    }

    /// Build a curated entry from an app bundle on disk — an Open-panel pick or a
    /// Finder/Dock drop in the Preferences editor (Bringr-93j.40). Returns `nil` when
    /// the URL isn't a readable bundle carrying a bundle identifier (a plain file or a
    /// non-app folder), so the editor silently ignores junk drops. The display name is
    /// the one Finder shows for the bundle.
    init?(bundleAt url: URL) {
        guard let bundle = Bundle(url: url),
              let bundleIdentifier = bundle.bundleIdentifier else {
            return nil
        }
        self.init(bundleIdentifier: bundleIdentifier, name: Self.displayName(forBundleAt: url))
    }

    /// Finder's localized display name for a bundle on disk, with a visible ".app"
    /// extension trimmed (it shows only when the user reveals all extensions) and a
    /// fall back to the file name so the entry is never label-less.
    static func displayName(forBundleAt url: URL) -> String {
        let shown = FileManager.default.displayName(atPath: url.path)
        let trimmed = shown.hasSuffix(".app") ? String(shown.dropLast(4)) : shown
        return trimmed.isEmpty ? url.deletingPathExtension().lastPathComponent : trimmed
    }
}

/// Persistence for the ordered "My Apps" list (Bringr-93j.37). The list is the user's
/// manual ordering of `CuratedApp` entries, stored as one JSON blob under a single
/// defaults key and read fresh at each summon — mirroring `RevealStrategy.current` and
/// `AppSortOrder.current`, so an edit in Preferences takes effect on the next summon
/// without a relaunch. A caseless enum: this is a namespace for the read/write helpers,
/// never an instance.
enum CuratedApps {
    /// `UserDefaults` key backing the persisted list. Single source of truth shared by the
    /// Preferences editor and `current(from:)` so they cannot drift. The `myApps.` prefix
    /// groups it with sibling settings (the "show other running apps" and order toggles).
    static let defaultsKey = "myApps.list"

    /// The persisted list in user order, or an empty list when nothing has been saved
    /// (the first-run default — no apps are curated until the user adds some) or when the
    /// stored blob can't be decoded.
    static func current(from defaults: UserDefaults = .standard) -> [CuratedApp] {
        guard let data = defaults.data(forKey: defaultsKey),
              let apps = try? JSONDecoder().decode([CuratedApp].self, from: data) else {
            return []
        }
        return apps
    }

    /// Persist the list in the given order. A no-op if encoding fails (it cannot for these
    /// plain string fields), so a transient error never wipes the saved list.
    static func save(_ apps: [CuratedApp], to defaults: UserDefaults = .standard) {
        guard let data = try? JSONEncoder().encode(apps) else { return }
        defaults.set(data, forKey: defaultsKey)
    }

    /// `UserDefaults` key backing the "show all other running apps" toggle (Bringr-93j.42).
    /// Single source of truth shared by the Preferences `@AppStorage` and
    /// `showsOtherRunningApps(from:)`, so the two cannot drift.
    static let showOtherRunningAppsDefaultsKey = "myApps.showOtherRunningApps"

    /// Default for the toggle: ON. With it on, an empty list reproduces the full
    /// all-running-apps wheel, so a user who has curated nothing sees no regression.
    static let showOtherRunningAppsDefault = true

    /// Whether the wheel appends the remaining running apps — those with a window on the
    /// summon screen and not already curated — after the pinned block. Read fresh at each
    /// summon, so a Preferences change applies on the next open without a relaunch. Falls
    /// back to the ON default when unset: `bool(forKey:)` alone returns `false` for an absent
    /// key, which would silently flip the intended default, so the unset case is checked
    /// explicitly (mirroring `RadialAppearance.skipSingleWindowLevel`).
    static func showsOtherRunningApps(from defaults: UserDefaults = .standard) -> Bool {
        guard defaults.object(forKey: showOtherRunningAppsDefaultsKey) != nil else {
            return showOtherRunningAppsDefault
        }
        return defaults.bool(forKey: showOtherRunningAppsDefaultsKey)
    }

    /// `UserDefaults` key backing the "do not sort my custom list" checkbox (Bringr-93j.43).
    /// Single source of truth shared by the Preferences `@AppStorage` and
    /// `keepsCuratedOrder(from:)`, so the two cannot drift.
    static let keepCuratedOrderDefaultsKey = "myApps.doNotSort"

    /// Default for the checkbox: ON — the curated apps keep the manual order the user
    /// arranged in the editor, regardless of the active `AppSortOrder`. This matches the
    /// behavior before the checkbox existed (the curated block was always in manual order),
    /// so an existing user sees no reordering.
    static let keepCuratedOrderDefault = true

    /// Whether the curated apps keep their manual order regardless of the active
    /// `AppSortOrder` (Bringr-93j.43). When true (the default), only the appended other
    /// running apps are sorted; when false, the Apps sort order may reorder the curated
    /// block too. Read fresh at each summon, so a Preferences change applies on the next
    /// open without a relaunch. Falls back to the ON default when unset — `bool(forKey:)`
    /// alone returns `false` for an absent key, which would silently flip the intended
    /// default, so the unset case is checked explicitly (mirroring `showsOtherRunningApps`).
    static func keepsCuratedOrder(from defaults: UserDefaults = .standard) -> Bool {
        guard defaults.object(forKey: keepCuratedOrderDefaultsKey) != nil else {
            return keepCuratedOrderDefault
        }
        return defaults.bool(forKey: keepCuratedOrderDefaultsKey)
    }

    /// Merge bundles picked or dropped into the editor (Bringr-93j.40) onto an existing
    /// list, appending in drop order only those whose bundle id isn't already listed — so
    /// re-adding an app is a no-op and the user's manual order is preserved. URLs that
    /// don't resolve to a bundle with an id are skipped, as is a duplicate within one drop.
    static func adding(bundlesAt urls: [URL], to existing: [CuratedApp]) -> [CuratedApp] {
        var result = existing
        var seen = Set(existing.map(\.bundleIdentifier))
        for url in urls {
            guard let app = CuratedApp(bundleAt: url), seen.insert(app.bundleIdentifier).inserted else {
                continue
            }
            result.append(app)
        }
        return result
    }
}
