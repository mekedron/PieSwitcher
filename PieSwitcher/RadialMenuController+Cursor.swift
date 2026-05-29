import AppKit

/// Read-only cursor helpers for the controller, split out so `RadialMenuController.swift`
/// stays within the file-length budget (mirroring `RadialNavigator+Region.swift`). They only
/// translate a region/point; the sole shared state they touch is the (internal) overlay
/// `window`, read for its frame in `offset(forGlobalCursor:)`. `@MainActor` propagates from
/// the type to these members.
extension RadialMenuController {
    /// Offset from the ring centre for a global (AppKit y-up) cursor, flipped into the
    /// layout's y-down space.
    func offset(forGlobalCursor cursor: CGPoint) -> CGPoint {
        let frame = window.frame
        return CGPoint(x: cursor.x - frame.midX, y: frame.midY - cursor.y)
    }

    /// Offset from the ring centre for a point in the overlay view's local (y-down,
    /// top-left origin) space.
    func offset(forLocalPoint local: CGPoint) -> CGPoint {
        let center = overallDiameter / 2
        return CGPoint(x: local.x - center, y: local.y - center)
    }

    /// Collapse a hover region to the commit vocabulary: any ring slice is a target, the
    /// dead zone / outside is none. The state machine only needs "a slice" vs "none" to pick
    /// select vs cancel; `commitSelection(region:)` reads the live region itself to resolve
    /// which window.
    func sliceTarget(_ region: HoverRegion) -> SliceTarget {
        switch region {
        case .slice(_, let index): return .slice(index)
        case .none: return .none
        }
    }
}
