import SwiftUI

struct AboutView: View {
    private let repoURL = URL(string: "https://github.com/mekedron/PieSwitcher")!

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "circle.hexagongrid.fill")
                .resizable()
                .scaledToFit()
                .frame(width: 96, height: 96)
                .foregroundStyle(.tint)

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

#Preview {
    AboutView()
}
