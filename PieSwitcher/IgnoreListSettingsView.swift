import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// The "Hidden Apps" list editor (Bringr-93j.59): apps that never appear in the wheel.
/// Backed by `AppIgnoreList`'s comma-separated string, which the wheel re-reads at each
/// summon, so an edit applies on the next open without a relaunch. `@AppStorage` binds
/// the raw text directly — this editor renders it as rows and writes it back through
/// `AppIgnoreList`'s append/remove helpers, so the stored format never depends on the UI.
///
/// Hiding an app only filters the wheel's contents. `ActivationExclusionList` is the list
/// that stops the wheel from opening while an app is frontmost.
struct HiddenAppsEditor: View {
    @AppStorage(AppIgnoreList.defaultsKey) private var text = ""
    @State private var selection: HiddenAppEntry.ID?
    @State private var isDropTargeted = false
    @State private var isAddingCustomEntry = false

    /// The stored entries resolved for display, rebuilt from `text` so an edit made
    /// anywhere — this editor, another pane, `defaults write` — shows up immediately.
    private var entries: [HiddenAppEntry] {
        AppIgnoreList.rawEntries(text).map(HiddenAppEntry.init)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            listBox
            controls
        }
        .sheet(isPresented: $isAddingCustomEntry) {
            CustomIgnoreEntrySheet(onAdd: append)
        }
    }

    private var listBox: some View {
        List(selection: $selection) {
            ForEach(entries) { entry in
                AppListRow(icon: entry.icon, title: entry.title, subtitle: entry.entry)
            }
        }
        .appListBox(height: 200, isDropTargeted: isDropTargeted)
        .appListEmptyState(
            "Add an app to keep it out of the wheel, even when it has open windows.",
            isVisible: entries.isEmpty
        )
        .dropDestination(for: URL.self) { urls, _ in
            addBundles(at: urls)
            return true
        } isTargeted: { isDropTargeted = $0 }
    }

    private var controls: some View {
        AppListControls(
            removeHelp: "Remove the selected app from the hidden list",
            isRemoveEnabled: selection != nil,
            onRemove: removeSelected
        ) {
            AppListAddMenu(help: "Add a running or installed app to the hidden list") {
                Button("Choose Application…") { addViaPanel() }
                Button("Add Entry by Name…") { isAddingCustomEntry = true }

                let running = RunningAppCandidate.current()
                if !running.isEmpty {
                    Divider()
                    ForEach(running) { app in
                        Button {
                            append(app.bundleIdentifier)
                        } label: {
                            Label { Text(app.name) } icon: { Image(nsImage: app.icon) }
                        }
                    }
                }
            }
        }
    }

    private func addViaPanel() {
        addBundles(at: AppBundlePanel.pick(prompt: "Hide", message: "Choose apps to keep out of the wheel"))
    }

    private func addBundles(at urls: [URL]) {
        for url in urls {
            guard let app = CuratedApp(bundleAt: url) else { continue }
            append(app.bundleIdentifier)
        }
    }

    private func append(_ entry: String) {
        text = AppIgnoreList.appending(entry, to: text)
    }

    private func removeSelected() {
        guard let id = selection, let entry = entries.first(where: { $0.id == id }) else { return }
        text = AppIgnoreList.removing(entry.entry, from: text)
        selection = nil
    }
}

/// One row in the hidden-apps editor. `entry` is the exact text stored in the list — a
/// bundle identifier or an app name, the two forms `AppIgnoreList` matches — and is what
/// removal acts on; the icon and title are resolution for display only, done once at
/// construction rather than per lookup.
struct HiddenAppEntry: Identifiable {
    let entry: String
    let title: String
    let icon: NSImage

    /// Case-folded, because the stored list treats "DDPM" and "ddpm" as one entry and two
    /// rows claiming the same identity would break `List` selection.
    var id: String { entry.lowercased() }

    /// Resolve an entry for display: a running app carrying this bundle id or display name
    /// gives the truest icon and name; failing that, an installed bundle resolves through
    /// Launch Services. An entry that matches neither — a name typed for a utility that
    /// isn't up right now — still lists under a generic icon, so it can be seen and removed
    /// instead of silently filtering the wheel forever.
    init(entry: String) {
        self.entry = entry

        let running = NSWorkspace.shared.runningApplications.first {
            $0.bundleIdentifier?.caseInsensitiveCompare(entry) == .orderedSame
                || $0.localizedName?.caseInsensitiveCompare(entry) == .orderedSame
        }
        let bundleURL = CuratedApp.bundleURL(forBundleIdentifier: entry)

        if let name = running?.localizedName {
            title = name
        } else if let bundleURL {
            title = FileManager.default.displayName(atPath: bundleURL.path)
        } else {
            title = entry
        }

        if let icon = running?.icon {
            self.icon = icon
        } else if let bundleURL {
            icon = NSWorkspace.shared.icon(forFile: bundleURL.path)
        } else {
            icon = NSWorkspace.shared.icon(for: .application)
        }
    }
}

/// Sheet for typing an entry by hand. The Open panel and the running-apps menu cover apps
/// that are installed or up right now; neither reaches a background utility that only ever
/// surfaces as a window owner ("DDPM") and isn't running when the user goes to list it.
/// `AppIgnoreList` matches names as well as bundle ids precisely so those can be excluded,
/// so the editor keeps a way to enter one.
private struct CustomIgnoreEntrySheet: View {
    let onAdd: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var entry = ""

    private var trimmed: String {
        entry.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Hide an app by name")
                .font(.headline)

            Text("Enter a bundle identifier (com.apple.Safari) or the app's name exactly as it "
                 + "appears in the wheel (Safari).")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            TextField("", text: $entry, prompt: Text("com.apple.Safari"))
                .textFieldStyle(.roundedBorder)
                .labelsHidden()
                .onSubmit(add)

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                Button("Add", action: add)
                    .keyboardShortcut(.defaultAction)
                    .disabled(trimmed.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 380)
    }

    private func add() {
        guard !trimmed.isEmpty else { return }
        onAdd(trimmed)
        dismiss()
    }
}

#Preview {
    HiddenAppsEditor()
        .padding()
        .frame(width: 460)
}
