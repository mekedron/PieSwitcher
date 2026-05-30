import AppKit
import CoreGraphics
import Foundation
import os

// MARK: - Detector input/output

/// A mouse button the chord cares about. v1 only uses the primary (left) and
/// secondary (right) buttons.
enum MouseButton: Equatable, Sendable {
    case left
    case right
}

/// Whether a button event is a press or a release.
enum MouseButtonPhase: Equatable, Sendable {
    case down
    case up
}

/// A single button transition with the time it occurred, in seconds on a
/// monotonic clock. The detector only ever sees these value events — never a
/// live `CGEvent` — so its logic is testable in isolation from the event stream.
struct MouseButtonEvent: Equatable, Sendable {
    let button: MouseButton
    let phase: MouseButtonPhase
    let timestamp: TimeInterval
}

/// What the live tap should do with the event (or buffer) it just fed the
/// detector. The live layer owns the actual `CGEvent` buffer; the detector only
/// decides the disposition, which keeps it pure.
///
/// - `pass`: deliver the current event to the focused app unchanged.
/// - `consume`: drop the current event (it must not reach the app).
/// - `hold`: buffer the current event and swallow it for now; the verdict comes
///   later (when the partner arrives, the button is released, or the timer fires).
/// - `releaseHeldThenHold`: replay the buffered events to the app, then buffer the
///   current one as the start of a new potential chord (a partner arrived too late
///   to be simultaneous).
/// - `releaseHeldWithCurrent`: append the current event to the buffer and replay
///   the whole buffer in order, then drop the original current event — a held
///   button was released without a partner, so it was a normal click.
/// - `summon`: a chord completed within the threshold; discard the buffered first
///   press (so it never leaks), drop the current event, and fire the trigger.
enum MouseChordReaction: Equatable {
    case pass
    case consume
    case hold
    case releaseHeldThenHold
    case releaseHeldWithCurrent
    case summon
}

// MARK: - Detector (pure)

/// Decides whether a left+right press pair counts as a simultaneous "summon"
/// chord, and what the live tap should do with each event so that a chord never
/// leaks to the focused app while normal single clicks still pass through.
///
/// The first button to go down is *held* (deferred) rather than delivered
/// immediately: only by waiting can we tell a lone click from the start of a
/// chord without leaking the press. The hold resolves the instant we learn the
/// answer — the partner press (chord), the same button's release (lone click), or
/// the threshold elapsing (a slow press-and-hold). This is a value type with no
/// dependency on `CGEvent`, so all of its behaviour is unit-tested directly.
struct MouseChordDetector {
    /// The maximum gap between the two presses for them to count as simultaneous.
    /// Configurable (AC1); also bounds how long a held press waits before it is
    /// replayed as a normal click.
    let threshold: TimeInterval

    private enum State: Equatable {
        case idle
        /// One button is held, awaiting a partner, its own release, or timeout.
        case heldFirst(button: MouseButton, downAt: TimeInterval)
        /// Both buttons formed a chord; swallow everything until both release.
        case chord
    }

    private var state: State = .idle
    /// Buttons currently physically pressed, so a chord can be torn down only once
    /// both of its buttons are released.
    private var pressed: Set<MouseButton> = []

    init(threshold: TimeInterval = 0.12) {
        self.threshold = threshold
    }

    /// Clear all state. Used when the tap (re)starts so a stale held press from a
    /// previous session never resolves into the new one.
    mutating func reset() {
        state = .idle
        pressed = []
    }

    /// Feed one button transition and get the disposition for it.
    mutating func handle(_ event: MouseButtonEvent) -> MouseChordReaction {
        switch event.phase {
        case .down:
            pressed.insert(event.button)
            return handleDown(event)
        case .up:
            pressed.remove(event.button)
            return handleUp(event)
        }
    }

    /// Called when the hold timer fires. Returns `true` if the held press has
    /// waited longer than the threshold and should now be replayed as a normal
    /// press (no partner ever arrived).
    mutating func handleTimeout(at now: TimeInterval) -> Bool {
        guard case .heldFirst(_, let downAt) = state, now - downAt >= threshold else {
            return false
        }
        state = .idle
        return true
    }

    /// Called when the live tap sees the mouse start to drag with a button down.
    /// A drag means the user is starting a drag, not a chord — drop the chord
    /// pursuit, return to idle, and return `true` so the caller releases the
    /// buffered press at once (Bringr-93j.94). Without this, the held press is
    /// only delivered when the threshold timer fires, which manifests as a
    /// system-wide stutter at the start of every fast window drag while the
    /// chord tap is enabled. Returns `false` if no press is being held.
    mutating func motionDetected() -> Bool {
        guard case .heldFirst = state else { return false }
        state = .idle
        return true
    }

    private mutating func handleDown(_ event: MouseButtonEvent) -> MouseChordReaction {
        switch state {
        case .idle:
            state = .heldFirst(button: event.button, downAt: event.timestamp)
            return .hold

        case .heldFirst(let first, let downAt):
            if event.button != first, event.timestamp - downAt <= threshold {
                state = .chord
                return .summon
            }
            // Partner came too late (or the same button repeated): the held press
            // was not part of a chord. Replay it and start holding this one.
            state = .heldFirst(button: event.button, downAt: event.timestamp)
            return .releaseHeldThenHold

        case .chord:
            return .consume
        }
    }

    private mutating func handleUp(_ event: MouseButtonEvent) -> MouseChordReaction {
        switch state {
        case .idle:
            // Up with nothing held (e.g. the release of an already-replayed press).
            return .pass

        case .heldFirst(let first, _):
            if event.button == first {
                state = .idle
                return .releaseHeldWithCurrent
            }
            // Release of a button we were not holding — deliver it and keep waiting.
            return .pass

        case .chord:
            if pressed.isEmpty { state = .idle }
            return .consume
        }
    }
}

// The live `MouseChordMonitor` lives in `MouseChordMonitor.swift` — split out of
// this file once the drag-detection wiring (Bringr-93j.94) pushed the combined
// length past the SwiftLint cap.
