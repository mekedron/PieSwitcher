import SwiftUI

/// The Keyboard pane of the Activation tab. Bringr-93j.111 replaced the modifier-
/// checkbox picker with the two-slot `KeyboardShortcutPicker`, which can bind bare
/// modifiers (with explicit left/right) and modifier+key combinations. Every key is
/// read fresh per event by `ModifierHoldMonitor`, so a change takes effect with no
/// relaunch. Folded into a `PreferencesPane` Form so the picker, hold delay, and
/// interaction-mode picker stay column-aligned with the rest of the window.
struct KeyboardActivationSettings: View {
    @AppStorage(ActivationHoldDelay.defaultsKey)
    private var delayMilliseconds = ActivationHoldDelay.defaultMilliseconds
    @AppStorage(InteractionMode.keyboardDefaultsKey)
    private var modeRaw = InteractionMode.defaultForKeyboard.rawValue

    var body: some View {
        PreferencesPane {
            Section {
                KeyboardShortcutPicker()
            } header: {
                Text("Shortcuts")
            } footer: {
                Text("Hold a shortcut to summon the wheel — no click or tap needed — then release "
                     + "to choose. Each slot accepts a single modifier held alone (e.g. Right Option) "
                     + "or a modifier+key combination. Left and right modifiers are distinct.")
            }

            Section {
                PreferencesSliderRow(
                    title: "Hold delay",
                    value: $delayMilliseconds,
                    range: ActivationHoldDelay.millisecondRange,
                    unit: "ms"
                )
            } header: {
                Text("Timing")
            } footer: {
                Text("Hold the keys at least this long before the wheel opens, so a quick tap "
                     + "(like Fn to switch the input language) won't summon it.")
            }

            Section {
                Picker("When summoned", selection: $modeRaw) {
                    ForEach(InteractionMode.allCases, id: \.rawValue) { mode in
                        Text(mode.keyboardDisplayName).tag(mode.rawValue)
                    }
                }
                .pickerStyle(.radioGroup)
            } header: {
                Text("Interaction")
            } footer: {
                Text(modeHelp + "\n\nNote: \"Press\" still has to last at least the Hold delay "
                     + "above before the wheel opens.")
            }
        }
    }

    private var modeHelp: String {
        switch InteractionMode(rawValue: modeRaw) ?? .defaultForKeyboard {
        case .holdToSelect:
            return "Keep holding the modifier keys, move the cursor to a slice, then release to choose."
        case .clickToStay:
            return "Tap the modifier keys to open the wheel; it stays open. Click a slice to "
                 + "choose, or the centre to cancel."
        }
    }
}

/// Legacy holder kept so older callers continue to compile — Bringr-93j.106 folded the
/// hold-delay slider into `KeyboardActivationSettings`'s Timing section directly.
struct ModifierHoldDelayPicker: View {
    @AppStorage(ActivationHoldDelay.defaultsKey)
    private var delayMilliseconds = ActivationHoldDelay.defaultMilliseconds

    var body: some View {
        PreferencesSliderRow(
            title: "Hold delay",
            value: $delayMilliseconds,
            range: ActivationHoldDelay.millisecondRange,
            unit: "ms"
        )
    }
}

/// Legacy holder for the keyboard interaction-mode picker (Bringr-93j.91). Kept so
/// older callers compile; the Activation tab now uses the inline picker in
/// `KeyboardActivationSettings` instead.
struct KeyboardInteractionMode: View {
    @AppStorage(InteractionMode.keyboardDefaultsKey)
    private var modeRaw = InteractionMode.defaultForKeyboard.rawValue

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("When summoned:", selection: $modeRaw) {
                ForEach(InteractionMode.allCases, id: \.rawValue) { mode in
                    Text(mode.keyboardDisplayName).tag(mode.rawValue)
                }
            }
            .pickerStyle(.radioGroup)

            Text(modeHelp)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var modeHelp: String {
        switch InteractionMode(rawValue: modeRaw) ?? .defaultForKeyboard {
        case .holdToSelect:
            return "Keep holding the modifier keys, move the cursor to a slice, then release to choose."
        case .clickToStay:
            return "Tap the modifier keys to open the wheel; it stays open. Click a slice to choose, "
                 + "or the centre to cancel."
        }
    }
}

// MARK: - Two-slot block

/// The shortcut block shown in the Keyboard Activation pane. Owns the two
/// `@AppStorage` Data slots, applies migration on appear (defence in depth so an
/// upgrader who heads straight to Preferences still gets the new defaults), and
/// surfaces the one-time migration notice (AC: "a one-time in-app notice").
struct KeyboardShortcutPicker: View {
    @AppStorage(KeyboardShortcutStore.slot1Key)
    private var slot1Data: Data?
    @AppStorage(KeyboardShortcutStore.slot2Key)
    private var slot2Data: Data?
    @AppStorage(KeyboardShortcutStore.initialisedKey)
    private var initialised = false
    @State private var showsAddSecond = false
    @State private var migrationNotice: String?

    private var slot1: KeyboardShortcut? { decode(slot1Data) }
    private var slot2: KeyboardShortcut? { decode(slot2Data) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            KeyboardShortcutSlotView(
                label: "Shortcut 1",
                shortcut: slot1,
                placeholder: "Not set",
                onCommit: { write(.slot1, $0) },
                onClear: slot1 == nil ? nil : { write(.slot1, nil) },
                onReset: { write(.slot1, KeyboardShortcutStore.freshInstallSlot1) }
            )

            if slot2 != nil || showsAddSecond {
                KeyboardShortcutSlotView(
                    label: "Shortcut 2",
                    shortcut: slot2,
                    placeholder: "Not set",
                    onCommit: { write(.slot2, $0) },
                    onClear: {
                        write(.slot2, nil)
                        showsAddSecond = false
                    },
                    onReset: nil
                )
            } else {
                Button {
                    showsAddSecond = true
                } label: {
                    Label("Add second shortcut", systemImage: "plus.circle")
                }
                .buttonStyle(.borderless)
            }

            if let notice = migrationNotice {
                migrationBanner(notice)
            }
        }
        .onAppear {
            KeyboardShortcutStore.runMigrationIfNeeded()
            migrationNotice = KeyboardShortcutStore.consumeMigrationNotice()
            // If the migration left an explicit Shortcut 2, reveal it now.
            showsAddSecond = slot2 != nil
        }
    }

    private func migrationBanner(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "info.circle.fill")
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 4) {
                Text(text)
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Got it") { migrationNotice = nil }
                    .buttonStyle(.borderless)
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.accentColor.opacity(0.10))
        )
    }

    // MARK: - Persistence helpers

    private enum SlotID { case slot1, slot2 }

    private func write(_ slot: SlotID, _ shortcut: KeyboardShortcut?) {
        switch slot {
        case .slot1: KeyboardShortcutStore.setSlot1(shortcut)
        case .slot2: KeyboardShortcutStore.setSlot2(shortcut)
        }
        // `@AppStorage` reads the underlying defaults on the next render — nudge it.
        if !initialised { initialised = true }
    }

    private func decode(_ data: Data?) -> KeyboardShortcut? {
        guard let data else { return nil }
        struct Box: Codable { let value: KeyboardShortcut? }
        return (try? JSONDecoder().decode(Box.self, from: data))?.value
    }
}
