import AppKit

/// Shows and clears the "dim others" spotlight overlay (US-013): a screen-covering
/// dark layer with the revealed window(s) cut out, so the target stays bright while
/// everything around it recedes. Behind a seam so `WindowController`'s dim dispatch
/// is unit-tested with a recording double — the live panel and its cutout drawing
/// have no test hook and are verified by build & run.
@MainActor
protocol Dimming {
    /// Darken the whole desktop except `holes` — the AppKit-global (bottom-left
    /// origin, y-up) frames of the windows being revealed. An empty `holes` dims
    /// everything uniformly, the graceful fallback when a frame can't be resolved.
    func dim(excluding holes: [CGRect])
    /// Remove the dim overlay. Safe to call when nothing is dimmed.
    func clear()
}

/// Live `Dimming` backed by a reused, click-through `NSPanel` floating just below
/// the radial menu and above every normal window. Created lazily on first use (the
/// dim is applied on hover, never on the summon hot path) and reused across summons.
@MainActor
final class LiveDimmer: Dimming {
    /// Darkness of the dimmed area. Fixed for v1 — US-014's appearance knobs tune the
    /// slice fill, not the reveal dim.
    private static let opacity: CGFloat = 0.55

    private var panel: NSPanel?

    func dim(excluding holes: [CGRect]) {
        // Cover the union of every screen so the dim spans the whole virtual desktop;
        // a single panel can be larger than one display.
        let union = NSScreen.screens.reduce(CGRect.null) { $0.union($1.frame) }
        guard !union.isNull else { return }
        let panel = panel ?? makePanel()
        self.panel = panel
        panel.setFrame(union, display: false)
        (panel.contentView as? DimmingContentView)?.update(
            holes: holes, panelFrame: union, opacity: Self.opacity
        )
        panel.orderFront(nil)
    }

    func clear() {
        panel?.orderOut(nil)
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        // Just below the radial menu (`.floating`) but above every normal app window,
        // so the dim covers the others without ever obscuring the wheel.
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue - 1)
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        // Never intercept input: a click on the dim falls through to the app beneath
        // and is handled as a click-outside cancel by the controller's dismiss monitor.
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        panel.contentView = DimmingContentView(frame: .zero)
        return panel
    }
}

/// Fills its bounds with a translucent black, punching transparent holes where the
/// revealed windows sit. Holes arrive in AppKit-global coordinates and are offset
/// into the view's local space; an even-odd winding rule leaves the holes unfilled.
final class DimmingContentView: NSView {
    private var holes: [CGRect] = []
    private var opacity: CGFloat = 0.5

    func update(holes: [CGRect], panelFrame: CGRect, opacity: CGFloat) {
        // The view fills the panel, whose bottom-left corner is the global origin of
        // the covered desktop, so a global rect maps to local by subtracting it.
        self.holes = holes.map { $0.offsetBy(dx: -panelFrame.minX, dy: -panelFrame.minY) }
        self.opacity = opacity
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(rect: bounds)
        for hole in holes {
            path.append(NSBezierPath(rect: hole))
        }
        path.windingRule = .evenOdd
        NSColor.black.withAlphaComponent(opacity).setFill()
        path.fill()
    }
}
