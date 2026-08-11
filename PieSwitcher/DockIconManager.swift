import AppKit

/// Shows the Dock icon while a standard window is open and hides it again once the
/// last one closes (Bringr-93j.45).
///
/// PieSwitcher ships as an `LSUIElement` accessory — no Dock icon, menu-bar only — which
/// feels off while a normal window like Preferences is up. Flipping the process
/// activation policy to `.regular` gives the app a Dock icon and ordinary window
/// behaviour; `.accessory` returns it to menu-bar-only.
///
/// Reference-counted so concurrent windows can't strand the icon: it appears on the
/// 0→1 edge and hides on the 1→0 edge, leaving the policy untouched in between. The
/// policy call is injected (`@MainActor` closure, live default drives `NSApp`) so the
/// counting logic is unit-testable without mutating the shared application.
@MainActor
final class DockIconManager {
    private let setPolicy: @MainActor (NSApplication.ActivationPolicy) -> Void
    private(set) var openWindowCount = 0

    init(setPolicy: (@MainActor (NSApplication.ActivationPolicy) -> Void)? = nil) {
        self.setPolicy = setPolicy ?? { NSApp.setActivationPolicy($0) }
    }

    /// Call from the user action that is about to open (or raise) a Dock-worthy
    /// window, before the window exists. Flips the policy to `.regular` immediately,
    /// without touching the count: the system can refuse an activation request from
    /// an `.accessory` app, which would strand the new window behind the frontmost
    /// app's windows. The window's own `windowOpened()` still runs on appear;
    /// setting `.regular` twice is harmless.
    func prepareToShowWindow() {
        setPolicy(.regular)
    }

    /// Call when a Dock-worthy window appears. Shows the Dock icon on the first one.
    func windowOpened() {
        openWindowCount += 1
        if openWindowCount == 1 {
            setPolicy(.regular)
        }
    }

    /// Call when a Dock-worthy window closes. Hides the Dock icon once the last one
    /// is gone. A stray close with nothing open is ignored, so an unbalanced
    /// disappear can't underflow the count or wrongly toggle the policy.
    func windowClosed() {
        guard openWindowCount > 0 else { return }
        openWindowCount -= 1
        if openWindowCount == 0 {
            setPolicy(.accessory)
        }
    }
}
