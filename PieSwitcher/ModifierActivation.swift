import AppKit
import CoreGraphics
import Foundation
import os

// MARK: - Modifier combination

/// A combination of modifier keys that, held together, summons the menu (Bringr-93j.35).
/// An `OptionSet` so any subset of the five keys can be required at once; the raw `Int`
/// bitmask is what Preferences persists, so a whole combination round-trips through a
/// single `@AppStorage`-friendly value.
struct ModifierCombination: OptionSet, Hashable, Sendable {
    let rawValue: Int

    init(rawValue: Int) { self.rawValue = rawValue }

    static let function = ModifierCombination(rawValue: 1 << 0)
    static let control = ModifierCombination(rawValue: 1 << 1)
    static let option = ModifierCombination(rawValue: 1 << 2)
    static let shift = ModifierCombination(rawValue: 1 << 3)
    static let command = ModifierCombination(rawValue: 1 << 4)

    /// Every modifier we recognise — used to mask away stray bits read from storage and
    /// to enumerate the Preferences checkboxes.
    static let all: ModifierCombination = [.function, .control, .option, .shift, .command]

    /// One selectable key for the Preferences UI, in the order macOS conventionally
    /// lists them (Fn, then ⌃ ⌥ ⇧ ⌘).
    struct Key: Identifiable, Sendable {
        let modifier: ModifierCombination
        let name: String
        var id: Int { modifier.rawValue }
    }

    static let keys: [Key] = [
        Key(modifier: .function, name: "Fn"),
        Key(modifier: .control, name: "Control"),
        Key(modifier: .option, name: "Option"),
        Key(modifier: .shift, name: "Shift"),
        Key(modifier: .command, name: "Command")
    ]

    /// The modifiers a `CGEvent` reports as held, reduced to the five we track so
    /// unrelated bits (Caps Lock, numeric pad) never spoil an exact match.
    init(cgFlags: CGEventFlags) {
        var combo: ModifierCombination = []
        if cgFlags.contains(.maskSecondaryFn) { combo.insert(.function) }
        if cgFlags.contains(.maskControl) { combo.insert(.control) }
        if cgFlags.contains(.maskAlternate) { combo.insert(.option) }
        if cgFlags.contains(.maskShift) { combo.insert(.shift) }
        if cgFlags.contains(.maskCommand) { combo.insert(.command) }
        self = combo
    }

    /// The selected keys as "Fn + Command", for the Preferences caption.
    var names: String {
        Self.keys.filter { contains($0.modifier) }.map(\.name).joined(separator: " + ")
    }
}

// The pre-Bringr-93j.96 `MouseChordActivation` namespace (a single Bool key for "L+R click")
// was replaced by the multi-method `MouseActivationConfig` in `MouseActivation.swift`. The
// keyboard side intentionally stays separate so each input source carries its own settings.

// MARK: - Persisted modifier combinations (legacy)

/// The pre-Bringr-93j.111 persisted keyboard-shortcut activation — one held modifier
/// combination stored as a bitmask. Kept around purely as the migration source for the
/// new two-slot picker (see `KeyboardShortcutStore.runMigrationIfNeeded`); the new code
/// path reads `KeyboardShortcutStore.armedShortcuts()` instead.
///
/// Bringr-93j.69 unified the former separate mouse-modifier and trackpad-modifier
/// settings into this single keyboard shortcut. Bringr-93j.111 replaced it with the
/// two-slot, side-aware picker; we keep this enum so the upgrade path can read it once
/// and rewrite the user's intent into the new shape.
enum ModifierActivation {
    /// `UserDefaults` key backing the persisted bitmask. The migration planner reads
    /// this once, then leaves it untouched — the new keys live alongside it.
    static let keyboardDefaultsKey = "activation.keyboard.modifiers"

    /// Pre-Bringr-93j.111 default: Fn. Only used when the migration planner runs into
    /// an upgrader whose legacy key is present but holds an invalid value.
    static let keyboardDefault: ModifierCombination = .function

    static func keyboard(from defaults: UserDefaults = .standard) -> ModifierCombination {
        read(keyboardDefaultsKey, default: keyboardDefault, from: defaults)
    }

    /// A stored `0` means "explicitly cleared" (the user unchecked every key, disabling the
    /// keyboard shortcut) — distinct from "never set", which yields the default. So an absent
    /// key gets the default while a cleared one stays empty. Stray bits are masked away.
    private static func read(
        _ key: String,
        default fallback: ModifierCombination,
        from defaults: UserDefaults
    ) -> ModifierCombination {
        guard let raw = defaults.object(forKey: key) as? Int else { return fallback }
        return ModifierCombination(rawValue: raw).intersection(.all)
    }
}

// MARK: - Live monitor (CGEventTap on flagsChanged + keyDown/keyUp)

