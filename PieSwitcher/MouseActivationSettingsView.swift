import SwiftUI

/// The Mouse section of Preferences: which `MouseActivationMethod`s are enabled, the hold
/// delay before the wheel opens, and the blocking toggle that decides whether the buttons'
/// normal actions are suppressed during the hold-delay window (Bringr-93j.96).
///
/// All three values write through `@AppStorage`, and `MouseChordMonitor` reads them fresh
/// on every event, so a change here takes effect on the next press without a relaunch.
struct MouseActivationSettings: View {
    @AppStorage(MouseActivationConfig.methodsDefaultsKey)
    private var methodsRaw = MouseActivationConfig.encodeMethods(MouseActivationConfig.defaultMethods)
    @AppStorage(MouseActivationHoldDelay.defaultsKey)
    private var delayMilliseconds = MouseActivationHoldDelay.defaultMilliseconds
    @AppStorage(MouseActivationConfig.blockingDefaultsKey)
    private var blocking = MouseActivationConfig.defaultBlocking

    var body: some View {
        let methods = MouseActivationConfig.decodeMethods(bitmask: methodsRaw)
        return VStack(alignment: .leading, spacing: 12) {
            methodChecklist

            Text(captionForMethods(methods))
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Divider()

            holdDelayPicker

            Divider()

            blockingToggle
        }
    }

    /// The seven multi-selectable activation methods, listed in the order they were added so
    /// the existing left+right chord stays first (Bringr-93j.96).
    private var methodChecklist: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Activation methods")
            ForEach(MouseActivationMethod.allCases, id: \.rawValue) { method in
                Toggle(method.displayName, isOn: binding(for: method))
                    .toggleStyle(.checkbox)
            }
        }
    }

    private var holdDelayPicker: some View {
        let value = Binding(
            get: { delayMilliseconds },
            set: { delayMilliseconds = MouseActivationHoldDelay.clampMilliseconds($0) }
        )
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Text("Hold delay")
                Slider(value: value, in: MouseActivationHoldDelay.millisecondRange)
                TextField("", value: value, format: .number.precision(.fractionLength(0)))
                    .frame(width: 52)
                    .multilineTextAlignment(.trailing)
                    .textFieldStyle(.roundedBorder)
                Text("ms")
            }

            Text("Hold the chosen buttons at least this long before the wheel opens. "
                 + "At 0 ms a multi-button chord (e.g. Left + Right) opens the instant both "
                 + "buttons are held; a longer delay lets you dismiss it by releasing before "
                 + "it elapses. Single-button methods (Middle, Forward, Backward) always need "
                 + "a brief hold so a quick tap stays a normal click.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var blockingToggle: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle("Suppress normal click while waiting", isOn: $blocking)

            Text(blocking
                 ? "Each activation button's normal action is delayed during the hold-delay "
                   + "window. A short tap fires the click as usual; holding past the delay "
                   + "summons the wheel and the click is skipped."
                 : "Each activation button's normal action fires immediately. The wheel "
                   + "summons in parallel once the hold delay elapses, but the click is not "
                   + "suppressed. This keeps the rest of the OS feeling lag-free.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
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
}
