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
    private var session: Session?

    init(system: WindowControlling? = nil, store: RevealStateStore? = nil) {
        self.system = system ?? LiveWindowSystem()
        self.store = store
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
    }

    /// Restore every app/window touched this session to its pre-summon
    /// visibility and ordering, then end the session. Safe to call with no
    /// active session. (AC5)
    func restore(reactivatingFrontmost: Bool = true) {
        guard let session else { return }

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
