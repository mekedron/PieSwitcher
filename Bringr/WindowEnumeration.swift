import AppKit
import CoreGraphics
import Foundation
import os

/// A window discovered at summon time, with the metadata the wheel needs to
/// render and target it. `id` carries the stable, system-assigned window number
/// (stable for the window's lifetime), so a remembered selection (US-012) can be
/// matched across summons.
struct WindowInfo: Equatable, Sendable {
    let id: WindowID
    let title: String

    /// The application that owns this window.
    var app: AppID { id.app }
}

/// An application that currently owns at least one normal, on-screen window,
/// paired with those windows in front-to-back order.
struct AppWindows: Equatable, Sendable {
    let id: AppID
    let name: String
    let windows: [WindowInfo]
}

/// A raw window record straight from the system window list, before any filtering or
/// grouping. Plain values so `WindowEnumerator`'s logic can be exercised with fixtures and
/// never touches the live window server in tests.
///
/// `isOnscreen`/`isMinimized`/`isHidden` classify a record once a broadened (all-windows)
/// query has surfaced windows the current-Space query hides (Bringr-93j.50): `isOnscreen`
/// is the system's "on the active Space, not minimized, not hidden" flag; the other two are
/// stamped by the live source from AX / `NSRunningApplication`. They default to a plain
/// on-screen window, so the current-Space query and existing fixtures need not set them.
struct RawWindow: Equatable, Sendable {
    let windowNumber: Int
    let ownerPID: pid_t
    let ownerName: String
    let title: String
    let layer: Int
    let alpha: Double
    let bounds: CGRect
    let isOnscreen: Bool
    let isMinimized: Bool
    let isHidden: Bool
    /// Whether the owning app's AX window list contains this number — i.e. Bringr can raise/
    /// focus it (Bringr-93j.52). Off-screen records the broadened query surfaces that aren't
    /// AX-backed are phantom helper surfaces (Chrome/Ghostty keep them) you can't focus, so
    /// they're dropped. Defaults true (on-screen windows are real), so fixtures needn't set it.
    let isAXBacked: Bool
    /// Whether the owning app is an ordinary Dock app (`activationPolicy == .regular`); the
    /// switcher drops background/agent/menu-bar-only apps so broadening to all Spaces/screens
    /// no longer floods the ring with them (Bringr-93j.51). Defaults true, so the narrow query
    /// and existing fixtures need not set it.
    let isDockApp: Bool
    /// Whether the owning app is on the user's exclusion list (Bringr-93j.59) — apps that must
    /// never appear in the wheel, matched by bundle id or name in `CGWindowSource`. Defaults
    /// false (nothing excluded), so the empty-list path and existing fixtures need not set it.
    let isIgnored: Bool
    /// Whether the window server reports this window as living on a managed Space (Bringr-93j.54).
    /// This is the cross-Space "is this a real, focusable window" signal: `isAXBacked` can't
    /// keep genuine other-Space windows because `kAXWindowsAttribute` never enumerates other
    /// Spaces, so such a window is AX-absent yet Space-assigned, while a phantom helper surface
    /// is neither. Defaults false, so the narrow query and existing fixtures (which keep real
    /// off-screen windows via `isAXBacked`) need not set it; the live source stamps it only on
    /// the broadened path's off-screen records.
    let isManagedWindow: Bool

    init(
        windowNumber: Int, ownerPID: pid_t, ownerName: String, title: String,
        layer: Int, alpha: Double, bounds: CGRect,
        isOnscreen: Bool = true, isMinimized: Bool = false, isHidden: Bool = false,
        isAXBacked: Bool = true, isDockApp: Bool = true, isIgnored: Bool = false,
        isManagedWindow: Bool = false
    ) {
        self.windowNumber = windowNumber
        self.ownerPID = ownerPID
        self.ownerName = ownerName
        self.title = title
        self.layer = layer
        self.alpha = alpha
        self.bounds = bounds
        self.isOnscreen = isOnscreen
        self.isMinimized = isMinimized
        self.isHidden = isHidden
        self.isAXBacked = isAXBacked
        self.isDockApp = isDockApp
        self.isIgnored = isIgnored
        self.isManagedWindow = isManagedWindow
    }

