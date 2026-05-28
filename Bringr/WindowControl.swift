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
    }

    private struct Session {
        var didCaptureApps = false
        var frontmostBefore: AppID?
        var appBaseline: [AppSnapshot] = []
        var windowBaseline: [AppID: [WindowSnapshot]] = [:]
    }

    private let system: WindowControlling
    /// Mirrors the in-flight baseline to disk so a crash mid-reveal can be undone on
    /// the next launch (US-015 AC3). `nil` disables journalling — the default for the
    /// fake-backed unit tests and the navigator's default controller; production
    /// injects a real store.
    private let store: RevealStateStore?
    /// Draws/clears the "dim others" spotlight (US-013). `nil` means no dimming —
    /// the default for unit tests and non-dim strategies; production injects a
    /// `LiveDimmer`. Tests inject a recording double to assert dim dispatch.
    private let dimmer: Dimming?
    /// The reveal strategy in force for the current summon. Set by the navigator
    /// before any reveal call (read fresh from the persisted setting at summon time)
    /// and held for the session, so a Preferences change can't switch mid-reveal.
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
    /// window moved out of the way (AC2), then make `window` visible, raise it, and
    /// focus it so it ends up frontmost and active (AC1).
    ///
    /// `restore` is told not to re-activate the prior frontmost app — that would
    /// race the target's own activation and could leave the chosen window behind it.
    /// Re-enumerating refreshes the AX element cache so a stale handle can't make
    /// un-minimize/raise/focus silently no-op. The un-minimize surfaces a target
    /// that was minimized before the summon.
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

    /// Hide every window of `target`'s app except `target`, capturing that app's
    /// window state/order first so `restore()` can put them back exactly. (AC3)
    func hideOtherWindows(besides target: WindowID) {
        captureWindowBaselineIfNeeded(for: target.app)
        if system.isMinimized(target) {
            system.setMinimized(target, false)
        }
        for window in system.windows(of: target.app)
        where window != target && !system.isMinimized(window) {
            system.setMinimized(window, true)
        }
    }

    // MARK: - Reveal strategies (US-013)

    /// Isolate `target` against the other apps (app-hover, US-010) using the active
    /// strategy. The navigator calls this on each app (re-)target; whatever the
    /// strategy does here, `restore()` undoes. All three share the captured baseline.
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

    /// Raise `target` to the front, leaving every other app where it is. Capturing the
    /// baseline records the prior frontmost so `restore()` can re-activate it.
    private func raiseAppToFront(_ target: AppID) {
        captureAppBaselineIfNeeded()
        if system.isHidden(target) { system.setHidden(target, false) }
        system.activate(target)
    }

    /// Raise `target` to the front and dim everything else, cutting the target app's
    /// windows out of the spotlight so they alone stay bright.
    private func dimApp(_ target: AppID) {
        captureAppBaselineIfNeeded()
        if system.isHidden(target) { system.setHidden(target, false) }
        system.activate(target)
        dimmer?.dim(excluding: frames(of: target))
    }

    /// Raise `target` window to the front within its app, leaving the app's other
    /// windows where they are.
    private func raiseWindowToFront(_ target: WindowID) {
        captureWindowBaselineIfNeeded(for: target.app)
        if system.isMinimized(target) { system.setMinimized(target, false) }
        system.raise(target)
    }

    /// Raise `target` window to the front and dim everything else, cutting just this
    /// window out of the spotlight. Falls back to a uniform dim if its frame is
    /// unavailable (the window is still raised, so it reads as the frontmost one).
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

    /// Restore just `app`'s windows to their captured baseline — un-minimize and
    /// re-raise back-to-front — and drop that one baseline, leaving app-level
    /// hiding and the session itself intact. Used when the cursor leaves the
    /// windows sub-wheel but the app stays isolated, so the app's other windows
    /// reappear without un-hiding the rest of the apps. No-op if that app's
    /// windows were never isolated this session.
    func restoreWindows(of app: AppID) {
        guard let windows = session?.windowBaseline[app] else { return }
        for snapshot in windows {
            system.setMinimized(snapshot.id, snapshot.wasMinimized)
        }
        for snapshot in windows.reversed() where !snapshot.wasMinimized {
            system.raise(snapshot.id)
        }
        session?.windowBaseline[app] = nil
        // Dim strategy: leaving the windows sub-wheel returns to the app-level
        // spotlight, so re-cut the dim to all of the app's windows. The app is still
        // frontmost, so it stays bright while the other apps remain dimmed.
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

        // 2. Per-app window minimized-state, then re-raise back-to-front so the
        //    original front window ends up on top again.
        for (_, windows) in session.windowBaseline {
            for snapshot in windows {
                system.setMinimized(snapshot.id, snapshot.wasMinimized)
            }
            for snapshot in windows.reversed() where !snapshot.wasMinimized {
                system.raise(snapshot.id)
            }
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

    /// Put each app/window in `snapshot` back to its pre-summon state, mirroring the
    /// ordering `restore()` uses: app visibility first (so a hidden app's windows
    /// become operable), then re-enumerate each app's windows to repopulate the live
    /// element cache before restoring their minimized-state, then re-activate the
    /// prior frontmost app.
    private func applySnapshot(_ snapshot: RevealSnapshot) {
        for app in snapshot.apps {
            system.setHidden(AppID(pid: app.pid), app.wasHidden)
        }
        for pid in Set(snapshot.windows.map(\.pid)) {
            _ = system.windows(of: AppID(pid: pid))
        }
        for window in snapshot.windows {
            system.setMinimized(
                WindowID(app: AppID(pid: window.pid), token: window.token), window.wasMinimized
            )
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
        session?.windowBaseline[app] = system.windows(of: app).map {
            WindowSnapshot(id: $0, wasMinimized: system.isMinimized($0))
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
                    pid: $0.id.app.pid, token: $0.id.token, wasMinimized: $0.wasMinimized
                )
            }
        }
        let snapshot = RevealSnapshot(
            frontmostPID: session.frontmostBefore?.pid, apps: apps, windows: windows
        )
        if snapshot.isEmpty { store.clear() } else { store.save(snapshot) }
    }
}
