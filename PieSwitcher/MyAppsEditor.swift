import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// The "My Apps" list editor (Bringr-93j.40): a curated, manually ordered set of apps
/// that becomes the wheel's default ordering for those apps. Reads and writes the same
/// `CuratedApps` defaults key the wheel reads at summon, so an edit applies on the next
/// open without a relaunch. Deliberately not `@AppStorage`: the value is a JSON-encoded
/// list, not an `@AppStorage`-native scalar, so it lives in `@State` hydrated from
/// `CuratedApps.current()` — this editor is the list's only writer, so a one-time read at
/// view creation stays in sync.
struct MyAppsEditor: View {
    @State private var apps: [CuratedApp] = CuratedApps.current()
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
                AppListRow(icon: icon(for: app), title: app.name)
            }
            .onMove { indices, destination in
                apps.move(fromOffsets: indices, toOffset: destination)
                persist()
            }
        }
        .appListBox(height: 160, isDropTargeted: isDropTargeted)
        .appListEmptyState("No apps yet", isVisible: apps.isEmpty)
        .dropDestination(for: URL.self) { urls, _ in
            addBundles(at: urls)
            return true
        } isTargeted: { isDropTargeted = $0 }
    }

    /// The bundle's Finder icon, or a generic application icon when the app is no
    /// longer installed (a stale entry still shows, so the user can remove it).
    private func icon(for app: CuratedApp) -> NSImage {
        guard let url = app.bundleURL else { return NSWorkspace.shared.icon(for: .application) }
        return NSWorkspace.shared.icon(forFile: url.path)
    }

    private var controls: some View {
        AppListControls(
            removeHelp: "Remove the selected app",
            isRemoveEnabled: selection != nil,
            onRemove: removeSelected
        ) {
            AppListAddButton(help: "Add an app…", action: addViaPanel)
        }
    }

    private func addViaPanel() {
        addBundles(at: AppBundlePanel.pick(prompt: "Add", message: "Choose apps to pin to the wheel"))
    }

    private func addBundles(at urls: [URL]) {
        let updated = CuratedApps.adding(bundlesAt: urls, to: apps)
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
        CuratedApps.save(apps)
    }
}

#Preview {
    MyAppsEditor()
        .padding()
        .frame(width: 460)
}
