import AppKit
import SwiftUI

/// Renders the radial wheel: one concentric ring per navigation level (apps, then
/// the hovered app's windows sub-wheel), each slice carrying its placeholder
/// content. The hovered slice is emphasised. No animations — wedges and labels are
/// placed directly from the tested `RadialLayout` geometry.
struct RadialMenuView: View {
    @ObservedObject var controller: RadialMenuController

    var body: some View {
        let diameter = controller.overallDiameter

        ZStack {
            ForEach(controller.rings) { ring in
                RadialRingView(
                    ring: ring,
                    hovered: controller.hovered,
                    prehighlighted: controller.prehighlighted
                )
            }
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
}

/// One concentric ring: a wedge + label per node. The hovered slice is filled most
/// strongly; a pre-highlighted slice (the app's remembered last selection) gets a
/// medium fill and a stronger outline so the suggested choice reads before the
/// cursor reaches it. (US-012 AC4)
struct RadialRingView: View {
    let ring: RadialRing
    let hovered: HoverRegion
    let prehighlighted: HoverRegion

    var body: some View {
        let layout = RadialLayout(itemCount: ring.nodes.count, geometry: ring.geometry)

        ZStack {
            ForEach(Array(ring.nodes.enumerated()), id: \.element.id) { index, node in
                let region = HoverRegion.slice(level: ring.level, index: index)
                let isHovered = hovered == region
                let isPrehighlighted = !isHovered && prehighlighted == region
                RadialWedge(layout: layout, index: index)
                    .fill(Color.accentColor.opacity(fillOpacity(hovered: isHovered, prehighlighted: isPrehighlighted)))
                    .overlay(
                        RadialWedge(layout: layout, index: index)
                            .stroke(
                                Color.primary.opacity(isPrehighlighted ? 0.5 : 0.15),
                                lineWidth: isPrehighlighted ? 2 : 1
                            )
                    )

                RadialSliceLabel(node: node, index: index)
                    .offset(
                        x: layout.sliceCenterOffset(at: index).x,
                        y: layout.sliceCenterOffset(at: index).y
                    )
            }
        }
    }

    private func fillOpacity(hovered: Bool, prehighlighted: Bool) -> Double {
        if hovered { return 0.42 }
        if prehighlighted { return 0.30 }
        return 0.18
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
/// slices show a 1-based index and the (best-effort) title. No live preview.
struct RadialSliceLabel: View {
    let node: MenuNode
    let index: Int

    var body: some View {
        VStack(spacing: 4) {
            if let app = node.representedApp {
                appIcon(for: app)
                Text(node.title)
                    .font(.caption)
                    .lineLimit(1)
            } else {
                Text("\(index + 1)")
                    .font(.title3.weight(.bold).monospacedDigit())
                Text(node.title)
                    .font(.caption2)
                    .lineLimit(1)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: 84)
    }

    @ViewBuilder
    private func appIcon(for app: AppID) -> some View {
        if let icon = NSRunningApplication(processIdentifier: app.pid)?.icon {
            Image(nsImage: icon)
                .resizable()
                .frame(width: 32, height: 32)
        } else {
            Image(systemName: "app.dashed")
                .font(.system(size: 28))
        }
    }
}
