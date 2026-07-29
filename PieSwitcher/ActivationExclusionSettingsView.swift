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
            addMenu

            Button {
                removeSelected()
            } label: {
                Image(systemName: "minus").frame(width: 18)
            }
            .buttonStyle(.bordered)
            .disabled(selection == nil)
            .help("Remove the selected app from the exclusion list")

            Spacer()
        }
        .controlSize(.small)
    }

    /// Plus button as a menu: the Open panel plus a direct list of running apps. The panel
    /// alone is not enough — the apps this list exists for (games, 3D suites) often live
    /// outside /Applications, in a Steam or launcher library the user would have to hunt
    /// through. Picking the app they are already running is the shortest path there is.
    private var addMenu: some View {
        Menu {
            Button("Choose Application…") { addViaPanel() }
            let running = runningApps()
            if !running.isEmpty {
                Divider()
                ForEach(running) { app in
                    Button {
                        add(app.curated)
                    } label: {
                        Label { Text(app.curated.name) } icon: { Image(nsImage: app.icon) }
                    }
                }
            }
        } label: {
            Image(systemName: "plus").frame(width: 18)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Add a running or installed app to the exclusion list")
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
        commit(ActivationExclusionList.adding(bundlesAt: urls, to: apps))
    }

    private func add(_ app: CuratedApp) {
        commit(ActivationExclusionList.adding(app, to: apps))
    }

    /// Adopt a merged list, skipping the write when nothing changed (re-adding a listed app).
    private func commit(_ updated: [CuratedApp]) {
        guard updated != apps else { return }
        apps = updated
        persist()
    }

    /// Currently-running ordinary (Dock) apps — the ones that can own focus and therefore
    /// trigger the exclusion — sorted by display name. PieSwitcher itself and apps with no
    /// bundle id are skipped; duplicate instances of one bundle id collapse to a single entry.
    /// Mirrors `IgnoreListSettings.runningApps`.
    private func runningApps() -> [RunningExclusionCandidate] {
        let selfID = Bundle.main.bundleIdentifier
        var seen = Set<String>()
        return NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }
            .compactMap { app -> RunningExclusionCandidate? in
                guard let id = app.bundleIdentifier, id != selfID, seen.insert(id).inserted else {
                    return nil
                }
                return RunningExclusionCandidate(
                    curated: CuratedApp(bundleIdentifier: id, name: app.localizedName ?? id),
                    icon: app.icon ?? NSWorkspace.shared.icon(for: .application)
                )
            }
            .sorted { $0.curated.name.localizedCaseInsensitiveCompare($1.curated.name) == .orderedAscending }
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

/// One running app offered by the quick-add menu: the entry that would be stored, plus the
/// live icon for the menu label. Identified by the curated entry's bundle id.
private struct RunningExclusionCandidate: Identifiable {
    let curated: CuratedApp
    let icon: NSImage

    var id: String { curated.id }
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
                     + "to the app normally — with no hold delay. Use it for games, 3D, and "
                     + "drawing apps that need the same mouse buttons the wheel summons on.\n\n"
                     + "This does not change what the wheel contains. To keep an app out of "
                     + "the wheel's list, add it under Apps → Hidden.")
            }
        }
    }
}

#Preview {
    ActivationExclusionSettings()
        .frame(width: 820, height: 500)
}
