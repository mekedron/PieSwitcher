import CoreGraphics
import Foundation

// MARK: - Held-keys snapshot

/// The set of modifier keys (with side) and the single non-modifier key currently held
/// down on the keyboard. The live monitor maintains one of these as each `CGEvent`
/// arrives and feeds it to the detector. Value-typed so the matching logic is unit-
/// tested in isolation from the event tap.
struct HeldKeys: Hashable, Sendable {
    /// Held modifier keys, each tagged with the side they're on. Fn always carries
    /// `.either` because the hardware reports a single Fn bit.
    var modifiers: Set<SidedModifier>
    /// The single non-modifier key currently down, if any. We track only one — a real
    /// shortcut binds to a single non-modifier key, and matching multiple key codes at
    /// once would let stray system keys break a long modifier hold.
    var nonModifierKey: Int?

    static let empty = HeldKeys(modifiers: [], nonModifierKey: nil)

    init(modifiers: Set<SidedModifier> = [], nonModifierKey: Int? = nil) {
        self.modifiers = modifiers
        self.nonModifierKey = nonModifierKey
    }
}

// MARK: - Device-dependent flag bits (left/right)

/// IOKit's left/right modifier flag bits. CoreGraphics's `CGEventFlags` constants only
/// expose the aggregate masks (`maskAlternate`, `maskCommand`, …) so we read the lower
/// device-dependent bits directly to recover which physical key is down. These constants
/// come from `<IOKit/hidsystem/IOLLEvent.h>` — hard-coded here so we don't drag the rest
/// of IOKit into the build (the values are part of the OS ABI and won't change).
enum DeviceFlagMask {
    static let leftControl: UInt64 = 0x0000_0001
    static let leftShift: UInt64 = 0x0000_0002
    static let rightShift: UInt64 = 0x0000_0004
    static let leftCommand: UInt64 = 0x0000_0008
    static let rightCommand: UInt64 = 0x0000_0010
    static let leftOption: UInt64 = 0x0000_0020
    static let rightOption: UInt64 = 0x0000_0040
    static let rightControl: UInt64 = 0x0000_2000
}

// MARK: - CGEventFlags → SidedModifier

/// Pure helpers that turn a `CGEventFlags` value into the held-modifier set. Lives in its
/// own enum so the tests can drive it with synthetic flag values without spinning up an
/// event tap.
/// Translate the flags reported by a `CGEvent` into the matching `SidedModifier`s.
/// Reads the aggregate `mask*` bits to know *whether* a modifier is down and the
/// device-dependent low bits to know *which side* — if the latter are missing
/// (synthetic events from outside the keyboard) the side falls back to `.either`
/// so the shortcut still has a chance to match a side-agnostic configuration.
enum SidedModifierParser {
    static func modifiers(from flags: CGEventFlags) -> Set<SidedModifier> {
        var result: Set<SidedModifier> = []
        let raw = flags.rawValue

        if flags.contains(.maskSecondaryFn) {
            // Fn has no side distinction at the hardware level.
            result.insert(SidedModifier(.function, .either))
        }
        if flags.contains(.maskControl) {
            let left = raw & DeviceFlagMask.leftControl != 0
            let right = raw & DeviceFlagMask.rightControl != 0
            insertSides(into: &result, family: .control, left: left, right: right)
        }
        if flags.contains(.maskAlternate) {
            let left = raw & DeviceFlagMask.leftOption != 0
            let right = raw & DeviceFlagMask.rightOption != 0
            insertSides(into: &result, family: .option, left: left, right: right)
        }
        if flags.contains(.maskShift) {
            let left = raw & DeviceFlagMask.leftShift != 0
            let right = raw & DeviceFlagMask.rightShift != 0
            insertSides(into: &result, family: .shift, left: left, right: right)
        }
        if flags.contains(.maskCommand) {
            let left = raw & DeviceFlagMask.leftCommand != 0
            let right = raw & DeviceFlagMask.rightCommand != 0
            insertSides(into: &result, family: .command, left: left, right: right)
        }
        return result
    }