    /// A copy carrying the per-window minimized/hidden/AX-backed/managed classification the
    /// live source resolves after the raw list is parsed (Bringr-93j.50 / Bringr-93j.52 /
    /// Bringr-93j.54). The Dock-app and ignored stamps are preserved from `self` (set when the
    /// record was first built).
    func classified(
        isMinimized: Bool, isHidden: Bool, isAXBacked: Bool, isManagedWindow: Bool
    ) -> RawWindow {
        RawWindow(
            windowNumber: windowNumber, ownerPID: ownerPID, ownerName: ownerName, title: title,
            layer: layer, alpha: alpha, bounds: bounds,
            isOnscreen: isOnscreen, isMinimized: isMinimized, isHidden: isHidden,
            isAXBacked: isAXBacked, isDockApp: isDockApp, isIgnored: isIgnored,
            isManagedWindow: isManagedWindow
        )
    }
}

/// Source of raw on-screen window records, behind a seam (mirrors
/// `WindowControlling`). The live conformer reads CoreGraphics' window list; the
/// test conformer returns fixtures, so enumeration logic runs with no live
/// system dependency and no permission prompt during tests.
@MainActor
protocol WindowEnumerationSource {
    /// Every window record, front-to-back, as the system reports them. `includingOffscreen`
    /// widens the query beyond the current Space's on-screen windows to also surface the
    /// off-Space, minimized, and hidden ones (Bringr-93j.48 / Bringr-93j.50): only the source
    /// can do this, because the public window list decides at query time which windows it
    /// covers — there is no per-record tag to post-filter on. When broadened, the source also
    /// classifies each record (`isOnscreen`/`isMinimized`/`isHidden`) so `WindowEnumerator`
    /// can keep only the categories the caller asked for; the narrow query needs no
    /// classification (every record is on-screen).
    func rawWindows(includingOffscreen: Bool) -> [RawWindow]
    /// This process's pid, so Bringr's own windows can be excluded.
    var selfPID: pid_t { get }
}

/// Reports which apps currently have on-screen windows and the windows each
/// owns, computed fresh on every summon so the wheel reflects live state.
///
/// All grouping/filtering lives here over the injectable `WindowEnumerationSource`
/// seam; the live CoreGraphics access is isolated in `CGWindowSource`.
@MainActor
final class WindowEnumerator {
    /// Smallest width/height a window may have and still count as "normal";
    /// drops the 1×1 / off-size helper surfaces some apps keep on screen.
    static let minimumWindowSize: CGFloat = 40

    private let source: WindowEnumerationSource
    /// The app/window sort orders to apply (Bringr-93j.34), read through closures so
    /// each `enumerate()` picks up the persisted Preferences value fresh at summon time
    /// (mirroring `RevealStrategy.current`), while tests inject fixed orders.
    private let appOrder: () -> AppSortOrder
    private let windowOrder: () -> WindowSortOrder
    /// The Dock's app order and the "Keep Finder last" flag for the `.dockPosition` sort
    /// (Bringr-93j.55), read through closures so each summon picks up the live Dock order and
    /// persisted toggle fresh (mirroring `appOrder`); tests inject fixed values. `appBundleID`
    /// resolves a grouped app's pid to its bundle id (the key the Dock order is in) and is
    /// only ever called on the `.dockPosition` path, so the other orders pay nothing for it.
    private let dockOrder: () -> [String]
    private let keepFinderLast: () -> Bool
    private let appBundleID: (pid_t) -> String?
    /// Bringr's own recent-use order (Bringr-93j.46). When present, the `.recentlyUsed`
    /// sort is driven by this persisted MRU instead of the live z-order, so previewing —
    /// which perturbs the live z-order — no longer reshuffles the order between summons.
    /// `nil` (the default, and every test that doesn't inject one) keeps the original
    /// live-z-order behavior, so this is purely additive.
    private let recency: RecencyTracker?
    private let log = Logger(subsystem: "com.mekedron.Bringr", category: "enumeration")

