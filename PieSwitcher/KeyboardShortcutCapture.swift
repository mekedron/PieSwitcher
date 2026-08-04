import Foundation

// MARK: - Capture session

/// Process-wide record of whether a Preferences shortcut field is currently recording.
///
/// The pickers listen through a *local* `NSEvent` monitor, but every armed shortcut is
/// matched by a head-inserted `CGEventTap` that sees the same keystroke first — so without
/// this, recording a new shortcut fires whatever the keys you are pressing happen to be
/// bound to. Pressing Option to re-record a slot would summon the wheel or switch windows
/// out from under the picker, which is exactly the state that makes a bad binding
/// impossible to correct.
///
/// Tokens rather than a counter: a field registers under a stable id, so a double `begin`
/// or an `end` from `onDisappear` after the field already committed are both no-ops instead
/// of leaving the session stuck open (which would silently disarm every shortcut) or
/// closing it early.
@MainActor
enum ShortcutCaptureSession {
    private static var activeTokens: Set<UUID> = []

    /// Whether any field is recording right now. Checked by every global shortcut tap on
    /// the edge that would otherwise fire.
    static var isCapturing: Bool { !activeTokens.isEmpty }

    static func begin(_ token: UUID) { activeTokens.insert(token) }
    static func end(_ token: UUID) { activeTokens.remove(token) }
}

// MARK: - Capture state machine (pure)

/// State the picker's capture loop walks through while the user records a shortcut.
/// Lives in its own value type so the whole decision tree — accept, reject, escape,
/// time-out, partial-key abort — is unit-tested without an `NSEvent` monitor.
///
/// The capture flow (AC: "the slot does not commit until either a valid shortcut is
/// held or the user presses Escape"):
///   1. Slot click → `.idle` → `.listening`.
///   2. First flagsChanged with at least one modifier → `.recording(snapshot)`.
///   3. Subsequent events update `snapshot` to the latest non-empty held state.
///   4. All keys released → `.committed(snapshot)`.
///   5. Escape pressed at any point with no other keys held → `.cancelled`.
///
/// Empty-modifier presses (e.g. a stray non-modifier key with no modifiers) are
/// rejected: the snapshot stays at whatever the user actually held last so accidental
/// partial keypresses can't corrupt the commit.
struct KeyboardShortcutCaptureMachine: Equatable {
    enum State: Equatable {
        case idle
        case listening
        case recording(HeldKeys)
        case committed(HeldKeys)
        case cancelled
    }

    private(set) var state: State = .idle

    /// Whether this field refuses a modifiers-only shortcut. On for the position shortcuts
    /// (Bringr-dk3): those fire an action outright and swallow their key, so a bare Option
    /// bound to one would hijack every use of Option on the system — including the ones the
    /// user needs to re-record it. The activation slots leave it off, because a held
    /// modifier is precisely what summons the wheel.
    var requiresNonModifierKey = false

    /// Set when a release was refused for carrying no non-modifier key, so the field can
    /// say what is missing rather than appearing to ignore the keys. Stays set for the rest
    /// of the session — the requirement is still unmet while the user holds the modifier
    /// again, so the hint has to survive until they add a key or give up.
    private(set) var rejectedModifierOnly = false

    init(requiresNonModifierKey: Bool = false) {
        self.requiresNonModifierKey = requiresNonModifierKey
    }

    /// Latest non-empty held state seen during recording. The picker renders this so
    /// the slot updates live as the user adjusts their fingers.
    var snapshot: HeldKeys? {
        switch state {
        case .recording(let snap), .committed(let snap):
            return snap
        case .idle, .listening, .cancelled:
            return nil
        }
    }

    var isCapturing: Bool {
        switch state {
        case .listening, .recording: return true
        case .idle, .committed, .cancelled: return false
        }
    }

    /// Begin a capture session. Called when the user clicks an idle slot (AC: "Clicking
    /// a slot puts it into capture mode"). Idempotent: starting an already-active
    /// session is a no-op so a double-click doesn't reset the recording mid-press.
    mutating func start() {
        guard state == .idle else { return }
        state = .listening
    }

