import Foundation

/// Identifies a running application by its process id.
struct AppID: Hashable, Sendable {
    let pid: pid_t
}

/// Identifies a window. `token` is an opaque, system-assigned handle (callers
/// treat it as opaque); `app` ties the window to its owning application.
///
/// The token is the window's `kCGWindowNumber` — the same value the enumeration
/// service (US-003) uses — so a `WindowID` produced by `WindowEnumerator` and one
/// produced by `LiveWindowSystem` for the same window are equal and interchangeable.
/// `WindowController` only relies on `WindowID` being `Hashable`.
struct WindowID: Hashable, Sendable {
    let app: AppID
    let token: Int
}

/// The window-system operations `WindowController` needs, behind a seam so the
/// orchestration logic can be unit-tested with an in-memory fake — no live
/// Accessibility calls and no real windows during tests. Mirrors the injectable
/// design of `PermissionsManager`.
@MainActor
protocol WindowControlling {
    /// Apps that are candidates for control (regular apps, excluding Bringr).
    func runningApps() -> [AppID]
    /// Windows of `app`, front-to-back.
    func windows(of app: AppID) -> [WindowID]
    /// The frontmost app, if any.
    func frontmostApp() -> AppID?

    func isHidden(_ app: AppID) -> Bool
    func setHidden(_ app: AppID, _ hidden: Bool)
    func activate(_ app: AppID)

    func isMinimized(_ window: WindowID) -> Bool
    func setMinimized(_ window: WindowID, _ minimized: Bool)
    /// Bring `window` to the front within its application.
    func raise(_ window: WindowID)
    /// Make `window` main and focused (its app should already be active).
    func focusWindow(_ window: WindowID)
    /// The window's frame in AppKit-global coordinates (bottom-left origin, y-up),
    /// or `nil` if it can't be resolved — used to cut the target out of the dim
    /// overlay (US-013 dim-others).
    func frame(of window: WindowID) -> CGRect?

    /// The window's top-left in its native (y-down) space, or `nil`. Captured before
    /// parking a window off-screen so it can be moved back exactly (Bringr-93j.24);
    /// not flipped to AppKit-global like `frame(of:)`, since capture and park share it.
    func position(of window: WindowID) -> CGPoint?
    /// Move `window`'s top-left to `point` (same space as `position(of:)`). Instant,
    /// unlike AX minimize's slow genie animation — the window-level hide-others reveal
    /// parks the app's other windows off-screen with this instead (Bringr-93j.24).
    func setPosition(_ window: WindowID, _ point: CGPoint)
}

/// Low-level window/app control primitives that the reveal strategies (US-013)
/// and selection (US-012) build on.
///
/// Every mutating primitive first captures the pre-mutation state of the scope
/// it touches — app visibility/order, or one app's window minimized-state/order
/// — exactly once per session. `restore()` replays that captured baseline, so it
/// returns to the pre-summon state no matter how many isolate/re-target calls
/// happened in between.
@MainActor
final class WindowController {
    private struct AppSnapshot {
        let id: AppID
        let wasHidden: Bool
    }

    private struct WindowSnapshot {
        let id: WindowID
        let wasMinimized: Bool
        /// Pre-summon top-left so a parked window moves back exactly; `nil` for
        /// windows minimized before the summon (never parked). (Bringr-93j.24)
        let originalPosition: CGPoint?
    }

    private struct Session {
        var didCaptureApps = false
        var frontmostBefore: AppID?
        var appBaseline: [AppSnapshot] = []
        var windowBaseline: [AppID: [WindowSnapshot]] = [:]
    }

    private let system: WindowControlling
    /// Mirrors the in-flight baseline to disk so a crash mid-reveal is undone next
    /// launch (US-015 AC3). `nil` disables journalling (tests/default); prod injects one.
    private let store: RevealStateStore?
    /// Draws/clears the "dim others" spotlight (US-013). `nil` = no dimming (tests/
    /// non-dim strategies); production injects a `LiveDimmer`, tests a recording double.
    private let dimmer: Dimming?
    /// The reveal strategy in force for the current summon, set by the navigator before
    /// any reveal call and held for the session so a Preferences change can't switch it.
    private var strategy: RevealStrategy = .default
    private var session: Session?

