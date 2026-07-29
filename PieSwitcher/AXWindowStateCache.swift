import AppKit
import ApplicationServices
import CoreGraphics

/// Accessibility SPI that returns the `CGWindowID` backing an AX window element —
/// the same SPI `LiveWindowSystem` declares; redeclared here because `@_silgen_name`
/// bindings are file-private.
@_silgen_name("_AXUIElementGetWindow")
private func axCacheGetWindow(
    _ element: AXUIElement,
    _ windowID: UnsafeMutablePointer<CGWindowID>
) -> AXError

/// Snapshot of the AX-derived, per-app window state the broadened collection scan
/// classifies with: which window numbers the app lists via AX, and which of those
/// are minimized.
///
/// The AX reads behind it are one blocking IPC round-trip per app plus one per
/// window — far too slow for the summon hot path, where a busy app (a compiling
/// IDE, an Electron app in GC) can hold the main thread for hundreds of
/// milliseconds. So `CGWindowSource.classify` answers synchronously from the last
/// snapshot and re-probes on a background task after each use: a summon pays AX
/// IPC only for a pid the snapshot has never seen. The price is one summon of
/// staleness — a window minimized after the last refresh classifies as off-Space
/// until the next refresh (typically landing within a second) — accepted as the
/// trade for an instant open. App hidden-state is NOT cached: it comes from
/// `NSRunningApplication`, a local read with no IPC to the target app, so the
/// classifier reads it live.
@MainActor
final class AXWindowStateCache {
    struct AppState: Sendable {
        /// Window numbers the app currently lists via `kAXWindowsAttribute`.
        let axNumbers: Set<Int>
        /// The subset of `axNumbers` whose `kAXMinimizedAttribute` reads true.
        let minimizedNumbers: Set<Int>
    }

    private var byPID: [pid_t: AppState] = [:]
    private var refreshInFlight = false

    /// The cached state for `pid`, or `nil` when it has never been probed.
    func state(forPID pid: pid_t) -> AppState? {
        byPID[pid]
    }

    /// Probe `pid` now, blocking, and cache the result — the cold-cache fallback for
    /// a pid the snapshot has never seen (first broadened read after launch covers
    /// most of these during the invisible pre-render pass; a freshly launched app
    /// costs one probe on its first appearance).
    func probeAndStore(_ pid: pid_t) -> AppState {
        let state = Self.probe(pid)
        byPID[pid] = state
        return state
    }

    /// Re-probe `pids` on a background task and merge the fresh states in, so the
    /// next broadened read answers from up-to-date state without paying IPC. One
    /// refresh at a time; a request arriving mid-refresh is dropped — the caller
    /// re-requests on its next read, so state converges anyway.
    func refreshSoon(_ pids: [pid_t]) {
        guard !refreshInFlight, !pids.isEmpty else { return }
        refreshInFlight = true
        Task.detached(priority: .utility) {
            var fresh: [pid_t: AppState] = [:]
            for pid in pids {
                fresh[pid] = Self.probe(pid)
            }
            let snapshot = fresh
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.byPID.merge(snapshot) { _, new in new }
                self.refreshInFlight = false
            }
        }
    }

    /// One app's AX window list and per-window minimized state. `nonisolated`
    /// because the background refresh calls it off the main thread — the AX API is
    /// thread-safe; a slow target app blocks only the probing task.
    nonisolated static func probe(_ pid: pid_t) -> AppState {
        let appElement = AXUIElementCreateApplication(pid)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            appElement, kAXWindowsAttribute as CFString, &value
        ) == .success, let windows = value as? [AXUIElement] else {
            return AppState(axNumbers: [], minimizedNumbers: [])
        }
        var axNumbers: Set<Int> = []
        var minimized: Set<Int> = []
        for window in windows {
            var windowID: CGWindowID = 0
            guard axCacheGetWindow(window, &windowID) == .success else { continue }
            let number = Int(windowID)
            axNumbers.insert(number)
            var minValue: CFTypeRef?
            if AXUIElementCopyAttributeValue(
                window, kAXMinimizedAttribute as CFString, &minValue
            ) == .success, (minValue as? Bool) == true {
                minimized.insert(number)
            }
        }
        return AppState(axNumbers: axNumbers, minimizedNumbers: minimized)
    }
}
