import Carbon.HIToolbox
import Foundation

// MARK: - Modifier family / side

/// One of the five modifier keys we can bind a shortcut to. `function` is intentionally
/// distinct from the four sided modifiers because the Fn key has no left/right hardware
/// distinction (Bringr-93j.111).
enum ModifierFamily: String, Codable, Sendable, Hashable, CaseIterable {
    case function
    case control
    case option
    case shift
    case command

    /// The on-screen symbol shown in the picker's key caps, matching the system's
    /// own glyphs so the cap reads like a real modifier key.
    var symbol: String {
        switch self {
        case .function: return "fn"
        case .control: return "⌃"
        case .option: return "⌥"
        case .shift: return "⇧"
        case .command: return "⌘"
        }
    }

    /// Long, screen-reader friendly name used in voice-overs and migration notices.
    var displayName: String {
        switch self {
        case .function: return "Fn"
        case .control: return "Control"
        case .option: return "Option"
        case .shift: return "Shift"
        case .command: return "Command"
        }
    }

    /// Whether this family supports left/right distinction. Fn does not — macOS only
    /// reports one Fn key so the side is always `.either`.
    var hasSideDistinction: Bool { self != .function }

    /// Stable ordering for the picker (matches the macOS convention: Fn ⌃ ⌥ ⇧ ⌘).
    static let orderedAll: [ModifierFamily] = [.function, .control, .option, .shift, .command]
}

/// Which physical key on the keyboard the shortcut binds to for this modifier family.
/// `.either` is the migration / side-agnostic mode: a shortcut imported from the
/// pre-Bringr-93j.111 checkbox UI matches whichever side the user presses, preserving
/// behaviour for upgrades. A freshly-recorded shortcut is always `.left` or `.right`.
enum ModifierSide: String, Codable, Sendable, Hashable {
    case left
    case right
    case either
}

/// One modifier key in a shortcut: the family (Control / Option / …) and which side of
/// the keyboard the user pressed. `function` always carries `.either` because Fn has no
/// side; matching code knows to skip the sidedness check for it.
struct SidedModifier: Hashable, Codable, Sendable {
    let family: ModifierFamily
    let side: ModifierSide

    init(_ family: ModifierFamily, _ side: ModifierSide) {
        self.family = family
        // The Fn key has no hardware-level left/right distinction so we collapse any
        // attempt to set a side into `.either`, keeping the invariant that runtime
        // matching never has to special-case Fn.
        self.side = family == .function ? .either : side
    }

    /// Display text for the key cap. We append "L" or "R" for sided modifiers so the
    /// user can tell at a glance whether the slot was recorded on the left or right
    /// side of the keyboard (AC: "visually disambiguates LEFT vs RIGHT").
    var capLabel: String {
        switch side {
        case .left where family.hasSideDistinction:
            return "L\(family.symbol)"
        case .right where family.hasSideDistinction:
            return "R\(family.symbol)"
        default:
            return family.symbol
        }
    }

    /// Long-form name used in voice-overs and footer captions ("Right Option").
    var displayName: String {
        switch side {
        case .left where family.hasSideDistinction: return "Left \(family.displayName)"
        case .right where family.hasSideDistinction: return "Right \(family.displayName)"
        default: return family.displayName
        }
    }
}

// MARK: - Keyboard shortcut

/// A single shortcut the user can bind to a slot: a set of modifier keys plus an optional
/// non-modifier key (`keyCode`). When `keyCode == nil` the shortcut fires on bare modifiers
/// being held alone (e.g. "Right Option"); when set, it requires the modifiers AND that
/// specific non-modifier key (e.g. "Right Option + Space").
///
/// `sideAgnostic` is `true` only for migrated shortcuts — the pre-Bringr-93j.111 checkbox
/// UI couldn't tell left from right, so we preserve that behaviour for upgrades by
/// matching either side. The first time the user re-records a slot in the new picker the
/// flag drops to `false` and the recorded side becomes authoritative.
struct KeyboardShortcut: Hashable, Codable, Sendable {
    /// The modifier keys that must be held. Empty is only valid alongside a `keyCode`
    /// (a non-modifier key shortcut with no modifier is rejected by the picker, but the
    /// type itself stays permissive so future menu shortcuts can use it).
    let modifiers: Set<SidedModifier>
    /// Carbon keycode of the non-modifier key, or `nil` for a bare-modifier shortcut.
    /// Stored as `Int` so the JSON survives an `Int`/`UInt16` migration; runtime
    /// matching converts to `UInt16`.
    let keyCode: Int?
    /// Migration flag: `true` for shortcuts derived from the old checkbox UI, so any
    /// `.left` / `.right` requirement is treated as `.either` at match time. Newly-
    /// recorded shortcuts are always `false`.
    let sideAgnostic: Bool

    init(modifiers: Set<SidedModifier>, keyCode: Int? = nil, sideAgnostic: Bool = false) {
        self.modifiers = modifiers
        self.keyCode = keyCode
        self.sideAgnostic = sideAgnostic
    }

    /// Whether the shortcut has anything at all to fire on. The picker uses this to tell
    /// "Not set" from "set but empty"; the latter shouldn't be reachable through the UI.
    var isEmpty: Bool { modifiers.isEmpty && keyCode == nil }

