import AppKit
import SwiftUI

// MARK: - Window

/// The onboarding window (Bringr-93j.112). A normal movable key window — not a
/// floating panel like `PermissionAlertWindow` — so it behaves like the
/// Preferences window does after `dockIcon.windowOpened()` flips PieSwitcher
/// into a windowed app. `isReleasedWhenClosed` is off so the presenter can keep
/// a single instance and re-use it across "Show Welcome…" clicks.
final class OnboardingWindow: NSWindow {
    @MainActor
    init(rootView: OnboardingRootView) {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 560),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        title = "Welcome to PieSwitcher"
        isReleasedWhenClosed = false
        contentView = NSHostingView(rootView: rootView)
        // Center on the screen where the cursor sits so a multi-monitor user
        // sees the window on the display they're looking at.
        center()
    }
}

// MARK: - Presenter

/// Owns the single onboarding-window instance and the show/hide lifecycle
/// (Bringr-93j.112). Two entry points feed it: `AppDelegate` calls
/// `showOnAutoOpenIfNeeded()` at launch (no-op when the user has already seen
/// it) and the status-bar menu calls `showFromMenu()` whenever the user picks
/// "Show Welcome…". Both paths route through `show()` so a re-click brings the
/// existing window to front instead of stacking duplicates (AC).
///
/// `DockIconManager` is reused so opening the onboarding promotes PieSwitcher
/// to a windowed app (Dock icon visible) while it's open, then hides it again
/// when the last window closes — matching the existing Preferences behavior.
@MainActor
final class OnboardingPresenter {
    private let permissions: PermissionsManager
    private let dockIcon: DockIconManager
    private var window: OnboardingWindow?
    private var closeObserver: (any NSObjectProtocol)?
    /// Open the window if the user has not yet been onboarded. Called from
    /// `AppDelegate.applicationDidFinishLaunching`.
    ///
    /// `delayedBy` lets the caller defer the auto-open a tick so the status-bar
    /// icon appears first; live, this is 0.4s, which feels like "the app
    /// finished launching" without being long enough for the user to start
    /// using the menu bar.
    init(permissions: PermissionsManager, dockIcon: DockIconManager) {
        self.permissions = permissions
        self.dockIcon = dockIcon
    }

    deinit {
        if let closeObserver {
            NotificationCenter.default.removeObserver(closeObserver)
        }
    }

    /// Whether the window is currently on screen. Inspected by tests so a
    /// re-click doesn't stack duplicates.
    var isShown: Bool { window?.isVisible ?? false }

    /// Auto-open path: only opens when the user has not yet completed
    /// onboarding. Idempotent — a second call when the flag is already set
    /// becomes a no-op, so a relaunch during the same login session never
    /// re-pops the window.
    func showOnAutoOpenIfNeeded() {
        guard OnboardingState.shouldAutoOpen() else { return }
        // Defer one runloop tick so `MenuBarExtra` finishes installing the
        // status-bar icon before the window steals key. Without the delay the
        // window appears in the centre of the screen with no anchor, which
        // looks like a popup; with it the icon flashes in first, then the
        // window appears, which reads as "the app finished launching".
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            self?.show()
        }
    }

    /// "Show Welcome…" path: always shows the window, no completed-flag check.
    /// Re-clicking brings the existing window to front (AC: "Multiple clicks
    /// on 'Show Welcome…' do not stack multiple onboarding windows").
    func showFromMenu() {
        show()
    }

    /// Shared open path. Creates the window on first use, brings it to front,
    /// promotes the app to a windowed app via `dockIcon`, and marks onboarding
    /// as seen so the next launch's auto-open path becomes a no-op.
    private func show() {
        if window == nil {
            window = OnboardingWindow(rootView: OnboardingRootView(
                permissions: permissions,
                onFinish: { [weak self] in self?.finish() }
            ))
            if let window {
                closeObserver = NotificationCenter.default.addObserver(
                    forName: NSWindow.willCloseNotification,
                    object: window,
                    queue: .main
                ) { [weak self] _ in
                    MainActor.assumeIsolated { self?.handleWindowClosed() }
                }
                dockIcon.windowOpened()
            }
        }

        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
        // Mark seen the moment the window appears (not when "Done" is clicked)
        // so a user who closes early still doesn't get re-prompted next launch.
        OnboardingState.markSeen()
    }

    /// "Done" path: dismiss and let `handleWindowClosed` clean up.
    private func finish() {
        window?.close()
    }

    private func handleWindowClosed() {
        if let closeObserver {
            NotificationCenter.default.removeObserver(closeObserver)
            self.closeObserver = nil
        }
        window = nil
        dockIcon.windowClosed()
    }
}
