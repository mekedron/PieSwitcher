import AppKit
import SwiftUI

/// Renders the radial wheel as three strictly separated z-layers, in this order:
///
///   1. **Glass backdrop** — one continuous Liquid Glass shape *per ring* (the union
///      of that ring's wedges), blended in a single `GlassEffectContainer`.
///   2. **Structure + emphasis** — per-slice hairline separators and the hover /
///      pre-highlight cue, drawn on top of the glass.
///   3. **Content** — app icons and labels, drawn last so they are always sharp.
///
/// The layering is load-bearing, not cosmetic. Liquid Glass *blurs whatever is behind
/// it*, and a `GlassEffectContainer` *merges adjacent glass shapes at rest*. The prior
/// design applied `.glassEffect` per wedge and interleaved each wedge with its label,
/// so (a) 8+ touching wedge-glasses morphed into one another — a stray wedge bulged
/// out of the ring — and (b) every icon sat *behind* a neighbouring wedge's glass and
/// was smeared. Collapsing each ring to a single glass shape removes the merge, and
/// hoisting all content above all glass keeps icons and text crisp.
///
/// No animations. Wedge geometry comes straight from the tested `RadialLayout`, shared
/// with hit-testing, so rendering and selection can never desync.
struct RadialMenuView: View {
    @ObservedObject var controller: RadialMenuController

    var body: some View {
        let diameter = controller.overallDiameter

        ZStack {
            glass
            emphasis
            content
        }
        .frame(width: diameter, height: diameter)
        .contentShape(Rectangle())
        // A zero-distance drag reports the click location so the controller can map
        // it to a slice (click-to-stay select) or the dead zone (cancel).
        .gesture(
            DragGesture(minimumDistance: 0)
                .onEnded { value in controller.clickInOverlay(atLocalPoint: value.location) }
        )
    }

    /// Layer 1 — the glass. One shape per ring keeps each ring a *single* glass
    /// element, so the container only ever blends the (concentric, abutting) ring
    /// annuli into one continuous frosted surface — never a field of wedges that
    /// morph apart. A cohesive drop shadow seats the whole wheel as a floating glass
    /// object so its silhouette reads on any desktop.
    private var glass: some View {
        glassRings.shadow(color: .black.opacity(0.28), radius: 10, y: 3)
    }

    @ViewBuilder
    private var glassRings: some View {
        if #available(macOS 26.0, *) {
            GlassEffectContainer(spacing: 0) {
                ForEach(controller.rings) { ring in RadialRingGlass(ring: ring) }
            }
        } else {
            ZStack {
                ForEach(controller.rings) { ring in RadialRingGlass(ring: ring) }
            }
        }
    }

    /// Layer 2 — per-slice separators and the hover / pre-highlight cue, above the
    /// glass and below the content.
    private var emphasis: some View {
        ZStack {
            ForEach(controller.rings) { ring in
                RadialRingEmphasis(
                    ring: ring,
                    hovered: controller.hovered,
                    prehighlighted: controller.prehighlighted,
                    appearance: controller.appearance
                )
            }
        }
    }

    /// Layer 3 — sharp icons and labels, on top of everything so the glass never
    /// blurs them.
    private var content: some View {
        ZStack {
            ForEach(controller.rings) { ring in
                RadialRingContent(ring: ring, showsLabels: controller.appearance.showsLabels)
            }
        }
    }
}

/// The Liquid Glass backdrop for one ring: glass clipped to the union of that ring's
/// wedges (an annulus, or annulus-with-gaps for an uneven window sub-wheel), so it is
/// exactly one glass element. `Color.clear` carries the effect because glass is a
/// backdrop layer, independent of content alpha. Falls back to `.ultraThinMaterial`
/// before macOS 26.
struct RadialRingGlass: View {
    let ring: RadialRing

    var body: some View {
        let shape = RadialRingShape(layout: ring.layout)
        if #available(macOS 26.0, *) {
            Color.clear.glassEffect(.regular, in: shape)
        } else {
            Color.clear.background(.ultraThinMaterial, in: shape)
        }
    }
}

/// One ring's structure and emphasis, drawn over the glass: every slice gets a faint
/// adaptive hairline so the wheel reads as discrete slices, and the hovered (then
/// pre-highlighted) slice gets a brighter `.primary` rim plus a stronger "lit" white
/// fill. The fill strength is the *unchanged* `RadialAppearance` opacity ladder, so
/// US-014's single opacity knob still tunes resting/pre-highlight/hover together. The
/// rim is adaptive `.primary` (flips with light/dark) so the selection cue contrasts
/// the glass in either appearance; both fill and rim are clipped to the wedge, so the
/// cue can never spill past the slice it marks.
struct RadialRingEmphasis: View {
    let ring: RadialRing
    let hovered: HoverRegion
    let prehighlighted: HoverRegion
    let appearance: RadialAppearance

    var body: some View {
        ZStack {
            ForEach(ring.nodes.indices, id: \.self) { index in
                let region = HoverRegion.slice(level: ring.level, index: index)
                let isHovered = hovered == region
                let isPrehighlighted = !isHovered && prehighlighted == region
                let wedge = RadialWedge(layout: ring.layout, index: index)

                wedge.fill(Color.white.opacity(
                    appearance.fillOpacity(hovered: isHovered, prehighlighted: isPrehighlighted)
                ))
                wedge.stroke(
                    rimColor(hovered: isHovered, prehighlighted: isPrehighlighted),
                    lineWidth: rimWidth(hovered: isHovered, prehighlighted: isPrehighlighted)
                )
            }
        }
    }