    /// Wall-clock duration of the most recent `enumerate()` call, recorded so the
    /// summon hot-path budget can be measured. `nil` until the first call. (AC4)
    private(set) var lastDuration: TimeInterval?

    /// The broadened (offscreen-inclusive) raw window list fetched once for the current
    /// summon, reused by every later broadened `enumerate()` of that summon (Bringr-93j.53).
    /// The source call behind it — the system-wide window list plus the AX classify of
    /// minimized/hidden/AX-backed state — is the entire cost of the broadened path, and it is
    /// identical for every read in one summon (apps ring and each app's windows sub-wheel);
    /// only the per-read keep-rule and screen filter differ. Without this, the sub-wheel's
    /// dynamic provider re-ran that whole classify on *every* hover, which is what made
    /// "Include minimized/hidden" lag by seconds. Dropped at the next summon's recording read
    /// (`recordingRecency: true`, the one authoritative per-summon read), so it never goes
    /// stale across summons. `nil` on the narrow (default) path, which is never cached so its
    /// per-hover live re-read — and the Bringr-93j.31 sub-wheel retry that relies on it — is
    /// preserved exactly.
    private var broadenedRawCache: [RawWindow]?

    init(
        source: WindowEnumerationSource? = nil,
        appOrder: @escaping () -> AppSortOrder = { AppSortOrder.current() },
        windowOrder: @escaping () -> WindowSortOrder = { WindowSortOrder.current() },
        dockOrder: @escaping () -> [String] = { DockOrder.current() },
        keepFinderLast: @escaping () -> Bool = { DockOrder.keepsFinderLast() },
        appBundleID: @escaping (pid_t) -> String? = {
            NSRunningApplication(processIdentifier: $0)?.bundleIdentifier
        },
        recency: RecencyTracker? = nil
    ) {
        self.source = source ?? CGWindowSource()
        self.appOrder = appOrder
        self.windowOrder = windowOrder
        self.dockOrder = dockOrder
        self.keepFinderLast = keepFinderLast
        self.appBundleID = appBundleID
        self.recency = recency
    }

