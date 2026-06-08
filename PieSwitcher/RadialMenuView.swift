import AppKit
import SwiftUI

/// Renders the radial wheel as three strictly separated z-layers, in this order:
///
///   1. **Glass backdrop** — ONE Liquid Glass element for the whole wheel, clipped to
///      the union of *every* visible ring's wedges, pinned to the overlay's fixed
///      square.
///   2. **Structure + emphasis** — per-slice hairline separators and the hover /
///      pre-highlight cue, drawn on top of the glass.
///   3. **Content** — app icons and labels, drawn last so they are always sharp.
///
/// The layering is load-bearing, not cosmetic. Liquid Glass *blurs whatever is behind
/// it*, and a `GlassEffectContainer` *merges adjacent glass shapes at rest* and
/// re-anchors that merged capsule whenever a glass child is added or removed. A prior
/// design gave each ring its own glass element, so the moment hover added the windows
/// sub-wheel the container re-anchored and the apps ring visibly jumped. Using a single
/// element whose *shape grows* — from the apps annulus to apps-plus-windows — leaves
/// nothing to re-anchor, so the wheel stays put on hover. Hoisting all content above
/// all glass keeps icons and text crisp (glass can't refract what sits in front of it).
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
            dwell
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

    /// Layer 1 — the glass. A SINGLE glass element clipped to the union of every
    /// visible ring's wedges and pinned to the overlay's fixed square, so its shape
    /// (and therefore its centre) never moves as rings come and go — only grows from
    /// the apps annulus to apps-plus-windows. A cohesive drop shadow seats the whole
    /// wheel as a floating glass object so its silhouette reads on any desktop.
    private var glass: some View {
        RadialGlassBackdrop(
            shape: RadialGlassShape(layouts: controller.rings.map(\.layout)),
            style: controller.appearance.glassStyle,
            tint: controller.appearance.glassTint.tintColor,
            fallbackMaterial: controller.appearance.offMaterialThickness.material
        )
        .frame(width: controller.overallDiameter, height: controller.overallDiameter)
        .shadow(color: .black.opacity(controller.appearance.glassShadowOpacity), radius: 12, y: 4)
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
                    appearance: controller.appearance,
                    highlightSource: controller.highlightSource
                )
            }
        }
    }

    /// Layer 3 — sharp icons and labels, on top of everything so the glass never
    /// blurs them.
    private var content: some View {
        ZStack {
            ForEach(controller.rings) { ring in
                RadialRingContent(
                    ring: ring,
                    showsAppLabels: controller.appearance.showsAppLabels,
                    showsWindowLabels: controller.appearance.showsWindowLabels,
                    shadowOpacity: controller.appearance.contentShadowOpacity
                )
            }
        }
    }

    /// Layer 4 — the dwell-to-activate progress arc (Bringr-93j.105), drawn last so it
    /// reads as a foreground cue on top of every other layer. Only the dwelt slice gets
    /// an arc; every other slice draws nothing. The arc lives on the slice's own outer
    /// border so the user sees the activation about to fire right where they're aiming,
    /// parallel to the cursor-centred ring in Bringr-93j.103.
    private var dwell: some View {
        ZStack {
            ForEach(controller.rings) { ring in
                RadialRingDwellOverlay(
                    ring: ring,
                    dwellRegion: controller.dwellRegion,
                    progress: controller.dwellProgress
                )
            }
        }
        .allowsHitTesting(false)
    }
}

/// The wheel's single Liquid Glass backdrop, clipped to `shape` (the union of every
/// visible ring's wedges). `Color.clear` carries the genuine material on macOS 26+
/// because glass is a backdrop layer, independent of content alpha. The Appearance
/// picker (Bringr-93j.115) chooses the variant: `.clear` is the most see-through and
/// the shipped default; `.regular` is Apple's heavier frosted variant; `.off` — and any
/// OS before macOS 26, which has no Liquid Glass — falls back to a frosted
/// `.ultraThinMaterial` in the same shape, lifted with a soft top-down sheen so the
/// wheel still reads as a defined translucent object rather than a flat blur. The
/// off path reuses that fallback verbatim, so it doubles as a way to preview the
/// pre-macOS-26 look on a current OS.
struct RadialGlassBackdrop: View {
    let shape: RadialGlassShape
    /// US-014 / Bringr-93j.115: which Liquid Glass variant to render, or off for the
    /// frosted fallback (forced on macOS < 26, where Liquid Glass doesn't exist).
    let style: RadialGlassStyle

