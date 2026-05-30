import Foundation

// MARK: - Mode

/// Whether the radial menu stays open after the summon trigger is released.
/// Persisted independently per input source (Bringr-93j.91): the mouse chord and the
/// keyboard shortcut each carry their own preference, so a single picker no longer
/// forces both to behave alike. Read fresh per summon via `current(for:from:)`. The
/// menu-bar fallback always behaves as `clickToStay` because a menu click has no
/// "hold" to track.
enum InteractionMode: String, CaseIterable, Sendable {
    /// The menu stays open only while the trigger is held: gliding to a slice and
    /// releasing over it selects it; releasing off any slice cancels.
    case holdToSelect
    /// The menu opens and remains after the trigger is released: a later click
    /// selects, a click off any slice (or Esc) cancels.
    case clickToStay

    /// The default mouse mode — hold-to-select is the most fluid match for a held
    /// chord: press, glide to a slice, release to pick, never leaving the wheel.
    static let defaultForMouse: InteractionMode = .holdToSelect
    /// The default keyboard mode — hold-to-select, matching the mouse. The same fluid
    /// flow (hold, glide, release) works for the keyboard shortcut once a hold delay
    /// is in place: `ActivationHoldDelay` ensures a quick modifier tap doesn't summon,
    /// while a deliberate hold reads as a hold and releasing over a slice commits.
    static let defaultForKeyboard: InteractionMode = .holdToSelect

    /// `UserDefaults` key backing the persisted mouse choice. The pre-Bringr-93j.91
    /// shared key (`interactionMode`) is abandoned, not migrated — matching the
    /// project's no-compat-shim convention.
    static let mouseDefaultsKey = "interactionMode.mouse"
    /// `UserDefaults` key backing the persisted keyboard choice. Same no-compat-shim
    /// rationale as the mouse key.
    static let keyboardDefaultsKey = "interactionMode.keyboard"

    /// Human-readable name for the mouse picker.
    var displayName: String {
        switch self {
        case .holdToSelect: return "Hold to select"
        case .clickToStay: return "Click to stay open"
        }
    }

    /// Human-readable name for the keyboard picker (Bringr-93j.91): "Click to stay
    /// open" is renamed to "Press" because you don't really "click" a keyboard.
    var keyboardDisplayName: String {
        switch self {
        case .holdToSelect: return "Hold to select"
        case .clickToStay: return "Press"
        }
    }

    /// The persisted mode for the given trigger, falling back to that source's
    /// default when unset or unrecognized.
    static func current(
        for trigger: MenuTrigger,
        from defaults: UserDefaults = .standard
    ) -> InteractionMode {
        switch trigger {
        case .mouseChord:
            return read(mouseDefaultsKey, default: defaultForMouse, from: defaults)
        case .modifierHold:
            return read(keyboardDefaultsKey, default: defaultForKeyboard, from: defaults)
        }
    }

    private static func read(
        _ key: String,
        default fallback: InteractionMode,
        from defaults: UserDefaults
    ) -> InteractionMode {
        guard let raw = defaults.string(forKey: key),
              let mode = InteractionMode(rawValue: raw) else {
            return fallback
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
///
/// Bringr-93j.91 made click-to-activate always-on: a click on a slice commits in
/// either mode, and a click off any slice cancels. The former opt-in flag is gone;
/// the keyboard's default mode is now `clickToStay`, so "click to choose" is the
/// out-of-the-box behaviour there, while hold-to-select still commits on release.
struct InteractionStateMachine {
    /// The active mode. The controller sets this before a summon so a change takes
    /// effect on the next open rather than mid-session (AC3).
    var mode: InteractionMode

    /// Whether the menu is currently open. Read-only to callers; only `handle`
    /// transitions it, so the machine is the single source of truth.
    private(set) var isOpen = false

    init(mode: InteractionMode = .defaultForMouse) {
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
            // A click always commits in either mode: click-to-stay was always click-to-commit,
            // and hold-to-select gained the same behaviour after Bringr-93j.91 made click-to-activate
            // always-on — so the user can click an item to pick it instead of releasing the trigger,
            // and a click off any slice cancels. A click *outside* the overlay reaches this path via
            // the dismiss monitor with `over: .none`, so the cancel arm still applies there.
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
