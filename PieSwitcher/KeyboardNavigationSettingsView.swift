import SwiftUI

/// The keyboard-navigation Preferences group (Bringr-93j.71). The Controls tab's
/// "Keyboard" sub-tab uses this pane (Bringr-93j.106), backed by a `PreferencesPane`
/// `Form` so the rows align with the rest of the window. All keys are read fresh at
/// each summon by `RadialMenuController`, so a change applies on the next open
/// without a relaunch. Arrow and number navigation are independent toggles that can
/// be on together; the confirm and multi-window-commit toggles only appear with
/// number navigation, which they modify.
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
        PreferencesPane {
            Section {
                Toggle("Control the wheel with the keyboard", isOn: $enabled)
                Toggle("Close the wheel on any unused key", isOn: $closeOnUnsupported)
            } header: {
                Text("Master")
            } footer: {
                Text("Move and choose with the keyboard while the wheel is open. The focused "
                     + "item previews exactly like a hovered one.\n\n"
                     + "\"Close on unused key\" dismisses the wheel when a key that has no "
                     + "current binding is pressed. The keystroke still reaches the app "
                     + "underneath unchanged — only Escape is consumed (it's the natural "
                     + "\"close this\" key), so shortcuts like Fn + Backspace keep working "
                     + "while the wheel is open.")
            }

            if enabled {
                Section {
                    Toggle("Arrow keys", isOn: $arrows)
                } header: {
                    Text("Arrow keys")
                } footer: {
                    Text("Left and right move between apps — and between an app's windows; up "
                         + "opens the focused app's windows and down goes back; Return or "
                         + "Space activates the focused item.")
                }

                Section {
                    Toggle("Number keys", isOn: $numbers)
                    if numbers {
                        Toggle("Require a confirm key after a number", isOn: $requireConfirmation)
                        Toggle(
                            "Commit a multi-window app without choosing a window",
                            isOn: $commitAppWithoutWindowChoice
                        )
                    }
                } header: {
                    Text("Number keys")
                } footer: {
                    Text(numberKeysFooter)
                }
            }
        }
    }

    private var numberKeysFooter: String {
        var text = "Apps are numbered 1–9 then 0, clockwise from the top. Press a number to "
            + "jump to that app — straight to its window when it has only one, or into its "
            + "windows when it has several."
        if numbers {
            text += "\n\nWith confirm required, a number only focuses the item — you confirm "
                + "with Return, Space, an arrow, or the same number again. With commit "
                + "without choosing on, releasing the trigger on a multi-window app picks "
                + "its active window instead of cancelling."
        }
        return text
    }
}
