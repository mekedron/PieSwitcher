import SwiftUI

/// The "Screens & Spaces" Preferences group (Bringr-93j.48): a per-level checkbox for the apps
/// ring and the windows sub-wheel, each choosing whether to span every display or stay on the
/// one the wheel was summoned on. Its own file (and own `@AppStorage`) so the `PreferencesView`
/// body stays within its length budget, mirroring `MyAppsEditor`. The keys are read fresh at
/// each summon via `CollectionPreferences.current`, so a change applies on the next open without
/// a relaunch. Both default off — collection stays on the current screen (the Bringr-93j.30
/// behaviour).
///
/// Bringr-93j.77: the two "all Spaces" checkboxes are commented out (not deleted). They were the
/// source of the phantom-window and off-Space collection issues (Bringr-93j.54) and aren't needed
/// right now, but may be useful again. Only the UI is removed — the backing implementation
/// (`CollectionScope.allSpaces`, `CollectionPreferences.appsAllSpaces`/`windowsAllSpaces`, and the
/// enumerator's all-Spaces query) is left intact. Their keys stay absent/false, so collection
/// stays on the current Space.
struct CollectionSettings: View {
    @AppStorage(CollectionPreferences.appsAllScreensDefaultsKey)
    private var appsAllScreens = CollectionPreferences.appsAllScreensDefault
    // @AppStorage(CollectionPreferences.appsAllSpacesDefaultsKey)
    // private var appsAllSpaces = CollectionPreferences.appsAllSpacesDefault
    @AppStorage(CollectionPreferences.windowsAllScreensDefaultsKey)
    private var windowsAllScreens = CollectionPreferences.windowsAllScreensDefault
    // @AppStorage(CollectionPreferences.windowsAllSpacesDefaultsKey)
    // private var windowsAllSpaces = CollectionPreferences.windowsAllSpacesDefault
    /// Global across both levels (Bringr-93j.50); read fresh at summon via
    /// `CollectionPreferences.current`, so a change applies on the next open without relaunch.
    @AppStorage(CollectionPreferences.includeMinimizedDefaultsKey)
    private var includeMinimized = CollectionPreferences.includeMinimizedDefault
    @AppStorage(CollectionPreferences.includeHiddenDefaultsKey)
    private var includeHidden = CollectionPreferences.includeHiddenDefault

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            group(
                title: "Apps",
                allScreens: $appsAllScreens,
                detail: "Which apps fill the first ring. When off, it lists only apps "
                    + "with a window on the screen you summon from."
            )
            group(
                title: "Windows",
                allScreens: $windowsAllScreens,
                detail: "Which of an app's windows fill its sub-ring. When off, it shows "
                    + "only that app's windows on the screen you summon from."
            )
            VStack(alignment: .leading, spacing: 8) {
                Text("Minimized & hidden").font(.headline)
                Toggle("Include minimized windows", isOn: $includeMinimized)
                Toggle("Include hidden windows", isOn: $includeHidden)
                Text("Minimized windows and windows of apps you've hidden (Hide, ⌘H — including "
                    + "ones PieSwitcher hides for you) are normally left out. Turn these on to include "
                    + "them in the wheel.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder
    private func group(title: String, allScreens: Binding<Bool>, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.headline)
            Toggle("Include \(title.lowercased()) from all screens", isOn: allScreens)
            // Bringr-93j.77: the "all Spaces" toggle is commented out (see the type doc comment).
            // Toggle("Include \(title.lowercased()) from all Spaces", isOn: allSpaces)
            Text(detail)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text("Spanning all screens only works when your displays share a single Space. With "
                + "'Displays have separate Spaces' on (System Settings ▸ Desktop & Dock, Mission "
                + "Control section), each display gets its own Space, so windows on the other "
                + "displays can't be collected.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
