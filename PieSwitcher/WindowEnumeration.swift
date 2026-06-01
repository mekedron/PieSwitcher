import AppKit
import CoreGraphics
import Foundation
import os

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
    ///
    /// `validatingOnscreen` additionally stamps each on-screen record's managed-Space
    /// membership (Bringr-93j.60) — the cheap window-server signal that tells a real on-screen
    /// window from a phantom backing surface. The enumerator asks for it only when there is no
    /// screen filter (all displays) to cull phantoms geometrically; off (the default), on-screen
    /// records are returned untouched and trusted, exactly as before.
    func rawWindows(includingOffscreen: Bool, validatingOnscreen: Bool) -> [RawWindow]
    /// This process's pid, so PieSwitcher's own windows can be excluded.
    var selfPID: pid_t { get }
    /// AX-reported window titles for `pid`, keyed by window number (Bringr-93j.110). Lets
    /// the enumerator fill in titles the CG list left blank — `kCGWindowName` needs Screen
    /// Recording (a v1 non-goal), so Accessibility is everyday life's only path to a real
    /// title. Empty when AX can't resolve them (denied, app has none listed).
    func axTitles(forPID pid: pid_t) -> [Int: String]
}

extension WindowEnumerationSource {
    /// Default: no AX titles. Test sources that don't care inherit this; live sources override.
    func axTitles(forPID pid: pid_t) -> [Int: String] { [:] }
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
    private let log = Logger(subsystem: "com.mekedron.PieSwitcher", category: "enumeration")

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
    /// "Include minimized/hidden" lag by seconds. Dropped at the next summon's first read
    /// (`freshSummon: true`, the one authoritative per-summon read), so it never goes
    /// stale across summons. `nil` on the narrow (default) path, which is never cached so its
    /// per-hover live re-read — and the Bringr-93j.31 sub-wheel retry that relies on it — is
    /// preserved exactly. Keyed by `validatingOnscreen` too (Bringr-93j.60): an all-screens
    /// broadened read stamps on-screen managed membership while a current-screen broadened read
    /// does not, so the two must not serve each other's list within a summon — a key mismatch
    /// re-fetches.
    private var broadenedRawCache: (validatingOnscreen: Bool, windows: [RawWindow])?

    init(
        source: WindowEnumerationSource? = nil,
        appOrder: @escaping () -> AppSortOrder = { AppSortOrder.current() },
        windowOrder: @escaping () -> WindowSortOrder = { WindowSortOrder.current() },
        dockOrder: @escaping () -> [String] = { DockOrder.current() },
        keepFinderLast: @escaping () -> Bool = { DockOrder.keepsFinderLast() },
        appBundleID: @escaping (pid_t) -> String? = {
            NSRunningApplication(processIdentifier: $0)?.bundleIdentifier
        }
    ) {
        self.source = source ?? CGWindowSource()
        self.appOrder = appOrder
        self.windowOrder = windowOrder
        self.dockOrder = dockOrder
        self.keepFinderLast = keepFinderLast
        self.appBundleID = appBundleID
    }