    /// Bail out without committing. Called on Escape or when the slot loses focus.
    /// Idempotent so a stray cancel never resurrects a settled commit.
    mutating func cancel() {
        switch state {
        case .listening, .recording:
            state = .cancelled
        case .idle, .committed, .cancelled:
            break
        }
    }

    /// Feed the live held state. `nonModifierWasPressed` is the rising edge for the
    /// non-modifier key in `held` — letters / digits / space etc. We track that
    /// separately so the picker can decide "user pressed a key while holding a
    /// modifier" (commit a combo shortcut) vs "modifiers held alone".
    mutating func update(held: HeldKeys) {
        switch state {
        case .listening:
            if !held.modifiers.isEmpty {
                // First modifier(s) down — start a recording with this snapshot.
                state = .recording(held)
            }
            // A stray non-modifier-only press while listening (no modifiers) is
            // ignored — we never commit a key-only shortcut from the picker.
        case .recording(let prev):
            if held.modifiers.isEmpty, held.nonModifierKey == nil {
                // All keys released — commit whatever was last held, unless this field
                // requires a real key and the user let go of modifiers alone. Refusing
                // returns to listening rather than cancelling, so they can simply press
                // again without re-clicking the field.
                if requiresNonModifierKey, prev.nonModifierKey == nil {
                    rejectedModifierOnly = true
                    state = .listening
                } else {
                    state = .committed(prev)
                }
            } else if !held.modifiers.isEmpty {
                // Still holding modifiers (possibly with a non-modifier key) — keep
                // the snapshot up to date so the picker renders the live combo.
                state = .recording(held)
            }
            // Held set is non-empty but has only a non-modifier key (user released
            // every modifier but is still holding a letter) → wait; we'll commit
            // when the non-modifier comes up too.
        case .idle, .committed, .cancelled:
            break
        }
    }

    /// The Escape key is special-cased: pressing Escape with no other keys held cancels
    /// the capture; pressing Escape while a real shortcut is being held is treated as
    /// "user changed their mind" and also cancels (AC: "Escape cancels the capture and
    /// leaves the slot at its previous value").
    mutating func handleEscape() {
        cancel()
    }

    /// Read-and-clear the committed snapshot. Returns `nil` if the capture didn't end
    /// in a commit (i.e. it was cancelled or never started). The picker calls this
    /// after a commit transition to produce the final `KeyboardShortcut` and persist.
    mutating func take() -> HeldKeys? {
        guard case .committed(let held) = state else {
            // Reset the machine so the slot is ready for another capture session.
            state = .idle
            return nil
        }
        state = .idle
        return held
    }
}

// MARK: - Held → KeyboardShortcut

/// Convert a captured `HeldKeys` into a persistable `KeyboardShortcut`. Recorded
/// shortcuts are always side-specific (`sideAgnostic = false`); the side comes
/// directly from which physical key the user pressed.
enum KeyboardShortcutFromHeld {
    /// Returns `nil` for held states that the picker shouldn't commit:
    ///   • No modifiers at all (a key-only shortcut is rejected by the picker UI).
    ///   • A modifier-only "either" (impossible from real hardware but defensive).
    static func make(from held: HeldKeys) -> KeyboardShortcut? {
        guard !held.modifiers.isEmpty else { return nil }
        // Collapse any duplicate-family entries (e.g. both leftShift and rightShift
        // held together) into a single `.either` entry — that's what the runtime
        // matching needs, and it matches the picker's intent of "the user held both
        // sides so they probably mean either".
        let collapsed = collapseDualSides(in: held.modifiers)
        return KeyboardShortcut(
            modifiers: collapsed,
            keyCode: held.nonModifierKey,
            sideAgnostic: false
        )
    }

    private static func collapseDualSides(in modifiers: Set<SidedModifier>) -> Set<SidedModifier> {
        var byFamily: [ModifierFamily: Set<ModifierSide>] = [:]
        for mod in modifiers {
            byFamily[mod.family, default: []].insert(mod.side)
        }
        var result: Set<SidedModifier> = []
        for (family, sides) in byFamily {
            if sides == [.left] {
                result.insert(SidedModifier(family, .left))
            } else if sides == [.right] {
                result.insert(SidedModifier(family, .right))
            } else {
                // Both held, or `.either` (Fn) — store as `.either`.
                result.insert(SidedModifier(family, .either))
            }
        }
        return result
    }
}
