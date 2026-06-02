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
    /// Backs the "Launch at login" toggle in Preferences (Bringr-toj).
    let launchAtLogin = LaunchAtLoginManager()
    /// Shows a Dock icon while the Preferences window is open and hides it again when
    /// it closes, so the menu-bar-only app behaves like a normal windowed app while a
    /// window is up (Bringr-93j.45). Driven by the Preferences window's
    /// appear/disappear in `PieSwitcherApp`.
    let dockIcon = DockIconManager()
    /// Sparkle auto-updater (Bringr-jz4). No-ops until `start()` is called and only
    /// actually starts polling when `SUFeedURL` is set in Info.plist, so debug builds
    /// without an appcast wired up stay quiet.
    let updater = SparkleUpdater()
    /// Owns the first-launch onboarding window and the "Show Welcome…" menu entry
    /// (Bringr-93j.112). Eagerly constructed via `lazy var` so the menu-bar SwiftUI
    /// scene — which captures `appDelegate.onboarding` at scene-build time, before
    /// `applicationDidFinishLaunching` runs — sees a non-nil presenter and the "Show
    /// Welcome…" item renders. Re-clicks reuse the same instance because the lazy
    /// initializer fires only once.
    private(set) lazy var onboarding = OnboardingPresenter(
        permissions: permissions,
        dockIcon: dockIcon
    )
    /// The pre-warmed radial menu, summoned by the menu-bar item (and, later, the
    /// global activation triggers in US-007/US-008). `nil` under XCTest, where the
    /// launch bootstrap is skipped.
    private(set) var radialMenu: RadialMenuController?
    private var permissionAlertWindow: PermissionAlertWindow?
    /// Global left+right mouse-chord activation (US-007). `nil` under XCTest.
    private var activationMonitor: MouseChordMonitor?
    /// Global modifier-key hold activation (Bringr-93j.35) — the keyboard shortcut (formerly
    /// split into the trackpad's trigger and the mouse's modifier option, unified in
    /// Bringr-93j.69), replacing the three-finger press. `nil` under XCTest.
    private var modifierMonitor: ModifierHoldMonitor?
    /// Global keyDown tap for optional keyboard navigation of the wheel (Bringr-93j.71). `nil`
    /// under XCTest. Always installed but only consumes keys while the menu is open with the
    /// feature on.
    private var keyboardNavMonitor: KeyboardNavMonitor?
    /// Pre-warmed cursor-progress indicator (Bringr-93j.103). Lit while either monitor's
    /// hold-delay timer is running, so the user can see how much longer they need to hold
    /// before the wheel opens. `nil` under XCTest.
    private var holdProgress: HoldProgressController?
    private var trustCancellable: AnyCancellable?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // The host app is launched by `xcodebuild test` to inject the test
        // bundle; the prompt below would block that run and pop a system
        // permission dialog, so skip the bootstrap under XCTest.
        guard !AppDelegate.isRunningTests else { return }

        permissions.startMonitoring()
        // Bringr-93j.111: migrate the legacy `activation.keyboard.modifiers` bitmask into
        // the new two-slot shortcut model before any monitor reads from defaults, so the
        // first event tap callback already sees the migrated configuration.
        KeyboardShortcutStore.runMigrationIfNeeded()
        prewarmRadialMenu()
        // Pre-warm the hold-progress indicator before the activation monitors so their
        // initialisers can capture a non-nil reference for the progress callbacks.
        holdProgress = HoldProgressController()
        startActivationMonitor()
        startModifierMonitor()
        startKeyboardNavMonitor()
        updater.start()

        // First-launch auto-open (Bringr-93j.112). The presenter is the same
        // `lazy var` the menu bar reads, so first access here is also the one
        // that constructs it — no separate code path that could drift.
        onboarding.showOnAutoOpenIfNeeded()

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
        // The curated "My Apps" wheel (Bringr-93j.41); it falls through to the full
        // all-running-apps wheel when the user has curated nothing.
        let switcher = MyAppsMenu(enumerator: enumerator)
        let registry = MenuRegistry()
        registry.register(switcher, for: .mouseChord)
        registry.register(switcher, for: .modifierHold)

        // A store-backed controller journals each reveal to disk; replay any reveal a
        // prior crash left stranded before the first summon (US-015 AC3).
        let windowControl = WindowController(store: RevealStateStore())
        windowControl.restoreFromSnapshotIfNeeded()
        radialMenu = RadialMenuController(registry: registry, windowControl: windowControl)
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
            },
            onProgressStart: { [weak self] duration in
                self?.holdProgress?.start(duration: duration)
            },
            onProgressEnd: { [weak self] in
                self?.holdProgress?.cancel()
            }
        )
        activationMonitor = monitor
        monitor.start()

        trustCancellable = permissions.$isTrusted
            .sink { [weak self] trusted in
                guard trusted, let self else { return }
                // Both taps need Accessibility permission, so retry them the instant the
                // user grants it — no relaunch (US-002).
                self.activationMonitor?.start()
                self.modifierMonitor?.start()
                self.keyboardNavMonitor?.start()
            }
    }

    /// Install the global modifier-key hold monitor (Bringr-93j.35) — the keyboard shortcut.
    /// Like the mouse-chord tap it needs Accessibility permission, so it may fail on first
    /// launch of an untrusted build and is retried the moment trust is granted; it never
    /// consumes a modifier key.
    private func startModifierMonitor() {
        let monitor = ModifierHoldMonitor(
            onPress: { [weak self] in
                guard let self, let radialMenu = self.radialMenu else { return }
                radialMenu.triggerPressed(for: .modifierHold, at: NSEvent.mouseLocation)
            },
            onRelease: { [weak self] in
                self?.radialMenu?.triggerReleased(at: NSEvent.mouseLocation)
            },
            onProgressStart: { [weak self] duration in
                self?.holdProgress?.start(duration: duration)
            },
            onProgressEnd: { [weak self] in
                self?.holdProgress?.cancel()
            }
        )
        modifierMonitor = monitor
        monitor.start()
    }

    /// Install the global keyboard-navigation tap (Bringr-93j.71). Like the other taps it needs
    /// Accessibility permission and is retried when trust is granted; it only consumes keys while
    /// the menu is open with keyboard navigation enabled, passing everything else through.
    private func startKeyboardNavMonitor() {
        let monitor = KeyboardNavMonitor(
            isActive: { [weak self] in self?.radialMenu?.acceptsKeyboardNav ?? false },
            onKey: { [weak self] key in self?.radialMenu?.handleKeyboardNavKey(key) ?? false }
        )
        keyboardNavMonitor = monitor
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
