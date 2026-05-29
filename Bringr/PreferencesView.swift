import SwiftUI

/// The Preferences window. v1 surfaces Accessibility-permission status, the actions
/// to grant it, the interaction mode (US-009), and the wheel appearance (US-014).
struct PreferencesView: View {
    @EnvironmentObject private var permissions: PermissionsManager
    @EnvironmentObject private var launchAtLogin: LaunchAtLoginManager
    /// Whether the wheel appends the other running apps after the curated block
    /// (Bringr-93j.42). `MyAppsMenu` reads the same key via `CuratedApps.showsOtherRunningApps`
    /// fresh at each summon, so a change here applies on the next open without a relaunch.
    @AppStorage(CuratedApps.showOtherRunningAppsDefaultsKey)
    private var showsOtherRunningApps = CuratedApps.showOtherRunningAppsDefault
    /// How the mouse and trackpad summon the menu (Bringr-93j.35). The same keys are read
    /// fresh by the activation monitors, so a change here takes effect with no relaunch.
    @AppStorage(MouseActivationMethod.defaultsKey)
    private var mouseMethodRaw = MouseActivationMethod.default.rawValue
    @AppStorage(ModifierActivation.mouseDefaultsKey)
    private var mouseModifiersRaw = ModifierActivation.mouseDefault.rawValue
    @AppStorage(ModifierActivation.trackpadDefaultsKey)
    private var trackpadModifiersRaw = ModifierActivation.trackpadDefault.rawValue

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                section("Permissions", isFirst: true) { permissionSection }
                section("Mouse") { mouseSection }
                section("Trackpad") { trackpadSection }
                section("Startup") { startupSection }
                section("Interaction") { interactionSection }
                section("Reveal") { revealSection }
                section("Sorting") { SortingSettings() }
                section("Collection") { collectionSection }
                section("Excluded Apps") { IgnoreListSettings() }
                section("My Apps") { myAppsSection }
                section("Appearance") { AppearanceSettings() }
            }
            .padding(28)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(width: 460, height: 600)
    }

    /// One titled settings group. Every section but the first is preceded by a
    /// divider, so adding a setting is a single `section(_:)` call and the window
    /// scrolls rather than stretching taller as more settings land here.
    @ViewBuilder
    private func section<Content: View>(
        _ title: String,
        isFirst: Bool = false,
        @ViewBuilder content: () -> Content
    ) -> some View {
        if !isFirst {
            Divider()
        }
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.title2)
                .bold()
            content()
        }
    }

    private var startupSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle(
                "Launch Bringr at login",
                isOn: Binding(
                    get: { launchAtLogin.isEnabled },
                    set: { launchAtLogin.setEnabled($0) }
                )
            )

            Text("Bringr starts automatically when you log in and runs in the menu bar.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var mouseSection: some View {
        let method = MouseActivationMethod(rawValue: mouseMethodRaw) ?? .default
        return VStack(alignment: .leading, spacing: 10) {
            Picker("Activate with:", selection: $mouseMethodRaw) {
                ForEach(MouseActivationMethod.allCases, id: \.rawValue) { method in
                    Text(method.displayName).tag(method.rawValue)
                }
            }
            .pickerStyle(.radioGroup)

            ModifierKeysPicker(rawValue: $mouseModifiersRaw)
                .disabled(method != .modifierKeys)
                .opacity(method == .modifierKeys ? 1 : 0.4)

            ModifierHoldDelayPicker()
                .disabled(method != .modifierKeys)
                .opacity(method == .modifierKeys ? 1 : 0.4)

            Text(mouseHelp(method: method))
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func mouseHelp(method: MouseActivationMethod) -> String {
        switch method {
        case .leftRightClick:
            return "Press the left and right mouse buttons together to summon the wheel."
        case .modifierKeys:
            let combo = ModifierCombination(rawValue: mouseModifiersRaw).intersection(.all)
            return combo.isEmpty
                ? "Pick one or more modifier keys to hold. Until then, the mouse can't summon the wheel."
                : "Hold \(combo.names) to summon the wheel, then release to choose."
        }
    }

    private var trackpadSection: some View {
        let combo = ModifierCombination(rawValue: trackpadModifiersRaw).intersection(.all)
        return VStack(alignment: .leading, spacing: 10) {
            ModifierKeysPicker(rawValue: $trackpadModifiersRaw)

            ModifierHoldDelayPicker()

            Text(combo.isEmpty
                 ? "Pick one or more modifier keys to hold. Until then, the trackpad can't summon the wheel."
                 : "Hold \(combo.names) to summon the wheel — no click or tap needed — then release to choose.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            TrackpadHapticsSettings()
        }
    }

    private var interactionSection: some View {
        InteractionSettings()
    }

    private var revealSection: some View {
        RevealSettings()
    }

    private var collectionSection: some View {
        CollectionSettings()
    }

    private var myAppsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            MyAppsEditor()

            VStack(alignment: .leading, spacing: 8) {
                Toggle("Show all other running apps", isOn: $showsOtherRunningApps)

                Text("When on, every other app with a window on the current screen follows your "
                     + "pinned apps. When off, the wheel shows only your pinned apps.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var permissionSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: permissions.status.symbolName)
                    .font(.title3)
                    .foregroundStyle(permissions.isTrusted ? Color.green : Color.orange)
                Text(permissions.status.title)
                    .font(.headline)
            }

            Text(permissions.status.detail)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 12) {
                if !permissions.isTrusted {
                    Button("Open System Settings") {
                        permissions.openAccessibilitySettings()
                    }
                    .buttonStyle(.borderedProminent)
                }

                Button("Re-check") {
                    permissions.recheck()
                }
            }
            .padding(.top, 4)
        }
    }
}

