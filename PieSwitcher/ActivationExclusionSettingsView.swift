import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// The activation-exclusion list editor (Bringr-93j.109): a stable list of
/// `CuratedApp` entries the user can add to (via a standard Open panel scoped to
/// applications) and remove from. Modelled on `MyAppsEditor` so the rows look like
/// the curated-apps pane — same icon-plus-name row, same plus/minus controls — and
/// each edit writes through `ActivationExclusionList.save` so the activation
/// monitors pick up the change on the next event.
struct ActivationExclusionEditor: View {
    @State private var apps: [CuratedApp] = ActivationExclusionList.current().apps
    @State private var selection: CuratedApp.ID?
    @State private var isDropTargeted = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            listBox
            controls
        }
    }

    private var listBox: some View {
        List(selection: $selection) {
            ForEach(apps) { app in
                ExclusionAppRow(app: app)
            }
            .onMove { indices, destination in
                apps.move(fromOffsets: indices, toOffset: destination)
                persist()
            }
        }
        .listStyle(.bordered(alternatesRowBackgrounds: true))
        .frame(height: 200)
        .overlay {
            if apps.isEmpty {
                Text("Add an app to disable the pie menu while that app is active.")
                    .font(.callout)
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)
            }
        }
        .overlay {
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(Color.accentColor, lineWidth: isDropTargeted ? 2 : 0)
        }
        .dropDestination(for: URL.self) { urls, _ in
            addBundles(at: urls)
            return true
        } isTargeted: { isDropTargeted = $0 }
    }

    private var controls: some View {
        HStack(spacing: 8) {
            Button {
                addViaPanel()
            } label: {
                Image(systemName: "plus").frame(width: 18)
            }
            .help("Add an app to the exclusion list…")

            Button {
                removeSelected()
            } label: {
                Image(systemName: "minus").frame(width: 18)
            }
            .disabled(selection == nil)
            .help("Remove the selected app from the exclusion list")

            Spacer()
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
    }

    /// Open panel scoped to applications, defaulting to /Applications, so the user can
    /// exclude any installed app — game, drawing app, CAD app — even when it isn't
    /// running. Picks merge through `ActivationExclusionList.adding`, which dedupes by
    /// bundle id.
    private func addViaPanel() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.prompt = "Exclude"
        panel.message = "Choose apps that should disable the pie menu when they're active"
        guard panel.runModal() == .OK else { return }
        addBundles(at: panel.urls)
    }

    private func addBundles(at urls: [URL]) {
        let updated = ActivationExclusionList.adding(bundlesAt: urls, to: apps)
        guard updated != apps else { return }
        apps = updated
        persist()
    }

    private func removeSelected() {
        guard let id = selection else { return }
        apps.removeAll { $0.id == id }
        selection = nil
        persist()
    }

    private func persist() {
        ActivationExclusionList.save(apps)
    }
}

/// One row in the exclusion-list editor: the app's Finder icon and display name.
/// Mirrors `MyAppsEditor`'s row so the two list-style editors look identical.
private struct ExclusionAppRow: View {
    let app: CuratedApp

    var body: some View {
        HStack(spacing: 8) {
            Image(nsImage: icon)
                .resizable()
                .frame(width: 18, height: 18)
            Text(app.name)
                .lineLimit(1)
        }
    }

    /// The bundle's Finder icon, or a generic application icon when the app is no
    /// longer installed (a stale entry still shows, so the user can choose to remove
    /// it — the spec calls this out as an explicit edge case).
    private var icon: NSImage {
        if let url = app.bundleURL {
            return NSWorkspace.shared.icon(forFile: url.path)
        }
        return NSWorkspace.shared.icon(for: .application)
    }
}

/// The "Excluded Apps" pane inside the Activation tab. Drops the editor into the
/// standard `PreferencesPane` Form so its section styling matches the rest of the
/// Preferences window. The footer text doubles as the discoverability copy the
/// spec calls for — it explains the use case (games, drawing apps) and the trigger
/// condition (the listed app is the active/frontmost app), so the user doesn't
/// need release notes to understand what the list does.
struct ActivationExclusionSettings: View {
    var body: some View {
        PreferencesPane {
            Section {
                ActivationExclusionEditor()
            } header: {
                Text("Excluded apps")
            } footer: {
                Text("When one of these apps is the active (frontmost) app, the pie menu's "
                     + "activation is disabled and your click, hold, or press passes through "
                     + "to the app normally. Use it for games and drawing apps that need the "
                     + "same mouse buttons the wheel summons on.")
            }
        }
    }
}

#Preview {
    ActivationExclusionSettings()
        .frame(width: 820, height: 500)
}
