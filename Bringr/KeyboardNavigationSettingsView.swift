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

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Toggle("Control the wheel with the keyboard", isOn: $enabled)

            Text("Move and choose with the keyboard while the wheel is open. The focused item "
                 + "previews exactly like a hovered one, in a distinct colour. Escape steps back "
                 + "from a window to its app, or closes the wheel from the top level.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if enabled {
                Divider()
                arrowsControls
                numbersControls
            }
        }
    }

    private var arrowsControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle("Arrow keys", isOn: $arrows)
            Text("Left and right move between apps — and between an app's windows; down opens the "
                 + "focused app's windows and up goes back; Return activates the focused item.")
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
                Toggle("Require Return to confirm a number", isOn: $requireConfirmation)
                Text("A number only focuses and previews the item; press Return to activate it, so "
                     + "you can look inside a window before committing.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