    init(system: WindowControlling? = nil, store: RevealStateStore? = nil, dimmer: Dimming? = nil) {
        self.system = system ?? LiveWindowSystem()
        self.store = store
        self.dimmer = dimmer
    }

    /// Set the strategy for the next reveal. Called once per summon before any
    /// isolate call; restore undoes whatever the active strategy did.
    func setStrategy(_ strategy: RevealStrategy) {
        self.strategy = strategy
    }

    /// Whether a capture/restore session is currently open.
    var hasActiveSession: Bool { session != nil }

    /// Where a window is parked to get it out of the way at the window level (instant,
    /// unlike AX minimize's slow animation — Bringr-93j.24). Far below-and-right of any
    /// realistic display (y-down), so the whole window is off-screen; `restore` undoes it.
    static let offScreenPoint = CGPoint(x: 50_000, y: 50_000)

    // MARK: - Primitives

    /// Raise `window` and move focus to it: first ask AX to raise the selected
    /// window, then activate its app, then focus/raise/focus the same window again
    /// so neither app activation nor restored window order can leave a prior front
    /// app/window as the winner. (AC1)
    func raiseAndFocus(_ window: WindowID) {
        system.raise(window)
        system.activate(window.app)
        system.focusWindow(window)
        system.raise(window)
        system.focusWindow(window)
    }

    /// Commit `window` as the user's choice (US-012): restore every other app and
    /// window moved out of the way (AC2), then surface, raise, and focus `window` (AC1).
    /// `restore` skips re-activating the prior frontmost (it would race the target's own
    /// activation); re-enumerating refreshes the AX cache so a stale handle can't no-op
    /// the un-minimize/raise/focus, and the un-minimize surfaces a hidden target.
    func commit(_ window: WindowID) {
        restore(reactivatingFrontmost: false)
        _ = system.windows(of: window.app)
        system.setMinimized(window, false)
        raiseAndFocus(window)
    }

    /// Commit `app` as the user's choice from the first-level apps ring. This is
    /// intentionally weaker than choosing a specific window: restore the reveal,
    /// then activate the app's current front window if one is available.
    func commit(_ app: AppID) {
        restore(reactivatingFrontmost: false)
        if let frontWindow = system.windows(of: app).first {
            system.setMinimized(frontWindow, false)
            raiseAndFocus(frontWindow)
        } else {
            system.activate(app)
        }
    }

    /// Hide every app except `target`, capturing app visibility/order first so
    /// `restore()` can put them back exactly. (AC2)
    func hideOtherApps(besides target: AppID) {
        captureAppBaselineIfNeeded()
        if system.isHidden(target) {
            system.setHidden(target, false)
        }
        for app in system.runningApps() where app != target && !system.isHidden(app) {
            system.setHidden(app, true)
        }
    }

    /// Get every window of `target`'s app except `target` out of the way by parking it
    /// off-screen — instant, unlike the AX minimize this replaced (Bringr-93j.24).
    /// Captures the app's window state/order first so `restore()` undoes it exactly (AC3).
    /// Re-targeting reuses that baseline: the new target un-parks (no-op on first isolate)
    /// and raises while the previous parks; user-minimized windows are left alone.
    func hideOtherWindows(besides target: WindowID) {
        captureWindowBaselineIfNeeded(for: target.app)
        if system.isMinimized(target) {
            system.setMinimized(target, false)
        }
        restoreCapturedPosition(of: target)
        for window in system.windows(of: target.app)
        where window != target && !system.isMinimized(window) {
            system.setPosition(window, Self.offScreenPoint)
        }
        system.raise(target)
    }

    /// Move `window` back to the position captured at baseline, if one was recorded
    /// (a no-op for a window minimized before the summon — it was never parked).
    private func restoreCapturedPosition(of window: WindowID) {
        guard let position = session?.windowBaseline[window.app]?
            .first(where: { $0.id == window })?.originalPosition else { return }
        system.setPosition(window, position)
    }

