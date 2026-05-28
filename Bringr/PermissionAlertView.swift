import SwiftUI

/// Contents of the launch-time Accessibility permission alert.
///
/// Improves on a static one-shot prompt by observing `PermissionsManager.isTrusted`:
/// the moment access is granted (picked up by the manager's live monitoring) the
/// window dismisses itself via `onClose`, so the constant dev re-grant loop needs no
/// manual "validate" step and no relaunch.
struct PermissionAlertView: View {
    @ObservedObject var permissions: PermissionsManager
    let onMoveAside: () -> Void
    let onClose: () -> Void

    @AppStorage(PermissionAlertWindow.suppressDefaultsKey) private var suppressAlert = false

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 40))
                .foregroundStyle(.orange)

            Text("Accessibility Access Needed")
                .font(.title2.bold())

            Text(
                "Bringr may have lost Accessibility access after a rebuild. macOS resets "
                + "permissions whenever an app's code signature changes. Grant access again "
                + "to keep enumerating and switching windows."
            )
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: 380)

            statusCard

            HStack(spacing: 12) {
                Button("Grant Accessibility Access") {
                    permissions.requestAccess()
                    onMoveAside()
                }
                .buttonStyle(.borderedProminent)

                Button("Open System Settings") {
                    permissions.openAccessibilitySettings()
                }
            }

            manualSteps

            Spacer(minLength: 0)

            HStack {
                Toggle("Don't show this again", isOn: $suppressAlert)
                    .toggleStyle(.checkbox)
                    .controlSize(.small)

                Spacer()

                Button("Close", action: onClose)
            }
        }
        .padding(32)
        .frame(width: 460, height: 580)
        .onChange(of: permissions.isTrusted) { _, trusted in
            if trusted { onClose() }
        }
    }

    private var statusCard: some View {
        HStack(spacing: 16) {
            Image(systemName: permissions.isTrusted ? "checkmark.circle.fill" : "hand.raised")
                .font(.title2)
                .foregroundStyle(permissions.isTrusted ? .green : .orange)
                .frame(width: 32)

            VStack(alignment: .leading, spacing: 2) {
                Text(permissions.status.title)
                    .font(.headline)
                Text(permissions.status.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder((permissions.isTrusted ? Color.green : Color.orange).opacity(0.3))
        )
    }

    private var manualSteps: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("If the Grant button doesn't work:", systemImage: "wrench.and.screwdriver")
                .font(.subheadline.bold())

            VStack(alignment: .leading, spacing: 4) {
                step("1", "Open System Settings \u{2192} Privacy & Security")
                step("2", "Select Accessibility")
                step("3", "Find Bringr in the list and remove it (select it, click \u{2013})")
                step("4", "Click + to add Bringr again, then turn its switch on")
            }
            .font(.subheadline)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.orange.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(.orange.opacity(0.3))
        )
    }

    private func step(_ number: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(number)
                .font(.subheadline.bold().monospacedDigit())
                .foregroundStyle(.orange)
                .frame(width: 16)
            Text(text)
        }
    }
}

#Preview {
    PermissionAlertView(
        permissions: PermissionsManager(probe: { false }),
        onMoveAside: {},
        onClose: {}
    )
}
