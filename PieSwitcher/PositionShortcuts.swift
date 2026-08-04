import Foundation
import os

// MARK: - Lists

/// Which ring of the wheel a position shortcut addresses (Bringr-dk3).
///
/// A position shortcut names a *slot*, not a subject: "the app in slot 3" rather than
/// "Safari". Whatever the wheel would show at that slot for the current sort order,
/// curated list, and collection scope is what the shortcut acts on — so the two stay in
/// step by construction, and a user who reorders the wheel reorders their shortcuts with it.
enum PositionShortcutList: String, CaseIterable, Sendable {
    /// The top-level apps ring: position N is the Nth slice, counting from twelve o'clock
    /// clockwise, in whatever order the Contents → Sorting settings produce.
    case apps
    /// The second-level windows sub-wheel of the app the user is currently in: position N
    /// is that app's Nth window in the same fixed order the sub-wheel lays out.
    case windows

    /// `UserDefaults` key backing this list's bindings. Single source of truth shared by
    /// the Preferences pane and the live monitor so the two cannot drift.
    var defaultsKey: String {
        switch self {
        case .apps: return "shortcuts.position.apps"
        case .windows: return "shortcuts.position.windows"
        }
    }

    var title: String {
        switch self {
        case .apps: return "Apps"
        case .windows: return "Windows"
        }
    }
}

// MARK: - Binding

/// One position → shortcut binding. `position` is 1-based because that is how the user
/// counts slices; the resolver converts to a ring index. `shortcut` is optional so a row
/// can exist in Preferences before the user has recorded anything into it.
///
/// Several bindings may name the same position — binding two shortcuts to position 1 is a
/// deliberate arrangement, not a conflict — so the row's identity is `id`, never `position`.
/// That same `id` is what the live detector tracks edges against, so editing a row mid-hold
/// can't leave a phantom "still held" entry behind.
struct PositionShortcutBinding: Codable, Hashable, Identifiable, Sendable {
    let id: UUID
    var position: Int
    var shortcut: KeyboardShortcut?

    init(id: UUID = UUID(), position: Int, shortcut: KeyboardShortcut? = nil) {
        self.id = id
        self.position = position
        self.shortcut = shortcut
    }
}

/// A binding flattened into the shape the live tap matches against: only rows that
/// actually carry a shortcut, tagged with the list they came from. Built fresh on every
/// event so a Preferences edit applies with no relaunch, matching the convention every
/// other activation setting uses.
struct ArmedPositionShortcut: Hashable, Sendable {
    let id: UUID
    let list: PositionShortcutList
    let position: Int
    let shortcut: KeyboardShortcut
}

// MARK: - Persistence

/// Persisted position-shortcut bindings for both lists (Bringr-dk3). Stored as JSON `Data`
/// under one key per list so the whole array — positions, shortcuts, and the sided modifier
/// detail inside each — round-trips through `@AppStorage`-compatible storage, the same way
/// `KeyboardShortcutStore` persists the two activation slots.
///
/// Both lists ship empty: the feature is opt-in, and an empty list is exactly "no position
/// shortcuts armed", so nothing is consumed from the keyboard until the user records
/// something.
enum PositionShortcutStore {
    /// Highest position a row can address. Not a limit on how many rows the user may keep —
    /// they can bind any subset — just a ceiling on the number a wheel could plausibly show,
    /// so a stray value can't produce an absurd row in Preferences.
    static let maxPosition = 99

    private static let log = Logger(subsystem: "com.mekedron.PieSwitcher", category: "PositionShortcuts")

    // MARK: Reading

