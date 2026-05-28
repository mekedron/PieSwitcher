import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

/// Accessibility SPI that returns the `CGWindowID` (i.e. `kCGWindowNumber`) backing
/// an `AXUIElement` window. It is the only reliable way to map an AX window element
/// to the stable window number the enumeration service (US-003) keys on, so the two
/// subsystems can agree on one `WindowID` token. Declared by symbol name; resolves
/// against the already-linked Accessibility framework. The caller treats a failure
/// as "no number" and falls back, so an absent symbol degrades rather than crashes.
@_silgen_name("_AXUIElementGetWindow")
private func axUIElementGetWindow(
    _ element: AXUIElement,
    _ windowID: UnsafeMutablePointer<CGWindowID>
) -> AXError

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
    private var session: Session?

    init(system: WindowControlling? = nil) {
        self.system = system ?? LiveWindowSystem()
    }

    /// Whether a capture/restore session is currently open.
    var hasActiveSession: Bool { session != nil }

    // MARK: - Primitives

    /// Raise `window` and move focus to it: activate its app, bring the window
    /// to the front, and make it main/focused. (AC1)
    func raiseAndFocus(_ window: WindowID) {
        system.activate(window.app)
        system.raise(window)
        system.focusWindow(window)
    }

    /// Commit `window` as the user's choice (US-012): first restore every app and
    /// window moved out of the way to its pre-summon state (AC2), then make
    /// `window` visible, raise it, and focus it so the chosen window ends up
    /// frontmost and active (AC1).
    ///
    /// Restoring before raising matters: `restore()` re-activates the prior
    /// frontmost app last, so it must run *before* the raise/focus or it would
    /// override the focus the user just asked for. The explicit un-minimize covers
    /// the case where the chosen window was itself minimized before the summon —
    /// the user picked it, so it should surface regardless of its prior state.
    func commit(_ window: WindowID) {
        restore()
        system.setMinimized(window, false)
        raiseAndFocus(window)
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
    func restore() {
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

        // 3. Frontmost app last, restoring app-level z-order and focus.
        if let frontmost = session.frontmostBefore {
            system.activate(frontmost)
        }

        self.session = nil
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
    }

    private func captureWindowBaselineIfNeeded(for app: AppID) {
        if session == nil { session = Session() }
        guard session?.windowBaseline[app] == nil else { return }
        session?.windowBaseline[app] = system.windows(of: app).map {
            WindowSnapshot(id: $0, wasMinimized: system.isMinimized($0))
        }
    }
}

/// Live `WindowControlling` backed by `NSRunningApplication` (app visibility and
/// activation) and the Accessibility API (per-window state and control).
///
/// Hiding a single window uses AX minimize, the only reversible per-window hide
/// the API offers; `restore()` un-minimizes it. AX element references are cached
/// by `WindowID` as windows are enumerated.
@MainActor
final class LiveWindowSystem: WindowControlling {
    private var elementCache: [WindowID: AXUIElement] = [:]
    private let selfPID = ProcessInfo.processInfo.processIdentifier

    func runningApps() -> [AppID] {
        NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular && $0.processIdentifier != selfPID }
            .map { AppID(pid: $0.processIdentifier) }
    }

    func windows(of app: AppID) -> [WindowID] {
        let appElement = AXUIElementCreateApplication(app.pid)
        guard let axWindows = copyWindows(appElement) else { return [] }

        var ids: [WindowID] = []
        for (index, axWindow) in axWindows.enumerated() {
            // Key on the stable CG window number so a target coming from the
            // enumeration service resolves to this AX element; fall back to the
            // enumeration index only if the SPI cannot report a number.
            let id = WindowID(app: app, token: windowNumber(of: axWindow) ?? index)
            elementCache[id] = axWindow
            ids.append(id)
        }
        return ids
    }

    func frontmostApp() -> AppID? {
        guard let app = NSWorkspace.shared.frontmostApplication,
              app.processIdentifier != selfPID else { return nil }
        return AppID(pid: app.processIdentifier)
    }

    func isHidden(_ app: AppID) -> Bool {
        runningApplication(app)?.isHidden ?? false
    }

    func setHidden(_ app: AppID, _ hidden: Bool) {
        guard let running = runningApplication(app) else { return }
        if hidden {
            running.hide()
        } else {
            running.unhide()
        }
    }

    func activate(_ app: AppID) {
        runningApplication(app)?.activate()
    }

    func isMinimized(_ window: WindowID) -> Bool {
        guard let element = elementCache[window] else { return false }
        return boolAttribute(element, kAXMinimizedAttribute)
    }

    func setMinimized(_ window: WindowID, _ minimized: Bool) {
        guard let element = elementCache[window] else { return }
        setBool(element, kAXMinimizedAttribute, minimized)
    }

    func raise(_ window: WindowID) {
        guard let element = elementCache[window] else { return }
        AXUIElementPerformAction(element, kAXRaiseAction as CFString)
    }

    func focusWindow(_ window: WindowID) {
        guard let element = elementCache[window] else { return }
        setBool(element, kAXMainAttribute, true)
        setBool(element, kAXFocusedAttribute, true)
    }

    // MARK: - Helpers

    private func runningApplication(_ app: AppID) -> NSRunningApplication? {
        NSRunningApplication(processIdentifier: app.pid)
    }

    /// The `kCGWindowNumber` backing an AX window element, or `nil` if the
    /// Accessibility SPI cannot report it.
    private func windowNumber(of element: AXUIElement) -> Int? {
        var windowID: CGWindowID = 0
        let result = axUIElementGetWindow(element, &windowID)
        return result == .success ? Int(windowID) : nil
    }

    private func copyWindows(_ appElement: AXUIElement) -> [AXUIElement]? {
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(
            appElement, kAXWindowsAttribute as CFString, &value
        )
        guard result == .success else { return nil }
        return value as? [AXUIElement]
    }

    private func boolAttribute(_ element: AXUIElement, _ attribute: String) -> Bool {
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
        guard result == .success, let boolValue = value as? Bool else { return false }
        return boolValue
    }

    private func setBool(_ element: AXUIElement, _ attribute: String, _ value: Bool) {
        let cfValue: CFBoolean = value ? kCFBooleanTrue : kCFBooleanFalse
        AXUIElementSetAttributeValue(element, attribute as CFString, cfValue)
    }
}