    /// Apps that currently own at least one normal, on-screen window, each with
    /// its windows front-to-back. Excludes PieSwitcher's overlay and apps whose only
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
    /// `freshSummon` marks the one authoritative read at the start of a summon (the apps
    /// ring), distinguishing it from the per-app sub-wheel re-reads that hover triggers; it
    /// invalidates the prior summon's broadened raw-window cache so a later broadened read of
    /// this summon never sees stale windows (Bringr-93j.53). The hover re-reads pass `false`
    /// to share the just-fetched broadened list.
    /// `validatesOnscreen` keeps an on-screen window only if it is a real, focusable window
    /// (Bringr-93j.60). Off (the default) trusts every on-screen record, the prior behaviour, so
    /// the hot default path is unchanged and existing callers/tests are unaffected. On — passed
    /// only when `screenBounds` is `nil`, where no screen filter culls off-display phantoms — an
    /// on-screen record must be on a managed Space (the source stamps `isManagedWindow`); a
    /// phantom backing surface is not. This is what stopped "all screens" from listing phantom
    /// windows that don't exist.
    func enumerate(
        onScreen screenBounds: CGRect? = nil,
        allSpaces: Bool = false,
        includeMinimized: Bool = false,
        includeHidden: Bool = false,
        validatesOnscreen: Bool = false,
        freshSummon: Bool = false
    ) -> [AppWindows] {
        let start = DispatchTime.now().uptimeNanoseconds
        // The summon-start read runs first, before any hover, so it marks a new summon: drop the
        // prior summon's cached broadened list so a later broadened read this summon can't serve
        // stale windows (Bringr-93j.53).
        if freshSummon { broadenedRawCache = nil }
        // Any broadening flag needs the all-windows query (the only one that surfaces
        // off-Space / minimized / hidden windows); with none set, the cheap current-Space
        // query suffices and every record is already on-screen.
        let includingOffscreen = allSpaces || includeMinimized || includeHidden
        let normal = normalWindows(includingOffscreen: includingOffscreen, validatingOnscreen: validatesOnscreen)
        // In the broadening / on-screen-validating modes the phantom report (Bringr-93j.60) is
        // worth the per-window detail; the hot default path never logs.
        if includingOffscreen || validatesOnscreen {
            logCollection(
                normal, allSpaces: allSpaces, includeMinimized: includeMinimized,
                includeHidden: includeHidden, validatesOnscreen: validatesOnscreen
            )
        }
        let collected = normal.filter {
            shouldCollect(
                $0, allSpaces: allSpaces, includeMinimized: includeMinimized,
                includeHidden: includeHidden, validatesOnscreen: validatesOnscreen
            )
        }
        let onScreen = filter(collected, toScreen: screenBounds)
        let grouped = group(onScreen)
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
    /// The all-screens-only read (`validatingOnscreen` without broadening) is deliberately on
    /// the uncached branch with the default path (Bringr-93j.60): its only added cost is the
    /// source's cheap window-server managed-Space stamp — not the AX classify the cache exists
    /// to amortise — and leaving it uncached preserves the Bringr-93j.31 sub-wheel retry's fresh
    /// post-reveal scan.
    private func normalWindows(includingOffscreen: Bool, validatingOnscreen: Bool) -> [RawWindow] {
        guard includingOffscreen else {
            return source.rawWindows(
                includingOffscreen: false, validatingOnscreen: validatingOnscreen
            ).filter(isNormalWindow)
        }
        // A validated (all-screens) cached scan also serves an unvalidated (screen-scoped) read, not
        // only an exact match (Bringr-93j.68): validateOnscreen only *adds* a managed stamp the
        // unvalidated keep-rule ignores, so it's a safe superset (never the reverse). Without it the
        // validated apps-ring scan couldn't feed the unvalidated windows sub-wheel, so each first hover
        // re-ran the broadened AX classify — which hangs ~1–2 s mid-`activate` when Preferences is open.
        if let cached = broadenedRawCache,
           cached.validatingOnscreen == validatingOnscreen || cached.validatingOnscreen {
            return cached.windows
        }
        let normal = source.rawWindows(
            includingOffscreen: true, validatingOnscreen: validatingOnscreen
        ).filter(isNormalWindow)
        broadenedRawCache = (validatingOnscreen, normal)
        return normal
    }

    /// Whether to keep a (normal) window given the broadening flags. Thin wrapper over
    /// `decision(for:...)`, which carries the keep/drop reason so the same rule drives both
    /// collection and the Bringr-93j.60 phantom logging without drifting.
    private func shouldCollect(
        _ window: RawWindow, allSpaces: Bool, includeMinimized: Bool,
        includeHidden: Bool, validatesOnscreen: Bool
    ) -> Bool {
        decision(
            for: window, allSpaces: allSpaces, includeMinimized: includeMinimized,
            includeHidden: includeHidden, validatesOnscreen: validatesOnscreen
        ).keep
    }

    /// The keep/drop verdict for one (normal) window, with a human-readable reason for logging.
    ///
    /// Dropped first, regardless of flags: a window whose owning app is on the exclusion list
    /// (Bringr-93j.59) or isn't an ordinary Dock app (Bringr-93j.51) — the switcher shows only
    /// Dock apps, on the narrow path too.
    ///
    /// An on-screen window is kept outright when not validating (the screen filter culls
    /// off-display phantoms geometrically); when validating (all screens, no screen filter) only
    /// if it is on a managed Space, so a phantom backing surface is dropped (Bringr-93j.60).
    ///
    /// Off-screen, a record neither AX-backed nor on a managed Space is an unfocusable phantom,
    /// dropped regardless of flags (Bringr-93j.52/.54). The rest are classified by precedence:
    /// hidden (Cmd-H, including PieSwitcher's "Hide others") over minimized, then off-Space — each
    /// kept only if its flag is on. A hidden window must *also* be AX-backed (Bringr-93j.79): a
    /// Cmd-H'd app's real windows stay AX-listed on the current Space, but the backing surfaces
    /// Chrome/Chromium keep are managed yet AX-absent, and the per-app hidden stamp marks them too —
    /// so managed membership alone (the off-Space signal) can't exclude them.
    private func decision(
        for window: RawWindow, allSpaces: Bool, includeMinimized: Bool,
        includeHidden: Bool, validatesOnscreen: Bool
    ) -> (keep: Bool, reason: String) {
        if window.isIgnored { return (false, "owning app is on the ignore list") }
        if !window.isDockApp { return (false, "owning app is not an ordinary Dock app") }
        if window.isOnscreen {
            guard validatesOnscreen else { return (true, "on-screen (screen-scoped, trusted)") }
            return window.isManagedWindow
                ? (true, "on-screen and on a managed Space")
                : (false, "on-screen but on no managed Space (phantom surface)")
        }
        if !window.isAXBacked && !window.isManagedWindow {
            return (false, "off-screen, neither AX-backed nor on a managed Space (phantom)")
        }
        if window.isHidden {
            guard window.isAXBacked else { return (false, "hidden-app surface absent from AX list (phantom)") }
            return (includeHidden, includeHidden ? "hidden-app window (included)" : "hidden-app window (excluded)")
        }
        if window.isMinimized {
            return (includeMinimized, includeMinimized ? "minimized window (included)" : "minimized window (excluded)")
        }
        return (allSpaces, allSpaces ? "off-Space window (included)" : "off-Space window (excluded)")
    }

    /// Log every normal window with its identifiers, classification signals, and the keep/drop
    /// reason, so a recurrence of the phantom-window bug is diagnosable from the logs without a
    /// rebuild (Bringr-93j.60). Only called in the broadening / on-screen-validating modes — the
    /// hot default path never logs — and at `.debug`, so it's available on demand (Console or
    /// `log show --debug --predicate 'subsystem == "com.mekedron.PieSwitcher"'`) without spamming
    /// ordinary use. Window titles are intentionally omitted (they can carry private content);
    /// the CG window number is the stable identifier for cross-referencing.
    private func logCollection(
        _ windows: [RawWindow], allSpaces: Bool, includeMinimized: Bool,
        includeHidden: Bool, validatesOnscreen: Bool
    ) {
        log.debug("""
            Collection scan: \(windows.count) normal window(s) — allSpaces:\(allSpaces) \
            includeMinimized:\(includeMinimized) includeHidden:\(includeHidden) \
            validatesOnscreen:\(validatesOnscreen)
            """)
        for window in windows {
            let verdict = decision(
                for: window, allSpaces: allSpaces, includeMinimized: includeMinimized,
                includeHidden: includeHidden, validatesOnscreen: validatesOnscreen
            )
            log.debug("""
                \(verdict.keep ? "KEEP" : "DROP") \(window.ownerName, privacy: .public) \
                #\(window.windowNumber) pid:\(window.ownerPID) \
                on:\(window.isOnscreen) managed:\(window.isManagedWindow) ax:\(window.isAXBacked) \
                min:\(window.isMinimized) hidden:\(window.isHidden) dock:\(window.isDockApp) \
                \(Int(window.bounds.width))x\(Int(window.bounds.height)) — \(verdict.reason, privacy: .public)
                """)
        }
    }

    private func isNormalWindow(_ window: RawWindow) -> Bool {
        // Keep our own windows out — except a Dock-worthy one (Preferences/About), a real
        // focusable window that should appear like any Dock app's (Bringr-93j.82); the overlay
        // and dim panels aren't layer 0, so the `layer == 0` check below drops them regardless.
        (window.ownerPID != source.selfPID || window.isDockApp)
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
            let ownerName = raws.first?.ownerName ?? ""
            // Only ask AX for titles when at least one CG title is blank (Bringr-93j.110):
            // Screen Recording populates every CG title, so the per-app AX read is skipped.
            let needsAX = raws.contains { $0.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            let axTitles = needsAX ? source.axTitles(forPID: pid) : [:]
            let infos = raws.enumerated().map { index, raw in
                WindowInfo(
                    id: WindowID(app: appID, token: raw.windowNumber),
                    title: title(for: raw, ownerName: ownerName, axTitles: axTitles, index: index)
                )
            }
            return AppWindows(id: appID, name: ownerName, windows: infos)
        }
    }

    /// Apply the persisted app/window sort orders (Bringr-93j.34) to the freshly grouped
    /// enumeration. Both orders impose a stable arrangement from values macOS already reports
    /// — the app name, the Dock's left-to-right order, the creation-ordered window number —
    /// so positions never reshuffle without any recency tracking of our own (Bringr-93j.90).
    private func sorted(_ apps: [AppWindows]) -> [AppWindows] {
        let windowsSorted = apps.map { app in
            AppWindows(id: app.id, name: app.name, windows: sortWindows(app.windows))
        }
        switch appOrder() {
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
    /// the first spot summon to summon.
    private func sortWindows(_ windows: [WindowInfo]) -> [WindowInfo] {
        switch windowOrder() {
        case .fixed:
            return windows.sorted { $0.id.token < $1.id.token }
        }
    }

    /// Displayed title (Bringr-93j.110): CG `kCGWindowName` if populated, then AX title for
    /// blank-CG windows, then "<App> — Window <N>" so a slice is never blank with window
    /// labels on. The app-name fallback disambiguates untitled windows; an ownerless edge
    /// case collapses to "Window <N>".
    private func title(
        for window: RawWindow, ownerName: String, axTitles: [Int: String], index: Int
    ) -> String {
        let cg = window.title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !cg.isEmpty { return cg }
        if let ax = axTitles[window.windowNumber]?
            .trimmingCharacters(in: .whitespacesAndNewlines), !ax.isEmpty { return ax }
        let owner = ownerName.trimmingCharacters(in: .whitespacesAndNewlines)
        return owner.isEmpty ? "Window \(index + 1)" : "\(owner) — Window \(index + 1)"
    }
}
