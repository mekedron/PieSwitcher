import SwiftUI

/// The Sorting pane of the Contents tab. The apps
/// sort-order picker, the "don't sort my pinned apps" toggle (Bringr-93j.34), and the
/// "Keep Finder last" toggle for the Dock-position order (Bringr-93j.55), all inside a
/// `PreferencesPane`-backed `Form` so the rows align with the rest of the window. Keys
/// are read fresh at each summon by `WindowEnumerator` / `MyAppsMenu`, so a change
/// applies on the next open without a relaunch. The windows sub-wheel has only one
/// available sort (Fixed position, Bringr-93j.90), so it isn't shown here.
struct SortingSettings: View {
    @AppStorage(AppSortOrder.defaultsKey) private var appSortOrderRaw = AppSortOrder.default.rawValue
    @AppStorage(CuratedApps.keepCuratedOrderDefaultsKey)
    private var keepCuratedOrder = CuratedApps.keepCuratedOrderDefault
    @AppStorage(DockOrder.keepFinderLastKey) private var keepFinderLast = DockOrder.keepFinderLastDefault

    var body: some View {
        let order = AppSortOrder(rawValue: appSortOrderRaw) ?? .default
        PreferencesPane {
            Section {
                Picker("Apps", selection: $appSortOrderRaw) {
                    ForEach(AppSortOrder.allCases, id: \.rawValue) { order in
                        Text(order.displayName).tag(order.rawValue)
                    }
                }
                .pickerStyle(.radioGroup)
            } header: {
                Text("Order")
            } footer: {
                Text(order.detail)
            }

            Section {
                Toggle("Don't sort my pinned apps", isOn: $keepCuratedOrder)
                if order == .dockPosition {
                    Toggle("Keep Finder last", isOn: $keepFinderLast)
                }
            } header: {
                Text("Overrides")
            } footer: {
                Text(footerText(for: order))
            }
        }
    }

    private func footerText(for order: AppSortOrder) -> String {
        var text = "Keep the apps you pinned in My Apps in the order you arranged them, "
            + "ignoring the order above. The other running apps are still sorted."
        if order == .dockPosition {
            text += "\n\nFinder is pinned to the Dock's first slot, so by Dock position it "
                + "would always lead. Turn \"Keep Finder last\" on to send it to the end "
                + "of the wheel instead."
        }
        return text
    }
}
