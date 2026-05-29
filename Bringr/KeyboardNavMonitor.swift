import AppKit
import CoreGraphics
import Foundation
import os

/// Global keyDown tap that drives optional keyboard navigation of the pie menu (Bringr-93j.71).
/// Installed once at launch and left running, but it only acts while the menu is open with
/// keyboard navigation enabled (`isActive`): then it maps each key to a `KeyboardNavKey` and
/// asks the controller to handle it, **consuming** the event when handled so a number or arrow
/// can't leak into the app underneath. Every other key — and every key when the feature is off
/// or the menu is closed — passes straight through, so this never interferes with normal typing.
///
/// Unlike the observe-only mouse/modifier taps it must be able to swallow a handled key, which is
/// exactly why an `NSEvent` global monitor won't do (those can't consume). Like the other taps it
/// needs Accessibility permission, so `start()` fails gracefully without it and is retried once
/// permission is granted.
@MainActor
final class KeyboardNavMonitor {
    /// Whether keyboard navigation should consume keys right now. Read fresh on each key.
    private let isActive: () -> Bool
    /// Handle one key; returns whether it was consumed.
    private let onKey: (KeyboardNavKey) -> Bool

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?

    private let log = Logger(subsystem: "com.mekedron.Bringr", category: "KeyboardNav")

    init(isActive: @escaping () -> Bool, onKey: @escaping (KeyboardNavKey) -> Bool) {
        self.isActive = isActive
        self.onKey = onKey
    }

    /// Whether the tap is currently installed.
    var isRunning: Bool { eventTap != nil }

    /// Install the event tap. Idempotent; returns `false` (and logs) if the tap cannot be created,
    /// which happens when the process lacks Accessibility permission. Call again once permission
    /// is granted to retry.
    @discardableResult
    func start() -> Bool {
        guard eventTap == nil else { return true }

        let mask: CGEventMask = 1 << CGEventType.keyDown.rawValue
        let callback: CGEventTapCallBack = { _, type, event, userInfo in
            guard let userInfo else { return Unmanaged.passUnretained(event) }
            let monitor = Unmanaged<KeyboardNavMonitor>.fromOpaque(userInfo).takeUnretainedValue()
            return MainActor.assumeIsolated { monitor.handle(type: type, event: event) }
        }

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            // Active tap (not listen-only): the callback returns nil to swallow a handled key.
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: callback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            log.error("Could not create keyboard-nav tap — Accessibility permission likely missing.")
            return false
        }

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)

        eventTap = tap
        runLoopSource = source
        log.info("Keyboard-nav tap installed.")
        return true
    }

    /// Remove the tap.
    func stop() {
        if let eventTap { CGEvent.tapEnable(tap: eventTap, enable: false) }
        if let runLoopSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes) }
        eventTap = nil
        runLoopSource = nil
    }

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        // The system disables a slow/over-budget tap; re-enable and pass through.
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let eventTap { CGEvent.tapEnable(tap: eventTap, enable: true) }
            return Unmanaged.passUnretained(event)
        }
        guard type == .keyDown, isActive() else { return Unmanaged.passUnretained(event) }
        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
        guard let key = KeyboardNavKey(keyCode: keyCode), onKey(key) else {
            return Unmanaged.passUnretained(event)
        }
        return nil // handled — swallow it so it can't reach the app underneath.
    }
}
