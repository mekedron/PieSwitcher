import CoreGraphics
import Foundation

/// A window discovered at summon time, with the metadata the wheel needs to
/// render and target it. `id` carries the stable, system-assigned window number
/// (stable for the window's lifetime), so a remembered selection (US-012) can be
/// matched across summons.
struct WindowInfo: Equatable, Sendable {
    let id: WindowID
    let title: String

    /// The application that owns this window.
    var app: AppID { id.app }
}

/// An application that currently owns at least one normal, on-screen window,
/// paired with those windows in front-to-back order.
struct AppWindows: Equatable, Sendable {
    let id: AppID
    let name: String
    let windows: [WindowInfo]
}

/// Which apps get real AX-resolved window titles when the CG list leaves a title
/// blank (the normal case under Accessibility-only permission). The AX read is one
/// synchronous IPC round-trip per app, and a busy or unresponsive app can stall it
/// for hundreds of milliseconds — so each `WindowEnumerator.enumerate` read should
/// ask for titles only where a title is actually displayed: nowhere on the apps
/// ring (its slices show app names), and for exactly one app on a windows sub-wheel.
enum AXTitleScope: Equatable, Sendable {
    /// No AX title reads; blank titles fall back to "<App> — Window <N>".
    case none
    /// AX titles for this one app only — the expanded windows sub-wheel.
    case app(pid_t)
    /// AX titles for every app with a blank-titled window.
    case all

    /// Whether this scope wants AX titles for `pid`.
    func includes(_ pid: pid_t) -> Bool {
        switch self {
        case .none: return false
        case .app(let scoped): return scoped == pid
        case .all: return true
        }
    }
}

/// A raw window record straight from the system window list, before any filtering or
/// grouping. Plain values so `WindowEnumerator`'s logic can be exercised with fixtures and
/// never touches the live window server in tests.
///
/// `isOnscreen`/`isMinimized`/`isHidden` classify a record once a broadened (all-windows)
/// query has surfaced windows the current-Space query hides (Bringr-93j.50): `isOnscreen`
/// is the system's "on the active Space, not minimized, not hidden" flag; the other two are
/// stamped by the live source from AX / `NSRunningApplication`. They default to a plain
/// on-screen window, so the current-Space query and existing fixtures need not set them.
struct RawWindow: Equatable, Sendable {
    let windowNumber: Int
    let ownerPID: pid_t
    let ownerName: String
    let title: String
    let layer: Int
    let alpha: Double
    let bounds: CGRect
    let isOnscreen: Bool
    let isMinimized: Bool
    let isHidden: Bool
    /// Whether the owning app's AX window list contains this number — i.e. PieSwitcher can raise/
    /// focus it (Bringr-93j.52). Off-screen records the broadened query surfaces that aren't
    /// AX-backed are phantom helper surfaces (Chrome/Ghostty keep them) you can't focus, so
    /// they're dropped. Defaults true (on-screen windows are real), so fixtures needn't set it.
    let isAXBacked: Bool
    /// Whether the owning app is an ordinary Dock app (`activationPolicy == .regular`); the
    /// switcher drops background/agent/menu-bar-only apps so broadening to all Spaces/screens
    /// no longer floods the ring with them (Bringr-93j.51). Defaults true, so the narrow query
    /// and existing fixtures need not set it.
    let isDockApp: Bool
    /// Whether the owning app is on the user's exclusion list (Bringr-93j.59) — apps that must
    /// never appear in the wheel, matched by bundle id or name in `CGWindowSource`. Defaults
    /// false (nothing excluded), so the empty-list path and existing fixtures need not set it.
    let isIgnored: Bool
    /// Whether the window server reports this window as living on a managed Space (Bringr-93j.54).
    /// This is the cross-Space "is this a real, focusable window" signal: `isAXBacked` can't
    /// keep genuine other-Space windows because `kAXWindowsAttribute` never enumerates other
    /// Spaces, so such a window is AX-absent yet Space-assigned, while a phantom helper surface
    /// is neither. The all-screens path also stamps it for on-screen records, where the same
    /// signal tells a real window from a phantom backing surface (Bringr-93j.60). Defaults false,
    /// so the narrow query and existing fixtures (which keep real off-screen windows via
    /// `isAXBacked`) need not set it; the live source stamps it on the paths that need it.
    let isManagedWindow: Bool

    init(
        windowNumber: Int, ownerPID: pid_t, ownerName: String, title: String,
        layer: Int, alpha: Double, bounds: CGRect,
        isOnscreen: Bool = true, isMinimized: Bool = false, isHidden: Bool = false,
        isAXBacked: Bool = true, isDockApp: Bool = true, isIgnored: Bool = false,
        isManagedWindow: Bool = false
    ) {
        self.windowNumber = windowNumber
        self.ownerPID = ownerPID
        self.ownerName = ownerName
        self.title = title
        self.layer = layer
        self.alpha = alpha
        self.bounds = bounds
        self.isOnscreen = isOnscreen
        self.isMinimized = isMinimized
        self.isHidden = isHidden
        self.isAXBacked = isAXBacked
        self.isDockApp = isDockApp
        self.isIgnored = isIgnored
        self.isManagedWindow = isManagedWindow
    }

    /// A copy carrying the per-window minimized/hidden/AX-backed/managed classification the
    /// live source resolves after the raw list is parsed (Bringr-93j.50 / Bringr-93j.52 /
    /// Bringr-93j.54 / Bringr-93j.60). The Dock-app and ignored stamps are preserved from `self`
    /// (set when the record was first built).
    func classified(
        isMinimized: Bool, isHidden: Bool, isAXBacked: Bool, isManagedWindow: Bool
    ) -> RawWindow {
        RawWindow(
            windowNumber: windowNumber, ownerPID: ownerPID, ownerName: ownerName, title: title,
            layer: layer, alpha: alpha, bounds: bounds,
            isOnscreen: isOnscreen, isMinimized: isMinimized, isHidden: isHidden,
            isAXBacked: isAXBacked, isDockApp: isDockApp, isIgnored: isIgnored,
            isManagedWindow: isManagedWindow
        )
    }
}
