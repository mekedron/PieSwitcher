import SwiftUI

/// The "Screens & Spaces" Preferences group (Bringr-93j.48): independent checkboxes for the
/// apps ring and the windows sub-wheel, each choosing whether to span every display / every
/// Space or stay on the one the wheel was summoned on. Its own file (and own `@AppStorage`
/// for the four keys) so the `PreferencesView` body stays within its length budget, mirroring
/// `MyAppsEditor`. The same keys are read fresh at each summon via `CollectionPreferences.current`,
/// so a change applies on the next open without a relaunch. All default off — collection stays
/// on the current screen and Space (the Bringr-93j.30 behaviour).
struct CollectionSettings: View {
    @AppStorage(CollectionPreferences.appsAllScreensDefaultsKey) private var appsAllScreens = false
    @AppStorage(CollectionPreferences.appsAllSpacesDefaultsKey) private var appsAllSpaces = false
    @AppStorage(CollectionPreferences.windowsAllScreensDefaultsKey) private var windowsAllScreens = false
    @AppStorage(CollectionPreferences.windowsAllSpacesDefaultsKey) private var windowsAllSpaces = false
    /// Global across both levels (Bringr-93j.50); read fresh at summon via
    /// `CollectionPreferences.current`, so a change applies on the next open without relaunch.
    @AppStorage(CollectionPreferences.includeMinimizedDefaultsKey) private var includeMinimized = false
    @AppStorage(CollectionPreferences.includeHiddenDefaultsKey) private var includeHidden = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            group(
                title: "Apps",
                allScreens: $appsAllScreens,
                allSpaces: $appsAllSpaces,
                detail: "Which apps fill the first ring. When both are off, it lists only apps "
                    + "with a window on the screen and Space you summon from."
            )
            group(
                title: "Windows",
                allScreens: $windowsAllScreens,
                allSpaces: $windowsAllSpaces,
                detail: "Which of an app's windows fill its sub-ring. When both are off, it shows "
                    + "only that app's windows on the screen and Space you summon from."
            )
            VStack(alignment: .leading, spacing: 8) {
                Text("Minimized & hidden").font(.headline)
                Toggle("Include minimized windows", isOn: $includeMinimized)
                Toggle("Include hidden windows", isOn: $includeHidden)
                Text("Minimized windows and windows of apps you've hidden (Hide, ⌘H — including "
                    + "ones Bringr hides for you) are normally left out. Turn these on to include "
                    + "them in the wheel.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder
    private func group(
        title: String, allScreens: Binding<Bool>, allSpaces: Binding<Bool>, detail: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.headline)
            Toggle("Include \(title.lowercased()) from all screens", isOn: allScreens)
            Toggle("Include \(title.lowercased()) from all Spaces", isOn: allSpaces)
            Text(detail)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
