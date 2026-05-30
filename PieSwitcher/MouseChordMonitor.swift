import AppKit
import CoreGraphics
import Foundation
import os

// MARK: - Live monitor (CGEventTap)

/// Installs a global mouse event tap, feeds presses into a `MouseChordDetector`, and fires
/// `onChord` when one of the configured `MouseActivationMethod`s' required buttons have all
/// been held for the configured hold delay (Bringr-93j.96).
///
/// The tap watches every mouse button (left, right, middle, and the two side buttons) plus
/// their drag events. Deferred presses are buffered as live `CGEvent`s only while *blocking*
/// mode is enabled; in non-blocking mode every event passes straight through and the chord is
/// detected non-invasively, which guarantees no system-wide lag — the CRITICAL constraint of
/// Bringr-93j.96. Accessibility/Input Monitoring permission is required; without it `start()`
/// fails gracefully and logs, matching US-002's permission-degradation philosophy.
@MainActor
final class MouseChordMonitor {
    var detector: MouseChordDetector
    let onChord: () -> Void
    private let onChordReleased: () -> Void
    /// The currently enabled `MouseActivationMethod`s, read fresh per event so a Preferences
    /// change applies on the next press with no relaunch. Empty set = mouse activation is off.
    private let methodsProvider: () -> Set<MouseActivationMethod>
    /// The hold delay in seconds, read fresh per event so a Preferences change applies on
    /// the next press without a relaunch.
    private let holdDelayProvider: () -> TimeInterval
    /// Whether blocking mode is on, read fresh per event. ON = button events of a pursued
    /// method are buffered; OFF = events always pass through and the detector observes only.
    private let blockingProvider: () -> Bool

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    var heldEvents: [CGEvent] = []
    var pursuitTimer: Timer?
    var holdDelayTimer: Timer?
    /// The match that the hold-delay timer is currently armed for, so a late state change
    /// (e.g. the user released a button before the delay elapsed) can cancel it precisely.
    var pendingMatch: MouseActivationMethod?

    /// Whether a chord is currently summoned and at least one of its buttons is still
    /// physically held. Used to fire `onChordReleased` exactly once when the last chord
    /// button comes up — the release that drives hold-to-select (US-009).
    var chordActive = false
    /// Buttons physically down right now, tracked from the raw event stream so the
    /// chord-release moment is known even when the detector consumes the ups.
    private var physicallyDown: Set<MouseButton> = []

    private let log = Logger(subsystem: "com.mekedron.PieSwitcher", category: "MouseChord")

    /// Stamped into `eventSourceUserData` of replayed events so the tap passes its own
    /// re-injected presses straight through instead of re-detecting them.
    static let replaySentinel: Int64 = 0x4252_4E47  // "BRNG"

    init(
        pursuitTimeout: TimeInterval = 0.12,
        methodsProvider: @escaping () -> Set<MouseActivationMethod> = { MouseActivationConfig.methods() },
        holdDelayProvider: @escaping () -> TimeInterval = { MouseActivationHoldDelay.current() },
        blockingProvider: @escaping () -> Bool = { MouseActivationConfig.blocking() },
        onChord: @escaping () -> Void,
        onChordReleased: @escaping () -> Void = {}
    ) {
        self.detector = MouseChordDetector(pursuitTimeout: pursuitTimeout)
        self.methodsProvider = methodsProvider
        self.holdDelayProvider = holdDelayProvider
        self.blockingProvider = blockingProvider
        self.onChord = onChord
        self.onChordReleased = onChordReleased
    }

    /// Whether the tap is currently installed.
    var isRunning: Bool { eventTap != nil }

