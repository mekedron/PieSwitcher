import CoreGraphics
import Foundation

/// Where the cursor currently sits on the (possibly multi-ring) wheel: a slice at
/// a given concentric `level` and `index`, or nothing — the central dead zone or
/// anywhere outside every ring.
enum HoverRegion: Equatable, Sendable {
    case slice(level: Int, index: Int)
    case none
}

/// One concentric ring of the wheel: the menu nodes shown at a given depth, paired
/// with the ring band they occupy. Level 0 is the apps ring; level 1 is the
/// hovered app's windows sub-wheel (US-010).
struct RadialRing: Identifiable {
    let level: Int
    let geometry: RadialGeometry
    let nodes: [MenuNode]

    var id: Int { level }
}

/// Hover-driven navigation through the menu tree, drawn as concentric rings.
///
/// Holds no AppKit window — only the rings to render, the hovered region, and the
/// reveal side effects (through `WindowController`). That keeps the whole drill-in
/// / re-target / collapse policy unit-testable against a fake window system, the
/// same pure-core / thin-shell split as `InteractionStateMachine` and
/// `MouseChordDetector`.
///
/// Nesting is driven by the US-005 tree, not a hard-coded two-level scheme (AC5):
/// expanding a slice appends `node.resolvedChildren()` as the next concentric
/// ring, re-resolved from live state on every (re-)target so the sub-wheel always
/// reflects the app's current windows.
@MainActor
final class RadialNavigator {
    /// Rings to render, innermost first. Empty when the wheel is closed.
    private(set) var rings: [RadialRing] = []
    /// The region the cursor is currently over, for highlighting.
    private(set) var hovered: HoverRegion = .none
    /// Index of the expanded slice on the apps ring, or `nil` when collapsed to
    /// apps-only. Drives re-target detection (hovering the same app is a no-op).
    private(set) var expandedAppIndex: Int?

    private let windowControl: WindowController
    private let baseGeometry: RadialGeometry
    private let maxDepth: Int

    init(
        windowControl: WindowController,
        baseGeometry: RadialGeometry = .default,
        maxDepth: Int = 2
    ) {
        self.windowControl = windowControl
        self.baseGeometry = baseGeometry
        self.maxDepth = max(1, maxDepth)
    }

    // MARK: - Concentric geometry

    /// Ring band for concentric `level`. Each level sits just outside the previous
    /// one, reusing the base ring's thickness, so level 0 matches the single ring
    /// US-006 shipped and the rings touch (no gap to fall through while gliding
    /// outward from an app to its windows).
    func ringGeometry(forLevel level: Int) -> RadialGeometry {
        let thickness = baseGeometry.outerRadius - baseGeometry.innerRadius
        let inner = baseGeometry.innerRadius + CGFloat(level) * thickness
        return RadialGeometry(innerRadius: inner, outerRadius: inner + thickness)
    }

    /// Side length of the square overlay needed to fit every concentric ring at
    /// full depth — the pre-warm size, fixed so a summon never resizes the window.
    var overallDiameter: CGFloat { 2 * ringGeometry(forLevel: maxDepth - 1).outerRadius }

    // MARK: - Lifecycle

    /// Begin a summon: show the apps ring, nothing expanded, nothing revealed.
    func open(appNodes: [MenuNode]) {
        rings = [RadialRing(level: 0, geometry: ringGeometry(forLevel: 0), nodes: appNodes)]
        expandedAppIndex = nil
        hovered = .none
    }

    /// End the interaction: restore every hidden app/window to its pre-summon state
    /// and clear the wheel. Safe with nothing revealed (restore is a no-op then).
    func close() {
        windowControl.restore()
        rings = []
        expandedAppIndex = nil
        hovered = .none
    }

    // MARK: - Hit-testing

    /// Map a cursor `offset` (from the ring centre, +x right / +y down) to the
    /// region it falls in. Rings are checked innermost-first; their bands touch, so
    /// at most one matches.
    func region(forOffset offset: CGPoint) -> HoverRegion {
        for ring in rings {
            let layout = RadialLayout(itemCount: ring.nodes.count, geometry: ring.geometry)
            if let index = layout.hitTest(offset) {
                return .slice(level: ring.level, index: index)
            }
        }
        return .none
    }

    // MARK: - Hover

    /// React to the cursor moving to `region`. On the apps ring this drills into or
    /// re-targets the hovered app; off every ring it collapses back to apps and
    /// restores them. A deeper ring (the windows sub-wheel) leaves the app
    /// expansion untouched — US-011 acts on window hovers.
    func updateHover(_ region: HoverRegion) {
        hovered = region
        switch region {
        case .slice(level: 0, let index):
            expandApp(at: index)
        case .slice:
            break
        case .none:
            collapse()
        }
    }

    // MARK: - Transitions

    /// Isolate the app under the apps-ring slice at `index` and open (or rebuild)
    /// its windows sub-wheel. Re-targeting from another app reuses
    /// `WindowController`'s captured baseline, so a later restore still returns to
    /// the pre-summon state.
    private func expandApp(at index: Int) {
        guard expandedAppIndex != index, let appsRing = rings.first,
              index >= 0, index < appsRing.nodes.count else { return }
        let appNode = appsRing.nodes[index]
        if let appID = appNode.representedApp {
            windowControl.hideOtherApps(besides: appID)
        }
        let subRing = RadialRing(
            level: 1,
            geometry: ringGeometry(forLevel: 1),
            nodes: appNode.resolvedChildren()
        )
        rings = [appsRing, subRing]
        expandedAppIndex = index
    }

    /// Drop the windows sub-wheel and restore the other apps. No-op when already
    /// collapsed, so brushing the dead zone repeatedly costs nothing.
    private func collapse() {
        guard expandedAppIndex != nil else { return }
        windowControl.restore()
        rings = Array(rings.prefix(1))
        expandedAppIndex = nil
    }
}
