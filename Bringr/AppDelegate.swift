import AppKit

/// Owns app-lifetime services and runs launch-time bootstrap.
///
/// This is the home for launch work that has no clean SwiftUI hook in a
/// menu-bar-only app: today the Accessibility-permission bootstrap, later the
/// overlay pre-warm (US-006) and the global activation taps (US-007/US-008).
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let permissions = PermissionsManager()
    private var permissionAlertWindow: PermissionAlertWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // The host app is launched by `xcodebuild test` to inject the test
        // bundle; the prompt below would block that run and pop a system
        // permission dialog, so skip the bootstrap under XCTest.
        guard !AppDelegate.isRunningTests else { return }

        permissions.startMonitoring()

        let suppressed = UserDefaults.standard.bool(forKey: PermissionAlertWindow.suppressDefaultsKey)
        if AppDelegate.shouldPresentPermissionAlert(isTrusted: permissions.isTrusted, suppressed: suppressed) {
            showPermissionAlert()
        }
    }

    /// Whether the launch-time permission alert should be shown: only when access
    /// is missing and the user has not opted out via "Don't show this again".
    nonisolated static func shouldPresentPermissionAlert(isTrusted: Bool, suppressed: Bool) -> Bool {
        !isTrusted && !suppressed
    }

    private func showPermissionAlert() {
        if permissionAlertWindow == nil {
            permissionAlertWindow = PermissionAlertWindow(permissions: permissions) { [weak self] in
                self?.dismissPermissionAlert()
            }
        }
        permissionAlertWindow?.center()

        let window = permissionAlertWindow
        DispatchQueue.main.async {
            window?.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    private func dismissPermissionAlert() {
        permissionAlertWindow?.close()
        permissionAlertWindow = nil
    }

    static var isRunningTests: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    }
}