    private func rimColor(hovered: Bool, prehighlighted: Bool) -> Color {
        if hovered { return Color.primary.opacity(0.85) }
        if prehighlighted { return Color.primary.opacity(0.5) }
        return Color.primary.opacity(0.14)
    }

    private func rimWidth(hovered: Bool, prehighlighted: Bool) -> CGFloat {
        if hovered { return 2 }
        if prehighlighted { return 1.5 }
        return 0.75
    }
}

/// One ring's content: an icon/label per node, placed at its slice's mid-ring point
/// and rendered last so the glass never blurs it.
struct RadialRingContent: View {
    let ring: RadialRing
    let showsLabels: Bool

    var body: some View {
        ZStack {
            ForEach(Array(ring.nodes.enumerated()), id: \.element.id) { index, node in
                RadialSliceLabel(node: node, index: index, showsLabels: showsLabels)
                    .offset(
                        x: ring.layout.sliceCenterOffset(at: index).x,
                        y: ring.layout.sliceCenterOffset(at: index).y
                    )
            }
        }
    }
}

/// The union of a ring's wedges, used as the single glass clip-shape for that ring.
/// Built by summing the tested `RadialWedge` paths, so the glass edge lands exactly on
/// the same geometry the slices and hit-testing use.
struct RadialRingShape: Shape {
    let layout: RadialLayout

    func path(in rect: CGRect) -> Path {
        var path = Path()
        for index in 0..<layout.itemCount {
            path.addPath(RadialWedge(layout: layout, index: index).path(in: rect))
        }
        return path
    }
}

/// A pie wedge for one slice, built by sampling the tested `RadialLayout.ringPoint`
/// math so it stays in lock-step with hit-testing and needs no SwiftUI arc-angle
/// conversion.
struct RadialWedge: Shape {
    let layout: RadialLayout
    let index: Int

    func path(in rect: CGRect) -> Path {
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let start = layout.startAngle(ofSliceAt: index)
        let end = layout.endAngle(ofSliceAt: index)
        let segments = max(2, Int((end - start) / (CGFloat.pi / 90)))

        var path = Path()
        for segment in 0...segments {
            let angle = start + (end - start) * CGFloat(segment) / CGFloat(segments)
            let point = layout.ringPoint(angle: angle, radius: layout.geometry.outerRadius)
            let placed = CGPoint(x: center.x + point.x, y: center.y + point.y)
            if segment == 0 { path.move(to: placed) } else { path.addLine(to: placed) }
        }
        for segment in 0...segments {
            let angle = end - (end - start) * CGFloat(segment) / CGFloat(segments)
            let point = layout.ringPoint(angle: angle, radius: layout.geometry.innerRadius)
            path.addLine(to: CGPoint(x: center.x + point.x, y: center.y + point.y))
        }
        path.closeSubpath()
        return path
    }
}

/// Placeholder slice content for v1: app slices show the app icon and name; window
/// slices show a 1-based index and the (best-effort) title. No live preview. Content
/// sits in the top z-layer (never behind glass) and carries a soft shadow, so icons
/// and text stay sharp and legible over the translucent ring on any background.
struct RadialSliceLabel: View {
    let node: MenuNode
    let index: Int
    /// When false (US-014 label-visibility off), the text title is hidden; the app
    /// icon and the window index number stay so slices remain identifiable.
    let showsLabels: Bool

    var body: some View {
        VStack(spacing: 4) {
            if node.representsApp {
                appIcon
                if showsLabels {
                    Text(node.title)
                        .font(.caption.weight(.semibold))
                        .lineLimit(1)
                        .foregroundStyle(.primary)
                }
            } else {
                Text("\(index + 1)")
                    .font(.title3.weight(.bold).monospacedDigit())
                    .foregroundStyle(.primary)
                if showsLabels {
                    Text(node.title)
                        .font(.caption2.weight(.medium))
                        .lineLimit(1)
                        .foregroundStyle(.primary)
                }
            }
        }
        .frame(maxWidth: 84)
        .shadow(color: .black.opacity(0.55), radius: 2, y: 0.5)
    }

    @ViewBuilder
    private var appIcon: some View {
        if let icon = node.appSliceIcon {
            Image(nsImage: icon)
                .resizable()
                .interpolation(.high)
                .frame(width: 34, height: 34)
                .shadow(color: .black.opacity(0.35), radius: 2.5, y: 1)
        } else {
            Image(systemName: "app.dashed")
                .font(.system(size: 30))
                .foregroundStyle(.primary)
        }
    }
}

extension MenuNode {
    /// The icon for an app slice: the running app's live icon, looked up by pid — the
    /// pre-My-Apps behavior, unchanged — falling back to the on-disk bundle icon by
    /// bundle id for a curated app that isn't running (Bringr-93j.38). `nil` when neither
    /// resolves, so the view shows a generic placeholder. Pure system lookups, so the
    /// fallback is exercised in tests against an always-installed app.
    var appSliceIcon: NSImage? {
        if let pid = representedApp?.pid,
           let icon = NSRunningApplication(processIdentifier: pid)?.icon {
            return icon
        }
        if let bundleIdentifier,
           let url = CuratedApp.bundleURL(forBundleIdentifier: bundleIdentifier) {
            return NSWorkspace.shared.icon(forFile: url.path)
        }
        return nil
    }
}
