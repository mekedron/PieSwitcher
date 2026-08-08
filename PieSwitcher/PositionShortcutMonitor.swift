import AppKit
import CoreGraphics
import Foundation
import os

/// Global tap that fires the user's position shortcuts (Bringr-dk3).
///
/// Built on the same `HeldKeys` snapshot and `KeyboardShortcutMatcher` the activation
/// shortcut uses, so a position shortcut recorded in the picker distinguishes left from
/// right exactly as the summon shortcut does. It differs from `ModifierHoldMonitor` in two
/// ways, both forced by what a position shortcut is:
///
/// * **It fires on the rising edge with no hold delay.** A position shortcut is an atomic
///   "go there", not a summon the user aims inside afterwards, so there is nothing to wait
///   for and nothing to preview.
/// * **It consumes the key.** A combination like `⌃⌥1` would otherwise reach the app
///   underneath as well, which for a shortcut meant to switch away from that app is exactly
///   the wrong outcome. Only the non-modifier key of a matched combo is swallowed —
///   modifier events always pass through, so a position shortcut bound to bare modifiers
///   (which the picker allows) can never break normal typing.
@MainActor
final class PositionShortcutMonitor {
    private var detector = PositionShortcutDetector()
    /// Live held-keys snapshot, updated incrementally per event so matching stays O(armed).
    private var held = HeldKeys.empty
    /// The key code whose `keyDown` was swallowed, so its auto-repeats and its matching
    /// `keyUp` are swallowed too. Without this the app underneath would see a key release
    /// it never saw pressed, and a held combo would leak repeats through.
    private var swallowedKeyCode: Int?

    private let onFire: (PositionShortcutList, Int) -> Void
    /// The armed bindings, read fresh on every event so a Preferences edit applies at once —
    /// the convention every other activation setting follows. Injected so tests pin a set.
    private let armedProvider: () -> [ArmedPositionShortcut]
    /// Whether a press must be dropped: the wheel is open (its own keyboard navigation owns
    /// the keys then), or the frontmost app is on the Positions exclusion list. That list is
    /// honoured here precisely because this tap *consumes* keys — an app the user has told
    /// the position shortcuts to stay out of must keep every keystroke. It is the Positions
    /// list, not Activation → Excluded Apps: the two are independent settings.
    private let isSuppressed: () -> Bool

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?

    private let log = Logger(subsystem: "com.mekedron.PieSwitcher", category: "PositionShortcuts")

    init(
        onFire: @escaping (PositionShortcutList, Int) -> Void,
        armedProvider: @escaping () -> [ArmedPositionShortcut] = { PositionShortcutStore.armed() },
        isSuppressed: @escaping () -> Bool = {
            PositionShortcutExclusionList.shouldSuppressShortcuts(
                frontmostBundleID: NSWorkspace.shared.frontmostApplication?.bundleIdentifier
            )
        }
    ) {
        self.onFire = onFire
        self.armedProvider = armedProvider
        self.isSuppressed = isSuppressed
    }

    var isRunning: Bool { eventTap != nil }

    /// Install the tap. Idempotent; returns `false` (and logs) when the tap can't be created,
    /// which means Accessibility permission is missing. Call again once it's granted.
    @discardableResult
    func start() -> Bool {
        guard eventTap == nil else { return true }

        let mask: CGEventMask = (1 << CGEventType.flagsChanged.rawValue)
            | (1 << CGEventType.keyDown.rawValue)
            | (1 << CGEventType.keyUp.rawValue)
        let callback: CGEventTapCallBack = { _, type, event, userInfo in
            guard let userInfo else { return Unmanaged.passUnretained(event) }
            let monitor = Unmanaged<PositionShortcutMonitor>.fromOpaque(userInfo).takeUnretainedValue()
            return MainActor.assumeIsolated {
                SlowStep.measure("position tap \(type.rawValue)") {
                    monitor.handle(type: type, event: event)
                }
            }
        }

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            // An active tap, unlike the activation monitor's: this one has to be able to
            // swallow the key of a matched combo.
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: callback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            log.error("Could not create position-shortcut tap — Accessibility permission likely missing.")
            return false
        }

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)

        eventTap = tap
        runLoopSource = source
        clearState()
        log.info("Position-shortcut tap installed.")
        return true
    }

    func stop() {
        if let eventTap { CGEvent.tapEnable(tap: eventTap, enable: false) }
        if let runLoopSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes) }
        eventTap = nil
        runLoopSource = nil
        clearState()
    }

    private func clearState() {
        detector.reset()
        held = .empty
        swallowedKeyCode = nil
    }

    // MARK: - Event handling

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let eventTap { CGEvent.tapEnable(tap: eventTap, enable: true) }
            return Unmanaged.passUnretained(event)
        }
        guard type == .flagsChanged || type == .keyDown || type == .keyUp else {
            return Unmanaged.passUnretained(event)
        }
        let passesThrough = step(
            type: type,
            keyCode: Int(event.getIntegerValueField(.keyboardEventKeycode)),
            modifiers: SidedModifierParser.modifiers(from: event.flags)
        )
        return passesThrough ? Unmanaged.passUnretained(event) : nil
    }

    /// One tracked event through the monitor's state machine; returns whether it passes
    /// through to the app underneath (`false` = swallowed). Split from `handle` on the
    /// already-decoded fields so tests can drive real press/release sequences — the
    /// swallow/latch interplay across events is exactly what a pure detector test can't see.
    func step(type: CGEventType, keyCode: Int, modifiers: Set<SidedModifier>) -> Bool {
        updateHeldSnapshot(type: type, keyCode: keyCode, modifiers: modifiers)

        // The tail of a combo we already swallowed: its auto-repeats and its matching keyUp
        // must not surface in the app underneath. Only the RETURN is decided here — the
        // detector below still observes the event, because the keyUp must clear its
        // per-binding latch. A latch that survives the release would make the next press of
        // the same combo read as still held: unfired, and leaked through to the app.
        var isSwallowedTail = false
        if let swallowed = swallowedKeyCode, keyCode == swallowed,
           type == .keyDown || type == .keyUp {
            isSwallowedTail = true
            if type == .keyUp { swallowedKeyCode = nil }
        }

        // Suppressed contexts still feed the detector, so a shortcut held across the moment
        // suppression lifts doesn't fire the instant it does — it has to be released and
        // pressed again. `ShortcutCaptureSession` is checked here rather than left to the
        // injected `isSuppressed` so no caller can switch it off: a position shortcut that
        // fires while its own field is recording is what makes a bad binding uncorrectable.
        let armed = (ShortcutCaptureSession.isCapturing || isSuppressed()) ? [] : armedProvider()
        let fired = detector.handle(held: held, armed: armed)
        guard !isSwallowedTail else { return false }
        guard let fired else { return true }
        onFire(fired.list, fired.position)

        // Bare-modifier shortcuts pass through: swallowing a `flagsChanged` would strand the
        // modifier as held everywhere else on the system.
        guard fired.shortcut.hasNonModifierKey, type == .keyDown else { return true }
        swallowedKeyCode = keyCode
        return false
    }

    /// Refresh `held` from the event, mirroring `ModifierHoldMonitor`.
    private func updateHeldSnapshot(type: CGEventType, keyCode: Int, modifiers: Set<SidedModifier>) {
        held.modifiers = modifiers
        switch type {
        case .keyDown:
            held.nonModifierKey = keyCode
        case .keyUp:
            if held.nonModifierKey == keyCode { held.nonModifierKey = nil }
        default:
            break
        }
    }
}