/// Watches global key changes through a `CGEventTap` and fires `onPress` / `onRelease`
/// when the held state matches an armed `KeyboardShortcut` (Bringr-93j.35 / Bringr-93j.111).
/// The keyboard shortcut is the only summon method on a laptop without an external mouse.
///
/// The tap **never consumes** an event — modifier keys and ordinary typing must keep
/// working everywhere — it only observes and always passes the event through. It needs
/// Accessibility permission like the mouse-chord tap, so `start()` fails gracefully
/// without it and is retried once permission is granted. The armed shortcuts are read
/// fresh on every change, so a Preferences change takes effect immediately with no
/// relaunch.
///
/// Bringr-93j.111 widened the tap from `flagsChanged` only to `flagsChanged + keyDown +
/// keyUp` so combo shortcuts like "Right Option + Space" can fire. The handler is still
/// O(1) per event, so the extra coverage doesn't add noticeable latency to typing.
@MainActor
final class ModifierHoldMonitor {
    private var detector = KeyboardShortcutDetector()
    /// Current held-keys snapshot. Updated incrementally on every event so the matcher
    /// can answer "does anything match right now?" cheaply.
    private var held = HeldKeys.empty
    /// Gates the rising edge behind the hold delay (Bringr-93j.58): a press is delivered
    /// only after the keys survive the delay, and a release before then cancels it.
    private var delayGate = ModifierHoldDelayGate()
    private let onPress: () -> Void
    private let onRelease: () -> Void
    /// Fires when the hold-delay timer is armed, with the delay in seconds. The progress
    /// indicator (Bringr-93j.103) uses it to start the on-cursor countdown — same visual
    /// treatment as the mouse hold delay, so the user sees the same fill animation regardless
    /// of which trigger they're holding.
    private let onProgressStart: (TimeInterval) -> Void
    /// Fires when the hold-delay timer is cancelled or completes (Bringr-93j.103), so the
    /// progress indicator clears.
    private let onProgressEnd: () -> Void
    /// The armed shortcuts, read fresh on each event so Preferences edits apply at once.
    /// Injected so tests can pass fixed shortcuts.
    private let armedProvider: () -> [KeyboardShortcut]
    /// The hold delay in seconds, read fresh on each rising edge so a Preferences change
    /// applies on the next hold. Injected so tests can pin a value.
    private let delayProvider: () -> TimeInterval
    /// Whether activation should be suppressed because the frontmost app is on the user's
    /// exclusion list (Bringr-93j.109). Checked on the detector's rising edge so a fresh
    /// hold over an excluded app is dropped, while an in-progress hold's falling edge still
    /// flows through cleanly. Read fresh per event, mirroring the other providers.
    private let exclusionProvider: () -> Bool

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    /// Pending delayed-press timer; non-nil while a hold is waiting out the delay.
    private var pressDelayTimer: Timer?

    private let log = Logger(subsystem: "com.mekedron.PieSwitcher", category: "ModifierHold")

    init(
        onPress: @escaping () -> Void,
        onRelease: @escaping () -> Void = {},
        armedProvider: @escaping () -> [KeyboardShortcut] = { KeyboardShortcutStore.armedShortcuts() },
        delayProvider: @escaping () -> TimeInterval = { ActivationHoldDelay.current() },
        exclusionProvider: @escaping () -> Bool = {
            ActivationExclusionList.shouldSuppressActivation(
                frontmostBundleID: NSWorkspace.shared.frontmostApplication?.bundleIdentifier
            )
        },
        onProgressStart: @escaping (TimeInterval) -> Void = { _ in },
        onProgressEnd: @escaping () -> Void = {}
    ) {
        self.onPress = onPress
        self.onRelease = onRelease
        self.armedProvider = armedProvider
        self.delayProvider = delayProvider
        self.exclusionProvider = exclusionProvider
        self.onProgressStart = onProgressStart
        self.onProgressEnd = onProgressEnd
    }

    /// Whether the tap is currently installed.
    var isRunning: Bool { eventTap != nil }