    /// Install the event tap. Idempotent; returns `false` (and logs) if the tap cannot be
    /// created, which happens when the process lacks the required permission. Call again
    /// once permission is granted to retry.
    @discardableResult
    func start() -> Bool {
        guard eventTap == nil else { return true }

        // Drag events are in the mask so a press-then-drag (any window drag) can short-circuit
        // the chord hold and let the down through immediately (Bringr-93j.94). Without them
        // the buffered down sits for the full pursuit timeout, which the user sees as a
        // system-wide drag-start stutter.
        let mask: CGEventMask =
            (1 << CGEventType.leftMouseDown.rawValue) |
            (1 << CGEventType.leftMouseUp.rawValue) |
            (1 << CGEventType.rightMouseDown.rawValue) |
            (1 << CGEventType.rightMouseUp.rawValue) |
            (1 << CGEventType.otherMouseDown.rawValue) |
            (1 << CGEventType.otherMouseUp.rawValue) |
            (1 << CGEventType.leftMouseDragged.rawValue) |
            (1 << CGEventType.rightMouseDragged.rawValue) |
            (1 << CGEventType.otherMouseDragged.rawValue)

        let callback: CGEventTapCallBack = { _, type, event, userInfo in
            guard let userInfo else { return Unmanaged.passUnretained(event) }
            let monitor = Unmanaged<MouseChordMonitor>.fromOpaque(userInfo).takeUnretainedValue()
            return MainActor.assumeIsolated {
                monitor.handle(type: type, event: event)
            }
        }

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: callback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            log.error("Could not create mouse event tap — Accessibility/Input Monitoring permission likely missing.")
            return false
        }

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)

        eventTap = tap
        runLoopSource = source
        detector.reset()
        log.info("Mouse chord tap installed.")
        return true
    }

    /// Remove the tap and clear any deferred state.
    func stop() {
        if let eventTap { CGEvent.tapEnable(tap: eventTap, enable: false) }
        if let runLoopSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes) }
        eventTap = nil
        runLoopSource = nil
        cancelPursuitTimer()
        cancelHoldDelayTimer()
        heldEvents.removeAll()
        chordActive = false
        physicallyDown.removeAll()
        pendingMatch = nil
        detector.reset()
    }

    // MARK: - Tap callback handling

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        // The system disables a slow/over-budget tap; re-enable and pass through.
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let eventTap { CGEvent.tapEnable(tap: eventTap, enable: true) }
            return Unmanaged.passUnretained(event)
        }

        let methods = methodsProvider()

        // No methods enabled = mouse activation is off; flush any half-buffered press and let
        // every event through untouched. Avoids stranding a buffered press if the user disables
        // methods mid-pursuit.
        if methods.isEmpty {
            if !heldEvents.isEmpty { replayHeldEvents() }
            cancelPursuitTimer()
            cancelHoldDelayTimer()
            pendingMatch = nil
            detector.reset()
            return Unmanaged.passUnretained(event)
        }

        // Our own replayed presses carry the sentinel — never re-detect them.
        if event.getIntegerValueField(.eventSourceUserData) == Self.replaySentinel {
            return Unmanaged.passUnretained(event)
        }

        if type == .leftMouseDragged || type == .rightMouseDragged || type == .otherMouseDragged {
            return handleDrag(event)
        }

        guard let button = MouseButton.from(eventType: type, event: event),
              let phase = MouseButtonPhase.from(eventType: type) else {
            return Unmanaged.passUnretained(event)
        }

        switch phase {
        case .down: physicallyDown.insert(button)
        case .up: physicallyDown.remove(button)
        }

        let blocking = blockingProvider()
        let holdDelay = holdDelayProvider()
        let reaction = detector.handle(
            MouseButtonEvent(button: button, phase: phase, timestamp: ProcessInfo.processInfo.systemUptime),
            methods: methods,
            holdDelay: holdDelay
        )
        let result = apply(reaction, to: event, blocking: blocking, holdDelay: holdDelay)

        // Fire once when the last button of a summoned chord is released — the signal
        // hold-to-select uses to commit (US-009).
        if chordActive, physicallyDown.isEmpty {
            chordActive = false
            onChordReleased()
        }
        return result
    }

    /// A drag with a button held while we are still waiting for a chord partner is plainly
    /// a drag, not a chord — release the buffered press at once so the focused app sees the
    /// drag start without the threshold-long stall that was causing system-wide drag-start
    /// stutter (Bringr-93j.94). Append the current drag to the buffer so the replay preserves
    /// down→drag order. The CRITICAL constraint of Bringr-93j.96 means this short-circuit also
    /// covers middle/side buttons via `.otherMouseDragged`.
    private func handleDrag(_ event: CGEvent) -> Unmanaged<CGEvent>? {
        guard detector.motionDetected() else { return Unmanaged.passUnretained(event) }
        cancelHoldDelayTimer()
        pendingMatch = nil
        heldEvents.append(event)
        replayHeldEvents()
        return nil
    }

    private func apply(
        _ reaction: MouseChordReaction,
        to event: CGEvent,
        blocking: Bool,
        holdDelay: TimeInterval
    ) -> Unmanaged<CGEvent>? {
        // In non-blocking mode every event passes through unchanged, with one exception:
        // the chord-completing press itself. summon() installs a global dismiss monitor
        // synchronously before this callback returns, so if the press were dispatched it
        // would immediately trigger that monitor's `click(over: .none)` and cancel the
        // wheel a beat after it opened (Bringr-93j.99 — the L+R activation regression
        // introduced when blocking defaulted to OFF). Consume just that one press; the
        // pursuit presses still pass through, which is non-blocking's whole promise.
        if !blocking {
            applySideEffects(reaction, holdDelay: holdDelay)
            if reaction == .summon { return nil }
            return Unmanaged.passUnretained(event)
        }
        return applyBlocking(reaction, event: event, holdDelay: holdDelay)
    }

    /// In blocking mode the detector's reactions drive what happens to the live event: pass
    /// through, drop, or buffer it for a later replay/discard.
    private func applyBlocking(
        _ reaction: MouseChordReaction,
        event: CGEvent,
        holdDelay: TimeInterval
    ) -> Unmanaged<CGEvent>? {
        switch reaction {
        case .pass:
            return Unmanaged.passUnretained(event)

        case .consume:
            return nil

        case .hold:
            heldEvents.append(event)
            updateMatchTrackers(holdDelay: holdDelay)
            return nil

        case .releaseHeldThenHold:
            replayHeldEvents()
            heldEvents.append(event)
            updateMatchTrackers(holdDelay: holdDelay)
            return nil

        case .releaseHeldWithCurrent:
            cancelHoldDelayTimer()
            pendingMatch = nil
            heldEvents.append(event)
            replayHeldEvents()
            return nil

        case .summon:
            cancelPursuitTimer()
            cancelHoldDelayTimer()
            pendingMatch = nil
            heldEvents.removeAll()
            chordActive = true
            onChord()
            return nil
        }
    }

    /// In non-blocking mode the live event always passes through, but the detector's
    /// transition still drives the hold-delay timer or the immediate summon, so the chord
    /// still fires on schedule.
    private func applySideEffects(_ reaction: MouseChordReaction, holdDelay: TimeInterval) {
        if reaction == .summon {
            cancelPursuitTimer()
            cancelHoldDelayTimer()
            pendingMatch = nil
            chordActive = true
            onChord()
            return
        }
        updateMatchTrackers(holdDelay: holdDelay)
    }

    /// Bring the pursuit and hold-delay timers in sync with the detector's current
    /// `matchedMethod`. Shared between blocking and non-blocking modes so a state change
    /// produces the same timing in both. The pursuit timer only runs while we have buffered
    /// events: in non-blocking mode there's nothing to replay, so leaving the detector in a
    /// long-lived partial-match state is fine — the user can complete the combo at any time.
    ///
    /// The timer is scheduled against the *effective* hold delay (`MouseActivationHoldDelay
    /// .effective(for:configured:)`), which applies the single-button floor: configured 0 ms
    /// stays 0 ms for multi-button chords, but bumps to the floor for single-button methods so
    /// a quick tap can be replayed as a normal click instead of being eaten by the wheel
    /// (Bringr-93j.100).
    private func updateMatchTrackers(holdDelay: TimeInterval) {
        guard !chordActive else { return }
        let matched = detector.matchedMethod
        if matched != pendingMatch {
            cancelHoldDelayTimer()
            pendingMatch = matched
            if let matched {
                let effective = MouseActivationHoldDelay.effective(for: matched, configured: holdDelay)
                if effective > 0 {
                    scheduleHoldDelayTimer(delay: effective)
                }
            }
        }
        if matched == nil, !heldEvents.isEmpty {
            schedulePursuitTimer()
        } else {
            cancelPursuitTimer()
        }
    }

}