    /// Tint applied to the genuine Liquid Glass material via `Glass.tint(...)`. `nil` when
    /// the user's tint has alpha 0, so the wheel renders untinted on the no-tint default.
    let tint: Color?
    /// Material picked for the `.off` fallback path (Bringr-93j.117). The five SwiftUI
    /// materials run from light to heavy blur, so Off mode acts as a real blur knob.
    let fallbackMaterial: Material

    var body: some View {
        if #available(macOS 26.0, *), style != .off {
            GlassEffectContainer(spacing: 0) {
                Color.clear.glassEffect(style.glass.tint(tint), in: shape)
            }
        } else {
            shape
                .fill(fallbackMaterial)
                .overlay(
                    LinearGradient(
                        colors: [.white.opacity(0.16), .white.opacity(0.02)],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                    .clipShape(shape)
                )
        }
    }
}

/// Bridge between the pure-value `RadialColor` and SwiftUI `Color` (Bringr-93j.117).
/// The model has no SwiftUI dependency by design, so the conversion lives here next to
/// the only renderer that needs it.
extension Color {
    init(_ color: RadialColor) {
        self.init(.sRGB, red: color.red, green: color.green, blue: color.blue, opacity: color.alpha)
    }
}

extension RadialColor {
    /// `nil` when alpha is 0 — so the `Glass.tint(nil)` no-tint path is hit instead of
    /// tinting with a transparent colour, which renders subtly differently.
    var tintColor: Color? {
        alpha == 0 ? nil : Color(self)
    }
}

extension RadialMaterialThickness {
    /// The SwiftUI `Material` that backs each picker step — light to heavy blur.
    var material: Material {
        switch self {
        case .ultraThin: return .ultraThinMaterial
        case .thin: return .thinMaterial
        case .regular: return .regularMaterial
        case .thick: return .thickMaterial
        case .ultraThick: return .ultraThickMaterial
        }
    }
}

@available(macOS 26.0, *)
private extension RadialGlassStyle {
    /// The `SwiftUI.Glass` variant that backs this picker option. `.off` is unused —
    /// `RadialGlassBackdrop` branches on `style == .off` *before* asking for a Glass,
    /// so this returns the safe identity in that case rather than crashing.
    var glass: Glass {
        switch self {
        case .clear: return .clear
        case .regular: return .regular
        case .off: return .identity
        }
    }
}

/// The union of every visible ring's wedges — the single clip-shape for the wheel's one
/// glass element. Composed from the per-ring `RadialRingShape` (itself the union of that
/// ring's tested `RadialWedge` paths), so the glass edge lands on exactly the geometry
/// the slices and hit-testing use, and the apps annulus and the windows arc read as one
/// continuous, concentric glass surface. Because every wedge is drawn from the same ring
/// centre, the union stays centred whatever rings are present, so the glass never shifts.
struct RadialGlassShape: Shape {
    /// One layout per visible ring (apps, then the hovered app's windows), innermost
    /// first; empty when the wheel is closed.
    let layouts: [RadialLayout]

