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

    init(
        windowNumber: Int, ownerPID: pid_t, ownerName: String, title: String,
        layer: Int, alpha: Double, bounds: CGRect,
        isOnscreen: Bool = true, isMinimized: Bool = false, isHidden: Bool = false,
        isAXBacked: Bool = true
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
    }

    /// A copy carrying the per-window minimized/hidden/AX-backed classification the live
    /// source resolves after the raw list is parsed (Bringr-93j.50 / Bringr-93j.52).
    func classified(isMinimized: Bool, isHidden: Bool, isAXBacked: Bool) -> RawWindow {
        RawWindow(
            windowNumber: windowNumber, ownerPID: ownerPID, ownerName: ownerName, title: title,
            layer: layer, alpha: alpha, bounds: bounds,
            isOnscreen: isOnscreen, isMinimized: isMinimized, isHidden: isHidden,
            isAXBacked: isAXBacked
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

    init(
        source: WindowEnumerationSource? = nil,
        appOrder: @escaping () -> AppSortOrder = { AppSortOrder.current() },
        windowOrder: @escaping () -> WindowSortOrder = { WindowSortOrder.current() },
        recency: RecencyTracker? = nil
    ) {
        self.source = source ?? CGWindowSource()
        self.appOrder = appOrder
        self.windowOrder = windowOrder
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
        // Any broadening flag needs the all-windows query (the only one that surfaces
        // off-Space / minimized / hidden windows); with none set, the cheap current-Space
        // query suffices and every record is already on-screen.
        let includingOffscreen = allSpaces || includeMinimized || includeHidden
        let normal = source.rawWindows(includingOffscreen: includingOffscreen).filter(isNormalWindow)
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

    /// Whether to keep a (normal) window given the broadening flags (Bringr-93j.50). An
    /// on-screen window is always kept (the default set). An off-screen record with no AX
    /// window is a phantom helper surface Bringr can't focus, so it is dropped regardless of
    /// flags (Bringr-93j.52). The rest are classified by precedence — a hidden app's windows
    /// count as hidden even if also minimized, since `includeHidden` is meant to bring a whole
    /// hidden app back — then kept only if the matching flag is on; anything left (off-Space)
    /// rides on `allSpaces`. With every flag off the source returned only on-screen windows
    /// (all AX-backed by default), so this keeps them all unchanged.
    private func shouldCollect(
        _ window: RawWindow, allSpaces: Bool, includeMinimized: Bool, includeHidden: Bool
    ) -> Bool {
        if window.isOnscreen { return true }
        if !window.isAXBacked { return false }
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

/// Live `WindowEnumerationSource` backed by CoreGraphics' on-screen window list.
/// Uses only public API: each record's `windowNumber` is the stable
/// `kCGWindowNumber`. (Titles via `kCGWindowName` require Screen Recording and
/// are normally empty under Accessibility-only permission — see `title(for:)`.)
@MainActor
final class CGWindowSource: WindowEnumerationSource {
    let selfPID = ProcessInfo.processInfo.processIdentifier
    /// The live AX / `NSRunningApplication` wrapper, reused only to read per-window minimized
    /// state and per-app hidden state when classifying a broadened list (Bringr-93j.50). This
    /// is read-only here; window control mutates its own separate instance.
    private let stateProbe = LiveWindowSystem()

    func rawWindows(includingOffscreen: Bool) -> [RawWindow] {
        // `.optionOnScreenOnly` limits the list to windows on the current Space that aren't
        // minimized or hidden; dropping it (an all-windows query) is the only public way to
        // reach all three groups (Bringr-93j.48 / Bringr-93j.50). The narrow form is left
        // exactly as before, so the unbroadened default is unchanged.
        let options: CGWindowListOption = includingOffscreen
            ? [.excludeDesktopElements]
            : [.optionOnScreenOnly, .excludeDesktopElements]
        guard let infoList = CGWindowListCopyWindowInfo(options, kCGNullWindowID)
            as? [[String: Any]] else { return [] }
        let raws = infoList.compactMap { rawWindow(from: $0, assumeOnscreen: !includingOffscreen) }
        return includingOffscreen ? classify(raws) : raws
    }

    /// Stamp each broadened record with its minimized/hidden/AX-backed state so the keep-rule
    /// can split off-Space from minimized from hidden and drop phantoms (Bringr-93j.52): each
    /// app's AX windows yield the minimized set and the set of controllable window numbers — a
    /// broadened record whose number is absent from the latter is a phantom. Hidden via `isHidden`.
    private func classify(_ raws: [RawWindow]) -> [RawWindow] {
        var minimizedNumbers: Set<Int> = []
        var hiddenPIDs: Set<pid_t> = []
        var axNumbers: Set<Int> = []
        for pid in Set(raws.map(\.ownerPID)) {
            let app = AppID(pid: pid)
            if stateProbe.isHidden(app) { hiddenPIDs.insert(pid) }
            for window in stateProbe.windows(of: app) {
                axNumbers.insert(window.token)
                if stateProbe.isMinimized(window) { minimizedNumbers.insert(window.token) }
            }
        }
        return raws.map {
            $0.classified(
                isMinimized: minimizedNumbers.contains($0.windowNumber),
                isHidden: hiddenPIDs.contains($0.ownerPID),
                isAXBacked: axNumbers.contains($0.windowNumber)
            )
        }
    }

    private func rawWindow(from info: [String: Any], assumeOnscreen: Bool) -> RawWindow? {
        guard let windowNumber = (info[kCGWindowNumber as String] as? NSNumber)?.intValue,
              let ownerPID = (info[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value,
              let layer = (info[kCGWindowLayer as String] as? NSNumber)?.intValue,
              let boundsDict = info[kCGWindowBounds as String] as? NSDictionary,
              let bounds = CGRect(dictionaryRepresentation: boundsDict as CFDictionary)
        else { return nil }

        // The narrow query returns only on-screen windows; the broadened one mixes in
        // off-screen records, so read the system flag there (absent → off-screen).
        let isOnscreen = assumeOnscreen
            || ((info[kCGWindowIsOnscreen as String] as? NSNumber)?.boolValue ?? false)
        return RawWindow(
            windowNumber: windowNumber,
            ownerPID: ownerPID,
            ownerName: (info[kCGWindowOwnerName as String] as? String) ?? "",
            title: (info[kCGWindowName as String] as? String) ?? "",
            layer: layer,
            alpha: (info[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 1,
            bounds: bounds,
            isOnscreen: isOnscreen
        )
    }
}

/// Resolves which display a summon happened on (Bringr-93j.30). This is the live
/// `NSScreen` lookup behind the screen restriction; the geometry that consumes its
/// result — `WindowEnumerator`'s screen filter — is pure and unit-tested, so this thin
/// resolver is covered by build & run rather than a hermetic test.
@MainActor
enum ScreenLocator {
    /// CoreGraphics-global bounds (top-left origin) of the display under `cursor`, an
    /// AppKit-global, y-up point such as `NSEvent.mouseLocation`. Returns `CGDisplayBounds`
    /// so the rect shares `RawWindow.bounds`' coordinate space; the cursor is matched in
    /// AppKit space (where it lives) and the result delivered in CoreGraphics space (where
    /// the windows live). `nil` when no display matches (e.g. a headless test host), which
    /// makes enumeration span all displays instead of hiding everything.
    static func displayBounds(forCursor cursor: CGPoint) -> CGRect? {
        let screen = NSScreen.screens.first { $0.frame.contains(cursor) } ?? NSScreen.main
        guard let screen,
              let number = screen.deviceDescription[
                NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
        else { return nil }
        return CGDisplayBounds(CGDirectDisplayID(number.uint32Value))
    }
}
