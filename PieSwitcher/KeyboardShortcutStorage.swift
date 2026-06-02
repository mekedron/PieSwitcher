import Foundation
import os

// MARK: - Persistence

/// Persisted state for the two keyboard-shortcut slots that drive the pie-menu
/// activation (Bringr-93j.111). Replaces the pre-Bringr-93j.111 single-bitmask
/// `activation.keyboard.modifiers` checkbox UI with two independent slots, each able to
/// hold a bare modifier or a modifier+key combination, with explicit left/right side
/// per modifier. Read fresh on every event by the monitor so a Preferences change
/// applies with no relaunch — same convention every other activation setting uses.
enum KeyboardShortcutStore {
    /// `UserDefaults` keys backing the two slots. Stored as JSON `Data` so the whole
    /// shortcut (modifier set + key code + side-agnostic flag) round-trips through
    /// `@AppStorage`-compatible storage. `Optional<KeyboardShortcut>` encodes to a
    /// single-field payload (`{"value": …}`), with `value: null` meaning "explicitly
    /// cleared" — distinct from an absent defaults key, which yields the default.
    static let slot1Key = "activation.keyboard.shortcut1"
    static let slot2Key = "activation.keyboard.shortcut2"
    /// One-shot flag set once the new defaults / migration have been written. While
    /// this is missing we know the current process is the first to see the new schema
    /// and migration logic should run before any reader returns a derived value.
    static let initialisedKey = "activation.keyboard.shortcutsInitialised"
    /// One-shot flag for the migration notice (AC: "a one-time in-app notice"). Set the
    /// moment the user sees the notice so it never reappears.
    static let migrationNoticeShownKey = "activation.keyboard.migrationNoticeShown"
    /// Pending notice payload, written by `runMigrationIfNeeded` and consumed by the
    /// preferences UI. Empty / absent string means "no pending notice".
    static let pendingMigrationNoticeKey = "activation.keyboard.pendingMigrationNotice"

    /// The default for fresh installs (Bringr-93j.113): a side-specific Right Command
    /// held alone. Right Option — the prior default — collides with the dead-key
    /// modifier on many European keyboard layouts (Option-N → ñ, Option-U → ¨), so a
    /// hold there interferes with normal typing. Right Command is much less commonly
    /// used as a system-wide modifier, so it's a safer out-of-the-box choice that
    /// still respects the "use a hand-specific modifier" principle. The user can
    /// re-record it in the picker.
    static let freshInstallSlot1 = KeyboardShortcut(
        modifiers: [SidedModifier(.command, .right)],
        keyCode: nil,
        sideAgnostic: false
    )
    static let freshInstallSlot2: KeyboardShortcut? = nil

    private static let log = Logger(subsystem: "com.mekedron.PieSwitcher", category: "KeyboardShortcuts")

    // MARK: Reading

    /// Read both slots from `defaults`. Returns `nil` for an unset slot. Must be called
    /// after `runMigrationIfNeeded` — the live monitor depends on the migration having
    /// already written the slots.
    static func slot1(from defaults: UserDefaults = .standard) -> KeyboardShortcut? {
        decode(defaults.data(forKey: slot1Key))
    }

    static func slot2(from defaults: UserDefaults = .standard) -> KeyboardShortcut? {
        decode(defaults.data(forKey: slot2Key))
    }

    /// The shortcuts currently configured to fire. Drops `nil` slots so the monitor
    /// sees just the configured list. The order is "Shortcut 1 first" — match-time
    /// short-circuits on the first match, so common path stays cheap.
    static func armedShortcuts(from defaults: UserDefaults = .standard) -> [KeyboardShortcut] {
        var armed: [KeyboardShortcut] = []
        if let slot = slot1(from: defaults), !slot.isEmpty { armed.append(slot) }
        if let slot = slot2(from: defaults), !slot.isEmpty { armed.append(slot) }
        return armed
    }

    // MARK: Writing

    /// Write a slot. Pass `nil` to mark it as explicitly unset (so the next read won't
    /// fall back to the fresh-install default).
    static func setSlot1(_ shortcut: KeyboardShortcut?, in defaults: UserDefaults = .standard) {
        write(shortcut, key: slot1Key, in: defaults)
    }

    static func setSlot2(_ shortcut: KeyboardShortcut?, in defaults: UserDefaults = .standard) {
        write(shortcut, key: slot2Key, in: defaults)
    }

    // MARK: Migration

    /// Run the one-time migration from the pre-Bringr-93j.111 checkbox bitmask to the
    /// new two-slot model. Idempotent: returns immediately on subsequent launches by
    /// checking `initialisedKey`. Called from `AppDelegate` before any monitor starts
    /// and from `PreferencesView` on appear (defence in depth in case Preferences is
    /// the first surface a user reaches).
    @discardableResult
    static func runMigrationIfNeeded(in defaults: UserDefaults = .standard) -> MigrationOutcome {
        if defaults.bool(forKey: initialisedKey) {
            return .alreadyDone
        }
        let outcome = MigrationPlanner.plan(reading: defaults)
        setSlot1(outcome.slot1, in: defaults)
        setSlot2(outcome.slot2, in: defaults)
        defaults.set(true, forKey: initialisedKey)
        // Stash the notice for the UI to consume — we don't show it from the model
        // layer so the migration stays headless and unit-testable.
        if let notice = outcome.notice {
            defaults.set(notice, forKey: pendingMigrationNoticeKey)
            log.info("Keyboard shortcut migration: \(notice, privacy: .public)")
        } else {
            defaults.removeObject(forKey: pendingMigrationNoticeKey)
        }
        return outcome.kind
    }

