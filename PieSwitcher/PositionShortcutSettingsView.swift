import SwiftUI

// MARK: - Tab

/// Sub-tab selector for the Shortcuts tab (Bringr-dk3). The two lists are split because
/// they address different rings and answer different questions — "which app" versus "which
/// window of the app I'm in" — and a user typically fills one of them heavily and the other
/// lightly.
enum PositionShortcutSubTab: String, PreferencesSubTab {
    case apps
    case windows

    static let defaultsKey = "preferences.shortcutsSubTab"
    static let `default`: PositionShortcutSubTab = .apps

    var title: String {
        switch self {
        case .apps: return "Apps"
        case .windows: return "Windows"
        }
    }

    /// The list this sub-tab edits.
    var list: PositionShortcutList {
        switch self {
        case .apps: return .apps
        case .windows: return .windows
        }
    }
}

/// The Shortcuts tab body: the sub-tab strip over whichever list it selects.
struct PositionShortcutsTab: View {
    @AppStorage(PositionShortcutSubTab.defaultsKey)
    private var subTabRaw = PositionShortcutSubTab.default.rawValue

    var body: some View {
        let selection = Binding(
            get: { PositionShortcutSubTab(rawValue: subTabRaw) ?? .default },
            set: { subTabRaw = $0.rawValue }
        )
        VStack(spacing: 0) {
            PreferencesSubTabs(selection: selection)

            // Keyed by the list so switching sub-tabs rebuilds the pane from that list's
            // persisted rows rather than reusing the other one's `@State`.
            PositionShortcutSettings(list: selection.wrappedValue.list)
                .id(selection.wrappedValue)
        }
    }
}

// MARK: - Pane

/// The Shortcuts pane for one position list (Bringr-dk3). The list is free-form: the user
/// adds as many rows as they like, and each row is a *pair* — the position to act on and
/// the shortcut that acts on it — both editable in place.
///
/// Two rows may name the same position. That is a legitimate arrangement (a chorded
/// shortcut and a function key both meaning "first app"), not a conflict, so a row's
/// identity is its `id` and never its position. Rows are always presented ascending by
/// position, so position 1 — the first app in the wheel — reads at the top.
struct PositionShortcutSettings: View {
    let list: PositionShortcutList

    @State private var bindings: [PositionShortcutBinding] = []
    /// The row currently recording a shortcut, so the others' controls can step out of the
    /// way while keys are being captured.
    @State private var capturingRowID: UUID?

    var body: some View {
        PreferencesPane {
            Section {
                PreferencesParagraph(explanation)
            }

            Section {
                if bindings.isEmpty {
                    Text(emptyState)
                        .font(.callout)
                        .foregroundStyle(.tertiary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 4)
                } else {
                    columnHeadings
                    ForEach(bindings) { binding in
                        row(for: binding)
                    }
                }

                Button(action: addRow) {
                    Label("Add shortcut", systemImage: "plus.circle")
                }
                .buttonStyle(.borderless)
            } header: {
                Text(sectionHeader)
            } footer: {
                Text(footer)
            }
        }
        .onAppear { bindings = PositionShortcutStore.bindings(list) }
    }

    // MARK: - Rows

