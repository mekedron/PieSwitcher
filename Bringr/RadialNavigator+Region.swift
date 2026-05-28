import CoreGraphics
import Foundation

/// Read-only hit-testing and region queries over the navigator's already-built rings,
/// split out so `RadialNavigator.swift` stays within the file-length budget. Because
/// they only read the live rings, the hover and cursor-lock decisions they feed stay
/// pure and unit-testable.
extension RadialNavigator {
    /// Whether the windows sub-wheel is open and populated: a level-1 ring carrying at
    /// least one window node. False when an app expansion's live scan momentarily
    /// returned no windows (Bringr-93j.31), which the next hover/retry rebuilds.
    var hasWindowSubWheel: Bool {
        rings.count > 1 && !rings[1].nodes.isEmpty
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

    /// Whether `offset` lies inside the cursor-lock region while the second-level lock
    /// is engaged (Bringr-93j.29): any window-ring (level 1) slice — including its
    /// angular slack, since `region` keeps reporting the open sub-wheel over an
    /// uncovered outer gap — or the parent app arc on the apps ring (level 0). Every
    /// other app arc, the dead centre, and anywhere outside the rings fall outside, so
    /// the controller snaps the pointer back there. Pure geometry over the live rings,
    /// so the confinement boundary is deterministic and unit-tested.
    func offsetWithinCursorLockRegion(_ offset: CGPoint) -> Bool {
        switch region(forOffset: offset) {
        case .slice(level: 1, _):
            return true
        case .slice(level: 0, let index):
            return index == expandedAppIndex
        case .slice, .none:
            return false
        }
    }
}