    /// Apps that currently own at least one normal, on-screen window, each with
    /// its windows front-to-back. Excludes Bringr itself and apps whose only
    /// on-screen surfaces are non-normal (menu-bar items, panels, agents).
    ///
    /// `screenBounds` restricts the result to one display (Bringr-93j.30): when set,
    /// only windows living on that display are returned, so the wheel reflects just the
    /// screen the menu was summoned on; an app drops out entirely if none of its windows
    /// are on that display. `nil` spans every display (the menu-bar summon, tests).
    ///
    /// `allSpaces` spans every Space (virtual desktop) versus only the current one
    /// (Bringr-93j.48); `includeMinimized` and `includeHidden` additionally keep minimized
    /// windows and windows of hidden apps (Bringr-93j.50). All three are off by default,
    /// preserving the current-Space, visible-only behaviour every existing caller and test
    /// relies on. Any of them widens the source query to all windows (the only way to reach
    /// those the on-screen query omits) and then a per-window keep-rule drops the categories
    /// not asked for — so, e.g., turning on `allSpaces` alone no longer drags minimized
    /// windows along. Independent of `screenBounds`, which still filters geometrically after.
    ///
    /// `recordingRecency` distinguishes the one authoritative summon-time read (the apps
    /// ring) from the per-app sub-wheel re-reads that hover triggers (Bringr-93j.46). Only
    /// the summon read folds the live order into `RecencyTracker`, because only it runs
    /// *before* any reveal perturbs the z-order; the hover re-reads pass `false` so a
    /// preview never updates the recent-use order. With no `RecencyTracker` injected this
    /// flag is inert.
    func enumerate(
        onScreen screenBounds: CGRect? = nil,
        allSpaces: Bool = false,
        includeMinimized: Bool = false,
        includeHidden: Bool = false,
        recordingRecency: Bool = false
    ) -> [AppWindows] {
        let start = DispatchTime.now().uptimeNanoseconds
        // The recording read is the one authoritative per-summon read (the apps ring), and it
        // runs first, before any hover — so it marks a new summon: drop the prior summon's
        // cached broadened list so a later broadened read this summon can't serve stale windows
        // (Bringr-93j.53).
        if recordingRecency { broadenedRawCache = nil }
        // Any broadening flag needs the all-windows query (the only one that surfaces
        // off-Space / minimized / hidden windows); with none set, the cheap current-Space
        // query suffices and every record is already on-screen.
        let includingOffscreen = allSpaces || includeMinimized || includeHidden
        let normal = normalWindows(includingOffscreen: includingOffscreen)
        let collected = normal.filter {
            shouldCollect($0, allSpaces: allSpaces, includeMinimized: includeMinimized, includeHidden: includeHidden)
        }
        let onScreen = filter(collected, toScreen: screenBounds)
        let grouped = group(onScreen)
        if recordingRecency { recency?.observe(grouped) }
        let result = sorted(grouped)
        let elapsed = TimeInterval(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000_000
        lastDuration = elapsed
        log.debug("Enumerated \(result.count) app(s) in \(Int((elapsed * 1000).rounded())) ms")
        return result
    }

    /// The normal-window raw list for this read. On the broadened path the system-wide query
    /// plus AX classify is fetched once per summon and reused (Bringr-93j.53): the list is the
    /// same for the apps ring and every windows sub-wheel of one summon — only the keep-rule and
    /// screen filter that `enumerate` applies afterwards differ — so re-fetching it on every
    /// hover was pure repeated cost. The narrow (default) path is deliberately not cached, so its
    /// per-hover live re-read stays exactly as before.
    private func normalWindows(includingOffscreen: Bool) -> [RawWindow] {
        guard includingOffscreen else {
            return source.rawWindows(includingOffscreen: false).filter(isNormalWindow)
        }
        if let cached = broadenedRawCache { return cached }
        let normal = source.rawWindows(includingOffscreen: true).filter(isNormalWindow)
        broadenedRawCache = normal
        return normal
    }

    /// Whether to keep a (normal) window given the broadening flags (Bringr-93j.50). A window
    /// whose owning app is on the user's exclusion list is always dropped — the strongest rule,
    /// applied before everything else, so an excluded app never appears no matter what
    /// (Bringr-93j.59). A window whose owning app isn't an ordinary Dock app is likewise dropped
    /// — the switcher shows only Dock apps, on the narrow path too, so "all screens" alone stops
    /// surfacing background / agent / menu-bar apps (Bringr-93j.51). Otherwise an on-screen
    /// window is always kept (the default set). An off-screen record that is neither AX-backed
    /// nor on a managed Space is a phantom helper surface Bringr can't focus, so it is dropped
    /// regardless of flags: AX backing covers same-Space / minimized / hidden windows
    /// (Bringr-93j.52), and managed-Space membership covers genuine other-Space windows that AX
    /// never enumerates (Bringr-93j.54) — a phantom is neither. The rest are classified by
    /// precedence — a hidden app's windows count as hidden even if also minimized, since
    /// `includeHidden` is meant to bring a whole hidden app back — then kept only if the matching
    /// flag is on; anything left (off-Space) rides on `allSpaces`. With every flag off the source
    /// returned only on-screen windows (Dock-app / not-ignored by default), so this keeps them all
    /// unchanged.
    private func shouldCollect(
        _ window: RawWindow, allSpaces: Bool, includeMinimized: Bool, includeHidden: Bool
    ) -> Bool {
        if window.isIgnored { return false }
        if !window.isDockApp { return false }
        if window.isOnscreen { return true }
        if !window.isAXBacked && !window.isManagedWindow { return false }
        if window.isHidden { return includeHidden }
        if window.isMinimized { return includeMinimized }
        return allSpaces
    }

    private func isNormalWindow(_ window: RawWindow) -> Bool {
        window.ownerPID != source.selfPID
            && window.layer == 0
            && window.alpha > 0
            && !window.ownerName.isEmpty
            && window.bounds.width >= Self.minimumWindowSize
            && window.bounds.height >= Self.minimumWindowSize
    }

    /// Keep only windows that live on `screenBounds` — a display's bounds in
    /// CoreGraphics' global, top-left-origin space, the same space as `RawWindow.bounds`
    /// (both come from CoreGraphics), so the comparison needs no coordinate flip. A
    /// window belongs to the display whose bounds contain its centre, so a window
    /// straddling two displays counts on the one holding most of it and never appears on
    /// both. `nil` keeps every window (span all displays). (Bringr-93j.30)
    private func filter(_ windows: [RawWindow], toScreen screenBounds: CGRect?) -> [RawWindow] {
        guard let screenBounds else { return windows }
        return windows.filter {
            screenBounds.contains(CGPoint(x: $0.bounds.midX, y: $0.bounds.midY))
        }
    }

    private func group(_ windows: [RawWindow]) -> [AppWindows] {
        var pidOrder: [pid_t] = []
        var byPID: [pid_t: [RawWindow]] = [:]
        for window in windows {
            if byPID[window.ownerPID] == nil { pidOrder.append(window.ownerPID) }
            byPID[window.ownerPID, default: []].append(window)
        }

        return pidOrder.map { pid in
            let raws = byPID[pid] ?? []
            let appID = AppID(pid: pid)
            let infos = raws.enumerated().map { index, raw in
                WindowInfo(
                    id: WindowID(app: appID, token: raw.windowNumber),
                    title: title(for: raw, index: index)
                )
            }
            return AppWindows(id: appID, name: raws.first?.ownerName ?? "", windows: infos)
        }
    }

    /// Apply the persisted app/window sort orders (Bringr-93j.34) to the freshly
    /// grouped, front-to-back enumeration. `.recentlyUsed` keeps that live z-order (the
    /// ⌘-Tab-matching default); the alternatives impose a stable arrangement from values
    /// macOS already reports — the app name, the creation-ordered window number — so
    /// positions stop reshuffling without any recency tracking of our own.
    private func sorted(_ apps: [AppWindows]) -> [AppWindows] {
        let windowsSorted = apps.map { app in
            AppWindows(id: app.id, name: app.name, windows: sortWindows(app.windows, appName: app.name))
        }
        switch appOrder() {
        case .recentlyUsed:
            // Drive recent-use from Bringr's own MRU when present, so previewing (which
            // perturbs the live z-order) doesn't reshuffle it; fall back to the live
            // front-to-back order when no tracker is injected (Bringr-93j.46).
            return recency?.orderedApps(windowsSorted) ?? windowsSorted
        case .name:
            return windowsSorted.sorted { lhs, rhs in
                switch lhs.name.localizedCaseInsensitiveCompare(rhs.name) {
                case .orderedAscending: return true
                case .orderedDescending: return false
                case .orderedSame: return lhs.id.pid < rhs.id.pid
                }
            }
        case .dockPosition:
            // Match the Dock's left-to-right order; apps not pinned to the Dock trail
            // after the pinned block (Bringr-93j.55). `appBundleID` resolves each app's
            // pid to the bundle id the Dock order is keyed on.
            return DockOrder.sorted(
                windowsSorted, bundleID: { appBundleID($0.id.pid) },
                dockOrder: dockOrder(), keepFinderLast: keepFinderLast()
            )
        }
    }

    /// Order one app's windows by the persisted window sort order. `.fixed` sorts by
    /// window number, which macOS assigns in creation order, so the oldest window keeps
    /// the first spot summon to summon. `.recentlyUsed` uses Bringr's own per-app window
    /// MRU when present, so previewing windows doesn't reshuffle them, falling back to the
    /// live front-to-back order otherwise (Bringr-93j.46).
    private func sortWindows(_ windows: [WindowInfo], appName: String) -> [WindowInfo] {
        switch windowOrder() {
        case .recentlyUsed:
            return recency?.orderedWindows(forAppNamed: appName, windows) ?? windows
        case .fixed:
            return windows.sorted { $0.id.token < $1.id.token }
        }
    }

    /// CoreGraphics window titles need Screen Recording permission, which Bringr
    /// does not request in v1, so titles are usually empty; fall back to a
    /// 1-based index label, which US-006 permits for window slices.
    private func title(for window: RawWindow, index: Int) -> String {
        let trimmed = window.title.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Window \(index + 1)" : trimmed
    }
}
