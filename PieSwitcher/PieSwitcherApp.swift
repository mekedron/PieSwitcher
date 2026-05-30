import SwiftUI

@main
struct PieSwitcherApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra {
            MenuContent(
                permissions: appDelegate.permissions,
                radialMenu: appDelegate.radialMenu,
                updater: appDelegate.updater
            )
        } label: {
            Image(systemName: "circle.hexagongrid")
        }
        .menuBarExtraStyle(.menu)

        Window("About PieSwitcher", id: "about") {
            AboutView()
        }
        .windowResizability(.contentSize)
        .defaultPosition(.center)

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

        Button("Check for Updates…") {
            updater.checkForUpdates()
        }

        Button("About PieSwitcher") {
            NSApp.activate(ignoringOtherApps: true)
            openWindow(id: "about")
        }

        Divider()

        Button("Quit PieSwitcher") {
            NSApplication.shared.terminate(nil)
        }
        .keyboardShortcut("q")
    }

    private func openPreferences() {
        NSApp.activate(ignoringOtherApps: true)
        openWindow(id: "preferences")
    }
}
