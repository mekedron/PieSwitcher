import Foundation

// MARK: - Mode

/// Whether the radial menu stays open after the summon trigger is released.
/// Persisted (AC3) and chosen in Preferences; governs the hold-capable triggers
/// (mouse chord, keyboard shortcut). The menu-bar fallback always behaves as
/// `clickToStay` because a menu click has no "hold" to track.
enum InteractionMode: String, CaseIterable, Sendable {
    /// The menu stays open only while the trigger is held: gliding to a slice and
    /// releasing over it selects it; releasing off any slice cancels.
    case holdToSelect
    /// The menu opens and remains after the trigger is released: a later click
    /// selects, a click off any slice (or Esc) cancels.
    case clickToStay

    /// Hold-to-select is the default — the most fluid match for the hold-natured
    /// mouse chord: press, glide to a slice, release to pick, never leaving the wheel.
    static let `default`: InteractionMode = .holdToSelect

    /// `UserDefaults` key backing the persisted choice. Single source of truth shared
    /// by the Preferences `@AppStorage` and `current(from:)` so they cannot drift.
    static let defaultsKey = "interactionMode"

    /// Human-readable name for the Preferences picker.
    var displayName: String {
        switch self {
        case .holdToSelect: return "Hold to select"
        case .clickToStay: return "Click to stay open"
        }
    }

    /// The persisted mode, falling back to `.default` when unset or unrecognized.
    static func current(from defaults: UserDefaults = .standard) -> InteractionMode {
        guard let raw = defaults.string(forKey: defaultsKey),
              let mode = InteractionMode(rawValue: raw) else {
            return .default
        }
        return mode
    }
}

// MARK: - State-machine vocabulary

/// What the cursor is over at the moment of a commit gesture: a specific slice, or
/// nothing (the central dead zone or outside the ring). Both the hold-mode release
/// and the click-to-stay click resolve to one of these, so the select/cancel
/// decision is identical for both modes (AC4).
enum SliceTarget: Equatable, Sendable {
    case slice(Int)
    case none
}

/// Inputs the interaction state machine reacts to. The live controller translates
/// triggers, releases, clicks, and Esc into these; the machine stays pure.
enum InteractionInput: Equatable, Sendable {
    /// The summon trigger fired (mouse chord, keyboard shortcut, or menu-bar item).
    case triggerPressed
    /// The summon trigger was released, with what the cursor was over at release.
    case triggerReleased(over: SliceTarget)
    /// A click landed while the menu was open, with what it was over.
    case click(over: SliceTarget)
    /// The user pressed Esc.
    case escape
    /// The summon context was lost out from under an open menu — the active Space
    /// changed, the session locked, or the trigger otherwise vanished without a
    /// clean release. Cancels exactly like Esc so no reveal is left stranded. (US-015)
    case triggerLost
}

/// What the controller should do in response to an input. The controller owns the
/// side effects (show/hide the overlay, focus a window in US-012, restore in
/// US-015); the machine only decides which path to take.
enum InteractionOutcome: Equatable, Sendable {
    case none
    case open
    case select(Int)
    case cancel
}

// MARK: - State machine (pure)

/// Decides open / select / cancel for both interaction modes, funnelling every
/// selection and cancellation through one shared path so the two modes differ only
/// in *when* a release commits versus persists (AC1, AC2, AC4).
///
/// A pure value type with no AppKit/overlay dependency, so the whole policy is
/// unit-tested directly (AC5).
struct InteractionStateMachine {
    /// The active mode. The controller sets this before a summon so a change takes
    /// effect on the next open rather than mid-session (AC3).
    var mode: InteractionMode

    /// Whether the menu is currently open. Read-only to callers; only `handle`
    /// transitions it, so the machine is the single source of truth.
    private(set) var isOpen = false

    init(mode: InteractionMode = .default) {
        self.mode = mode
    }

    /// Feed one input and get the side effect the controller should perform.
    mutating func handle(_ input: InteractionInput) -> InteractionOutcome {
        switch input {
        case .triggerPressed:
            return handleTriggerPressed()
        case .triggerReleased(let target):
            guard isOpen else { return .none }
            // Hold-to-select commits on release; click-to-stay persists for a later click.
            guard mode == .holdToSelect else { return .none }
            return commit(for: target)
        case .click(let target):
            guard isOpen else { return .none }
            // Click-to-stay commits on a click; hold-to-select only ever commits on release.
            guard mode == .clickToStay else { return .none }
            return commit(for: target)
        case .escape, .triggerLost:
            // Both force a cancel when open: Esc, and any abrupt loss of the summon
            // context that would otherwise strand a reveal (US-015).
            guard isOpen else { return .none }
            isOpen = false
            return .cancel
        }
    }

    /// Force the machine to the closed state after a keyboard-driven commit (Bringr-93j.71),
    /// which performs the selection directly on the navigator rather than through the mode-gated
    /// release/click path. Mirrors the `isOpen = false` every commit/cancel already does, so the
    /// next trigger opens cleanly.
    mutating func markClosed() {
        isOpen = false
    }

    private mutating func handleTriggerPressed() -> InteractionOutcome {
        // Re-triggering while open dismisses it (toggle parity with the menu-bar item).
        if isOpen {
            isOpen = false
            return .cancel
        }
        isOpen = true
        return .open
    }

    /// Resolve a commit gesture's target into the shared select/cancel outcome —
    /// the single path both modes funnel through (AC4) — and close the menu.
    private mutating func commit(for target: SliceTarget) -> InteractionOutcome {
        isOpen = false
        switch target {
        case .slice(let index): return .select(index)
        case .none: return .cancel
        }
    }
}