    /// One list's bindings, always ascending by position — the order the pane shows and the
    /// order the runtime walks, so what the user reads top-to-bottom is what fires first.
    ///
    /// A stored modifiers-only shortcut is blanked back to "not set" on the way out. A
    /// position shortcut fires outright and swallows its key, so a bare Option bound to one
    /// hijacks every use of Option on the system — including the presses needed to re-record
    /// it. The picker refuses to create one; clearing it here disarms any that predates that
    /// rule, and leaves the row visible so the user can see what needs re-recording.
    static func bindings(
        _ list: PositionShortcutList, from defaults: UserDefaults = .standard
    ) -> [PositionShortcutBinding] {
        guard let data = defaults.data(forKey: list.defaultsKey),
              let decoded = try? JSONDecoder().decode([PositionShortcutBinding].self, from: data)
        else { return [] }
        let inRange = decoded.filter { $0.position >= 1 && $0.position <= maxPosition }
        return sorted(inRange.map { binding in
            guard let shortcut = binding.shortcut, !shortcut.hasNonModifierKey else { return binding }
            var cleared = binding
            cleared.shortcut = nil
            return cleared
        })
    }

    /// Ascending by position, ties broken by existing order. The tie-break is what keeps
    /// several shortcuts bound to the same position from swapping rows under the user every
    /// time the list is re-read — `sorted(by:)` alone gives no such guarantee.
    static func sorted(_ bindings: [PositionShortcutBinding]) -> [PositionShortcutBinding] {
        bindings.enumerated()
            .sorted { lhs, rhs in
                lhs.element.position == rhs.element.position
                    ? lhs.offset < rhs.offset
                    : lhs.element.position < rhs.element.position
            }
            .map(\.element)
    }

    /// Every armed binding across both lists, apps-first and then by position. Rows that
    /// carry no shortcut yet are dropped — they exist only as placeholders in the pane.
    static func armed(from defaults: UserDefaults = .standard) -> [ArmedPositionShortcut] {
        PositionShortcutList.allCases.flatMap { list in
            bindings(list, from: defaults).compactMap { binding in
                guard let shortcut = binding.shortcut, !shortcut.isEmpty else { return nil }
                return ArmedPositionShortcut(
                    id: binding.id, list: list, position: binding.position, shortcut: shortcut
                )
            }
        }
    }

    // MARK: Writing

    static func setBindings(
        _ bindings: [PositionShortcutBinding],
        for list: PositionShortcutList,
        in defaults: UserDefaults = .standard
    ) {
        guard let data = try? JSONEncoder().encode(bindings) else {
            log.error("Failed to encode position shortcuts for \(list.defaultsKey, privacy: .public)")
            return
        }
        defaults.set(data, forKey: list.defaultsKey)
    }
}

// MARK: - Position → ring index

/// Turns a 1-based user-facing position into an index into a resolved ring, or `nil` when
/// the wheel is currently shorter than that. Pure, so "position 5 with three apps open does
/// nothing" is asserted directly rather than inferred from a live wheel.
enum PositionShortcutResolver {
    static func index(forPosition position: Int, count: Int) -> Int? {
        guard position >= 1, position <= count else { return nil }
        return position - 1
    }
}

// MARK: - Edge detection (pure)

/// Rising-edge detector for the armed position shortcuts. Mirrors
/// `KeyboardShortcutDetector`, but tracks a match per binding rather than one latch for the
/// whole set: two position shortcuts sharing a modifier must each fire on their own key,
/// and neither may re-fire while the other is pressed.
///
/// Only the first newly-matched binding fires per event. Several rows may share a position
/// — that is the point of the list — but two rows sharing a *shortcut* must still activate
/// one thing; the apps-before-windows, ascending-position order
/// `PositionShortcutStore.armed` produces makes which one wins deterministic.
struct PositionShortcutDetector {
    private(set) var activeIDs: Set<UUID> = []

    /// Feed the current held state and the armed bindings; returns the binding that just
    /// went from unmatched to matched, if any.
    mutating func handle(held: HeldKeys, armed: [ArmedPositionShortcut]) -> ArmedPositionShortcut? {
        var matching: Set<UUID> = []
        var fired: ArmedPositionShortcut?
        for entry in armed where KeyboardShortcutMatcher.matches(held, shortcut: entry.shortcut) {
            matching.insert(entry.id)
            if fired == nil, !activeIDs.contains(entry.id) { fired = entry }
        }
        activeIDs = matching
        return fired
    }

    /// Forget every latched match. Called when the tap (re)starts so a shortcut held across
    /// a permission grant doesn't resolve into a fire the user never made.
    mutating func reset() { activeIDs.removeAll() }
}
