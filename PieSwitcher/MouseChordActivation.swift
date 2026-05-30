import AppKit
import CoreGraphics
import Foundation
import os

// The `MouseButton`, `MouseButtonPhase`, `MouseButtonEvent`, and the persisted activation
// config (`MouseActivationConfig`, `MouseActivationHoldDelay`) live in `MouseActivation.swift`
// — Bringr-93j.96 split them out as the multi-method config grew past this file's budget.

// MARK: - Detector input/output

/// What the live tap should do with the event (or buffer) it just fed the detector. The live
/// layer owns the actual `CGEvent` buffer; the detector only decides the disposition, which
/// keeps it pure.
///
/// - `pass`: deliver the current event to the focused app unchanged.
/// - `consume`: drop the current event (it must not reach the app).
/// - `hold`: buffer the current event and swallow it for now; the verdict comes later (when
///   the pursuit completes, fails, the pursuit timeout fires, or the hold delay elapses).
/// - `releaseHeldThenHold`: replay the buffered events to the app, then buffer the current one
///   as the start of a new pursuit (a method was pursued but the new press broke the match).
/// - `releaseHeldWithCurrent`: append the current event to the buffer and replay the whole
///   buffer in order, then drop the original current event — a pursuit ended without summoning,
///   so its buffered events are the user's normal clicks.
/// - `summon`: a method matched with an effectively-0 ms hold delay; discard the buffered
///   pursuit events (so they never leak) and fire the trigger right now. With a non-zero
///   effective hold delay this never appears: the live monitor uses the hold-delay timer
///   instead, and only triggers the summon side effect after the timer fires. "Effectively
///   zero" applies the single-button floor (Bringr-93j.100), so a single-button method at
///   user-configured 0 ms still takes the `.hold`/timer path — letting a quick tap fall
///   through as a normal click.
enum MouseChordReaction: Equatable {
    case pass
    case consume
    case hold
    case releaseHeldThenHold
    case releaseHeldWithCurrent
    case summon
}

// MARK: - Detector (pure)

/// Decides whether the currently-held mouse buttons match one of the enabled `MouseActivation`
/// methods, and what the live tap should do with each event so that a successful match never
/// leaks to the focused app while normal single clicks still pass through.
///
/// Bringr-93j.96 generalised what used to be a hard-coded left+right chord into a multi-method
/// matcher with a user-configurable hold delay. Methods, hold delay, and blocking are read fresh
/// per event so a Preferences change applies on the next press with no relaunch. The detector
/// stays free of `CGEvent` and timers: it answers "what should I do with this transition?" and
/// "did a full match just appear?", and the live monitor handles buffers, timers, and replays.
struct MouseChordDetector {
    /// How long to keep a buffered partial-match press waiting for the missing buttons of any
    /// enabled method before giving up. Distinct from the user-visible hold delay (which fires
    /// after a full match): the pursuit timeout caps how long a NON-matching but POTENTIALLY-
    /// matching state can stall the focused app's clicks. Internal because surfacing it would
    /// re-introduce the stutter the user is paying to avoid.
    let pursuitTimeout: TimeInterval

    private enum State: Equatable {
        case idle
        /// A press is buffered as the start of pursuing one of the enabled methods. `pursuit`
        /// is the method whose buttons are currently *exactly* matched, or `nil` if we're
        /// partially matched (some buttons of some method are held) and still waiting for
        /// the rest.
        case heldFirst(startedAt: TimeInterval, pursuit: MouseActivationMethod?)
        /// A method's required buttons are matched and the hold delay has elapsed — chord
        /// active. The detector consumes the chord's events until everything releases.
        case chord
    }

    private var state: State = .idle
    /// Buttons currently physically pressed, so a chord can be torn down only once every
    /// participating button releases, and so the match check is just a set comparison.
    private var pressed: Set<MouseButton> = []

    init(pursuitTimeout: TimeInterval = 0.12) {
        self.pursuitTimeout = pursuitTimeout
    }

    /// The method whose required buttons are currently all held, or `nil` if no method
    /// matches the current physical state. Exposed so the live monitor knows when a full
    /// match just appeared (start the hold-delay timer) or disappeared (cancel it).
    var matchedMethod: MouseActivationMethod? {
        if case .heldFirst(_, let pursuit) = state { return pursuit }
        return nil
    }

    /// Whether the detector is in chord-active mode — set by `.summon` reactions or by an
    /// explicit `chordSummoned()` call (the path the hold-delay timer takes). The live
    /// monitor uses this to know when subsequent events should be consumed.
    var isChordActive: Bool {
        if case .chord = state { return true }
        return false
    }

    /// Clear all state. Used when the tap (re)starts so a stale held press from a previous
    /// session never resolves into the new one.
    mutating func reset() {
        state = .idle
        pressed = []
    }

    /// Promote a pending full match into the active chord state without going through a `.down`
    /// event. The live monitor calls this after a non-zero hold delay elapses while a match
    /// is still in place; with a 0 ms hold delay the detector reaches this state directly via
    /// the `.summon` reaction, so this is the timer-path counterpart.
    mutating func chordSummoned() {
        state = .chord
    }

