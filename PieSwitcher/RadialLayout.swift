import CoreGraphics
import Foundation

/// Ring dimensions of the radial menu: a central dead zone and an outer edge.
/// US-014 will let the user tune these; v1 ships the defaults.
struct RadialGeometry: Equatable, Sendable {
    /// Radius of the central dead zone. A cursor closer to the centre than this
    /// hits no slice — the cancel region for US-009/US-015.
    let innerRadius: CGFloat
    /// Outer radius of the ring. A cursor farther out than this hits no slice.
    let outerRadius: CGFloat

    static let `default` = RadialGeometry(innerRadius: 110 * 55 / 160, outerRadius: 110)

    /// Mid-ring radius, where a slice's icon/label sits.
    var midRadius: CGFloat { (innerRadius + outerRadius) / 2 }
    /// Side length of the square overlay that bounds the whole ring.
    var diameter: CGFloat { outerRadius * 2 }
}

/// One slice's angular extent: a `start` edge and a `span`, both clockwise from
/// straight up in radians (y-down convention). The slice covers `[start, start +
/// span)`; its centre is `start + span / 2`. Letting every slice carry its own arc
/// is what lets a ring be unevenly divided (the US-016 window sub-wheel) while the
/// apps ring stays an exact equal division.
struct SliceArc: Equatable, Sendable {
    let start: CGFloat
    let span: CGFloat
}

/// Angular layout of slices around a ring, plus hit-testing from a cursor offset.
/// Pure geometry — no AppKit, no SwiftUI — so it is fully unit-tested and the same
/// math drives both rendering (`RadialMenuView`) and selection (US-009+).
///
/// A layout is a table of per-slice arcs. Equal division (`init(itemCount:)`) keeps
/// the v1 convention — slice 0 centred at the top (12 o'clock), slices advancing
/// clockwise, the ring fully covered — while `windowRing(...)` builds the uneven,
/// app-aligned arcs of the US-016 sub-wheel. Offsets and the hit-test point are
/// measured from the ring centre in a y-down space (matching SwiftUI's drawing
/// coordinates): +x right, +y down.
struct RadialLayout: Equatable, Sendable {
    private let arcs: [SliceArc]
    let geometry: RadialGeometry

    /// Number of slices in the ring.
    var itemCount: Int { arcs.count }

    /// Equal division: `itemCount` slices of identical width, slice 0 centred at the
    /// top and the ring fully covered — the v1 apps-ring layout.
    init(itemCount: Int, geometry: RadialGeometry = .default) {
        let count = max(0, itemCount)
        let span = count > 0 ? (2 * CGFloat.pi) / CGFloat(count) : 0
        self.arcs = (0..<count).map { SliceArc(start: CGFloat($0) * span - span / 2, span: span) }
        self.geometry = geometry
    }

    /// An explicit, possibly uneven arc table — the general form behind `windowRing`.
    init(arcs: [SliceArc], geometry: RadialGeometry = .default) {
        self.arcs = arcs
        self.geometry = geometry
    }

    /// Width of the first slice, in radians; zero when empty. For an equal division
    /// every slice has this width, so existing call sites read it as "the" span.
    var sliceSpan: CGFloat { arcs.first?.span ?? 0 }

    /// Angular width of slice `index`, in radians.
    func span(ofSliceAt index: Int) -> CGFloat { arc(at: index).span }

    /// Centre angle of slice `index`, clockwise from straight up, in radians.
    func centerAngle(ofSliceAt index: Int) -> CGFloat {
        let arc = arc(at: index)
        return arc.start + arc.span / 2
    }

    /// Leading edge angle of slice `index`, clockwise from straight up.
    func startAngle(ofSliceAt index: Int) -> CGFloat { arc(at: index).start }

    /// Trailing edge angle of slice `index`, clockwise from straight up.
    func endAngle(ofSliceAt index: Int) -> CGFloat {
        let arc = arc(at: index)
        return arc.start + arc.span
    }

    /// A point at `angle` (clockwise from straight up) and `radius` from the ring
    /// centre, in the y-down drawing space. Up is `(0, -radius)`.
    func ringPoint(angle: CGFloat, radius: CGFloat) -> CGPoint {
        CGPoint(x: radius * sin(angle), y: -radius * cos(angle))
    }

    /// Offset from the ring centre to the mid-ring point of slice `index` — where
    /// that slice's icon/label is placed.
    func sliceCenterOffset(at index: Int) -> CGPoint {
        ringPoint(angle: centerAngle(ofSliceAt: index), radius: geometry.midRadius)
    }

