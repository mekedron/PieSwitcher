import CoreGraphics
import Foundation

/// Read-only queries over the navigator's already-built rings — hit-testing, region
/// lookups, the derived concentric geometry, and which app is expanded — split out so
/// `RadialNavigator.swift` stays within the file-length budget. Because they only read
/// the live rings (and the base geometry), the hover and skip decisions they feed stay
/// pure and unit-testable.
extension RadialNavigator {
    /// Whether the windows sub-wheel is open and populated: a level-1 ring carrying at
    /// least one window node. False when an app expansion's live scan momentarily
    /// returned no windows (Bringr-93j.31), which the next hover/retry rebuilds.
    var hasWindowSubWheel: Bool {
        rings.count > 1 && !rings[1].nodes.isEmpty
    }

    /// Whether the windows sub-wheel was deliberately not opened for the expanded app —
    /// the skip-single-window-level case (Bringr-93j.75): the app is expanded (revealed)
    /// but only the apps ring shows. Distinct from the empty-scan race (Bringr-93j.31),
    /// which keeps the empty level-1 ring (so `rings.count == 2`), letting the controller's
    /// retry fire for the race but not for a settled single-window app.
    var subWheelSuppressed: Bool {
        expandedAppIndex != nil && rings.count == 1
    }

    /// Map a cursor `offset` (from the ring centre, +x right / +y down) to the
    /// region it falls in, using each ring's own shared layout. Rings are checked
    /// innermost-first; their bands touch, so at most one slice matches.
    ///
    /// A cursor inside a ring's radial band but over an uncovered angular gap (an
    /// empty outer sector of a partially-filled US-016 window ring) is a no-op: it
    /// returns the current `hovered` region so the sub-wheel stays open, rather than
    /// `.none` which would collapse it. Only the dead centre or a point outside every
    /// band — neither of which is in any ring's band — returns `.none`.
    func region(forOffset offset: CGPoint) -> HoverRegion {
        let distance = hypot(offset.x, offset.y)
        var withinARingBand = false
        for ring in rings {
            if let index = ring.layout.hitTest(offset) {
                return .slice(level: ring.level, index: index)
            }
            if distance >= ring.geometry.innerRadius, distance <= ring.geometry.outerRadius {
                withinARingBand = true
            }
        }
        return withinARingBand ? hovered : .none
    }

    // MARK: - Concentric geometry

    /// Ring band for concentric `level`: each sits just outside the previous, reusing the base
    /// thickness, so level 0 matches the original single ring and the rings touch (no gap).
    func ringGeometry(forLevel level: Int) -> RadialGeometry {
        let thickness = baseGeometry.outerRadius - baseGeometry.innerRadius
        let inner = baseGeometry.innerRadius + CGFloat(level) * thickness
        return RadialGeometry(innerRadius: inner, outerRadius: inner + thickness)
    }

    /// Side length of the square overlay needed to fit every concentric ring at the
    /// current base size and full depth. The controller resizes the pre-warmed window to
    /// this on summon when the appearance changed (US-014) — a resize of the reused
    /// window, not an allocation, so the hot path stays cheap (FR-14).
    var overallDiameter: CGFloat { 2 * ringGeometry(forLevel: maxDepth - 1).outerRadius }

    // MARK: - Expansion state

    /// The app node currently expanded on the apps ring, if any.
    var expandedAppNode: MenuNode? {
        guard let index = expandedAppIndex, let appsRing = rings.first,
              index >= 0, index < appsRing.nodes.count else { return nil }
        return appsRing.nodes[index]
    }

    /// The app currently expanded on the apps ring, if any — the scope window
    /// isolation acts within.
    var expandedAppID: AppID? {
        expandedAppNode?.representedApp
    }
}
