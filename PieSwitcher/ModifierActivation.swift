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

// MARK: - Mouse left+right-click trigger

/// Whether the simultaneous left+right mouse click summons the menu (US-007). This is the
/// mouse's summon trigger; the keyboard's held modifier combination
/// (`ModifierActivation.keyboard`) is a separate, independent trigger, so either, both, or
/// neither can be on at once (Bringr-93j.67, Bringr-93j.69).
/// A caseless namespace for the read helper, mirroring `HideOnCommit`; read fresh by
/// `MouseChordMonitor` on every event so a Preferences change applies with no relaunch.
enum MouseChordActivation {
    /// `UserDefaults` key backing the toggle. Single source of truth shared by the
    /// Preferences `@AppStorage` and `isEnabled(from:)` so the two cannot drift.
    static let defaultsKey = "activation.mouse.leftRightClick"

    /// Default: ON. Left+right click is the out-of-the-box v1 mouse trigger, so a fresh
    /// install summons with it (matching the pre-Bringr-93j.67 default mouse method).
    static let `default` = true

    /// Whether the left+right chord is an active mouse trigger. Because the default is ON,
    /// the unset case is checked explicitly — `bool(forKey:)` alone returns `false` for an
    /// absent key, which would silently flip the default (mirroring `CuratedApps`).
    static func isEnabled(from defaults: UserDefaults = .standard) -> Bool {
        guard defaults.object(forKey: defaultsKey) != nil else { return `default` }
        return defaults.bool(forKey: defaultsKey)
    }
}

// MARK: - Persisted modifier combinations

/// The persisted keyboard-shortcut activation — one held modifier combination — plus the
/// set of combinations currently "armed". Read fresh like the other settings, so a change
/// applies immediately without a relaunch.
///
/// Bringr-93j.69 unified the former separate mouse-modifier and trackpad-modifier settings
/// into this single keyboard shortcut: the modifier hold is a global key event that never
/// distinguished mouse from trackpad, so two persisted combinations were redundant. The mouse
/// keeps its own, independent left+right-click trigger (see `MouseChordActivation`).
enum ModifierActivation {
    /// `UserDefaults` key backing the persisted combination. The pre-Bringr-93j.69 keys
    /// (`activation.mouse.modifiers`, `activation.trackpad.modifiers`) are abandoned, not
    /// migrated — matching the project's no-compat-shim convention.
    static let keyboardDefaultsKey = "activation.keyboard.modifiers"

    /// Defaults to Fn: out of the box, holding Fn summons the menu with no mouse or trackpad
    /// gesture. This was the prior trackpad default and is the only summon method on a laptop
    /// without an external mouse.
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

    /// Every modifier combination that should summon the menu right now: the single keyboard
    /// shortcut, included only when non-empty so unchecking every key disables the keyboard
    /// path rather than arming "no modifiers". Independent of the mouse's left+right-click
    /// trigger (see `MouseChordActivation`), which is not a modifier combination and so is
    /// not represented here. Returned as an array because the detector matches against a set
    /// of armed combinations (a shape that also leaves room for future per-menu shortcuts).
    static func armedCombinations(from defaults: UserDefaults = .standard) -> [ModifierCombination] {
        let keyboard = keyboard(from: defaults)
        return keyboard.isEmpty ? [] : [keyboard]
    }
}

// MARK: - Detector (pure)

/// Recognises when the held modifiers match one of the armed combinations, emitting a
/// single `press` on the rising edge and a single `release` on the falling edge — the
/// same press/release shape the hold-capable triggers feed the interaction state machine
/// (US-009). Pure and value-typed, so the edge logic is unit-tested without an event tap.
///
/// Matching is *exact*: the held set must equal an armed set. Holding extra modifiers
/// never summons, and adding a modifier to an active combination ends it — so a genuine
/// shortcut like ⌘⇧4 never fires a ⌘-armed trigger, and the menu gets out of the way the
/// moment the chord changes.
struct ModifierHoldDetector {
    enum Reaction: Equatable, Sendable {
        case none
        case press
        case release
    }