    // MARK: - Reveal strategies (US-013)

    /// Isolate `target` against the other apps (app-hover, US-010) using the active
    /// strategy; whatever the strategy does, `restore()` undoes. All share one baseline.
    func revealApp(_ target: AppID) {
        switch strategy {
        case .hideOthers: hideOtherApps(besides: target)
        case .raiseToFront: raiseAppToFront(target)
        case .dimOthers: dimApp(target)
        }
    }

    /// Isolate `target` against its app's other windows (window-hover, US-011) using
    /// the active strategy.
    func revealWindow(_ target: WindowID) {
        switch strategy {
        case .hideOthers: hideOtherWindows(besides: target)
        case .raiseToFront: raiseWindowToFront(target)
        case .dimOthers: dimWindow(target)
        }
    }

    /// Raise `target` to the front, leaving other apps put; baseline capture records
    /// the prior frontmost so `restore()` re-activates it.
    private func raiseAppToFront(_ target: AppID) {
        captureAppBaselineIfNeeded()
        if system.isHidden(target) { system.setHidden(target, false) }
        system.activate(target)
    }

    /// Raise `target` and dim everything else, cutting the app's windows out of the
    /// spotlight so they alone stay bright.
    private func dimApp(_ target: AppID) {
        captureAppBaselineIfNeeded()
        if system.isHidden(target) { system.setHidden(target, false) }
        system.activate(target)
        dimmer?.dim(excluding: frames(of: target))
    }

    /// Raise `target` window to the front within its app, leaving the app's others put.
    private func raiseWindowToFront(_ target: WindowID) {
        captureWindowBaselineIfNeeded(for: target.app)
        if system.isMinimized(target) { system.setMinimized(target, false) }
        system.raise(target)
    }

    /// Raise `target` window and dim everything else, cutting just it out of the
    /// spotlight; falls back to a uniform dim if its frame is unavailable (still raised).
    private func dimWindow(_ target: WindowID) {
        captureWindowBaselineIfNeeded(for: target.app)
        if system.isMinimized(target) { system.setMinimized(target, false) }
        system.raise(target)
        dimmer?.dim(excluding: system.frame(of: target).map { [$0] } ?? [])
    }

    /// The frames of `app`'s current windows, for the dim cutout; windows whose frame
    /// can't be resolved are skipped (their region simply stays dimmed).
    private func frames(of app: AppID) -> [CGRect] {
        system.windows(of: app).compactMap { system.frame(of: $0) }
    }

    /// Put one app's captured window baseline back: un-park to origin, restore minimized-
    /// state, then re-raise back-to-front so the original front window ends up on top.
    private func restoreWindowBaseline(_ windows: [WindowSnapshot]) {
        for snapshot in windows {
            if let position = snapshot.originalPosition {
                system.setPosition(snapshot.id, position)
            }
            system.setMinimized(snapshot.id, snapshot.wasMinimized)
        }
        for snapshot in windows.reversed() where !snapshot.wasMinimized {
            system.raise(snapshot.id)
        }
    }

    /// Restore just `app`'s windows to their captured baseline and drop that baseline,
    /// leaving app-level hiding and the session intact — used when the cursor leaves
    /// the windows sub-wheel but the app stays isolated. No-op if never isolated.
    func restoreWindows(of app: AppID) {
        guard let windows = session?.windowBaseline[app] else { return }
        restoreWindowBaseline(windows)
        session?.windowBaseline[app] = nil
        // Dim strategy: leaving the sub-wheel returns to the app-level spotlight, so
        // re-cut the dim to all of the app's windows (the app stays frontmost/bright).
        if strategy == .dimOthers {
            dimmer?.dim(excluding: frames(of: app))
        }
    }

