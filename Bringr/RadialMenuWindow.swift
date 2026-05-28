import AppKit
import SwiftUI

/// Pre-warmed overlay that hosts the radial wheel. Created once at launch and
/// shown/hidden — never rebuilt on the summon hot path (the < 16 ms budget).
///
/// A borderless, transparent, non-activating floating panel: it floats above the
/// app the user summoned it over without activating Bringr or deactivating that
/// app — which would disturb the very window state the switcher must preserve.
final class RadialMenuWindow: NSPanel {
    @MainActor
    init(contentSize: CGSize) {
        super.init(
            contentRect: NSRect(origin: .zero, size: contentSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = .floating
        isFloatingPanel = true
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        // Ask for cursor-move events so the overlay's local monitor has something to
        // catch in click-to-stay, where moves are delivered to us rather than the app
        // underneath (see `RadialMenuController.startMenuMonitors`).
        acceptsMouseMovedEvents = true
    }
}

/// Indirection over AppKit's event-monitor calls so the while-open monitor wiring is
/// unit-testable. Production wires `NSEvent`'s global *and* local monitors; a test
/// injects a recorder to assert hover gets both — the regression here was a
/// global-only hover monitor, which never fires for cursor moves the window server
/// routes to our own overlay (the click-to-stay case).
struct EventMonitorInstaller {
    /// Passive monitor for events sent to *other* apps. Returns an opaque token.
    var addGlobal: (NSEvent.EventTypeMask, @escaping (NSEvent) -> Void) -> Any?
    /// Monitor for events sent to *this* app; the handler returns the event to pass
    /// it through (or nil to consume it). Returns an opaque token.
    var addLocal: (NSEvent.EventTypeMask, @escaping (NSEvent) -> NSEvent?) -> Any?
    /// Tears down a monitor created by either installer.
    var remove: (Any) -> Void

    static let live = EventMonitorInstaller(
        addGlobal: { NSEvent.addGlobalMonitorForEvents(matching: $0, handler: $1) },
        addLocal: { NSEvent.addLocalMonitorForEvents(matching: $0, handler: $1) },
        remove: { NSEvent.removeMonitor($0) }
    )
}
