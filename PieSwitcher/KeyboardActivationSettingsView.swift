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
