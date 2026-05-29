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
        // The Dock apps (regular activation policy) currently running — the only apps the
        // wheel shows. Stamped onto every record so the enumerator can drop the rest, on the
        // narrow path too, so "all screens" alone is filtered even though it doesn't broaden
        // the query (Bringr-93j.51). One workspace scan, reusing `runningApps()`' `.regular`
        // rule, regardless of window count.
        let dockPIDs = Set(stateProbe.runningApps().map(\.pid))
        let ignoredPIDs = ignoredPIDs()
        let raws = infoList.compactMap {
            rawWindow(
                from: $0, assumeOnscreen: !includingOffscreen,
                dockPIDs: dockPIDs, ignoredPIDs: ignoredPIDs
            )
        }
        return includingOffscreen ? classify(raws) : raws
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
    /// Only apps that actually surfaced an OFF-screen record are AX-probed (Bringr-93j.53): an
    /// on-screen record is kept by `WindowEnumerator.shouldCollect`'s onscreen short-circuit
    /// before it ever consults minimized/hidden/AX-backed, so probing an app whose windows are
    /// all on-screen is pure wasted IPC — and that IPC (one `copyWindows` per app, one
    /// `isMinimized` per window) is what made the broadened path lag. The per-window minimized
    /// read is likewise limited to off-screen window numbers, since on-screen windows are never
    /// minimized. The managed-Space probe is limited to off-screen Dock-app records — non-Dock
    /// records are dropped before the managed check matters. On-screen records are returned
    /// untouched (their defaults already match what the old probe computed for them).
    private func classify(_ raws: [RawWindow]) -> [RawWindow] {
        let offscreen = raws.filter { !$0.isOnscreen }
        guard !offscreen.isEmpty else { return raws }
        let offscreenPIDs = Set(offscreen.map(\.ownerPID))
        let offscreenNumbers = Set(offscreen.map(\.windowNumber))
        let managedNumbers = CGWindowSpaces.managedWindowNumbers(
            among: offscreen.filter(\.isDockApp).map(\.windowNumber)
        )

        var minimizedNumbers: Set<Int> = []
        var hiddenPIDs: Set<pid_t> = []
        var axNumbers: Set<Int> = []
        for pid in offscreenPIDs {
            let app = AppID(pid: pid)
            if stateProbe.isHidden(app) { hiddenPIDs.insert(pid) }
            for window in stateProbe.windows(of: app) {
                axNumbers.insert(window.token)
                if offscreenNumbers.contains(window.token), stateProbe.isMinimized(window) {
                    minimizedNumbers.insert(window.token)
                }
            }
        }
        return raws.map { raw in
            guard !raw.isOnscreen else { return raw }
            return raw.classified(
                isMinimized: minimizedNumbers.contains(raw.windowNumber),
                isHidden: hiddenPIDs.contains(raw.ownerPID),
                isAXBacked: axNumbers.contains(raw.windowNumber),
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
