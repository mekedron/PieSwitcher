import SwiftUI

@main
struct PieSwitcherApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra {
            MenuContent(
                permissions: appDelegate.permissions,
                radialMenu: appDelegate.radialMenu,
                updater: appDelegate.updater,
                onboarding: appDelegate.onboarding
            )
        } label: {
            Image(systemName: "circle.hexagongrid")
        }
        .menuBarExtraStyle(.menu)

        // Bringr-93j.97 folded the former standalone "About" window into Preferences as a
        // tab, so this scene is the only window the app ships now. The menu bar's "About
        // PieSwitcher" item writes `PreferencesTab.about` into UserDefaults before
        // calling `openWindow(id: "preferences")`, so it lands on the About tab.
        Window("PieSwitcher Preferences", id: "preferences") {
            PreferencesView()
                .environmentObject(appDelegate.permissions)
                .environmentObject(appDelegate.launchAtLogin)
                .onAppear { appDelegate.dockIcon.windowOpened() }
                .onDisappear { appDelegate.dockIcon.windowClosed() }
        }
        .windowResizability(.contentSize)
        .defaultPosition(.center)
    }
}

private struct MenuContent: View {
    @ObservedObject var permissions: PermissionsManager
    let radialMenu: RadialMenuController?
    let updater: SparkleUpdater
    let onboarding: OnboardingPresenter
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        if !permissions.isTrusted {
            Button {
                openPreferences()
            } label: {
                Label("Grant Accessibility Access…", systemImage: "exclamationmark.triangle.fill")
            }
            Divider()
        }

        if let radialMenu {
            Button("Open Window Switcher") {
                radialMenu.summonFromMenuBar(at: NSEvent.mouseLocation)
            }
            Divider()
        }

        Button("Preferences…") {
            openPreferences()
        }
        .keyboardShortcut(",")

        Button("Show Welcome…") {
            NSApp.activate(ignoringOtherApps: true)
            onboarding.showFromMenu()
        }

        Button("Check for Updates…") {
            updater.checkForUpdates()
        }

        Button("About PieSwitcher") {
            openPreferences(on: .about)
        }

        Divider()

        Button("Quit PieSwitcher") {
            NSApplication.shared.terminate(nil)
        }
        .keyboardShortcut("q")
    }

    /// Activate the app and open Preferences, optionally pre-selecting a tab. When `tab`
    /// is supplied we write the persisted key first so the TabView's `@AppStorage` picks
    /// it up the moment the window mounts (or, if already open, snaps to the new
    /// selection); when omitted, the window reopens on the last-used tab.
    private func openPreferences(on tab: PreferencesTab? = nil) {
        if let tab {
            UserDefaults.standard.set(tab.rawValue, forKey: PreferencesTab.defaultsKey)
        }
        NSApp.activate(ignoringOtherApps: true)
        openWindow(id: "preferences")
    }
}
