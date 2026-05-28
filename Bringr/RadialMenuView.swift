import AppKit
import SwiftUI

/// Renders the radial wheel: one wedge per top-level node, each carrying its
/// placeholder content (app icon + name for app slices; index + title for window
/// slices). No animations — wedges and labels are placed directly from the tested
/// `RadialLayout` geometry. Hover-reveal lands in US-010/US-011.
struct RadialMenuView: View {
    @ObservedObject var controller: RadialMenuController

    var body: some View {
        let slices = controller.slices
        let layout = RadialLayout(itemCount: slices.count, geometry: controller.geometry)

        ZStack {
            ForEach(Array(slices.enumerated()), id: \.element.id) { index, node in
                RadialWedge(layout: layout, index: index)
                    .fill(Color.accentColor.opacity(0.18))
                    .overlay(
                        RadialWedge(layout: layout, index: index)
                            .stroke(Color.primary.opacity(0.15), lineWidth: 1)
                    )

                RadialSliceLabel(node: node, index: index)
                    .offset(
                        x: layout.sliceCenterOffset(at: index).x,
                        y: layout.sliceCenterOffset(at: index).y
                    )
            }
        }
        .frame(width: controller.geometry.diameter, height: controller.geometry.diameter)
        .contentShape(Rectangle())
        // A zero-distance drag reports the click location so the controller can map
        // it to a slice (click-to-stay select) or the dead zone (cancel).
        .gesture(
            DragGesture(minimumDistance: 0)
                .onEnded { value in controller.clickInOverlay(atLocalPoint: value.location) }
        )
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