/// The interaction-mode picker (US-009) and the optional second-level cursor-lock toggle
/// (Bringr-93j.29), grouped in their own view so the Preferences body stays within its
/// length budget. Both keys are read fresh at each summon by `RadialMenuController`, so a
/// change here applies on the next open without a relaunch.
private struct InteractionSettings: View {
    @AppStorage(InteractionMode.defaultsKey) private var modeRaw = InteractionMode.default.rawValue
    @AppStorage(CursorLock.defaultsKey) private var cursorLockEnabled = CursorLock.default

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
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

            VStack(alignment: .leading, spacing: 8) {
                Toggle("Lock the cursor inside an app's windows", isOn: $cursorLockEnabled)

                Text("When you open an app's windows, keep the pointer on that app and its "
                     + "windows so it can't slip onto another app. Move back onto the app to "
                     + "release it.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var modeHelp: String {
        switch InteractionMode(rawValue: modeRaw) ?? .default {
        case .holdToSelect:
            return "Release the trigger over a slice to choose it; release on the centre to cancel."
        case .clickToStay:
            return "The wheel stays open after release. Click a slice to choose it, or the centre to cancel."
        }
    }
}

/// The reveal-strategy picker (US-013) and the optional "leave only my selection on
/// screen" toggle (Bringr-93j.27), grouped in their own view so the Preferences body
/// stays within its length budget. Both keys are read fresh at each summon by
/// `RadialMenuController`, so a change here applies on the next open without a relaunch.
private struct RevealSettings: View {
    @AppStorage(RevealStrategy.defaultsKey) private var revealStrategyRaw = RevealStrategy.default.rawValue
    @AppStorage(HideOnCommit.defaultsKey) private var hideOnCommit = HideOnCommit.default

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 8) {
                Picker("When hovering:", selection: $revealStrategyRaw) {
                    ForEach(RevealStrategy.allCases, id: \.rawValue) { strategy in
                        Text(strategy.displayName).tag(strategy.rawValue)
                    }
                }
                .pickerStyle(.radioGroup)

                Text((RevealStrategy(rawValue: revealStrategyRaw) ?? .default).detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(alignment: .leading, spacing: 8) {
                Toggle("Leave only my selection on screen", isOn: $hideOnCommit)

                Text("After you choose, hide everything else so only your selection remains. "
                     + "Picking a window minimizes its app's other windows and hides every other "
                     + "app; picking an app leaves just its front window.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// A row of checkboxes for the five modifier keys, backed by a bitmask in `UserDefaults`
/// so any combination round-trips through one `@AppStorage` value (Bringr-93j.35).
private struct ModifierKeysPicker: View {
    @Binding var rawValue: Int

    var body: some View {
        HStack(spacing: 14) {
            ForEach(ModifierCombination.keys) { key in
                Toggle(key.name, isOn: binding(for: key.modifier))
                    .toggleStyle(.checkbox)
            }
        }
    }

    private func binding(for modifier: ModifierCombination) -> Binding<Bool> {
        Binding(
            get: { ModifierCombination(rawValue: rawValue).contains(modifier) },
            set: { isOn in
                var combo = ModifierCombination(rawValue: rawValue).intersection(.all)
                if isOn { combo.insert(modifier) } else { combo.remove(modifier) }
                rawValue = combo.rawValue
            }
        )
    }
}

/// A slider plus a numeric field for the modifier hold delay (Bringr-93j.58). Rendered in
/// both the Mouse and Trackpad sections; both bind the one key, so editing either keeps
/// them in sync. `ModifierHoldMonitor` reads the same key fresh on each hold, so a change
/// applies on the next summon without a relaunch.
private struct ModifierHoldDelayPicker: View {
    @AppStorage(ActivationHoldDelay.defaultsKey)
    private var delayMilliseconds = ActivationHoldDelay.defaultMilliseconds

    var body: some View {
        let value = Binding(
            get: { delayMilliseconds },
            set: { delayMilliseconds = ActivationHoldDelay.clampMilliseconds($0) }
        )
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Text("Hold delay")
                Slider(value: value, in: ActivationHoldDelay.millisecondRange)
                TextField("", value: value, format: .number.precision(.fractionLength(0)))
                    .frame(width: 52)
                    .multilineTextAlignment(.trailing)
                    .textFieldStyle(.roundedBorder)
                Text("ms")
            }

            Text("Hold the keys at least this long before the wheel opens, so a quick tap "
                 + "(like Fn to switch the input language) won't summon it. Shared by Mouse "
                 + "and Trackpad.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

#Preview {
    PreferencesView()
        .environmentObject(PermissionsManager(probe: { false }))
        .environmentObject(LaunchAtLoginManager(probe: { false }))
}
