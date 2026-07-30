import SwiftUI

/// The Mouse pane of the Activation tab after the Bringr-93j.106 redesign. Every
/// control sits inside a `PreferencesPane`-backed `Form` so the rows align in a
/// clean two-column layout: a checklist of activation methods up top, a Timing
/// section for hold-delay and movement threshold, a Click-behaviour section for
/// suppress/lock, and finally the mouse interaction-mode picker. Every value
/// writes through `@AppStorage` and `MouseChordMonitor` reads them fresh on each
/// event, so a change takes effect on the next press without a relaunch.
struct MouseActivationSettings: View {
    @AppStorage(MouseActivationConfig.methodsDefaultsKey)
    private var methodsRaw = MouseActivationConfig.encodeMethods(MouseActivationConfig.defaultMethods)
    @AppStorage(MouseActivationHoldDelay.defaultsKey)
    private var delayMilliseconds = MouseActivationHoldDelay.defaultMilliseconds
    @AppStorage(MouseActivationMoveThreshold.defaultsKey)
    private var moveThresholdPoints = MouseActivationMoveThreshold.defaultPoints
    @AppStorage(MouseActivationConfig.blockingDefaultsKey)
    private var blocking = MouseActivationConfig.defaultBlocking
    @AppStorage(MouseActivationConfig.lockDefaultsKey)
    private var lock = MouseActivationConfig.defaultLock
    @AppStorage(InteractionMode.mouseDefaultsKey)
    private var modeRaw = InteractionMode.defaultForMouse.rawValue

    var body: some View {
        let methods = MouseActivationConfig.decodeMethods(bitmask: methodsRaw)
        PreferencesPane {
            Section {
                PreferencesParagraph(
                    "Middle click is the recommended default on macOS: it's one of the least-"
                    + "used mouse buttons (its only common roles are closing tabs and opening "
                    + "links in a new tab in browsers) and it has no scroll behaviour, which "
                    + "makes it the least disruptive button to capture."
                )
            }

            Section {
                methodChecklist
            } header: {
                Text("Activation methods")
            } footer: {
                Text(captionForMethods(methods))
            }

            Section {
                PreferencesSliderRow(
                    title: "Hold delay",
                    value: $delayMilliseconds,
                    range: MouseActivationHoldDelay.millisecondRange,
                    unit: "ms"
                )

                PreferencesSliderRow(
                    title: "Cancel if cursor moves",
                    value: $moveThresholdPoints,
                    range: MouseActivationMoveThreshold.pointRange,
                    unit: "pt"
                )
            } header: {
                Text("Timing")
            } footer: {
                Text("Hold the chosen buttons at least this long before the wheel opens; a "
                     + "progress ring fills around the cursor while you wait (switch it off "
                     + "in Appearance › Display). Cursor drift "
                     + "beyond the threshold counts as a drag and the wheel doesn't open — "
                     + "raise it if a steady hold keeps getting cancelled by tiny jitter.")
            }

            Section {
                Toggle("Suppress normal click while waiting", isOn: $blocking)
                Toggle("Lock mouse-button action while holding", isOn: $lock)
            } header: {
                Text("Click behaviour")
            } footer: {
                Text("Suppress defers the focused app's normal click until the wait elapses "
                     + "(short tap still clicks; long hold summons). Lock is stronger: when "
                     + "the wheel opens, every event of the activation button is dropped, so "
                     + "there's no ghost click. A short tap still fires normally. Avoid Lock "
                     + "for Left/Right click — text selection and context menus start on "
                     + "mouseDown, so locking those feels unresponsive.")
            }

            Section {
                Picker("When summoned", selection: $modeRaw) {
                    ForEach(InteractionMode.allCases, id: \.rawValue) { mode in
                        Text(mode.displayName).tag(mode.rawValue)
                    }
                }
                .pickerStyle(.radioGroup)
            } header: {
                Text("Interaction")
            } footer: {
                Text(modeHelp)
            }
        }
    }

    /// The seven multi-selectable activation methods, listed in the order they were added so
    /// the existing left+right chord stays first (Bringr-93j.96).
    private var methodChecklist: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(MouseActivationMethod.allCases, id: \.rawValue) { method in
                Toggle(method.displayName, isOn: binding(for: method))
                    .toggleStyle(.checkbox)
            }
        }
    }

    private func binding(for method: MouseActivationMethod) -> Binding<Bool> {
        Binding(
            get: { MouseActivationConfig.decodeMethods(bitmask: methodsRaw).contains(method) },
            set: { isOn in
                var methods = MouseActivationConfig.decodeMethods(bitmask: methodsRaw)
                if isOn { methods.insert(method) } else { methods.remove(method) }
                methodsRaw = MouseActivationConfig.encodeMethods(methods)
            }
        )
    }

    private func captionForMethods(_ methods: Set<MouseActivationMethod>) -> String {
        guard !methods.isEmpty else {
            return "Pick one or more mouse combinations to summon the wheel. Until then, "
                + "the keyboard shortcut is the only way to summon it."
        }
        let names = MouseActivationMethod.allCases
            .filter { methods.contains($0) }
            .map(\.displayName)
            .joined(separator: ", ")
        return "Enabled: \(names). Any one of these summons the wheel."
    }

    private var modeHelp: String {
        switch InteractionMode(rawValue: modeRaw) ?? .defaultForMouse {
        case .holdToSelect:
            return "Hold the chord, glide to a slice, release to choose; release on the centre to cancel."
        case .clickToStay:
            return "The wheel stays open after release. Click a slice to choose it, or the centre to cancel."
        }
    }
}

/// The mouse's interaction-mode picker (US-009 / Bringr-93j.91). Kept as a standalone
/// view so older callers that referenced it directly continue to compile; the
/// Activation tab now folds the picker into `MouseActivationSettings` so the whole
/// mouse pane reads as one cohesive Form (Bringr-93j.106).
struct MouseInteractionMode: View {
    @AppStorage(InteractionMode.mouseDefaultsKey)
    private var modeRaw = InteractionMode.defaultForMouse.rawValue

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("When summoned:", selection: $modeRaw) {
                ForEach(InteractionMode.allCases, id: \.rawValue) { mode in
                    Text(mode.displayName).tag(mode.rawValue)
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
        switch InteractionMode(rawValue: modeRaw) ?? .defaultForMouse {
        case .holdToSelect:
            return "Hold the chord, glide to a slice, release to choose; release on the centre to cancel."
        case .clickToStay:
            return "The wheel stays open after release. Click a slice to choose it, or the centre to cancel."
        }
    }
}