    private var columnHeadings: some View {
        HStack(spacing: 12) {
            Text(positionColumnTitle)
                .frame(width: positionFieldWidth, alignment: .leading)
            Text("Shortcut")
            Spacer()
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    private func row(for binding: PositionShortcutBinding) -> some View {
        HStack(spacing: 12) {
            TextField(
                positionColumnTitle,
                value: positionBinding(for: binding.id),
                format: .number
            )
            .labelsHidden()
            .multilineTextAlignment(.trailing)
            .textFieldStyle(.roundedBorder)
            .frame(width: positionFieldWidth)
            .help("Which slice of the wheel this shortcut acts on. 1 is the first one.")

            KeyboardShortcutCaptureField(
                shortcut: binding.shortcut,
                placeholder: "Not set",
                onCommit: { setShortcut($0, forRow: binding.id) },
                minWidth: 200,
                onCaptureStateChange: { capturingRowID = $0 ? binding.id : nil }
            )

            Spacer(minLength: 0)

            if capturingRowID != binding.id {
                Button {
                    removeRow(binding.id)
                } label: {
                    Image(systemName: "minus.circle")
                        .imageScale(.medium)
                }
                .buttonStyle(.borderless)
                .help("Remove this shortcut")
            }
        }
    }

    /// Two-way binding for a row's position. Reads keep the field showing whatever the row
    /// holds; writes clamp into range and re-sort, so a row typed down to 1 moves to the top
    /// the moment the field commits.
    private func positionBinding(for id: UUID) -> Binding<Int> {
        Binding(
            get: { bindings.first { $0.id == id }?.position ?? 1 },
            set: { newValue in
                update(id) {
                    $0.position = min(max(newValue, 1), PositionShortcutStore.maxPosition)
                }
            }
        )
    }

    // MARK: - Editing

    private func addRow() {
        // A fresh row lands one past the highest position already bound, which is what a
        // user filling the list top-down wants; they can type any other number over it.
        let next = min((bindings.map(\.position).max() ?? 0) + 1, PositionShortcutStore.maxPosition)
        write(bindings + [PositionShortcutBinding(position: next)])
    }

    private func removeRow(_ id: UUID) {
        write(bindings.filter { $0.id != id })
    }

    private func setShortcut(_ shortcut: KeyboardShortcut, forRow id: UUID) {
        update(id) { $0.shortcut = shortcut }
    }

    private func update(_ id: UUID, _ mutate: (inout PositionShortcutBinding) -> Void) {
        var updated = bindings
        guard let index = updated.firstIndex(where: { $0.id == id }) else { return }
        mutate(&updated[index])
        write(updated)
    }

    private func write(_ updated: [PositionShortcutBinding]) {
        let ordered = PositionShortcutStore.sorted(updated)
        bindings = ordered
        PositionShortcutStore.setBindings(ordered, for: list)
    }

    // MARK: - Copy

    private var positionFieldWidth: CGFloat { 58 }

    private var positionColumnTitle: String {
        switch list {
        case .apps: return "App #"
        case .windows: return "Window #"
        }
    }

    private var sectionHeader: String {
        switch list {
        case .apps: return "App positions"
        case .windows: return "Window positions"
        }
    }

    private var explanation: String {
        switch list {
        case .apps:
            return "Jump straight to a slice of the wheel without opening it. A shortcut here "
                + "activates whatever app currently sits at that position, counting from the "
                + "top of the wheel and going clockwise — 1 is the first app."
        case .windows:
            return "Switch between the windows of the app you are currently in. A shortcut here "
                + "focuses that app's window at the given position, in the same order its "
                + "sub-wheel lays them out — 1 is the first window."
        }
    }

    private var emptyState: String {
        switch list {
        case .apps: return "No app positions bound yet."
        case .windows: return "No window positions bound yet."
        }
    }

    private var footer: String {
        let common = "\n\nShortcuts fire immediately, with no hold delay, and are swallowed so "
            + "the app underneath never sees them. Apps listed under Activation → Excluded "
            + "Apps keep their keys."
        switch list {
        case .apps:
            return "Positions follow the wheel: reordering it under Contents → Sorting, or "
                + "pinning apps under Contents → Apps, changes what each shortcut activates. "
                + "A position the wheel is currently too short to have does nothing." + common
        case .windows:
            return "Windows keep a fixed position by age — the one opened first stays first — "
                + "so a shortcut points at the same window for as long as it is open. If the "
                + "current app has fewer windows than that, the shortcut does nothing." + common
        }
    }
}

#Preview {
    PositionShortcutSettings(list: .apps)
}
