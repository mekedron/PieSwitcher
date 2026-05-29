import AppKit
import SwiftUI

/// Renders the radial wheel: one concentric ring per navigation level (apps, then
/// the hovered app's windows sub-wheel), each slice drawn as macOS Liquid Glass.
/// The hovered slice is emphasised. No animations — wedges and labels are placed
/// directly from the tested `RadialLayout` geometry.
///
/// The look is deliberately neutral glass rather than a tinted accent: a translucent
/// frosted ring with adaptive (`.primary`) rims and high-contrast labels, so the
/// wheel reads on any desktop without leaning on a saturated colour.
struct RadialMenuView: View {
    @ObservedObject var controller: RadialMenuController

    var body: some View {
        let diameter = controller.overallDiameter

        rings
            .frame(width: diameter, height: diameter)
            .contentShape(Rectangle())
            // A zero-distance drag reports the click location so the controller can map
            // it to a slice (click-to-stay select) or the dead zone (cancel).
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onEnded { value in controller.clickInOverlay(atLocalPoint: value.location) }
            )
    }

    /// Every concentric ring, wrapped in a `GlassEffectContainer` on macOS 26+ so the
    /// per-slice glass blends into one continuous frosted ring and renders efficiently.
    /// Before macOS 26 the same ring stack renders with a material fallback.
    @ViewBuilder
    private var rings: some View {
        if #available(macOS 26.0, *) {
            GlassEffectContainer(spacing: 2) { ringStack }
        } else {
            ringStack
        }
    }

    private var ringStack: some View {
        ZStack {
            ForEach(controller.rings) { ring in
                RadialRingView(
                    ring: ring,
                    hovered: controller.hovered,
                    prehighlighted: controller.prehighlighted,
                    appearance: controller.appearance
                )
            }
        }
    }
}

/// One concentric ring: a glass wedge + label per node. The hovered slice gets the
/// strongest emphasis; a pre-highlighted slice (the app's remembered last selection)
/// gets a medium emphasis so the suggested choice reads before the cursor reaches it
/// (US-012 AC4).
struct RadialRingView: View {
    let ring: RadialRing
    let hovered: HoverRegion
    let prehighlighted: HoverRegion
    let appearance: RadialAppearance

    var body: some View {
        let layout = ring.layout

        ZStack {
            ForEach(Array(ring.nodes.enumerated()), id: \.element.id) { index, node in
                let region = HoverRegion.slice(level: ring.level, index: index)
                let isHovered = hovered == region
                let isPrehighlighted = !isHovered && prehighlighted == region

                RadialGlassWedge(
                    layout: layout,
                    index: index,
                    fillOpacity: appearance.fillOpacity(hovered: isHovered, prehighlighted: isPrehighlighted),
                    emphasis: emphasis(hovered: isHovered, prehighlighted: isPrehighlighted)
                )

                RadialSliceLabel(node: node, index: index, showsLabels: appearance.showsLabels)
                    .offset(
                        x: layout.sliceCenterOffset(at: index).x,
                        y: layout.sliceCenterOffset(at: index).y
                    )
            }
        }
    }

    private func emphasis(hovered: Bool, prehighlighted: Bool) -> RadialGlassWedge.Emphasis {
        if hovered { return .hovered }
        if prehighlighted { return .prehighlighted }
        return .resting
    }
}

/// One slice rendered as Liquid Glass: a translucent glass base clipped to the
/// wedge, a neutral (white) "lit" fill whose strength is the emphasis opacity — so
/// US-014's single opacity knob still tunes the whole resting/pre-highlight/hover
/// ladder — and an adaptive `.primary` rim that separates slices and carries the
/// selection cue independently of the fill's luminance, so it reads in light and
/// dark alike. No accent-blue and no animation. Falls back to `.ultraThinMaterial`
/// before macOS 26.
struct RadialGlassWedge: View {
    enum Emphasis { case resting, prehighlighted, hovered }

    let layout: RadialLayout
    let index: Int
    let fillOpacity: Double
    let emphasis: Emphasis

    var body: some View {
        let shape = RadialWedge(layout: layout, index: index)

        glassBase(in: shape)
            .overlay(shape.fill(Color.white.opacity(fillOpacity)))
            .overlay(shape.stroke(rimColor, lineWidth: rimWidth))
    }

    @ViewBuilder
    private func glassBase(in shape: RadialWedge) -> some View {
        if #available(macOS 26.0, *) {
            Color.clear.glassEffect(.regular, in: shape)
        } else {
            Color.clear.background(.ultraThinMaterial, in: shape)
        }
    }

    /// Adaptive rim: `.primary` flips with the appearance, so the outline always
    /// contrasts the glass beneath. Hover is the strongest cue, pre-highlight next.
    private var rimColor: Color {
        switch emphasis {
        case .resting: return Color.primary.opacity(0.15)
        case .prehighlighted: return Color.primary.opacity(0.5)
        case .hovered: return Color.primary.opacity(0.7)
        }
    }

    private var rimWidth: CGFloat {
        emphasis == .resting ? 1 : 2
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
/// slices show a 1-based index and the (best-effort) title. No live preview. Labels
/// use full-strength `.primary` text with a soft shadow so they stay legible over
/// the translucent glass on any background (the readability goal of this redesign).
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
                        .font(.caption.weight(.medium))
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
        .shadow(color: .black.opacity(0.4), radius: 1.5, y: 0.5)
    }

    @ViewBuilder
    private var appIcon: some View {
        if let icon = node.appSliceIcon {
            Image(nsImage: icon)
                .resizable()
                .frame(width: 32, height: 32)
        } else {
            Image(systemName: "app.dashed")
                .font(.system(size: 28))
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
