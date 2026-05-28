import AppKit
import SwiftUI

/// Launch-time alert that walks the user through (re-)granting Accessibility access.
///
/// Dev builds are ad-hoc signed, so every rebuild changes the code signature and
/// macOS TCC revokes the previously granted Accessibility permission. This floating
/// window — separate from Preferences — surfaces the re-grant steps. Because
/// `PermissionsManager` monitors trust live, the window closes itself the instant
/// access is restored (see `PermissionAlertView`), so no relaunch is needed.
///
/// A floating level plus `NSApp.activate(ignoringOtherApps:)` is required for it to
/// come forward from a menu-bar-only (`LSUIElement`) app.
final class PermissionAlertWindow: NSWindow {
    /// `UserDefaults` key backing the optional "Don't show this again" toggle.
    nonisolated static let suppressDefaultsKey = "suppressPermissionAlert"

    @MainActor
    init(permissions: PermissionsManager, onClose: @escaping () -> Void) {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 580),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )

        titlebarAppearsTransparent = true
        titleVisibility = .hidden
        isReleasedWhenClosed = false
        level = .floating

        let rootView = PermissionAlertView(
            permissions: permissions,
            onMoveAside: { [weak self] in self?.moveAside() },
            onClose: onClose
        )
        contentView = NSHostingView(rootView: rootView)

        center()
    }

    /// Slides the window to the left edge so it does not cover the system
    /// Accessibility prompt that appears after the user clicks Grant.
    func moveAside() {
        guard let screen = screen ?? NSScreen.main else { return }
        var frame = self.frame
        frame.origin.x = screen.visibleFrame.minX + 20
        setFrame(frame, display: true, animate: true)
    }
}