    /// Feed one button transition and get the disposition for it. `methods` are the currently
    /// enabled activation methods; `holdDelay` controls the immediate-vs-deferred summon
    /// decision (0 → return `.summon` and switch to chord state at once; non-zero → return
    /// `.hold` and let the live monitor's timer drive `chordSummoned()`).
    mutating func handle(
        _ event: MouseButtonEvent,
        methods: Set<MouseActivationMethod> = [],
        holdDelay: TimeInterval = 0
    ) -> MouseChordReaction {
        switch event.phase {
        case .down:
            pressed.insert(event.button)
            return handleDown(event, methods: methods, holdDelay: holdDelay)
        case .up:
            pressed.remove(event.button)
            return handleUp(event, methods: methods)
        }
    }

    /// Called when the pursuit timer fires. Returns `true` if a buffered partial-match press
    /// has waited longer than the pursuit timeout and should now be replayed as a normal
    /// press (no full match arrived). The hold-delay timer is the live monitor's concern;
    /// this one only rescues partial-match buffers from indefinite stalling.
    mutating func handleTimeout(at now: TimeInterval) -> Bool {
        guard case .heldFirst(let startedAt, let pursuit) = state,
              pursuit == nil,
              now - startedAt >= pursuitTimeout else {
            return false
        }
        state = .idle
        return true
    }

    /// Called when the live tap sees the mouse start to drag with a button down. A drag
    /// means the user is starting a drag, not a chord — drop the chord pursuit, return to
    /// idle, and return `true` so the caller releases the buffered press at once
    /// (Bringr-93j.94). Without this, the held press is only delivered when the threshold
    /// timer fires, which manifests as a system-wide stutter at the start of every fast
    /// window drag while the chord tap is enabled. Returns `false` if no press is being held.
    ///
    /// The pressed set is also cleared so a follow-up press that *would* complete a method
    /// alongside the (now drag-committed) button never re-triggers a summon mid-drag. The
    /// user opted into the drag; matching restarts from a clean physical-state snapshot
    /// once they release and re-press.
    mutating func motionDetected() -> Bool {
        guard case .heldFirst = state else { return false }
        state = .idle
        pressed = []
        return true
    }

    private mutating func handleDown(
        _ event: MouseButtonEvent,
        methods: Set<MouseActivationMethod>,
        holdDelay: TimeInterval
    ) -> MouseChordReaction {
        let pursuit = methods.first(where: { $0.requiredButtons == pressed })
        // "Pursuit is still alive" means some enabled method's required set covers everything
        // currently held — adding more buttons could complete it. A button that's in *some*
        // method but breaks every superset relationship (e.g. Forward pressed while pursuing
        // Left+Right) is irrelevant to the pursuit and ends it.
        let canStillBePursuit = methods.contains(where: { $0.requiredButtons.isSuperset(of: pressed) })

        switch state {
        case .idle:
            guard canStillBePursuit else { return .pass }
            if let pursuit, MouseActivationHoldDelay.effective(for: pursuit, configured: holdDelay) == 0 {
                state = .chord
                return .summon
            }
            state = .heldFirst(startedAt: event.timestamp, pursuit: pursuit)
            return .hold

        case .heldFirst:
            return extendPursuit(
                event,
                pursuit: pursuit,
                canStillBePursuit: canStillBePursuit,
                holdDelay: holdDelay
            )

        case .chord:
            return .consume
        }
    }

    /// Continue an in-progress pursuit when a new button comes down: stay in pursuit if the
    /// new press keeps the held set a subset of some method's required set (and complete the
    /// match if it now equals one), otherwise replay the buffer alongside the current event.
    private mutating func extendPursuit(
        _ event: MouseButtonEvent,
        pursuit: MouseActivationMethod?,
        canStillBePursuit: Bool,
        holdDelay: TimeInterval
    ) -> MouseChordReaction {
        if canStillBePursuit {
            if let pursuit, MouseActivationHoldDelay.effective(for: pursuit, configured: holdDelay) == 0 {
                state = .chord
                return .summon
            }
            state = .heldFirst(startedAt: event.timestamp, pursuit: pursuit)
            return .hold
        }
        state = .idle
        return .releaseHeldWithCurrent
    }

    private mutating func handleUp(
        _ event: MouseButtonEvent,
        methods: Set<MouseActivationMethod>
    ) -> MouseChordReaction {
        switch state {
        case .idle:
            return .pass

        case .heldFirst(let startedAt, _):
            let pursuit = methods.first(where: { $0.requiredButtons == pressed })
            let stillPotential = !pressed.isEmpty && methods.contains(where: {
                $0.requiredButtons.isSuperset(of: pressed)
            })
            if stillPotential || pursuit != nil {
                state = .heldFirst(startedAt: startedAt, pursuit: pursuit)
                return .hold
            }
            state = .idle
            return .releaseHeldWithCurrent

        case .chord:
            if pressed.isEmpty { state = .idle }
            return .consume
        }
    }
}

// The live `MouseChordMonitor` lives in `MouseChordMonitor.swift` — split out of this file
// once the drag-detection wiring (Bringr-93j.94) pushed the combined length past the cap.
