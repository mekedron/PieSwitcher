import Foundation

/// Low-level window/app control primitives that the reveal strategies (US-013) and
/// selection (US-012) build on. Every mutating primitive captures the pre-mutation
/// state it touches once per session; `restore()` replays that baseline, returning to
/// the pre-summon state no matter how many isolate/re-target calls happened between.
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
    /// Mirrors the in-flight baseline to disk so a crash mid-reveal is undone next launch
    /// (US-015 AC3); `nil` disables journalling (tests/default), production injects one.
    private let store: RevealStateStore?
    /// Draws/clears the "dim others" spotlight (US-013); `nil` = no dimming (tests/non-dim).
    private let dimmer: Dimming?
    /// The reveal strategy for the current summon, held so a Preferences change can't switch it mid-reveal.
    private var strategy: RevealStrategy = .default
    /// Whether a commit should clear every other app/window off the screen, leaving only the
    /// selection (Bringr-93j.27). Held for the summon like `strategy`, so a Preferences change
    /// can't flip it mid-interaction.
    private var hideOnCommit = false
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

    /// Enable/disable "leave only my selection on screen" for the next summon
    /// (Bringr-93j.27). Set once per summon before commit, mirroring `setStrategy`.
    func setHideOnCommit(_ enabled: Bool) {
        hideOnCommit = enabled
    }

    /// Whether a capture/restore session is currently open.
    var hasActiveSession: Bool { session != nil }

    // MARK: - Primitives

    /// Raise `window` and move focus to it: AX-raise it, activate its app, then
    /// focus/raise/focus it again so neither app activation nor restored window order
    /// can leave a prior front app/window as the winner. (AC1)
    func raiseAndFocus(_ window: WindowID) {
        system.raise(window)
        system.activate(window.app)
        system.focusWindow(window)
        system.raise(window)
        system.focusWindow(window)
    }

    /// Commit `window` as the user's choice (US-012): raise+focus the chosen window
    /// (AC1), then restore everything moved aside (AC2). Bringr-93j.86 reordered raise
    /// before restore so other apps unhiding can no longer flash visible for a frame
    /// before the chosen window reaches the top — the user-reported blink. AX cache
    /// stays valid because the chosen app was visible throughout the reveal.
    func commit(_ window: WindowID) {
        // OLD implementation (preserved per Bringr-93j.86 for easy rollback if this
        // reorder breaks the activation/switch flow). Old rationale: `restore` first
        // refreshed the AX cache via the unhide+re-enumeration. The visible cost was
        // unhiding every other app a frame before the chosen one came to the top.
        //   restore(reactivatingFrontmost: false)
        //   let live = system.windows(of: window.app)
        //   system.setMinimized(window, false)
        //   raiseAndFocus(window)
        //   if !live.contains(window) { system.raiseAcrossSpaces(window) }
        //   if hideOnCommit { hideEveryAppExcept(window.app) }

        // Restore chosen app's window baseline first so siblings return to original
        // z-order (Bringr-93j.47), or the previously-front sibling stays at the bottom.
        if let baseline = session?.windowBaseline[window.app] {
            restoreWindowBaseline(baseline)
            session?.windowBaseline[window.app] = nil
        }
        let live = system.windows(of: window.app)
        system.setMinimized(window, false)
        raiseAndFocus(window)
        // Cross-Space fallback (Bringr-93j.54): kAXWindowsAttribute doesn't enumerate
        // other Spaces, so the AX raise/focus above no-op'd; raise by CG number instead.
        if !live.contains(window) { system.raiseAcrossSpaces(window) }
        // With hide-on-commit on, other apps are re-hidden immediately — skip the
        // unhide-then-re-hide flicker (Bringr-93j.86). Otherwise restore unhides them
        // behind the chosen window (which is now on top), so the user sees no flash.
        if hideOnCommit {
            endSessionWithoutRestoringAppVisibility()
            hideEveryAppExcept(window.app)
        } else {
            restore(reactivatingFrontmost: false)
        }
    }

    /// Commit `app` from the first-level apps ring: raise its front window (or reopen
    /// if windowless, Bringr-93j.61), then restore. Reordered per Bringr-93j.86 — see
    /// `commit(_ window:)` for the rationale.
    func commit(_ app: AppID) {
        // OLD implementation (preserved per Bringr-93j.86 for easy rollback):
        //   restore(reactivatingFrontmost: false)
        //   if let frontWindow = system.windows(of: app).first {
        //       system.setMinimized(frontWindow, false)
        //       raiseAndFocus(frontWindow)
        //   } else {
        //       system.reopen(app)
        //   }
        //   if hideOnCommit { hideEveryAppExcept(app) }

        if let baseline = session?.windowBaseline[app] {
            restoreWindowBaseline(baseline)
            session?.windowBaseline[app] = nil
        }
        if let frontWindow = system.windows(of: app).first {
            system.setMinimized(frontWindow, false)
            raiseAndFocus(frontWindow)
        } else {
            system.reopen(app)
        }
        if hideOnCommit {
            endSessionWithoutRestoringAppVisibility()
            hideEveryAppExcept(app)
        } else {
            restore(reactivatingFrontmost: false)
        }
    }

    /// End the session without unhiding any apps — used by `commit` with `hideOnCommit`
    /// on, so the apps the reveal hid are not unhid and re-hidden in the same breath
    /// (the visible flicker Bringr-93j.86 fixed). Like `restore()` minus the app-
    /// visibility loop and the frontmost re-activation.
    private func endSessionWithoutRestoringAppVisibility() {
        dimmer?.clear()
        if let session {
            // Defensive: only the target app's window baseline is populated in normal
            // flows, and commit already cleared it. Replay any leftover baselines.
            for (_, windows) in session.windowBaseline {
                restoreWindowBaseline(windows)
            }
        }
        store?.clear()
        session = nil
    }

    /// The app's current front (active) window — the first in z-order — or `nil` if it has none.
    /// Keyboard nav lands its initial focus here when drilling into an app (Bringr-93j.73), so the
    /// active window is focused regardless of how the sub-wheel is sorted; matched by stable token.
    /// The same "front window is the app's choice" notion `commit(_ app:)` uses.
    func frontWindow(of app: AppID) -> WindowID? {
        system.windows(of: app).first
    }

    // MARK: - Leave-only-my-selection on commit (Bringr-93j.27, Bringr-93j.49)

    /// Hide every app except `target` (Cmd-H), skipping those already hidden — the
    /// "leave only my selection on screen" sweep a commit runs when the setting is on. It
    /// only ever hides OTHER apps: every window of the chosen app stays on screen and the
    /// picked one is simply activated, never minimizing siblings to surface one (Bringr-93j.49).
    /// Runs after `commit` has restored the reveal and ended the session, so these are
    /// deliberate, permanent, user-recoverable changes — not journaled and never auto-undone.
    /// The permanent, outside-a-session counterpart to `hideOtherApps`, which captures a
    /// baseline to restore.
    private func hideEveryAppExcept(_ target: AppID) {
        for app in system.runningApps() where app != target && !system.isHidden(app) {
            system.setHidden(app, true)
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
    /// the active strategy. Hide-others and raise-to-front simply raise the hovered
    /// window — once the other *apps* are already hidden by `revealApp`, isolating
    /// the chosen app's sibling windows adds no benefit and reintroduced every
    /// window-management bug we'd chased (Bringr-93j.81/.28/.32 off-screen height
    /// clamp; Bringr-93j.24 minimize lag), so no strategy parks at the window level
    /// (Bringr-93j.83/.84).
    func revealWindow(_ target: WindowID) {
        switch strategy {
        case .hideOthers, .raiseToFront: raiseWindowToFront(target)
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

    /// Put one app's captured window baseline back: restore minimized-state, then
    /// re-raise back-to-front so the original front window ends up on top.
    private func restoreWindowBaseline(_ windows: [WindowSnapshot]) {
        for snapshot in windows {
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

    /// Restore every app/window touched this session to its pre-summon visibility and
    /// ordering, then end the session. Safe to call with no active session. (AC5)
    func restore(reactivatingFrontmost: Bool = true) {
        guard let session else { return }

        // 0. Remove any dim spotlight first (a no-op for the other strategies).
        dimmer?.clear()

        // 1. App visibility first, so windows are operated on while their app is shown.
        for snapshot in session.appBaseline {
            system.setHidden(snapshot.id, snapshot.wasHidden)
        }

        // 2. Per-app window state: restore minimized-state, re-raise to order.
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
    /// replay it so nothing stays hidden/minimized, then clear it. Returns whether a
    /// stranded reveal was undone; a no-op when the last session restored cleanly.
    @discardableResult
    func restoreFromSnapshotIfNeeded() -> Bool {
        guard let store, let snapshot = store.load() else { return false }
        applySnapshot(snapshot)
        store.clear()
        return true
    }

    /// Put each app/window in `snapshot` back to its pre-summon state in `restore()`'s
    /// order: app visibility first, then re-enumerate each app to repopulate the AX cache
    /// before restoring minimized-state, then the prior frontmost.
    private func applySnapshot(_ snapshot: RevealSnapshot) {
        for app in snapshot.apps {
            system.setHidden(AppID(pid: app.pid), app.wasHidden)
        }
        for pid in Set(snapshot.windows.map(\.pid)) {
            _ = system.windows(of: AppID(pid: pid))
        }
        for window in snapshot.windows {
            let id = WindowID(app: AppID(pid: window.pid), token: window.token)
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
            WindowSnapshot(id: id, wasMinimized: system.isMinimized(id))
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
                    wasMinimized: $0.wasMinimized
                )
            }
        }
        let snapshot = RevealSnapshot(
            frontmostPID: session.frontmostBefore?.pid, apps: apps, windows: windows
        )
        if snapshot.isEmpty { store.clear() } else { store.save(snapshot) }
    }
}
