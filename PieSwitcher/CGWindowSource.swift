import AppKit
import CoreGraphics
import Foundation

/// Live `WindowEnumerationSource` backed by CoreGraphics' on-screen window list.
/// Uses only public API: each record's `windowNumber` is the stable
/// `kCGWindowNumber`. (Titles via `kCGWindowName` require Screen Recording and
/// are normally empty under Accessibility-only permission — see `title(for:)`.)
@MainActor
final class CGWindowSource: WindowEnumerationSource {
    let selfPID = ProcessInfo.processInfo.processIdentifier
    /// The live AX / `NSRunningApplication` wrapper, reused read-only to classify a list:
    /// per-window minimized state and per-app hidden state on a broadened list (Bringr-93j.50),
    /// and — via `runningApps()` — which owning apps are ordinary Dock apps (Bringr-93j.51).
    /// Window control mutates its own separate instance.
    private let stateProbe = LiveWindowSystem()
    /// Background-refreshed AX window state for `classify` (Bringr-3qp), so the
    /// broadened path's per-app AX IPC stays off the summon hot path.
    private let axState = AXWindowStateCache()

    /// AX-reported window titles for `pid`, used by `WindowEnumerator` when the CG window
    /// list left a window title blank — the common case under Accessibility-only permission
    /// (Bringr-93j.110). Served from `AXWindowStateCache`, so a hover that opens a sub-wheel
    /// never blocks on the target app: titles come from the last probe and the ring rebuilds
    /// when a fresher one lands (Bringr-jud).
    func axTitles(forPID pid: pid_t) -> [Int: String] {
        axState.titles(forPID: pid)
    }

    /// Warm the AX snapshot for every app the wheel is about to show, so the first hover onto
    /// any of them draws real titles from cache instead of the "<App> — Window <N>" fallback.
    /// Background work only (Bringr-jud).
    func prefetchAXState(forPIDs pids: [pid_t]) {
        axState.refresh(pids)
    }

    func rawWindows(includingOffscreen: Bool, validatingOnscreen: Bool) -> [RawWindow] {
        // `.optionOnScreenOnly` limits the list to windows on the current Space that aren't
        // minimized or hidden; dropping it (an all-windows query) is the only public way to
        // reach all three groups (Bringr-93j.48 / Bringr-93j.50). The narrow form is left
        // exactly as before, so the unbroadened default is unchanged.
        let options: CGWindowListOption = includingOffscreen
            ? [.excludeDesktopElements]
            : [.optionOnScreenOnly, .excludeDesktopElements]
        guard let infoList = CGWindowListCopyWindowInfo(options, kCGNullWindowID)
            as? [[String: Any]] else { return [] }
        // The Dock apps (regular activation policy) currently running — the only apps the
        // wheel shows. Stamped onto every record so the enumerator can drop the rest, on the
        // narrow path too, so "all screens" alone is filtered even though it doesn't broaden
        // the query (Bringr-93j.51). One workspace scan, regardless of window count. Unlike the
        // control path's `runningApps()` this keeps PieSwitcher itself: while a Dock-worthy
        // window (Preferences/About) is open its policy is `.regular` (Bringr-93j.45), so that
        // window appears in the pie like any other app's (Bringr-93j.82).
        let dockPIDs = Set(
            NSWorkspace.shared.runningApplications
                .filter { $0.activationPolicy == .regular }
                .map(\.processIdentifier)
        )
        let ignoredPIDs = ignoredPIDs()
        let raws = infoList.compactMap {
            rawWindow(
                from: $0, assumeOnscreen: !includingOffscreen,
                dockPIDs: dockPIDs, ignoredPIDs: ignoredPIDs
            )
        }
        let classified = includingOffscreen ? classify(raws) : raws
        // All-screens has no screen filter to cull off-display phantoms, so stamp each on-screen
        // record's managed-Space membership and let the enumerator drop the phantoms (Bringr-93j.60).
        return validatingOnscreen ? validateOnscreen(classified) : classified
    }

    /// Stamp every on-screen Dock-app record with whether it lives on a managed Space, the cheap
    /// window-server signal that tells a real on-screen window from a phantom backing surface
    /// (Bringr-93j.60). Only the on-screen records are touched — the broadened `classify` already
    /// stamped the off-screen ones, and a non-Dock record is dropped earlier regardless. Unlike
    /// `classify` this issues no AX IPC (no per-app `copyWindows`, no unresponsive-app hang), so
    /// it needs no caching and is safe on the per-hover narrow path.
    private func validateOnscreen(_ raws: [RawWindow]) -> [RawWindow] {
        let onscreen = raws.filter { $0.isOnscreen && $0.isDockApp }
        guard !onscreen.isEmpty else { return raws }
        let managed = CGWindowSpaces.managedWindowNumbers(among: onscreen.map(\.windowNumber))
        return raws.map { raw in
            guard raw.isOnscreen, raw.isDockApp else { return raw }
            return raw.classified(
                isMinimized: raw.isMinimized, isHidden: raw.isHidden,
                isAXBacked: raw.isAXBacked, isManagedWindow: managed.contains(raw.windowNumber)
            )
        }
    }

