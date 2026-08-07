import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// The activation-exclusion list editor (Bringr-93j.109): a stable list of
/// `CuratedApp` entries the user can add to (via a standard Open panel scoped to
/// applications) and remove from. Modelled on `MyAppsEditor` so the rows look like
/// the curated-apps pane — same icon-plus-name row, same plus/minus controls — and
/// each edit writes through `save` so the monitors pick up the change on the next
/// event. `defaultsKey` selects WHICH exclusion list this instance edits — the
/// activation one or the Positions one — so the two panes share one editor without
/// ever sharing a list.
struct ActivationExclusionEditor: View {
    let defaultsKey: String
    let emptyState: String
    let panelPrompt: String
    let panelMessage: String

    @State private var apps: [CuratedApp]
    @State private var selection: CuratedApp.ID?
    @State private var isDropTargeted = false

    init(
        defaultsKey: String = ActivationExclusionList.defaultsKey,
        emptyState: String = "Add an app to disable the pie menu while that app is active.",
        panelPrompt: String = "Exclude",
        panelMessage: String = "Choose apps that should disable the pie menu when they're active"
    ) {
        self.defaultsKey = defaultsKey
        self.emptyState = emptyState
        self.panelPrompt = panelPrompt
        self.panelMessage = panelMessage
        _apps = State(initialValue: ActivationExclusionList.current(key: defaultsKey).apps)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            listBox
            controls
        }
    }

    private var listBox: some View {
        List(selection: $selection) {
            ForEach(apps) { app in
                AppListRow(icon: icon(for: app), title: app.name, subtitle: app.bundleIdentifier)
            }
            .onMove { indices, destination in
                apps.move(fromOffsets: indices, toOffset: destination)
                persist()
            }
        }
        .appListBox(height: 200, isDropTargeted: isDropTargeted)
        .appListEmptyState(emptyState, isVisible: apps.isEmpty)
        .dropDestination(for: URL.self) { urls, _ in
            addBundles(at: urls)
            return true
        } isTargeted: { isDropTargeted = $0 }
    }

    /// The bundle's Finder icon, or a generic application icon when the app is no longer
    /// installed (a stale entry still shows, so the user can choose to remove it — the spec
    /// calls this out as an explicit edge case).
    private func icon(for app: CuratedApp) -> NSImage {
        guard let url = app.bundleURL else { return NSWorkspace.shared.icon(for: .application) }
        return NSWorkspace.shared.icon(forFile: url.path)
    }

    private var controls: some View {
        AppListControls(
            removeHelp: "Remove the selected app from the exclusion list",
            isRemoveEnabled: selection != nil,
            onRemove: removeSelected
        ) {
            AppListAddMenu(help: "Add a running or installed app to the exclusion list") {
                Button("Choose Application…") { addViaPanel() }

                let running = RunningAppCandidate.current()
                if !running.isEmpty {
                    Divider()
                    ForEach(running) { app in
                        Button {
                            add(app.curated)
                        } label: {
                            Label { Text(app.name) } icon: { Image(nsImage: app.icon) }
                        }
                    }
                }
            }
        }
    }

    /// Picks merge through `ActivationExclusionList.adding`, which dedupes by bundle id.
    private func addViaPanel() {
        addBundles(at: AppBundlePanel.pick(prompt: panelPrompt, message: panelMessage))
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

    private func removeSelected() {
        guard let id = selection else { return }
        apps.removeAll { $0.id == id }
        selection = nil
        persist()
    }

    private func persist() {
        ActivationExclusionList.save(apps, key: defaultsKey)
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
                     + "the wheel's list, add it under Contents → Hidden. Position shortcuts "
                     + "have their own separate list under Positions → Excluded Apps.")
            }
        }
    }
}

#Preview {
    ActivationExclusionSettings()
        .frame(width: 820, height: 500)
}
