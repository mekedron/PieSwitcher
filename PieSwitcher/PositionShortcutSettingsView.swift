import SwiftUI

// MARK: - Tab

/// Sub-tab selector for the Positions tab (Bringr-dk3). The two binding lists are split
/// because they address different rings and answer different questions — "which app" versus
/// "which window of the app I'm in" — and a user typically fills one of them heavily and the
/// other lightly. "Excluded Apps" is the Positions-only exclusion list: apps whose keys the
/// shortcuts must never consume, independent of Activation → Excluded Apps.
enum PositionShortcutSubTab: String, PreferencesSubTab {
    case apps
    case windows
    case excluded

    static let defaultsKey = "preferences.positionsSubTab"
    static let `default`: PositionShortcutSubTab = .apps

    var title: String {
        switch self {
        case .apps: return "Apps"
        case .windows: return "Windows"
        case .excluded: return "Excluded Apps"
        }
    }
}

/// The Positions tab body: the sub-tab strip over whichever pane it selects.
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

            // Keyed by the sub-tab so switching rebuilds the pane from that pane's
            // persisted rows rather than reusing the other one's `@State`.
            switch selection.wrappedValue {
            case .apps:
                PositionShortcutSettings(list: .apps).id(PositionShortcutSubTab.apps)
            case .windows:
                PositionShortcutSettings(list: .windows).id(PositionShortcutSubTab.windows)
            case .excluded:
                PositionShortcutExclusionSettings().id(PositionShortcutSubTab.excluded)
            }
        }
    }
}

/// The "Excluded Apps" pane inside the Positions tab: the editor over
/// `PositionShortcutExclusionList`'s own storage key. Starts empty — position shortcuts
/// work everywhere until an app is added here — and never reads or writes the activation
/// exclusion list, so the two panes can be configured independently.
struct PositionShortcutExclusionSettings: View {
    var body: some View {
        PreferencesPane {
            Section {
                ActivationExclusionEditor(
                    defaultsKey: PositionShortcutExclusionList.defaultsKey,
                    emptyState: "Add an app to let it keep its keys — position shortcuts "
                        + "won't fire while it is active.",
                    panelPrompt: "Exclude",
                    panelMessage: "Choose apps whose keystrokes position shortcuts should never take"
                )
            } header: {
                Text("Excluded apps")
            } footer: {
                Text("While one of these apps is the active (frontmost) app, position "
                     + "shortcuts do not fire and every keystroke passes through to the app "
                     + "normally. Use it for apps whose own shortcuts collide with the ones "
                     + "bound here.\n\nThis list is separate from Activation → Excluded Apps, "
                     + "which only disables opening the pie menu.")
            }
        }
    }
}

// MARK: - Pane

/// The Positions pane for one position list (Bringr-dk3). The list is free-form: the user
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
                presetRow
            } header: {
                Text("Quick start")
            } footer: {
                Text(presetFooter)
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
        .onAppear { reload() }
    }

    // MARK: - Rows

    /// The one-click starter set. Offered rather than applied: these shortcuts consume
    /// their keys system-wide, so nothing binds until the user asks.
    @ViewBuilder
    private var presetRow: some View {
        if isPresetInstalled {
            HStack(spacing: 12) {
                Label("\(PositionShortcutPreset.summary(for: list)) are set up",
                      systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.tint)
                Spacer(minLength: 0)
                Button("Remove") {
                    PositionShortcutPreset.remove(list)
                    reload()
                }
            }
        } else {
            HStack {
                Button("Add \(PositionShortcutPreset.summary(for: list))") {
                    PositionShortcutPreset.install(list)
                    reload()
                }
                Spacer(minLength: 0)
            }
        }
    }

    private var presetFooter: String {
        "Adds \(PositionShortcutPreset.summary(for: list)) for the first "
            + "\(PositionShortcutPreset.positionCount) positions, on the left Option only so "
            + "the right one keeps typing what it always did. Rows you set up yourself are "
            + "left alone."
    }

    private var isPresetInstalled: Bool {
        // Derived from `bindings` rather than re-read, so the row flips the instant an edit
        // lands instead of a redraw later.
        let bound = Set(bindings.compactMap(\.shortcut))
        return PositionShortcutPreset.recommended(for: list).allSatisfy { binding in
            binding.shortcut.map(bound.contains) ?? false
        }
    }

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
                onCaptureStateChange: { capturingRowID = $0 ? binding.id : nil },
                // A position shortcut fires outright and swallows its key, so it must carry
                // a real key: a bare modifier would hijack every use of that modifier.
                requiresNonModifierKey: true
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

    /// Re-read the persisted rows, for edits made outside this view's own `write` — the
    /// preset buttons, and the onboarding screen that may have installed the same set.
    private func reload() {
        bindings = PositionShortcutStore.bindings(list)
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
            + "the app underneath never sees them. Each one needs a real key alongside its "
            + "modifiers — a bare ⌥ or ⌘ would take over that modifier everywhere. Apps "
            + "listed under Positions → Excluded Apps keep their keys."
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
