import SwiftUI

@main
struct BringrApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra {
            MenuContent(permissions: appDelegate.permissions, radialMenu: appDelegate.radialMenu)
        } label: {
            Image(systemName: "circle.hexagongrid")
        }
        .menuBarExtraStyle(.menu)

        Window("About Bringr", id: "about") {
            AboutView()
        }
        .windowResizability(.contentSize)
        .defaultPosition(.center)

        Window("Bringr Preferences", id: "preferences") {
            PreferencesView()
                .environmentObject(appDelegate.permissions)
        }
        .windowResizability(.contentSize)
        .defaultPosition(.center)
    }
}

private struct MenuContent: View {
    @ObservedObject var permissions: PermissionsManager
    let radialMenu: RadialMenuController?
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

        Button("About Bringr") {
            NSApp.activate(ignoringOtherApps: true)
            openWindow(id: "about")
        }

        Divider()

        Button("Quit Bringr") {
            NSApplication.shared.terminate(nil)
        }
        .keyboardShortcut("q")
    }

    private func openPreferences() {
        NSApp.activate(ignoringOtherApps: true)
        openWindow(id: "preferences")
    }
}