    /// Restore every app/window touched this session to its pre-summon
    /// visibility and ordering, then end the session. Safe to call with no
    /// active session. (AC5)
    func restore(reactivatingFrontmost: Bool = true) {
        guard let session else { return }

        // 0. Remove any dim spotlight first (a no-op for the other strategies).
        dimmer?.clear()

        // 1. App visibility first, so windows are operated on while their app is shown.
        for snapshot in session.appBaseline {
            system.setHidden(snapshot.id, snapshot.wasHidden)
        }

        // 2. Per-app window state: un-park, restore minimized-state, re-raise to order.
        for (_, windows) in session.windowBaseline {
            restoreWindowBaseline(windows)
        }

        // 3. Frontmost app last (skipped on commit, which activates the chosen
        //    window's app instead — a second activation here would race it).
        if reactivatingFrontmost, let frontmost = session.frontmostBefore {
            system.activate(frontmost)
        }

        store?.clear()
        self.session = nil
    }

    // MARK: - Restore-on-launch safety net (AC3)

    /// If a previous session was killed mid-reveal, its baseline is still persisted —
    /// replay it so no app stays hidden and no window stays minimized, then clear it.
    /// Returns whether a stranded reveal was found and undone. A no-op (returns
    /// `false`) on the common path where the last session restored cleanly.
    @discardableResult
    func restoreFromSnapshotIfNeeded() -> Bool {
        guard let store, let snapshot = store.load() else { return false }
        applySnapshot(snapshot)
        store.clear()
        return true
    }

    /// Put each app/window in `snapshot` back to its pre-summon state in the same order
    /// `restore()` uses: app visibility first, then re-enumerate each app to repopulate
    /// the AX element cache before un-parking / restoring minimized-state, then the
    /// prior frontmost app.
    private func applySnapshot(_ snapshot: RevealSnapshot) {
        for app in snapshot.apps {
            system.setHidden(AppID(pid: app.pid), app.wasHidden)
        }
        for pid in Set(snapshot.windows.map(\.pid)) {
            _ = system.windows(of: AppID(pid: pid))
        }
        for window in snapshot.windows {
            let id = WindowID(app: AppID(pid: window.pid), token: window.token)
            if let position = window.originalPosition {
                system.setPosition(id, position)
            }
            system.setMinimized(id, window.wasMinimized)
        }
        if let frontmost = snapshot.frontmostPID {
            system.activate(AppID(pid: frontmost))
        }
    }

    // MARK: - Baseline capture (AC4)

    private func captureAppBaselineIfNeeded() {
        if session == nil { session = Session() }
        guard session?.didCaptureApps == false else { return }
        session?.didCaptureApps = true
        session?.frontmostBefore = system.frontmostApp()
        session?.appBaseline = system.runningApps().map {
            AppSnapshot(id: $0, wasHidden: system.isHidden($0))
        }
        persistSnapshot()
    }

    private func captureWindowBaselineIfNeeded(for app: AppID) {
        if session == nil { session = Session() }
        guard session?.windowBaseline[app] == nil else { return }
        session?.windowBaseline[app] = system.windows(of: app).map { id in
            let minimized = system.isMinimized(id)
            return WindowSnapshot(
                id: id,
                wasMinimized: minimized,
                originalPosition: minimized ? nil : system.position(of: id)
            )
        }
        persistSnapshot()
    }

    /// Mirror the current in-memory baseline to the store. Called whenever the
    /// baseline grows — once per app-hover, once per app's first window-isolation —
    /// so it stays off the summon hot path. Clears the store when nothing is captured.
    private func persistSnapshot() {
        guard let store, let session else { return }
        let apps = session.appBaseline.map {
            RevealSnapshot.AppEntry(pid: $0.id.pid, wasHidden: $0.wasHidden)
        }
        let windows = session.windowBaseline.values.flatMap { snapshots in
            snapshots.map {
                RevealSnapshot.WindowEntry(
                    pid: $0.id.app.pid, token: $0.id.token,
                    wasMinimized: $0.wasMinimized, originalPosition: $0.originalPosition
                )
            }
        }
        let snapshot = RevealSnapshot(
            frontmostPID: session.frontmostBefore?.pid, apps: apps, windows: windows
        )
        if snapshot.isEmpty { store.clear() } else { store.save(snapshot) }
    }
}
