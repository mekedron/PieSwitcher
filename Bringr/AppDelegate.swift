import AppKit
import Combine

/// Owns app-lifetime services and runs launch-time bootstrap.
///
/// This is the home for launch work that has no clean SwiftUI hook in a
/// menu-bar-only app: today the Accessibility-permission bootstrap, later the
/// overlay pre-warm (US-006) and the global activation taps (US-007/US-008).
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let permissions = PermissionsManager()
    /// The pre-warmed radial menu, summoned by the menu-bar item (and, later, the
    /// global activation triggers in US-007/US-008). `nil` under XCTest, where the
    /// launch bootstrap is skipped.
    private(set) var radialMenu: RadialMenuController?
    private var permissionAlertWindow: PermissionAlertWindow?
    /// Global left+right mouse-chord activation (US-007). `nil` under XCTest.
    private var activationMonitor: MouseChordMonitor?
    /// Global three-finger trackpad-press activation (US-008). `nil` under XCTest,
    /// or when MultitouchSupport / a trackpad is unavailable on the host.
    private var trackpadMonitor: ThreeFingerMonitor?
    private var trustCancellable: AnyCancellable?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // The host app is launched by `xcodebuild test` to inject the test
        // bundle; the prompt below would block that run and pop a system
        // permission dialog, so skip the bootstrap under XCTest.
        guard !AppDelegate.isRunningTests else { return }

        permissions.startMonitoring()
        prewarmRadialMenu()
        startActivationMonitor()
        startTrackpadMonitor()

        let suppressed = UserDefaults.standard.bool(forKey: PermissionAlertWindow.suppressDefaultsKey)
        if AppDelegate.shouldPresentPermissionAlert(isTrusted: permissions.isTrusted, suppressed: suppressed) {
            showPermissionAlert()
        }
    }

    /// Build the menu registry and the overlay window now, at launch, so a summon
    /// never allocates the window on the hot path (US-006 / FR-14). The v1 window
    /// switcher answers both activation triggers.
    private func prewarmRadialMenu() {
        let enumerator = WindowEnumerator()
        let switcher = WindowSwitcherMenu(enumerator: enumerator)
        let registry = MenuRegistry()
        registry.register(switcher, for: .mouseChord)
        registry.register(switcher, for: .threeFingerPress)
        radialMenu = RadialMenuController(registry: registry)
    }

    /// Install the global mouse-chord tap (US-007). The tap needs Accessibility
    /// permission, so it may fail on first launch of an untrusted dev build; we
    /// retry the instant `PermissionsManager` reports trust, with no relaunch.
    private func startActivationMonitor() {
        let monitor = MouseChordMonitor(
            onChord: { [weak self] in
                guard let self, let radialMenu = self.radialMenu else { return }
                radialMenu.triggerPressed(for: .mouseChord, at: NSEvent.mouseLocation)
            },
            onChordReleased: { [weak self] in
                self?.radialMenu?.triggerReleased(at: NSEvent.mouseLocation)
            }
        )
        activationMonitor = monitor
        monitor.start()

        trustCancellable = permissions.$isTrusted
            .sink { [weak self] trusted in
                if trusted { self?.activationMonitor?.start() }
            }
    }

    /// Install the global three-finger trackpad monitor (US-008). Unlike the mouse
    /// tap, MultitouchSupport needs no Accessibility permission, so it starts
    /// outright; if the framework or a trackpad is missing it degrades gracefully
    /// (logs, no crash) and three-finger activation is simply unavailable.
    private func startTrackpadMonitor() {
        let monitor = ThreeFingerMonitor(
            onPress: { [weak self] in
                guard let self, let radialMenu = self.radialMenu else { return }
                radialMenu.triggerPressed(for: .threeFingerPress, at: NSEvent.mouseLocation)
            },
            onRelease: { [weak self] in
                self?.radialMenu?.triggerReleased(at: NSEvent.mouseLocation)
            }
        )
        trackpadMonitor = monitor
        monitor.start()
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
