import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// The "Excluded Apps" Preferences group (Bringr-93j.59): the ignore list of apps that must
/// never appear in the wheel. A free-text field holds the comma-separated entries (each a
/// bundle id or an app name), and an Add menu appends either a currently-running app (picked by
/// name) or any installed app (via the Open panel) as its bundle id. Its own file and
/// `@AppStorage` so the `PreferencesView` body stays within its length budget, mirroring
/// `CollectionSettings` / `MyAppsEditor`. The same key is read fresh at each summon via
/// `AppIgnoreList.current`, so an edit applies on the next open without a relaunch.
struct IgnoreListSettings: View {
    @AppStorage(AppIgnoreList.defaultsKey) private var text = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 8) {
                TextField("com.apple.Safari, Dell Display Manager", text: $text, axis: .vertical)
                    .lineLimit(2...4)
                    .textFieldStyle(.roundedBorder)

                addMenu
            }

            Text("Apps listed here never appear in the wheel, even if they have open windows. "
                 + "Separate entries with commas — each a bundle identifier (com.apple.Safari) "
                 + "or an app name (Safari). Use Add to pick a running or installed app.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var addMenu: some View {
        Menu {
            Button("Choose Application…") { addViaPanel() }
            let running = runningApps()
            if !running.isEmpty {
                Divider()
                ForEach(running) { app in
                    Button {
                        append(app.id)
                    } label: {
                        Label { Text(app.name) } icon: { Image(nsImage: app.icon) }
                    }
                }
            }
        } label: {
            Image(systemName: "plus")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Add a running or installed app to the exclusion list")
    }

    private func append(_ entry: String) {
        text = AppIgnoreList.appending(entry, to: text)
    }

    /// Open panel scoped to applications, mirroring `MyAppsEditor`, so any installed app can be
    /// excluded even when it isn't running. Each picked bundle's id is appended.
    private func addViaPanel() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.prompt = "Exclude"
        panel.message = "Choose apps to keep out of the wheel"
        guard panel.runModal() == .OK else { return }
        for url in panel.urls {
            if let app = CuratedApp(bundleAt: url) { append(app.bundleIdentifier) }
        }
    }

    /// Currently-running ordinary (Dock) apps — the ones that can actually appear in the wheel —
    /// sorted by display name, so the user can exclude a lingering utility without hunting in
    /// Finder. Bringr itself and apps with no bundle id are skipped; duplicate instances of one
    /// bundle id collapse to a single entry.
    private func runningApps() -> [RunningApp] {
        let selfID = Bundle.main.bundleIdentifier
        var seen = Set<String>()
        return NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }
            .compactMap { app -> RunningApp? in
                guard let id = app.bundleIdentifier, id != selfID, seen.insert(id).inserted else {
                    return nil
                }
                let icon = app.icon ?? NSWorkspace.shared.icon(for: .application)
                return RunningApp(id: id, name: app.localizedName ?? id, icon: icon)
            }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }
}

/// One running app shown in the Add menu, keyed by bundle id (its stable handle and unique row
/// identity).
private struct RunningApp: Identifiable {
    let id: String
    let name: String
    let icon: NSImage
}

#Preview {
    IgnoreListSettings()
        .padding()
        .frame(width: 460)
}
