import SwiftUI

struct AboutView: View {
    private let repoURL = URL(string: "https://github.com/mekedron/PieSwitcher")!

    var body: some View {
        VStack(spacing: 18) {
            PieMark()
                .frame(width: 96, height: 96)
                .accessibilityHidden(true)

            VStack(spacing: 6) {
                Text("PieSwitcher")
                    .font(.title)
                    .bold()

                Text("Radial launcher and window manager for macOS")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)

                Text(versionString)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }

            Link("github.com/mekedron/PieSwitcher", destination: repoURL)
                .font(.callout)

            Button("Check for Updates…") {
                SparkleUpdater.shared?.checkForUpdates()
            }

            Text(copyrightString)
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 40)
        .padding(.vertical, 32)
        .frame(minWidth: 360)
    }

    private var versionString: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "0.0.0"
        let build = info?["CFBundleVersion"] as? String ?? "0"
        return "Version \(version) (\(build))"
    }

    private var copyrightString: String {
        Bundle.main.infoDictionary?["NSHumanReadableCopyright"] as? String ?? ""
    }
}

/// The PieSwitcher radial-pie logo mark — a ring with a highlighted top wedge and
/// two divider legs. Matches the landing-page logo (`site/index.html`) and the app
/// icon (`Assets.xcassets/AppIcon`). Drawn as a vector so it stays crisp at any size.
struct PieMark: View {
    /// Brand purple, #7b5cff — the accent used throughout the landing page.
    var color = Color(red: 123 / 255, green: 92 / 255, blue: 255 / 255)

    var body: some View {
        Canvas { ctx, size in
            let scale = min(size.width, size.height) / 24
            let line = 1.5 * scale
            func pt(_ ptX: CGFloat, _ ptY: CGFloat) -> CGPoint { CGPoint(x: ptX * scale, y: ptY * scale) }
            // Point on a circle, angle measured clockwise from straight up.
            func arc(_ radius: CGFloat, _ deg: CGFloat) -> CGPoint {
                let ang = deg * .pi / 180
                return pt(12 + radius * sin(ang), 12 - radius * cos(ang))
            }

            // Outer ring (r 9.2) and inner ring (r 3.3), both centered at (12, 12).
            func ring(_ radius: CGFloat) -> Path {
                Path(ellipseIn: CGRect(x: (12 - radius) * scale, y: (12 - radius) * scale,
                                       width: 2 * radius * scale, height: 2 * radius * scale))
            }
            ctx.stroke(ring(9.2), with: .color(color), lineWidth: line)
            ctx.stroke(ring(3.3), with: .color(color), lineWidth: line)

            // Filled top wedge: outer arc -40°..+40° through the top, inner arc back, closed.
            var wedge = Path()
            wedge.move(to: arc(9.2, -40))
            for step in 0...48 { wedge.addLine(to: arc(9.2, -40 + 80 * CGFloat(step) / 48)) }
            for step in 0...48 { wedge.addLine(to: arc(3.3, 40 - 80 * CGFloat(step) / 48)) }
            wedge.closeSubpath()
            ctx.fill(wedge, with: .color(color))

            // Two divider legs from the inner ring out toward the bottom.
            var legs = Path()
            legs.move(to: pt(14.12, 14.53)); legs.addLine(to: pt(17.91, 19.05))
            legs.move(to: pt(9.88, 14.53)); legs.addLine(to: pt(6.09, 19.05))
            ctx.stroke(legs, with: .color(color), style: StrokeStyle(lineWidth: line, lineCap: .round))
        }
    }
}

#Preview {
    AboutView()
}
