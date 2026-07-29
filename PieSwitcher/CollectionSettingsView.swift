import SwiftUI

/// The Scope pane of the Contents tab (Bringr-93j.48).
/// Folds the per-level "all screens" toggles, the minimized/hidden inclusion toggles,
/// and the Dock-app inclusion toggle (Bringr-93j.98) into a single `PreferencesPane`-
/// backed `Form` so the rows align with the rest of the window. Keys are read fresh at
/// each summon via `CollectionPreferences.current`, so a change applies on the next open
/// without a relaunch.
///
/// Bringr-93j.77: the two "all Spaces" checkboxes are commented out (not deleted). They
/// were the source of the phantom-window and off-Space collection issues (Bringr-93j.54)
/// and aren't needed right now, but may be useful again. Only the UI is removed — the
/// backing implementation is left intact.
struct CollectionSettings: View {
    @AppStorage(CollectionPreferences.appsAllScreensDefaultsKey)
    private var appsAllScreens = CollectionPreferences.appsAllScreensDefault
    @AppStorage(CollectionPreferences.windowsAllScreensDefaultsKey)
    private var windowsAllScreens = CollectionPreferences.windowsAllScreensDefault
    @AppStorage(CollectionPreferences.includeMinimizedDefaultsKey)
    private var includeMinimized = CollectionPreferences.includeMinimizedDefault
    @AppStorage(CollectionPreferences.includeHiddenDefaultsKey)
    private var includeHidden = CollectionPreferences.includeHiddenDefault
    @AppStorage(CollectionPreferences.includeAllDockAppsDefaultsKey)
    private var includeAllDockApps = CollectionPreferences.includeAllDockAppsDefault

    var body: some View {
        PreferencesPane {
            Section {
                Toggle("Include apps from all screens", isOn: $appsAllScreens)
                Toggle("Include windows from all screens", isOn: $windowsAllScreens)
            } header: {
                Text("Screens")
            } footer: {
                Text("When off, the wheel only sees apps and windows on the screen you "
                     + "summon from. Spanning all screens needs your displays to share one "
                     + "Space (System Settings ▸ Desktop & Dock).")
            }

            Section {
                Toggle("Include minimized windows", isOn: $includeMinimized)
                Toggle("Include hidden windows", isOn: $includeHidden)
            } header: {
                Text("Minimized & hidden")
            } footer: {
                Text("Minimized windows and windows of apps you've hidden (Hide, ⌘H — "
                     + "including ones PieSwitcher hides for you) are normally left out. "
                     + "Turn these on to include them in the wheel.")
            }

            Section {
                Toggle("Include all apps from the Dock", isOn: $includeAllDockApps)
            } header: {
                Text("Dock apps")
            } footer: {
                Text("Add every app from your Dock to the wheel — even ones that aren't "
                     + "running and have no windows. Picking a not-running Dock app launches "
                     + "it, just like clicking its Dock icon.")
            }
        }
    }
}