    /// Horizontal cap for a label centred on slice `index`: the chord across the
    /// slice's angular span at the mid-ring radius — the width the label is allowed
    /// before it would overflow into a neighbouring slice (Bringr-93j.92). A
    /// single-line `Text` with this as its `frame(maxWidth:)` truncates with a
    /// trailing ellipsis once it hits the cap, so labels stay inside their slice on
    /// narrow rings (many apps, compressed overflow windows) instead of overflowing.
    /// Slices wider than 180° clamp to the full midRadius diameter, so a single-slice
    /// ring (the apps-vs-windows ratio fallback) doesn't fold to zero width past π.
    func sliceLabelMaxWidth(at index: Int) -> CGFloat {
        let effectiveSpan = min(span(ofSliceAt: index), CGFloat.pi)
        return 2 * geometry.midRadius * sin(effectiveSpan / 2)
    }

    /// The slice a cursor offset falls in, or `nil` for the dead zone, outside the
    /// ring, or an uncovered gap between arcs. `offset` is measured from the ring
    /// centre, +x right / +y down. Containment is modulo-2π so arcs may wrap past the
    /// 12 o'clock seam; an equal division still returns exactly one slice per angle.
    func hitTest(_ offset: CGPoint) -> Int? {
        let distance = hypot(offset.x, offset.y)
        guard distance >= geometry.innerRadius, distance <= geometry.outerRadius else {
            return nil
        }
        // Angle clockwise from straight up: up is (0, -1) → 0; right (1, 0) → π/2.
        let angle = normalized(atan2(offset.x, -offset.y))
        for (index, arc) in arcs.enumerated() where normalized(angle - arc.start) < arc.span {
            return index
        }
        return nil
    }

    /// Arc table for an app's window sub-wheel (US-016): each window slice is as wide
    /// as an app slice and fans clockwise from the parent app, so the sub-wheel reads
    /// as an extension of the app being pointed at instead of re-dividing the circle.
    ///
    /// - `windowCount <= appCount`: each window gets a full app-arc starting at the
    ///   parent's leading edge; window 0 sits over the parent. Any leftover app-arcs
    ///   get no slice (an uncovered gap — `hitTest` returns `nil` there).
    /// - `windowCount > appCount` (overflow fisheye): the focused window keeps a full
    ///   app-arc and the rest compress equally to share the remaining circle, laid out
    ///   clockwise in node order so the focused slice bulges in place.
    /// - `appCount <= 1` (no context arc to share) or a vanishing compressed span:
    ///   fall back to equal division so no slice is zero-width.
    static func windowRing(
        windowCount: Int,
        appCount: Int,
        parentIndex: Int,
        focusedWindowIndex: Int?,
        geometry: RadialGeometry = .default
    ) -> RadialLayout {
        let twoPi = 2 * CGFloat.pi
        guard windowCount > 0 else { return RadialLayout(arcs: [], geometry: geometry) }
        guard appCount > 1 else { return RadialLayout(itemCount: windowCount, geometry: geometry) }

        let appArc = twoPi / CGFloat(appCount)
        let anchorStart = CGFloat(parentIndex) * appArc - appArc / 2

        if windowCount <= appCount {
            let arcs = (0..<windowCount).map {
                SliceArc(start: anchorStart + CGFloat($0) * appArc, span: appArc)
            }
            return RadialLayout(arcs: arcs, geometry: geometry)
        }

        let compressed = (twoPi - appArc) / CGFloat(windowCount - 1)
        guard compressed > 1e-9 else { return RadialLayout(itemCount: windowCount, geometry: geometry) }

        let focus = min(max(focusedWindowIndex ?? 0, 0), windowCount - 1)
        var arcs: [SliceArc] = []
        var cursor = anchorStart
        for slot in 0..<windowCount {
            let span = slot == focus ? appArc : compressed
            arcs.append(SliceArc(start: cursor, span: span))
            cursor += span
        }
        return RadialLayout(arcs: arcs, geometry: geometry)
    }

    /// Wraps `angle` into `[0, 2π)`.
    private func normalized(_ angle: CGFloat) -> CGFloat {
        let twoPi = 2 * CGFloat.pi
        let remainder = angle.truncatingRemainder(dividingBy: twoPi)
        return remainder < 0 ? remainder + twoPi : remainder
    }

    /// Bounds-safe arc lookup: a zero-span arc for an out-of-range index, so the
    /// angle accessors never trap if a caller's index outruns the table.
    private func arc(at index: Int) -> SliceArc {
        guard index >= 0, index < arcs.count else { return SliceArc(start: 0, span: 0) }
        return arcs[index]
    }
}

/// Pure helpers for placing the overlay window: centre it on the cursor. Kept free
/// of AppKit so the math is unit-tested with plain values.
enum RadialMenuPlacement {
    /// Bottom-left origin (AppKit global, y-up) that centres a `windowSize` window
    /// on `cursor` — the global mouse location (`NSEvent.mouseLocation`). Centring
    /// on the cursor places the wheel on whichever display the cursor is over.
    static func windowOrigin(forCursor cursor: CGPoint, windowSize: CGSize) -> CGPoint {
        CGPoint(
            x: cursor.x - windowSize.width / 2,
            y: cursor.y - windowSize.height / 2
        )
    }
}
