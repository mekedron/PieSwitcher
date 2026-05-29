import CoreGraphics
import Foundation

// MARK: - Settings

/// Optional keyboard navigation for the pie menu (Bringr-93j.71). Off unless turned on; when
/// on, the wheel can be driven by arrow keys and/or number keys, with an optional "press
/// Return to confirm" step for the number mode. A caseless namespace for the persistence
/// helpers, mirroring `CursorLock`/`MouseChordActivation`; read fresh at each summon so a
/// Preferences change applies on the next open without a relaunch.
///
/// Arrow and number navigation are independent sub-toggles, so either, both, or neither can be
/// on at once — they share one focus model, so combining them needs no extra wiring.
enum KeyboardNavigation {
    /// Top-level toggle. Default OFF, so a fresh install behaves exactly as before.
    static let enabledKey = "keyboardNav.enabled"
    /// Arrow-key navigation sub-toggle.
    static let arrowsKey = "keyboardNav.arrows"
    /// Number-key navigation sub-toggle.
    static let numbersKey = "keyboardNav.numbers"
    /// Number mode "require Return to confirm" sub-toggle: a number only focuses/previews, then
    /// Return activates. Default OFF (numbers activate instantly).
    static let confirmKey = "keyboardNav.requireConfirmation"

    static let enabledDefault = false
    static let arrowsDefault = true
    static let numbersDefault = true
    static let confirmDefault = false

    static func isEnabled(from defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: enabledKey)
    }

    static func arrowsEnabled(from defaults: UserDefaults = .standard) -> Bool {
        readTrueDefault(arrowsKey, from: defaults)
    }

    static func numbersEnabled(from defaults: UserDefaults = .standard) -> Bool {
        readTrueDefault(numbersKey, from: defaults)
    }

    static func requiresConfirmation(from defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: confirmKey)
    }

    /// A true-defaulted toggle: an absent key yields `true`, so the sub-options are on out of
    /// the box once the master switch is enabled (mirroring `MouseChordActivation`).
    private static func readTrueDefault(_ key: String, from defaults: UserDefaults) -> Bool {
        guard defaults.object(forKey: key) != nil else { return true }
        return defaults.bool(forKey: key)
    }
}

/// The keyboard-navigation settings resolved once per summon, like `CollectionPreferences`.
/// The arrow/number flags are already AND-ed with the top-level switch, so a consumer only
/// checks the flag it needs.
struct KeyboardNavigationConfig: Equatable, Sendable {
    let isEnabled: Bool
    let arrowsEnabled: Bool
    let numbersEnabled: Bool
    let requiresConfirmation: Bool

    static let disabled = KeyboardNavigationConfig(
        isEnabled: false, arrowsEnabled: false, numbersEnabled: false, requiresConfirmation: false
    )

    static func current(from defaults: UserDefaults = .standard) -> KeyboardNavigationConfig {
        let on = KeyboardNavigation.isEnabled(from: defaults)
        return KeyboardNavigationConfig(
            isEnabled: on,
            arrowsEnabled: on && KeyboardNavigation.arrowsEnabled(from: defaults),
            numbersEnabled: on && KeyboardNavigation.numbersEnabled(from: defaults),
            requiresConfirmation: KeyboardNavigation.requiresConfirmation(from: defaults)
        )
    }
}

// MARK: - Highlight source

/// Whether the active wheel highlight (`hovered`) was last moved by the mouse or the keyboard,
/// so the view can tint keyboard focus distinctly from mouse hover while reusing the same
/// emphasis treatment (Bringr-93j.71).
enum HighlightSource: Equatable, Sendable {
    case mouse
    case keyboard
}

// MARK: - Keys

/// A direction on the wheel for arrow-key navigation.
enum KeyboardArrow: Equatable, Sendable {
    case left, right, up, down
}

/// A key the pie menu reacts to while open under keyboard navigation. The live monitor maps
/// hardware key codes to these, keeping the navigator's decision logic free of AppKit.
enum KeyboardNavKey: Equatable, Sendable {
    case arrow(KeyboardArrow)
    /// A digit 0...9 (the app/window number; `0` stands for the tenth item).
    case digit(Int)
    case confirm
    case escape

    /// Map a macOS virtual key code to a navigation key, or `nil` for keys the menu ignores
    /// (which the monitor then passes through to the app underneath). Both the number row and
    /// the keypad map to digits, and both Return and keypad Enter confirm, so the keyboard
    /// layout the user actually has doesn't matter.
    init?(keyCode: Int64) {
        switch keyCode {
        case 123: self = .arrow(.left)
        case 124: self = .arrow(.right)
        case 125: self = .arrow(.down)
        case 126: self = .arrow(.up)
        case 36, 76: self = .confirm
        case 53: self = .escape
        default:
            guard let digit = Self.digitsByKeyCode[keyCode] else { return nil }
            self = .digit(digit)
        }
    }

    /// Number-row and keypad key codes that map to a digit (a dictionary rather than a switch so
    /// the mapping stays a single low-complexity lookup).
    private static let digitsByKeyCode: [Int64: Int] = [
        18: 1, 19: 2, 20: 3, 21: 4, 23: 5, 22: 6, 26: 7, 28: 8, 25: 9, 29: 0,
        83: 1, 84: 2, 85: 3, 86: 4, 87: 5, 88: 6, 89: 7, 91: 8, 92: 9, 82: 0
    ]
}

// MARK: - Navigation math (pure)

/// Pure helpers shared by the navigator's keyboard handling, split out so the wrapping and
/// digit→index rules are unit-tested without any ring state.
enum KeyboardNavMath {
    /// Wrap `index` into `0..<count`, so moving left past 0 lands on the last slice and right
    /// past the end lands on 0. Returns 0 for a non-positive count.
    static func wrap(_ index: Int, count: Int) -> Int {
        guard count > 0 else { return 0 }
        return ((index % count) + count) % count
    }

    /// The 0-based slice index a pressed digit selects: 1...9 map to 0...8 and 0 maps to the
    /// tenth slice (index 9). Numbers only ever address the first ten slices (Bringr-93j.71); an
    /// 11th+ slice has no number and is reached with the arrows.
    static func index(forDigit digit: Int) -> Int? {
        switch digit {
        case 1...9: return digit - 1
        case 0: return 9
        default: return nil
        }
    }
}

// MARK: - Navigator outcome

/// What a keyboard key did to the wheel, so the controller can perform the matching side
/// effect: ignore it (pass the key through to the app underneath), consume it after moving
/// focus/preview, commit a selection (the navigator already focused the target and restored the
/// rest), or close the whole menu (Escape at the top level).
enum KeyboardNavOutcome: Equatable {
    case ignored
    case handled
    case committed(RadialCommitResult)
    case close
}