    func path(in rect: CGRect) -> Path {
        var path = Path()
        for layout in layouts {
            path.addPath(RadialRingShape(layout: layout).path(in: rect))
        }
        return path
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
    /// Whether the hovered slice was reached by keyboard (Bringr-93j.71): keyboard focus reuses
    /// the same emphasis but swaps the white "lit" cue for an accent-coloured one, so it reads
    /// clearly as keyboard focus rather than mouse hover.
    let highlightSource: HighlightSource

    var body: some View {
        ZStack {
            ForEach(ring.nodes.indices, id: \.self) { index in
                let region = HoverRegion.slice(level: ring.level, index: index)
                let isHovered = hovered == region
                let isPrehighlighted = !isHovered && prehighlighted == region
                let isKeyboardFocus = isHovered && highlightSource == .keyboard
                let wedge = RadialWedge(layout: ring.layout, index: index)

                wedge.fill((isKeyboardFocus ? Color.accentColor : Color(appearance.sliceFillColor)).opacity(
                    appearance.fillOpacity(hovered: isHovered, prehighlighted: isPrehighlighted)
                ))
                wedge.stroke(
                    rimColor(hovered: isHovered, prehighlighted: isPrehighlighted, keyboardFocus: isKeyboardFocus),
                    lineWidth: rimWidth(hovered: isHovered, prehighlighted: isPrehighlighted)
                )
            }
        }
    }

    private func rimColor(hovered: Bool, prehighlighted: Bool, keyboardFocus: Bool) -> Color {
        if hovered { return keyboardFocus ? Color.accentColor : Color.primary.opacity(appearance.hoverRimOpacity) }
        if prehighlighted { return Color.primary.opacity(appearance.prehighlightRimOpacity) }
        return Color.primary.opacity(appearance.restingRimOpacity)
    }

    private func rimWidth(hovered: Bool, prehighlighted: Bool) -> CGFloat {
        if hovered { return appearance.hoverRimWidth }
        if prehighlighted { return appearance.prehighlightRimWidth }
        return appearance.restingRimWidth
    }
}

/// One ring's content: an icon/label per node, placed at its slice's mid-ring point
/// and rendered last so the glass never blurs it. The two label flags (Bringr-93j.110)
/// are independent — the apps ring reads `showsAppLabels`, the windows sub-wheel reads
/// `showsWindowLabels`, and `RadialSliceLabel` routes each node to the right one based
/// on whether it represents an app.
struct RadialRingContent: View {
    let ring: RadialRing
    let showsAppLabels: Bool
    let showsWindowLabels: Bool
    let shadowOpacity: Double

    var body: some View {
        ZStack {
            ForEach(Array(ring.nodes.enumerated()), id: \.element.id) { index, node in
                RadialSliceLabel(
                    node: node,
                    index: index,
                    showsAppLabels: showsAppLabels,
                    showsWindowLabels: showsWindowLabels,
                    shadowOpacity: shadowOpacity,
                    maxLabelWidth: ring.layout.sliceLabelMaxWidth(at: index)
                )
                .offset(
                    x: ring.layout.sliceCenterOffset(at: index).x,
                    y: ring.layout.sliceCenterOffset(at: index).y
                )
            }
        }
    }
}

/// The union of one ring's wedges (an annulus, or annulus-with-gaps for an uneven
/// window sub-wheel), summed from the tested `RadialWedge` paths so its edge lands
/// exactly on the geometry the slices and hit-testing use. `RadialGlassShape` composes
/// one of these per visible ring into the wheel's single glass clip-shape.
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
    /// Whether app slices on the apps ring show their application name (Bringr-93j.110).
    /// When false, only the app icon shows. Window slices ignore this flag.
    let showsAppLabels: Bool
    /// Whether window slices on the windows sub-wheel show their title (Bringr-93j.110).
    /// When false, only the 1-based window index shows. App slices ignore this flag.
    let showsWindowLabels: Bool
    /// Opacity of the shadow behind the icon and text (Bringr-93j.66), so the user can
    /// strengthen it for legibility on busy backgrounds or remove it entirely.
    let shadowOpacity: Double
    /// Horizontal cap on the label box, derived from the slice's chord at the mid-ring
    /// (`RadialLayout.sliceLabelMaxWidth`), so single-line text truncates with a
    /// trailing ellipsis once it would overflow into a neighbouring slice
    /// (Bringr-93j.92) instead of being clipped by the fixed 84pt cap that didn't
    /// adapt to narrower rings (many apps, overflow compressed windows).
    let maxLabelWidth: CGFloat

    var body: some View {
        VStack(spacing: 4) {
            if node.representsApp {
                appIcon
                if showsAppLabels {
                    Text(node.title)
                        .font(.caption.weight(.semibold))
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .foregroundStyle(.primary)
                }
            } else {
                Text("\(index + 1)")
                    .font(.title3.weight(.bold).monospacedDigit())
                    .foregroundStyle(.primary)
                if showsWindowLabels {
                    Text(node.title)
                        .font(.caption2.weight(.medium))
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .foregroundStyle(.primary)
                }
            }
        }
        .frame(maxWidth: maxLabelWidth)
        .shadow(color: .black.opacity(shadowOpacity), radius: 2, y: 0.5)
    }

    @ViewBuilder
    private var appIcon: some View {
        if let icon = node.appSliceIcon {
            Image(nsImage: icon)
                .resizable()
                .interpolation(.high)
                .frame(width: 34, height: 34)
                .shadow(color: .black.opacity(shadowOpacity), radius: 2.5, y: 1)
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