    /// Pop the pending migration notice (call from the UI once it's been shown).
    static func consumeMigrationNotice(in defaults: UserDefaults = .standard) -> String? {
        let notice = defaults.string(forKey: pendingMigrationNoticeKey)
        defaults.removeObject(forKey: pendingMigrationNoticeKey)
        defaults.set(true, forKey: migrationNoticeShownKey)
        return (notice?.isEmpty == false) ? notice : nil
    }

    // MARK: Codable storage

    private static func decode(_ data: Data?) -> KeyboardShortcut? {
        guard let data else { return nil }
        struct Box: Codable { let value: KeyboardShortcut? }
        return (try? JSONDecoder().decode(Box.self, from: data))?.value
    }

    private static func write(_ shortcut: KeyboardShortcut?, key: String, in defaults: UserDefaults) {
        struct Box: Codable { let value: KeyboardShortcut? }
        guard let data = try? JSONEncoder().encode(Box(value: shortcut)) else {
            log.error("Failed to encode keyboard shortcut for \(key, privacy: .public)")
            return
        }
        defaults.set(data, forKey: key)
    }
}

// MARK: - Migration

/// Possible end states the migration can land in, so callers (and tests) can assert
/// against the exact path taken.
enum MigrationOutcome: Equatable {
    /// First launch with the new schema, no prior checkbox config — fresh defaults
    /// applied.
    case freshInstall
    /// Migrated a single ticked modifier (or none, falling back to the default).
    case migratedSingleModifier
    /// Migrated multiple ticked modifiers — split across slots, possibly dropping
    /// some, and a notice is queued for the UI.
    case migratedMultipleModifiers
    /// The old key was explicitly cleared (stored 0) — both slots stay unset and
    /// keyboard activation is disabled.
    case migratedDisabled
    /// Migration ran in a prior launch; nothing to do.
    case alreadyDone
}

/// Pure migration planner — given a `UserDefaults`, decide what the two new slots
/// should be and whether to surface a notice. Lives in its own type so the whole
/// decision is unit-tested without writing anything.
enum MigrationPlanner {
    struct Plan: Equatable {
        var slot1: KeyboardShortcut?
        var slot2: KeyboardShortcut?
        var notice: String?
        var kind: MigrationOutcome
    }

    static func plan(reading defaults: UserDefaults) -> Plan {
        // The old bitmask key. Absence means "fresh install with the new schema";
        // presence means we have something to migrate.
        let oldKey = ModifierActivation.keyboardDefaultsKey
        guard let raw = defaults.object(forKey: oldKey) as? Int else {
            return Plan(
                slot1: KeyboardShortcutStore.freshInstallSlot1,
                slot2: KeyboardShortcutStore.freshInstallSlot2,
                notice: nil,
                kind: .freshInstall
            )
        }
        let combo = ModifierCombination(rawValue: raw).intersection(.all)
        if combo.isEmpty {
            // User explicitly unticked every box — keep keyboard activation disabled.
            return Plan(
                slot1: nil,
                slot2: nil,
                notice: nil,
                kind: .migratedDisabled
            )
        }

        let families = orderedFamilies(from: combo)
        switch families.count {
        case 1:
            // Single modifier ticked → Shortcut 1 only, side-agnostic. No notice.
            return Plan(
                slot1: bareSideAgnostic(family: families[0]),
                slot2: nil,
                notice: nil,
                kind: .migratedSingleModifier
            )
        default:
            // Two or more modifiers ticked → split across the two slots, drop the rest.
            let slot1 = bareSideAgnostic(family: families[0])
            let slot2 = families.count >= 2 ? bareSideAgnostic(family: families[1]) : nil
            let dropped = families.dropFirst(2).map(\.displayName)
            let notice = noticeText(picked: Array(families.prefix(2)), dropped: dropped)
            return Plan(
                slot1: slot1,
                slot2: slot2,
                notice: notice,
                kind: .migratedMultipleModifiers
            )
        }
    }

    /// Stable order for picking which ticked modifier becomes Shortcut 1 vs Shortcut 2.
    /// Matches `ModifierFamily.orderedAll` so the choice is deterministic across runs.
    private static func orderedFamilies(from combo: ModifierCombination) -> [ModifierFamily] {
        var out: [ModifierFamily] = []
        if combo.contains(.function) { out.append(.function) }
        if combo.contains(.control) { out.append(.control) }
        if combo.contains(.option) { out.append(.option) }
        if combo.contains(.shift) { out.append(.shift) }
        if combo.contains(.command) { out.append(.command) }
        return out
    }

    private static func bareSideAgnostic(family: ModifierFamily) -> KeyboardShortcut {
        KeyboardShortcut(
            modifiers: [SidedModifier(family, .either)],
            keyCode: nil,
            sideAgnostic: true
        )
    }

    private static func noticeText(picked: [ModifierFamily], dropped: [String]) -> String {
        let kept = picked.map(\.displayName).joined(separator: " and ")
        if dropped.isEmpty {
            return "Your keyboard activation was upgraded to the new shortcut picker. "
                + "\(kept) now fire independently — open Preferences to refine them or "
                + "set explicit left/right sides."
        }
        let droppedList = dropped.joined(separator: ", ")
        return "Your keyboard activation was upgraded to the new shortcut picker. "
            + "\(kept) now fire independently; \(droppedList) was dropped because "
            + "only two slots are supported. Open Preferences to adjust."
    }
}
