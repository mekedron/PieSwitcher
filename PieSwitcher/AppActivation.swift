import AppKit

/// Raises the app and one of its windows after a user action in the status-bar menu.
///
/// A bare `NSApp.activate` straight from a menu action is unreliable here in two ways:
/// - an `.accessory` app's activation request can be refused outright, stranding the
///   just-opened window behind the frontmost app's windows — so
///   `DockIconManager.prepareToShowWindow()` must flip the policy to `.regular` first;
/// - the policy flip and the closing status-bar menu both settle a runloop pass later,
///   and an activation issued in the same pass loses to the menu teardown handing
///   focus back to the previously frontmost app.
///
/// `bringToFront` therefore defers one pass, activates, and raises the window with
/// `orderFrontRegardless()` as well, which keeps it above other apps' windows even
/// when the system still refuses the activation. The window is resolved per attempt —
/// a SwiftUI `openWindow` materialises its `NSWindow` asynchronously — retrying a
/// bounded number of passes until it exists.
@MainActor
enum AppActivation {
    /// Activate the app on the next runloop pass, with no window of our own to raise —
    /// e.g. ahead of Sparkle presenting its own update window.
    static func activate() {
        DispatchQueue.main.async {
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    /// Activate the app and raise the window `window()` resolves to, retrying on
    /// subsequent runloop passes while the window does not exist yet.
    static func bringToFront(
        retriesLeft: Int = 20,
        _ window: @escaping @MainActor () -> NSWindow?
    ) {
        DispatchQueue.main.async {
            NSApp.activate(ignoringOtherApps: true)
            if let window = window() {
                window.makeKeyAndOrderFront(nil)
                window.orderFrontRegardless()
            } else if retriesLeft > 0 {
                bringToFront(retriesLeft: retriesLeft - 1, window)
            }
        }
    }
}
