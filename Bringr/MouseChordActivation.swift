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

// MARK: - Live monitor (CGEventTap)

/// Installs a global mouse event tap, feeds presses into a `MouseChordDetector`,
/// and fires `onChord` when a simultaneous left+right press is detected.
///
/// The tap is active (`.defaultTap`) so the detector can suppress the chord's
/// events (AC4). Deferred presses are buffered as live `CGEvent`s and replayed —
/// tagged with a sentinel so the tap ignores its own re-injected events — when the
/// detector decides they were ordinary clicks (AC2). Accessibility/Input
/// Monitoring permission is required; without it `start()` fails gracefully and
/// logs, matching the permission-degradation philosophy of US-002.
@MainActor
final class MouseChordMonitor {
    private var detector: MouseChordDetector
    private let onChord: () -> Void

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var heldEvents: [CGEvent] = []
    private var holdTimer: Timer?

    private let log = Logger(subsystem: "com.mekedron.Bringr", category: "MouseChord")

    /// Stamped into `eventSourceUserData` of replayed events so the tap passes its
    /// own re-injected presses straight through instead of re-detecting them.
    private static let replaySentinel: Int64 = 0x4252_4E47  // "BRNG"

    init(threshold: TimeInterval = 0.12, onChord: @escaping () -> Void) {
        self.detector = MouseChordDetector(threshold: threshold)
        self.onChord = onChord
    }

    /// Whether the tap is currently installed.
    var isRunning: Bool { eventTap != nil }

    /// Install the event tap. Idempotent; returns `false` (and logs) if the tap
    /// cannot be created, which happens when the process lacks the required
    /// permission. Call again once permission is granted to retry.
    @discardableResult
    func start() -> Bool {
        guard eventTap == nil else { return true }

        let mask: CGEventMask =
            (1 << CGEventType.leftMouseDown.rawValue) |
            (1 << CGEventType.leftMouseUp.rawValue) |
            (1 << CGEventType.rightMouseDown.rawValue) |
            (1 << CGEventType.rightMouseUp.rawValue)

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
        cancelHoldTimer()
        heldEvents.removeAll()
        detector.reset()
    }

    // MARK: - Tap callback handling

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        // The system disables a slow/over-budget tap; re-enable and pass through.
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let eventTap { CGEvent.tapEnable(tap: eventTap, enable: true) }
            return Unmanaged.passUnretained(event)
        }

        // Our own replayed presses carry the sentinel — never re-detect them.
        if event.getIntegerValueField(.eventSourceUserData) == Self.replaySentinel {
            return Unmanaged.passUnretained(event)
        }

        guard let button = Self.button(for: type), let phase = Self.phase(for: type) else {
            return Unmanaged.passUnretained(event)
        }

        let reaction = detector.handle(
            MouseButtonEvent(button: button, phase: phase, timestamp: ProcessInfo.processInfo.systemUptime)
        )
        return apply(reaction, to: event)
    }

    private func apply(_ reaction: MouseChordReaction, to event: CGEvent) -> Unmanaged<CGEvent>? {
        switch reaction {
        case .pass:
            return Unmanaged.passUnretained(event)

        case .consume:
            return nil

        case .hold:
            heldEvents.append(event)
            scheduleHoldTimer()
            return nil

        case .releaseHeldThenHold:
            replayHeldEvents()
            heldEvents.append(event)
            scheduleHoldTimer()
            return nil

        case .releaseHeldWithCurrent:
            cancelHoldTimer()
            heldEvents.append(event)
            replayHeldEvents()
            return nil

        case .summon:
            cancelHoldTimer()
            heldEvents.removeAll()
            onChord()
            return nil
        }
    }

    /// Re-inject every buffered press, in order, tagged so the tap lets them
    /// through. Posting from inside the callback keeps the original ordering, so
    /// the app sees a clean press/release rather than an out-of-order pair.
    private func replayHeldEvents() {
        cancelHoldTimer()
        let events = heldEvents
        heldEvents.removeAll()
        for event in events {
            event.setIntegerValueField(.eventSourceUserData, value: Self.replaySentinel)
            event.post(tap: .cgSessionEventTap)
        }
    }

    private func scheduleHoldTimer() {
        cancelHoldTimer()
        let timer = Timer(timeInterval: detector.threshold, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.holdTimerFired() }
        }
        RunLoop.main.add(timer, forMode: .common)
        holdTimer = timer
    }

    private func cancelHoldTimer() {
        holdTimer?.invalidate()
        holdTimer = nil
    }

    private func holdTimerFired() {
        if detector.handleTimeout(at: ProcessInfo.processInfo.systemUptime) {
            replayHeldEvents()
        }
    }

    private static func button(for type: CGEventType) -> MouseButton? {
        switch type {
        case .leftMouseDown, .leftMouseUp: return .left
        case .rightMouseDown, .rightMouseUp: return .right
        default: return nil
        }
    }

    private static func phase(for type: CGEventType) -> MouseButtonPhase? {
        switch type {
        case .leftMouseDown, .rightMouseDown: return .down
        case .leftMouseUp, .rightMouseUp: return .up
        default: return nil
        }
    }
}