    /// Install the event tap. Idempotent; returns `false` (and logs) if the tap cannot be
    /// created, which happens when the process lacks Accessibility permission. Call again
    /// once permission is granted to retry.
    @discardableResult
    func start() -> Bool {
        guard eventTap == nil else { return true }

        // Bringr-93j.111 widens the mask: combo shortcuts like "Right Option + Space" need
        // keyDown/keyUp too. We still never consume — the user keeps typing through us.
        let mask: CGEventMask = (1 << CGEventType.flagsChanged.rawValue)
            | (1 << CGEventType.keyDown.rawValue)
            | (1 << CGEventType.keyUp.rawValue)
        let callback: CGEventTapCallBack = { _, type, event, userInfo in
            guard let userInfo else { return Unmanaged.passUnretained(event) }
            let monitor = Unmanaged<ModifierHoldMonitor>.fromOpaque(userInfo).takeUnretainedValue()
            return MainActor.assumeIsolated { monitor.handle(type: type, event: event) }
        }

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            // Active-but-pass-through, matching the proven mouse-chord tap's permission
            // path; the callback always returns the event, so no modifier is ever eaten.
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: callback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            log.error("Could not create modifier-hold tap — Accessibility permission likely missing.")
            return false
        }

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)

        eventTap = tap
        runLoopSource = source
        detector.reset()
        held = .empty
        clearPendingPress()
        log.info("Modifier-hold tap installed.")
        return true
    }

    /// Remove the tap and clear latched state.
    func stop() {
        if let eventTap { CGEvent.tapEnable(tap: eventTap, enable: false) }
        if let runLoopSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes) }
        eventTap = nil
        runLoopSource = nil
        detector.reset()
        held = .empty
        clearPendingPress()
    }

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        // The system disables a slow/over-budget tap; re-enable and pass through.
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let eventTap { CGEvent.tapEnable(tap: eventTap, enable: true) }
            return Unmanaged.passUnretained(event)
        }
        guard updateHeldSnapshot(type: type, event: event) else {
            return Unmanaged.passUnretained(event)
        }
        applyEdge(detector.handle(held: held, armed: armedProvider()))
        return Unmanaged.passUnretained(event)
    }

    /// Refresh `held` from the event. Returns `false` for event types we don't care
    /// about, so the caller can short-circuit without invoking the detector.
    private func updateHeldSnapshot(type: CGEventType, event: CGEvent) -> Bool {
        switch type {
        case .flagsChanged:
            held.modifiers = SidedModifierParser.modifiers(from: event.flags)
            return true
        case .keyDown:
            held.modifiers = SidedModifierParser.modifiers(from: event.flags)
            held.nonModifierKey = Int(event.getIntegerValueField(.keyboardEventKeycode))
            return true
        case .keyUp:
            held.modifiers = SidedModifierParser.modifiers(from: event.flags)
            let keyCode = Int(event.getIntegerValueField(.keyboardEventKeycode))
            // Only clear the slot if the released key matches the one we were tracking;
            // releasing a different key (rare during normal typing) shouldn't blank
            // our snapshot.
            if held.nonModifierKey == keyCode { held.nonModifierKey = nil }
            return true
        default:
            return false
        }
    }

    /// React to a detector edge. Press fires through the hold-delay gate (unless the
    /// frontmost app is on the exclusion list); release propagates straight through.
    private func applyEdge(_ edge: KeyboardShortcutDetector.Reaction) {
        switch edge {
        case .press:
            // Frontmost-app exclusion (Bringr-93j.109): a fresh hold over an excluded app is
            // dropped, but the detector still tracks state so a later release of the same hold
            // (via the .release branch below) flows through cleanly — the gate stays idle, so
            // `handleRelease` returns `.ignore` and no stray dismiss fires.
            guard !exclusionProvider() else { return }
            scheduleDelayedPress()
        case .release: handleRelease()
        case .none: break
        }
    }

    // MARK: - Hold delay (Bringr-93j.58)

    /// Arm the delay timer on a rising edge. A zero delay fires the press immediately so
    /// the pre-93j.58 behaviour (summon on the rising edge) is preserved exactly.
    private func scheduleDelayedPress() {
        guard delayGate.press() else { return }
        cancelPressDelayTimer()
        let delay = delayProvider()
        guard delay > 0 else {
            deliverDelayedPress()
            return
        }
        let timer = Timer(timeInterval: delay, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.deliverDelayedPress() }
        }
        RunLoop.main.add(timer, forMode: .common)
        pressDelayTimer = timer
        // Light up the cursor-progress circle (Bringr-93j.103) for the same delay the timer
        // uses; the mouse-side monitor lights the same indicator the same way, so a held
        // modifier feels identical to a held button visually.
        onProgressStart(delay)
    }

    /// The delay elapsed (or was zero): deliver the press, but only if the hold survived —
    /// the gate declines a stale fire whose release already slipped in first.
    private func deliverDelayedPress() {
        cancelPressDelayTimer()
        if delayGate.delayElapsed() { onPress() }
    }

    /// A falling edge: cancel a still-pending press (the hold was too short) or propagate
    /// the release if the press was already delivered.
    private func handleRelease() {
        switch delayGate.release() {
        case .cancelPendingPress: cancelPressDelayTimer()
        case .propagateRelease: onRelease()
        case .ignore: break
        }
    }

    private func clearPendingPress() {
        cancelPressDelayTimer()
        delayGate.reset()
    }

    private func cancelPressDelayTimer() {
        let wasArmed = pressDelayTimer != nil
        pressDelayTimer?.invalidate()
        pressDelayTimer = nil
        if wasArmed { onProgressEnd() }
    }
}
