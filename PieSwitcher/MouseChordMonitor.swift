import AppKit
import CoreGraphics
import Foundation
import os

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
    private let onChordReleased: () -> Void
    /// Whether the left+right chord is the mouse's active trigger right now, read fresh
    /// each event so switching the mouse to modifier keys takes effect at once (Bringr-93j.35).
    private let isEnabled: () -> Bool

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var heldEvents: [CGEvent] = []
    private var holdTimer: Timer?

    /// Whether a chord is currently summoned and at least one of its buttons is
    /// still physically held. Used to fire `onChordReleased` exactly once, when the
    /// last chord button comes up — the release that drives hold-to-select (US-009).
    private var chordActive = false
    /// Buttons physically down right now, tracked from the raw event stream so the
    /// chord-release moment is known even though the detector consumes the ups.
    private var physicallyDown: Set<MouseButton> = []

    private let log = Logger(subsystem: "com.mekedron.PieSwitcher", category: "MouseChord")

    /// Stamped into `eventSourceUserData` of replayed events so the tap passes its
    /// own re-injected presses straight through instead of re-detecting them.
    private static let replaySentinel: Int64 = 0x4252_4E47  // "BRNG"

    init(
        threshold: TimeInterval = 0.12,
        isEnabled: @escaping () -> Bool = { true },
        onChord: @escaping () -> Void,
        onChordReleased: @escaping () -> Void = {}
    ) {
        self.detector = MouseChordDetector(threshold: threshold)
        self.isEnabled = isEnabled
        self.onChord = onChord
        self.onChordReleased = onChordReleased
    }

    /// Whether the tap is currently installed.
    var isRunning: Bool { eventTap != nil }

    /// Install the event tap. Idempotent; returns `false` (and logs) if the tap
    /// cannot be created, which happens when the process lacks the required
    /// permission. Call again once permission is granted to retry.
    @discardableResult
    func start() -> Bool {
        guard eventTap == nil else { return true }

        // Drag events are in the mask so a press-then-drag (any window drag) can
        // short-circuit the chord hold and let the down through immediately
        // (Bringr-93j.94). Without them the buffered down sits for the full
        // threshold, which the user sees as a system-wide drag-start stutter.
        let mask: CGEventMask =
            (1 << CGEventType.leftMouseDown.rawValue) |
            (1 << CGEventType.leftMouseUp.rawValue) |
            (1 << CGEventType.rightMouseDown.rawValue) |
            (1 << CGEventType.rightMouseUp.rawValue) |
            (1 << CGEventType.leftMouseDragged.rawValue) |
            (1 << CGEventType.rightMouseDragged.rawValue)

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
        chordActive = false
        physicallyDown.removeAll()
        detector.reset()
    }

    // MARK: - Tap callback handling

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        // The system disables a slow/over-budget tap; re-enable and pass through.
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let eventTap { CGEvent.tapEnable(tap: eventTap, enable: true) }
            return Unmanaged.passUnretained(event)
        }

        // The mouse may be set to a modifier-key trigger instead of the chord; if so,
        // flush any half-buffered press and let every click through untouched (Bringr-93j.35).
        if !isEnabled() {
            if !heldEvents.isEmpty { replayHeldEvents() }
            detector.reset()
            return Unmanaged.passUnretained(event)
        }

        // Our own replayed presses carry the sentinel — never re-detect them.
        if event.getIntegerValueField(.eventSourceUserData) == Self.replaySentinel {
            return Unmanaged.passUnretained(event)
        }

        if type == .leftMouseDragged || type == .rightMouseDragged {
            return handleDrag(event)
        }

        guard let button = Self.button(for: type), let phase = Self.phase(for: type) else {
            return Unmanaged.passUnretained(event)
        }

        switch phase {
        case .down: physicallyDown.insert(button)
        case .up: physicallyDown.remove(button)
        }

        let reaction = detector.handle(
            MouseButtonEvent(button: button, phase: phase, timestamp: ProcessInfo.processInfo.systemUptime)
        )
        let result = apply(reaction, to: event)

        // Fire once when the last button of a summoned chord is released — the
        // signal hold-to-select uses to commit (US-009).
        if chordActive, physicallyDown.isEmpty {
            chordActive = false
            onChordReleased()
        }
        return result
    }

    /// A drag with a button held while we are still waiting for a chord partner is
    /// plainly a drag, not a chord — release the buffered press at once so the
    /// focused app sees the drag start without the threshold-long stall that was
    /// causing system-wide drag-start stutter (Bringr-93j.94). Append the current
    /// drag to the buffer so the replay preserves down→drag order.
    private func handleDrag(_ event: CGEvent) -> Unmanaged<CGEvent>? {
        guard detector.motionDetected() else { return Unmanaged.passUnretained(event) }
        heldEvents.append(event)
        replayHeldEvents()
        return nil
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
            chordActive = true
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
