import SwiftUI

/// The reveal-strategy picker (US-013) and the optional "leave only my selection on
/// screen" toggle (Bringr-93j.27). The Selection tab's "Windows" sub-tab uses this
/// pane: both controls decide what happens to the user's *windows* while they hover
/// the wheel and once they commit, which is a selection concern, not a visual one.
/// They live inside a `PreferencesPane`-backed `Form` so the row alignment matches
/// the rest of the window. Every key is read fresh at each summon by
/// `RadialMenuController`, so a change here applies on the next open without a relaunch.
///
/// The "leave only my selection on screen" toggle is gated to `.raiseToFront`
/// (Bringr-93j.89): `.hideOthers` already hides everything else at hover time, so
/// the post-commit hide is redundant and the checkbox would be meaningless.
struct RevealSettings: View {
    @AppStorage(RevealStrategy.defaultsKey) private var revealStrategyRaw = RevealStrategy.default.rawValue
    @AppStorage(HideOnCommit.defaultsKey) private var hideOnCommit = HideOnCommit.default

    var body: some View {
        let strategy = RevealStrategy(rawValue: revealStrategyRaw) ?? .default
        PreferencesPane {
            Section {
                Picker("Reveal mode", selection: $revealStrategyRaw) {
                    ForEach(RevealStrategy.allCases, id: \.rawValue) { strategy in
                        Text(strategy.displayName).tag(strategy.rawValue)
                    }
                }
                .pickerStyle(.radioGroup)
            } header: {
                Text("Reveal")
            } footer: {
                Text(strategy.detail)
            }

            if strategy == .raiseToFront {
                Section {
                    Toggle("Leave only my selection on screen", isOn: $hideOnCommit)
                } header: {
                    Text("After commit")
                } footer: {
                    Text("After you choose, hide everything else so only your selection "
                         + "remains. Picking a window minimizes its app's other windows and "
                         + "hides every other app; picking an app leaves just its front window.")
                }
            }
        }
    }
}