    private static func insertSides(
        into result: inout Set<SidedModifier>,
        family: ModifierFamily,
        left: Bool,
        right: Bool
    ) {
        if left { result.insert(SidedModifier(family, .left)) }
        if right { result.insert(SidedModifier(family, .right)) }
        // Fallback when the high-level mask is set but neither device-dependent bit is —
        // can happen with synthesized events. Treat as `.either` so a side-agnostic
        // shortcut still matches; side-specific shortcuts won't, which is correct.
        if !left, !right { result.insert(SidedModifier(family, .either)) }
    }
}

// MARK: - Matching

/// Whether the user's current `HeldKeys` satisfies a configured `KeyboardShortcut`.
/// Match rules:
///   • Modifier families must be exactly equal — extras either way break the match,
///     just like the pre-Bringr-93j.111 detector enforced "exact combo".
///   • For each modifier in the shortcut:
///       – `.either` (or `sideAgnostic` is on) matches any held side(s) for that family.
///       – `.left` requires exactly the left side to be held (not both, not right).
///       – `.right` requires exactly the right side (not both, not left).
///   • The non-modifier key (if any) must match exactly.
struct KeyboardShortcutMatcher {
    static func matches(_ held: HeldKeys, shortcut: KeyboardShortcut) -> Bool {
        // Reject empty shortcuts at the matcher rather than relying on every armed
        // provider to filter them — defence in depth against a stray empty slot firing
        // when the user releases every key.
        guard !shortcut.isEmpty else { return false }
        // Bare modifier shortcuts only fire when no non-modifier key is held; combo
        // shortcuts must match the exact key code (nil-vs-nil works automatically).
        guard held.nonModifierKey == shortcut.keyCode else { return false }

        let heldFamilies = Set(held.modifiers.map(\.family))
        let shortcutFamilies = Set(shortcut.modifiers.map(\.family))
        guard heldFamilies == shortcutFamilies else { return false }

        for shortcutMod in shortcut.modifiers
            where !modifierSidesMatch(shortcutMod, held: held, sideAgnostic: shortcut.sideAgnostic) {
            return false
        }
        return true
    }

    private static func modifierSidesMatch(
        _ shortcutMod: SidedModifier,
        held: HeldKeys,
        sideAgnostic: Bool
    ) -> Bool {
        let heldSides = held.modifiers
            .filter { $0.family == shortcutMod.family }
            .map(\.side)
        // Fn has no side — treat its "either" as a presence check.
        guard shortcutMod.family.hasSideDistinction else {
            return !heldSides.isEmpty
        }
        // Side-agnostic (migrated) shortcuts match whichever side is held, including
        // both sides at once — preserves the pre-Bringr-93j.111 behaviour for upgrades.
        if sideAgnostic || shortcutMod.side == .either {
            return !heldSides.isEmpty
        }
        // Side-specific match: exactly that side held, nothing more.
        return heldSides == [shortcutMod.side]
    }
}

// MARK: - Detector (pure)

/// Edge detector for the new shortcut model. Drops in where the pre-Bringr-93j.111
/// `ModifierHoldDetector` used to sit: feed it the live `HeldKeys` and the armed
/// shortcut list and it emits `press` on the rising edge, `release` on the falling
/// edge. Pure and value-typed so the state machine is unit-tested without a tap.
///
/// Matching is "any armed shortcut matches" — sliding between two matching shortcuts
/// (e.g. from a bare modifier to a combo with the same modifier plus a key) does NOT
/// re-fire, the same way the prior detector kept the menu stable across distinct
/// armed combinations.
struct KeyboardShortcutDetector {
    enum Reaction: Equatable, Sendable {
        case none
        case press
        case release
    }

    private(set) var isActive = false

    /// Feed the current held state and the armed shortcuts; returns the edge, if any.
    mutating func handle(held: HeldKeys, armed: [KeyboardShortcut]) -> Reaction {
        let matches = armed.contains { KeyboardShortcutMatcher.matches(held, shortcut: $0) }
        switch (matches, isActive) {
        case (true, false):
            isActive = true
            return .press
        case (false, true):
            isActive = false
            return .release
        case (true, true), (false, false):
            return .none
        }
    }

    /// Forget any latched activation. Called when the monitor (re)starts so a stale hold
    /// from a previous session never resolves into a new summon.
    mutating func reset() { isActive = false }
}
