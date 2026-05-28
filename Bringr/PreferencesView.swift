import SwiftUI

/// The Preferences window. v1 surfaces Accessibility-permission status, the actions
/// to grant it, and the interaction mode (US-009); later stories (US-013/US-014) add
/// their settings here as additional sections.
struct PreferencesView: View {
    @EnvironmentObject private var permissions: PermissionsManager
    /// The persisted interaction mode. The same key is read by `RadialMenuController`
    /// (via `InteractionMode.current`), so a change here takes effect on the next summon.
    @AppStorage(InteractionMode.defaultsKey) private var interactionModeRaw = InteractionMode.default.rawValue

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Permissions")
                .font(.title2)
                .bold()

            permissionSection

            Divider()

            Text("Interaction")
                .font(.title2)
                .bold()

            interactionSection

            Spacer(minLength: 0)
        }
        .padding(28)
        .frame(width: 460, height: 380)
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
}