    /// PIDs of currently-running apps the user has excluded (Bringr-93j.59), resolved once per
    /// query like `dockPIDs` and stamped onto every record so the enumerator drops them on both
    /// the narrow and broadened paths, even when they have an on-screen window. Empty — with no
    /// workspace scan — when the ignore list is empty, so the common case pays nothing. A running
    /// app matches by either its bundle id or its localized name, the two handles the list holds.
    private func ignoredPIDs() -> Set<pid_t> {
        let ignore = AppIgnoreList.current()
        guard !ignore.isEmpty else { return [] }
        return Set(
            NSWorkspace.shared.runningApplications
                .filter { ignore.excludes(bundleID: $0.bundleIdentifier, name: $0.localizedName ?? "") }
                .map(\.processIdentifier)
        )
    }

    /// Stamp each broadened record with its minimized/hidden/AX-backed/managed-Space state so
    /// the keep-rule can split off-Space from minimized from hidden and drop phantoms
    /// (Bringr-93j.52 / Bringr-93j.54): each app's AX windows yield the minimized set and the set
    /// of AX-controllable window numbers, and `CGWindowSpaces` yields the set living on a managed
    /// Space. A broadened off-screen record absent from *both* is a phantom; one present in the
    /// managed set but not the AX set is a genuine other-Space window AX can't see. Hidden via
    /// `isHidden`. The Dock-app stamp is set earlier by `rawWindow(from:...)` and carried through.
    ///
    /// Only apps that actually surfaced an OFF-screen record matter (Bringr-93j.53): an
    /// on-screen record is kept by `WindowEnumerator.shouldCollect`'s onscreen short-circuit
    /// before it ever consults minimized/hidden/AX-backed. Their AX state answers from
    /// `AXWindowStateCache`, which never issues IPC on this thread (Bringr-jud): a pid the
    /// snapshot has never seen classifies optimistically — AX-backed and not minimized, so a
    /// freshly launched app's windows show rather than being culled as phantoms — and the
    /// background probe corrects it, typically before the wheel is even released. Hidden
    /// state is read live: `NSRunningApplication.isHidden` involves no IPC to the target app.
    /// The managed-Space probe (cheap, window-server) is limited to off-screen Dock-app
    /// records. On-screen records are returned untouched.
    private func classify(_ raws: [RawWindow]) -> [RawWindow] {
        let offscreen = raws.filter { !$0.isOnscreen }
        guard !offscreen.isEmpty else { return raws }
        let offscreenPIDs = Set(offscreen.map(\.ownerPID))
        let managedNumbers = CGWindowSpaces.managedWindowNumbers(
            among: offscreen.filter(\.isDockApp).map(\.windowNumber)
        )

        var hiddenPIDs: Set<pid_t> = []
        var states: [pid_t: AXWindowStateCache.AppState] = [:]
        for pid in offscreenPIDs {
            if stateProbe.isHidden(AppID(pid: pid)) { hiddenPIDs.insert(pid) }
            states[pid] = axState.state(forPID: pid)
        }
        // Freshen the snapshot off this thread, so the next broadened read classifies against
        // current minimized/AX state — and so a pid seen here for the first time is known by
        // then rather than staying optimistic.
        axState.refresh(Array(offscreenPIDs))
        return raws.map { raw in
            guard !raw.isOnscreen else { return raw }
            let state = states[raw.ownerPID]
            return raw.classified(
                isMinimized: state?.minimizedNumbers.contains(raw.windowNumber) ?? false,
                isHidden: hiddenPIDs.contains(raw.ownerPID),
                isAXBacked: state?.axNumbers.contains(raw.windowNumber) ?? true,
                isManagedWindow: managedNumbers.contains(raw.windowNumber)
            )
        }
    }

    private func rawWindow(
        from info: [String: Any], assumeOnscreen: Bool,
        dockPIDs: Set<pid_t>, ignoredPIDs: Set<pid_t>
    ) -> RawWindow? {
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
            isOnscreen: isOnscreen,
            isDockApp: dockPIDs.contains(ownerPID),
            isIgnored: ignoredPIDs.contains(ownerPID)
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