    /// Whether an armed combination is currently held. Read-only to callers; only
    /// `handle` transitions it, so the detector is the single source of truth.
    private(set) var isActive = false

    /// Feed the currently-held modifiers and the armed combinations and get the edge.
    mutating func handle(held: ModifierCombination, armed: [ModifierCombination]) -> Reaction {
        let matches = armed.contains { !$0.isEmpty && $0 == held }
        switch (matches, isActive) {
        case (true, false):
            isActive = true
            return .press
        case (false, true):
            isActive = false
            return .release
        case (true, true), (false, false):
            return .none
        }
    }

    /// Clear the latched state, so a stale hold from a previous session never resolves
    /// into a new one. Called when the monitor (re)starts.
    mutating func reset() { isActive = false }
}

// MARK: - Live monitor (CGEventTap on flagsChanged)

/// Watches global modifier-key changes through a `CGEventTap` and fires `onPress` /
/// `onRelease` when the held modifiers start / stop matching an armed combination
/// (Bringr-93j.35). This is the keyboard shortcut — the only summon method on a laptop
/// without an external mouse; it replaces the unreliable three-finger trackpad press.
///
/// The tap **never consumes** an event — modifier keys must keep working everywhere — it
/// only observes and always passes the event through. It needs Accessibility permission
/// like the mouse-chord tap, so `start()` fails gracefully without it and is retried once
/// permission is granted. The armed combinations are read fresh on every change, so a
/// Preferences change takes effect immediately with no relaunch.
@MainActor
final class ModifierHoldMonitor {
    private var detector = ModifierHoldDetector()
    /// Gates the rising edge behind the hold delay (Bringr-93j.58): a press is delivered
    /// only after the keys survive the delay, and a release before then cancels it.
    private var delayGate = ModifierHoldDelayGate()
    private let onPress: () -> Void
    private let onRelease: () -> Void
    /// The armed combinations, read fresh on each modifier change so Preferences edits
    /// apply at once. Injected so tests can pass fixed combinations.
    private let armedProvider: () -> [ModifierCombination]
    /// The hold delay in seconds, read fresh on each rising edge so a Preferences change
    /// applies on the next hold. Injected so tests can pin a value.
    private let delayProvider: () -> TimeInterval

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    /// Pending delayed-press timer; non-nil while a hold is waiting out the delay.
    private var pressDelayTimer: Timer?

    private let log = Logger(subsystem: "com.mekedron.PieSwitcher", category: "ModifierHold")

    init(
        onPress: @escaping () -> Void,
        onRelease: @escaping () -> Void = {},
        armedProvider: @escaping () -> [ModifierCombination] = { ModifierActivation.armedCombinations() },
        delayProvider: @escaping () -> TimeInterval = { ActivationHoldDelay.current() }
    ) {
        self.onPress = onPress
        self.onRelease = onRelease
        self.armedProvider = armedProvider
        self.delayProvider = delayProvider
    }

    /// Whether the tap is currently installed.
    var isRunning: Bool { eventTap != nil }

    /// Install the event tap. Idempotent; returns `false` (and logs) if the tap cannot be
    /// created, which happens when the process lacks Accessibility permission. Call again
    /// once permission is granted to retry.
    @discardableResult
    func start() -> Bool {
        guard eventTap == nil else { return true }

        let mask: CGEventMask = 1 << CGEventType.flagsChanged.rawValue
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
        clearPendingPress()
    }

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        // The system disables a slow/over-budget tap; re-enable and pass through.
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let eventTap { CGEvent.tapEnable(tap: eventTap, enable: true) }
            return Unmanaged.passUnretained(event)
        }
        guard type == .flagsChanged else { return Unmanaged.passUnretained(event) }

        let held = ModifierCombination(cgFlags: event.flags)
        switch detector.handle(held: held, armed: armedProvider()) {
        case .press: scheduleDelayedPress()
        case .release: handleRelease()
        case .none: break
        }
        return Unmanaged.passUnretained(event)
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
        pressDelayTimer?.invalidate()
        pressDelayTimer = nil
    }
}
