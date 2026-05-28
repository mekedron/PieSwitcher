import SwiftUI

/// The Preferences window. v1 surfaces Accessibility-permission status, the actions
/// to grant it, the interaction mode (US-009), and the wheel appearance (US-014).
struct PreferencesView: View {
    @EnvironmentObject private var permissions: PermissionsManager
    @EnvironmentObject private var launchAtLogin: LaunchAtLoginManager
    /// The persisted interaction mode. The same key is read by `RadialMenuController`
    /// (via `InteractionMode.current`), so a change here takes effect on the next summon.
    @AppStorage(InteractionMode.defaultsKey) private var interactionModeRaw = InteractionMode.default.rawValue
    /// Persisted appearance. The same keys are read by `RadialAppearance.current` at
    /// each summon, so changes apply on the next summon without a relaunch (AC2).
    @AppStorage(RadialAppearance.radiusDefaultsKey)
    private var outerRadius = Double(RadialAppearance.defaultOuterRadius)
    @AppStorage(RadialAppearance.opacityDefaultsKey)
    private var fillOpacity = RadialAppearance.defaultFillOpacity
    @AppStorage(RadialAppearance.labelsDefaultsKey)
    private var showsLabels = RadialAppearance.defaultShowsLabels
    /// The persisted reveal strategy. The same key is read by `RadialMenuController`
    /// (via `RevealStrategy.current`) at each summon, so a change here takes effect on
    /// the next summon without a relaunch (US-013 AC4).
    @AppStorage(RevealStrategy.defaultsKey) private var revealStrategyRaw = RevealStrategy.default.rawValue

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Permissions")
                .font(.title2)
                .bold()

            permissionSection

            Divider()

            Text("Startup")
                .font(.title2)
                .bold()

            startupSection

            Divider()

            Text("Interaction")
                .font(.title2)
                .bold()

            interactionSection

            Divider()

            Text("Reveal")
                .font(.title2)
                .bold()

            revealSection

            Divider()

            Text("Appearance")
                .font(.title2)
                .bold()

            appearanceSection

            Spacer(minLength: 0)
        }
        .padding(28)
        .frame(width: 460, height: 720)
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

    private var appearanceSection: some View {
        let minRadius = Double(RadialAppearance.radiusRange.lowerBound)
        let maxRadius = Double(RadialAppearance.radiusRange.upperBound)
        let opacityRange = RadialAppearance.opacityRange

        return VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Size")
                Slider(value: $outerRadius, in: minRadius...maxRadius)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text("Slice fill opacity")
                Slider(value: $fillOpacity, in: opacityRange)
            }

            Toggle("Show labels", isOn: $showsLabels)

            Text("Changes apply the next time you summon the wheel.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var interactionSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("When summoned:", selection: $interactionModeRaw) {
                ForEach(InteractionMode.allCases, id: \.rawValue) { mode in
                    Text(mode.displayName).tag(mode.rawValue)
                }
            }
            .pickerStyle(.radioGroup)

            Text(interactionHelp)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var interactionHelp: String {
        switch InteractionMode(rawValue: interactionModeRaw) ?? .default {
        case .holdToSelect:
            return "Release the trigger over a slice to choose it; release on the centre to cancel."
        case .clickToStay:
            return "The wheel stays open after release. Click a slice to choose it, or the centre to cancel."
        }
    }

    private var revealSection: some View {
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

#Preview {
    PreferencesView()
        .environmentObject(PermissionsManager(probe: { false }))
        .environmentObject(LaunchAtLoginManager(probe: { false }))
}