    /// Whether the shortcut binds a non-modifier key. Bare-modifier shortcuts (the common
    /// case) have `false`; combo shortcuts like "Right Option + Space" have `true`.
    var hasNonModifierKey: Bool { keyCode != nil }
}

// MARK: - Key code → display name

/// Human-readable name for a Carbon key code, used by the key cap display. Falls back to
/// a generic "Key …" so an unknown key still renders something rather than blowing up.
enum KeyCodeDisplay {
    // swiftlint:disable:next cyclomatic_complexity
    static func label(for keyCode: Int) -> String {
        switch Int(keyCode) {
        case kVK_Space: return "Space"
        case kVK_Return: return "↩"
        case kVK_Tab: return "⇥"
        case kVK_Delete: return "⌫"
        case kVK_ForwardDelete: return "⌦"
        case kVK_Escape: return "⎋"
        case kVK_LeftArrow: return "←"
        case kVK_RightArrow: return "→"
        case kVK_UpArrow: return "↑"
        case kVK_DownArrow: return "↓"
        case kVK_Home: return "↖"
        case kVK_End: return "↘"
        case kVK_PageUp: return "⇞"
        case kVK_PageDown: return "⇟"
        case kVK_ANSI_Period: return "."
        case kVK_ANSI_Comma: return ","
        case kVK_ANSI_Semicolon: return ";"
        case kVK_ANSI_Quote: return "'"
        case kVK_ANSI_Slash: return "/"
        case kVK_ANSI_Backslash: return "\\"
        case kVK_ANSI_Minus: return "-"
        case kVK_ANSI_Equal: return "="
        case kVK_ANSI_LeftBracket: return "["
        case kVK_ANSI_RightBracket: return "]"
        case kVK_ANSI_Grave: return "`"
        case kVK_F1: return "F1"
        case kVK_F2: return "F2"
        case kVK_F3: return "F3"
        case kVK_F4: return "F4"
        case kVK_F5: return "F5"
        case kVK_F6: return "F6"
        case kVK_F7: return "F7"
        case kVK_F8: return "F8"
        case kVK_F9: return "F9"
        case kVK_F10: return "F10"
        case kVK_F11: return "F11"
        case kVK_F12: return "F12"
        default:
            if let letter = letterLabel(for: keyCode) { return letter }
            if let digit = digitLabel(for: keyCode) { return digit }
            return "Key \(keyCode)"
        }
    }

    private static func letterLabel(for keyCode: Int) -> String? {
        let map: [Int: String] = [
            kVK_ANSI_A: "A", kVK_ANSI_B: "B", kVK_ANSI_C: "C", kVK_ANSI_D: "D",
            kVK_ANSI_E: "E", kVK_ANSI_F: "F", kVK_ANSI_G: "G", kVK_ANSI_H: "H",
            kVK_ANSI_I: "I", kVK_ANSI_J: "J", kVK_ANSI_K: "K", kVK_ANSI_L: "L",
            kVK_ANSI_M: "M", kVK_ANSI_N: "N", kVK_ANSI_O: "O", kVK_ANSI_P: "P",
            kVK_ANSI_Q: "Q", kVK_ANSI_R: "R", kVK_ANSI_S: "S", kVK_ANSI_T: "T",
            kVK_ANSI_U: "U", kVK_ANSI_V: "V", kVK_ANSI_W: "W", kVK_ANSI_X: "X",
            kVK_ANSI_Y: "Y", kVK_ANSI_Z: "Z"
        ]
        return map[keyCode]
    }

    private static func digitLabel(for keyCode: Int) -> String? {
        let map: [Int: String] = [
            kVK_ANSI_0: "0", kVK_ANSI_1: "1", kVK_ANSI_2: "2", kVK_ANSI_3: "3",
            kVK_ANSI_4: "4", kVK_ANSI_5: "5", kVK_ANSI_6: "6", kVK_ANSI_7: "7",
            kVK_ANSI_8: "8", kVK_ANSI_9: "9"
        ]
        return map[keyCode]
    }
}

// MARK: - Display helpers

extension KeyboardShortcut {
    /// Ordered key cap labels for the picker, matching the macOS modifier ordering
    /// (Fn ⌃ ⌥ ⇧ ⌘) and then the non-modifier key. Empty when the shortcut is empty —
    /// the picker shows "Not set" in that case.
    var capLabels: [String] {
        var labels = ModifierFamily.orderedAll.compactMap { family -> String? in
            guard let mod = modifiers.first(where: { $0.family == family }) else { return nil }
            return mod.capLabel
        }
        if let keyCode {
            labels.append(KeyCodeDisplay.label(for: keyCode))
        }
        return labels
    }

    /// Long-form description for accessibility labels and the footer caption
    /// (e.g. "Right Option + Space").
    var displayName: String {
        var parts = ModifierFamily.orderedAll.compactMap { family -> String? in
            modifiers.first(where: { $0.family == family })?.displayName
        }
        if let keyCode {
            parts.append(KeyCodeDisplay.label(for: keyCode))
        }
        return parts.joined(separator: " + ")
    }
}
