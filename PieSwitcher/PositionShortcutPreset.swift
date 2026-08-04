import Carbon.HIToolbox
import Foundation

/// The one-click starter set of position shortcuts (Bringr-dk3): ⌥1–⌥4 for the first four
/// apps in the wheel, ⌥⇧1–⌥⇧4 for the first four windows of whatever app you are in.
///
/// Opt-in by construction. Nothing here runs unless the user asks for it, from the
/// onboarding screen or the Positions pane — an install that happened on its own would take
/// over ⌥1–⌥4 system-wide for someone who never asked for position shortcuts at all.
///
/// Installing merges rather than replaces: a recommended row is added only when its
/// shortcut is not already bound somewhere in that list, so a user who has arranged their
/// own rows keeps every one of them, and no shortcut ends up bound twice (where only the
/// lower-numbered position would ever fire).
enum PositionShortcutPreset {
    /// How many positions the starter set covers. Four is enough to be useful on the first
    /// day without claiming a row of digits the user may want for something else; the pane
    /// adds more.
    static let positionCount = 4

    /// The digits, in position order. Position N binds the Nth of these.
    private static let keyCodes = [kVK_ANSI_1, kVK_ANSI_2, kVK_ANSI_3, kVK_ANSI_4]

    /// The **left** Option, specifically. Position shortcuts swallow their key, and ⌥ with a
    /// digit is a live typing combination on most layouts — ⌥2 is `@` on the Nordic ones,
    /// ⌥1 is `©`. Claiming one side leaves the other typing those characters exactly as
    /// before, so the starter set can be handed to anyone without asking what layout they
    /// use. It also matches how the rest of the app picks defaults: a hand-specific
    /// modifier, like the Right Command that summons the wheel.
    ///
    /// Shift stays side-agnostic — it only tells the two lists apart, and there is no reason
    /// to make the user find a particular one.
    private static func modifiers(for list: PositionShortcutList) -> Set<SidedModifier> {
        switch list {
        case .apps:
            return [SidedModifier(.option, .left)]
        case .windows:
            return [SidedModifier(.option, .left), SidedModifier(.shift, .either)]
        }
    }

    /// The starter rows for `list`, positions 1…`positionCount`.
    static func recommended(for list: PositionShortcutList) -> [PositionShortcutBinding] {
        let modifiers = modifiers(for: list)
        return keyCodes.prefix(positionCount).enumerated().map { index, keyCode in
            PositionShortcutBinding(
                position: index + 1,
                shortcut: KeyboardShortcut(modifiers: modifiers, keyCode: keyCode)
            )
        }
    }

    /// The key caps one row of the starter set wears, for the onboarding example. Uses the
    /// same `L⌥` convention as the picker, so the sidedness is visible rather than implied.
    static func capLabels(for list: PositionShortcutList) -> [String] {
        list == .apps ? ["L⌥"] : ["L⌥", "⇧"]
    }

    /// Human-readable summary of what `list`'s starter set binds, for the button and the
    /// onboarding copy — "L⌥1–L⌥4" rather than four separate cap rows.
    static func summary(for list: PositionShortcutList) -> String {
        let prefix = capLabels(for: list).joined()
        return "\(prefix)1–\(prefix)\(positionCount)"
    }

    /// Whether every recommended shortcut for `list` is already bound in it.
    static func isInstalled(_ list: PositionShortcutList, in defaults: UserDefaults = .standard) -> Bool {
        let bound = boundShortcuts(list, in: defaults)
        return recommended(for: list).allSatisfy { binding in
            binding.shortcut.map(bound.contains) ?? false
        }
    }

    /// Add the missing recommended rows to `list`, leaving everything already there alone.
    static func install(_ list: PositionShortcutList, in defaults: UserDefaults = .standard) {
        let existing = PositionShortcutStore.bindings(list, from: defaults)
        var bound = boundShortcuts(list, in: defaults)
        var added: [PositionShortcutBinding] = []
        for binding in recommended(for: list) {
            guard let shortcut = binding.shortcut, !bound.contains(shortcut) else { continue }
            bound.insert(shortcut)
            added.append(binding)
        }
        guard !added.isEmpty else { return }
        PositionShortcutStore.setBindings(
            PositionShortcutStore.sorted(existing + added), for: list, in: defaults
        )
    }

    /// Drop the rows this preset installed, identified by their shortcut so a row the user
    /// re-pointed at another position still goes, while rows they bound themselves stay.
    static func remove(_ list: PositionShortcutList, in defaults: UserDefaults = .standard) {
        let recommendedShortcuts = Set(recommended(for: list).compactMap(\.shortcut))
        let kept = PositionShortcutStore.bindings(list, from: defaults).filter { binding in
            binding.shortcut.map { !recommendedShortcuts.contains($0) } ?? true
        }
        PositionShortcutStore.setBindings(kept, for: list, in: defaults)
    }

    private static func boundShortcuts(
        _ list: PositionShortcutList, in defaults: UserDefaults
    ) -> Set<KeyboardShortcut> {
        Set(PositionShortcutStore.bindings(list, from: defaults).compactMap(\.shortcut))
    }
}
