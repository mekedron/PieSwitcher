import SwiftUI

/// The optional keyboard-navigation settings (Bringr-93j.71), in their own view so the
/// Preferences body stays within its length budget (mirroring `AppearanceSettings`). All keys
/// are read fresh at each summon by `RadialMenuController`, so a change here applies on the next
/// open without a relaunch. Arrow and number navigation are independent toggles that can be on
/// together; the confirm toggle only appears with number navigation, which it modifies.
struct KeyboardNavigationSettings: View {
    @AppStorage(KeyboardNavigation.enabledKey) private var enabled = KeyboardNavigation.enabledDefault
    @AppStorage(KeyboardNavigation.arrowsKey) private var arrows = KeyboardNavigation.arrowsDefault
    @AppStorage(KeyboardNavigation.numbersKey) private var numbers = KeyboardNavigation.numbersDefault
    @AppStorage(KeyboardNavigation.confirmKey) private var requireConfirmation = KeyboardNavigation.confirmDefault
    @AppStorage(KeyboardNavigation.closeOnUnsupportedKey)
    private var closeOnUnsupported = KeyboardNavigation.closeOnUnsupportedDefault
    @AppStorage(KeyboardNavigation.commitAppWithoutWindowChoiceKey)
    private var commitAppWithoutWindowChoice = KeyboardNavigation.commitAppWithoutWindowChoiceDefault

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Toggle("Control the wheel with the keyboard", isOn: $enabled)

            Text("Move and choose with the keyboard while the wheel is open. The focused item "
                 + "previews exactly like a hovered one, in a distinct colour. Escape steps back "
                 + "from a window to its app, or closes the wheel from the top level.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Divider()
            closeOnUnsupportedControls

            if enabled {
                Divider()
                arrowsControls
                numbersControls
            }
        }
    }

    /// Always shown, even with the main switch off (Bringr-93j.95): "supported" is dynamic — a key
    /// counts only when it actually does something under the current settings. With the switch off
    /// the whole keyboard-nav cluster (arrows, numbers, Enter, Escape, Space) is unsupported too,
    /// so this checkbox is the only switch that controls whether any of them close the wheel.
    private var closeOnUnsupportedControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle("Close the wheel on any unused key", isOn: $closeOnUnsupported)
            Text("Pressing a key the wheel isn't currently using closes it. A key counts as unused "
                 + "when its keyboard-nav category is off, so disabling Arrow keys (or Number keys, "
                 + "or the whole feature above) means those keys also close the wheel.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var arrowsControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle("Arrow keys", isOn: $arrows)
            Text("Left and right move between apps — and between an app's windows; up opens the "
                 + "focused app's windows and down goes back; Return or Space activates the focused item.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var numbersControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle("Number keys", isOn: $numbers)
            Text("Apps are numbered 1–9 then 0, clockwise from the top. Press a number to jump to "
                 + "that app — straight to its window when it has only one, or into its windows "
                 + "(numbered the same way) when it has several.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if numbers {
                Toggle("Require a confirm key after a number", isOn: $requireConfirmation)
                Text("A number only focuses and previews the item, so you can look inside a window "
                     + "before committing. Confirm with Return, Space, an arrow key, or by pressing "
                     + "the same number again.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Toggle("Commit a multi-window app without choosing a window", isOn: $commitAppWithoutWindowChoice)
                Text("After a number jumps to an app with several windows, releasing the trigger or "
                     + "confirming without picking a window activates that app and its active window, "
                     + "instead of cancelling. Pick a window with a number or arrow as usual.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
