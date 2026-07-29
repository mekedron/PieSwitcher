import SwiftUI

/// The Dwell pane of the Selection tab (Bringr-93j.105
/// + Bringr-93j.107): the on/off toggle, the dwell duration slider, and the
/// drag-and-drop-only gate, with in-pane blurbs so a reader understands what each
/// option does before flipping it. Backed by a `PreferencesPane` `Form` so the rows
/// align with the rest of the window. All three keys write through `@AppStorage`;
/// `RadialMenuController` reads them once per summon via `DwellActivation.current()`,
/// so a change here takes effect on the next open without a relaunch.
struct DwellActivationSettings: View {
    @AppStorage(DwellActivation.enabledDefaultsKey)
    private var enabled = DwellActivation.defaultEnabled
    @AppStorage(DwellActivation.durationDefaultsKey)
    private var durationMilliseconds = DwellActivation.defaultDurationMilliseconds
    @AppStorage(DwellActivation.duringDragOnlyDefaultsKey)
    private var duringDragOnly = DwellActivation.defaultDuringDragOnly

    var body: some View {
        PreferencesPane {
            Section {
                Toggle("Auto-activate when the cursor rests on a slice", isOn: $enabled)
            } header: {
                Text("Dwell")
            } footer: {
                Text("Hover an app or window slice for a moment without moving the cursor "
                     + "and it activates automatically — no click or release needed. A "
                     + "progress stroke winds around that slice's full border so you can "
                     + "see how much longer to wait.")
            }

            Section {
                PreferencesSliderRow(
                    title: "Dwell duration",
                    value: secondsBinding($durationMilliseconds),
                    range: secondsRange(DwellActivation.durationMillisecondRange),
                    step: 0.1,
                    unit: "s",
                    fractionDigits: 1
                )
                .disabled(!enabled)
            } header: {
                Text("Duration")
            } footer: {
                Text("How long the cursor must rest on a slice before it auto-activates. "
                     + "Lower values mean the wheel feels more eager; higher values let you "
                     + "scan across slices without accidentally committing.")
            }

            Section {
                Toggle("Use dwell only during drag-and-drop", isOn: $duringDragOnly)
                    .disabled(!enabled)
            } header: {
                Text("When to dwell")
            } footer: {
                Text("With this on (recommended), dwell only auto-activates while you're "
                     + "dragging something — perfect for dropping a file or image into "
                     + "another app's window through the wheel, since you can't release "
                     + "the mouse to commit without dropping early. Outside of a drag the "
                     + "wheel commits only on release or click, so dwell never fires by "
                     + "surprise during normal use. Turn off to dwell at all times.")
            }
        }
    }

    /// Two-way mapping between the stored millisecond value and a seconds binding the
    /// slider/numeric field surface, so the row reads as "2.5 s" while the underlying
    /// defaults key stays in the millisecond unit the rest of the codebase uses.
    private func secondsBinding(_ milliseconds: Binding<Double>) -> Binding<Double> {
        Binding(
            get: { milliseconds.wrappedValue / 1000 },
            set: { milliseconds.wrappedValue = DwellActivation.clampMilliseconds($0 * 1000) }
        )
    }

    private func secondsRange(_ range: ClosedRange<Double>) -> ClosedRange<Double> {
        (range.lowerBound / 1000)...(range.upperBound / 1000)
    }
}
