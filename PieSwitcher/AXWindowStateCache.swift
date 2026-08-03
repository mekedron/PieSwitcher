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

/// Snapshot of the per-app state the wheel reads over the Accessibility API: which
/// window numbers the app lists, which of those are minimized, and each window's title.
///
/// Every one of those reads is a blocking IPC round-trip — one per app plus two per
/// window — and a busy app (a compiling IDE, an Electron app in GC) can hold its answer
/// for hundreds of milliseconds. On the main thread that stalls the wheel *and*, through
/// the activation tap on the main run loop, the pointer itself (see `AXMessaging`). So
/// nothing on the interaction path probes inline: readers get the last snapshot, and a
/// background probe on `AXMessaging.probeQueue` refreshes it.
///
/// The price is staleness bounded by one probe round-trip: a window minimized or
/// retitled since the last probe reads at its previous value until the refresh lands.
/// Readers that show the stale value — the windows sub-wheel — rebuild on
/// `didUpdateNotification`, so the correction appears in place rather than waiting for
/// the next summon. App hidden-state is deliberately absent: `NSRunningApplication`
/// answers it locally with no IPC to the target app, so the classifier reads it live.
@MainActor
final class AXWindowStateCache {
    struct AppState: Sendable, Equatable {
        /// Window numbers the app lists via `kAXWindowsAttribute`.
        let axNumbers: Set<Int>
        /// The subset of `axNumbers` whose `kAXMinimizedAttribute` reads true.
        let minimizedNumbers: Set<Int>
        /// `kAXTitleAttribute` per window number — the only source of a real window title
        /// under Accessibility-only permission, where CG leaves every title blank.
        let titles: [Int: String]

        static let empty = AppState(axNumbers: [], minimizedNumbers: [], titles: [:])
    }

    /// Posted on the main thread when a probe changed an app's snapshot, carrying that
    /// app's pid under `pidUserInfoKey`, so on-screen UI built from the previous snapshot
    /// can rebuild itself.
    static let didUpdateNotification =
        Notification.Name("com.mekedron.PieSwitcher.axWindowStateDidUpdate")
    static let pidUserInfoKey = "pid"

    private var byPID: [pid_t: AppState] = [:]
    /// Pids with a probe in flight, so a hover burst over one app queues one probe rather
    /// than one per event. Per-pid rather than a single global flag, so a probe for one app
    /// never swallows the request for another.
    private var probing: Set<pid_t> = []

    /// The cached state for `pid`, or `nil` when it has never been probed. Refreshing is the
    /// caller's move — `classify` refreshes its whole scanned set in one call.
    func state(forPID pid: pid_t) -> AppState? {
        byPID[pid]
    }

    /// Cached window titles for `pid`, empty until its first probe lands. Requests a refresh,
    /// so a sub-wheel opened on stale titles corrects itself when that probe returns.
    func titles(forPID pid: pid_t) -> [Int: String] {
        refresh([pid])
        return byPID[pid]?.titles ?? [:]
    }

    /// Probe each of `pids` in the background and merge the results in. A pid already being
    /// probed is skipped; its requester re-asks on the next read, so state converges either
    /// way. Never blocks the caller.
    func refresh(_ pids: [pid_t]) {
        let pending = pids.filter { probing.insert($0).inserted }
        guard !pending.isEmpty else { return }
        AXMessaging.probeQueue.async { [weak self] in
            for pid in pending {
                let state = Self.probe(pid)
                DispatchQueue.main.async {
                    MainActor.assumeIsolated { self?.store(state, forPID: pid) }
                }
            }
        }
    }

    /// Merge one probe result in and announce it when it changed something the UI may be
    /// showing.
    private func store(_ state: AppState, forPID pid: pid_t) {
        probing.remove(pid)
        guard byPID[pid] != state else { return }
        byPID[pid] = state
        NotificationCenter.default.post(
            name: Self.didUpdateNotification, object: nil, userInfo: [Self.pidUserInfoKey: pid]
        )
    }

    /// One app's AX window list, minimized set, and titles — the whole per-app probe in a
    /// single traversal, so the collection classifier and the sub-wheel share one round-trip
    /// instead of paying two. `nonisolated` because it runs on `AXMessaging.probeQueue`: the
    /// AX API is safe to call there, and a wedged target app blocks only that queue.
    nonisolated static func probe(_ pid: pid_t) -> AppState {
        let appElement = AXUIElementCreateApplication(pid)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            appElement, kAXWindowsAttribute as CFString, &value
        ) == .success, let windows = value as? [AXUIElement] else {
            return .empty
        }
        var axNumbers: Set<Int> = []
        var minimized: Set<Int> = []
        var titles: [Int: String] = [:]
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
            var titleValue: CFTypeRef?
            if AXUIElementCopyAttributeValue(
                window, kAXTitleAttribute as CFString, &titleValue
            ) == .success, let title = titleValue as? String, !title.isEmpty {
                titles[number] = title
            }
        }
        return AppState(axNumbers: axNumbers, minimizedNumbers: minimized, titles: titles)
    }
}
