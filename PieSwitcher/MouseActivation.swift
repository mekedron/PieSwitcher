import CoreGraphics
import Foundation

// MARK: - Mouse buttons

/// A mouse button that can take part in a summon combination (Bringr-93j.96 generalised the
/// pre-existing left+right pair to a multi-select set of methods drawn from a richer alphabet
/// of buttons). The detector and monitor stay free of `CGEvent` so this enum is the bridge: the
/// monitor maps `CGEvent` types to these cases, the detector reasons about them as plain values.
enum MouseButton: Equatable, Hashable, Sendable {
    case left
    case right
    case middle
    case forward
    case backward
}

/// Whether a button event is a press or a release.
enum MouseButtonPhase: Equatable, Sendable {
    case down
    case up
}

/// A single button transition with the time it occurred, in seconds on a monotonic clock.
/// The detector only ever sees these value events — never a live `CGEvent` — so its logic is
/// testable in isolation from the event stream.
struct MouseButtonEvent: Equatable, Sendable {
    let button: MouseButton
    let phase: MouseButtonPhase
    let timestamp: TimeInterval
}

extension MouseButton {
    /// Decode a `CGEventType` (plus the event itself for "other" button numbers) into the
    /// matching `MouseButton`, or `nil` for an event type that's not a button transition.
    /// Lives next to `MouseButton` so the live monitor and any future consumers share one
    /// authoritative mapping.
    ///
    /// Button numbering: 0 is left and 1 is right (delivered via `leftMouse*`/`rightMouse*`
    /// types); 2 is middle (the wheel button), 3 is the backward thumb button, 4 is the
    /// forward thumb button — the rest are delivered via `otherMouse*` with the number in
    /// `mouseEventButtonNumber`. Higher numbers exist on exotic mice but aren't mapped.
    static func from(eventType: CGEventType, event: CGEvent) -> MouseButton? {
        switch eventType {
        case .leftMouseDown, .leftMouseUp: return .left
        case .rightMouseDown, .rightMouseUp: return .right
        case .otherMouseDown, .otherMouseUp:
            switch event.getIntegerValueField(.mouseEventButtonNumber) {
            case 2: return .middle
            case 3: return .backward
            case 4: return .forward
            default: return nil
            }
        default: return nil
        }
    }
}

extension MouseButtonPhase {
    /// Decode a `CGEventType` into a button phase (`.down`/`.up`), or `nil` for a type
    /// that's not a button transition (e.g. drag, flagsChanged).
    static func from(eventType: CGEventType) -> MouseButtonPhase? {
        switch eventType {
        case .leftMouseDown, .rightMouseDown, .otherMouseDown: return .down
        case .leftMouseUp, .rightMouseUp, .otherMouseUp: return .up
        default: return nil
        }
    }
}

// MARK: - Activation methods (multi-select)

/// One way the user can summon the menu with the mouse (Bringr-93j.96). A method is a *set*
/// of buttons that must all be physically held for the configured hold delay before the wheel
/// opens. The enum case identifies the method; `requiredButtons` lists the buttons it needs.
///
/// New methods drop in cleanly: add a case, give it a stable `rawValue` for the persistence
/// bitmask, supply its required buttons and display name. Existing persisted bitmasks keep
/// working because cases keep their bit (the rawValue is the bit index).
enum MouseActivationMethod: Int, CaseIterable, Sendable, Hashable {
    case leftRight = 0
    case middle = 1
    case middleLeft = 2
    case middleRight = 3
    case forward = 4
    case backward = 5
    case forwardBackward = 6

    /// The bit this method takes in the persistence bitmask. Powers-of-two so any subset of
    /// methods round-trips through a single `Int` value (the `@AppStorage`-friendly shape).
    var bit: Int { 1 << rawValue }

    /// The exact set of buttons that must all be held for this method to fire. The detector
    /// matches on equality (not "subset"), so holding extra buttons never triggers a method
    /// whose set is a strict subset of what's held — the user picked Middle, not Middle-while-
    /// holding-something-else.
    var requiredButtons: Set<MouseButton> {
        switch self {
        case .leftRight: return [.left, .right]
        case .middle: return [.middle]
        case .middleLeft: return [.middle, .left]
        case .middleRight: return [.middle, .right]
        case .forward: return [.forward]
        case .backward: return [.backward]
        case .forwardBackward: return [.forward, .backward]
        }
    }

    /// Whether this method fires on a single button. Single-button methods can't tell a tap
    /// apart from a deliberate hold without *some* delay — the gesture is identical until
    /// time passes — so the detector enforces a floor on the user-configured hold delay for
    /// them (Bringr-93j.100). Multi-button chords don't need the floor: pressing two specific
    /// buttons together is itself an intentional signal, so 0 ms summon-on-simultaneity works.
    var isSingleButton: Bool { requiredButtons.count == 1 }

    /// Human-readable label for the Preferences checkbox.
    var displayName: String {
        switch self {
        case .leftRight: return "Left + Right click together"
        case .middle: return "Middle button"
        case .middleLeft: return "Middle + Left"
        case .middleRight: return "Middle + Right"
        case .forward: return "Forward (next) button"
        case .backward: return "Backward (previous) button"
        case .forwardBackward: return "Forward + Backward"
        }
    }
}

// MARK: - Persisted mouse-activation config

/// The persisted mouse activation: which methods are enabled (multi-select bitmask), the
/// hold delay, and the blocking toggle (Bringr-93j.96). Lives behind a caseless namespace
/// like `MouseChordActivation` did before; each value is read fresh on every event by the
/// live monitor so a Preferences change applies on the next summon with no relaunch.
///
/// The pre-Bringr-93j.96 key (`activation.mouse.leftRightClick`) is abandoned, not migrated —
/// matching the project's no-compat-shim convention. Bringr-93j.113 flipped the fresh-install
/// default from `{leftRight}` to `{middle}`: Left and Right are too easy to fire by accident
/// during normal app use, while Middle is rarely bound elsewhere on macOS and is a natural
/// fit for "summon a menu". Combined with the hold-delay floor below, this is low-collision.
enum MouseActivationConfig {
    /// `UserDefaults` key for the methods bitmask. One source of truth shared by Preferences
    /// `@AppStorage` and the monitor's reader, so the two cannot drift.
    static let methodsDefaultsKey = "activation.mouse.methods"

    /// Default methods: the Middle button (Bringr-93j.113). Replaces the pre-93j.113 left+right
    /// chord default — Middle is one of the least-used mouse buttons on macOS (its only common
    /// roles are closing tabs and opening links in new tabs in browsers) and it has no scroll
    /// behaviour, which makes it the least disruptive button to capture.
    static let defaultMethods: Set<MouseActivationMethod> = [.middle]

    /// The persisted set of enabled methods. An absent key returns the default; a stored 0
    /// means "the user unchecked every method" (mouse activation disabled), distinct from
    /// "never set" — `integer(forKey:)` alone would silently flip the default for the absent
    /// case, hence the presence check (same pattern as `MouseChordActivation` previously).
    static func methods(from defaults: UserDefaults = .standard) -> Set<MouseActivationMethod> {
        guard defaults.object(forKey: methodsDefaultsKey) != nil else { return defaultMethods }
        return decodeMethods(bitmask: defaults.integer(forKey: methodsDefaultsKey))
    }

    /// Whether any method is enabled, the gate `MouseChordMonitor` uses to decide if its
    /// pursuit/buffering logic should run at all (a cheap quick-out on every event).
    static func isEnabled(from defaults: UserDefaults = .standard) -> Bool {
        !methods(from: defaults).isEmpty
    }

    /// Decode an `Int` bitmask into a method set, masking away any stray bits so a corrupted
    /// or future-format value never produces a phantom case.
    static func decodeMethods(bitmask: Int) -> Set<MouseActivationMethod> {
        Set(MouseActivationMethod.allCases.filter { bitmask & $0.bit != 0 })
    }

    /// Encode a method set back to a bitmask, for tests and Preferences round-trips.
    static func encodeMethods(_ methods: Set<MouseActivationMethod>) -> Int {
        methods.reduce(0) { $0 | $1.bit }
    }

    // MARK: Blocking toggle

    /// `UserDefaults` key for the blocking toggle. When ON, a button press that is part of
    /// an active method is suppressed during the hold-delay window: a short release replays
    /// the press as a normal click, a hold past the delay summons the wheel and the press is
    /// dropped. When OFF, the button's normal action fires immediately and the summon happens
    /// independently after the hold delay.
    static let blockingDefaultsKey = "activation.mouse.blocking"

    /// Default: ON (blocking). Suppresses the chosen buttons' normal action during the hold-delay
    /// window, so a stray middle-click paste or right-click menu doesn't fire while the user is
    /// pursuing a chord. The user can opt out for the non-blocking path, which guarantees no
    /// added latency on the activation buttons but lets their normal action leak through (the
    /// constraint that drove the pre-93j.94 stutter is now satisfied either way — the chord
    /// detector replays held buttons on drag, so blocking no longer stalls window drags).
    static let defaultBlocking = true

    /// Whether blocking mode is active. Absent key returns the default; an explicit `false`
    /// stays off (the presence check distinguishes the two cases the same way the methods
    /// reader does).
    static func blocking(from defaults: UserDefaults = .standard) -> Bool {
        guard defaults.object(forKey: blockingDefaultsKey) != nil else { return defaultBlocking }
        return defaults.bool(forKey: blockingDefaultsKey)
    }

    // MARK: Lock toggle

    /// `UserDefaults` key for the lock toggle (Bringr-93j.103). Strictly stronger than the
    /// blocking toggle above: where blocking *defers* the activation buttons' clicks during the
    /// hold-delay window (and replays them as a normal click on a quick release), Lock simply
    /// *drops* them — mouseDown and mouseUp both — for every event whose button is required by
    /// an enabled method. The focused app sees nothing from those buttons for the duration of
    /// the hold-or-tap, whether the wheel ends up summoning or not.
    static let lockDefaultsKey = "activation.mouse.lock"

    /// Default: OFF. Lock makes sense almost exclusively for Middle (most middle-click behaviour
    /// fires on mouseUp — closing a tab, opening a link in a new tab — so eating both edges of
    /// the click is invisible during normal browsing). For Left and Right it shows up as
    /// noticeable unresponsiveness (text-selection drag, link-target arming, context menu all
    /// start on mouseDown), so the default sits at OFF and the Preferences blurb warns the user
    /// before they turn it on.
    static let defaultLock = false

    /// Whether lock mode is active. Absent key returns the default; an explicit `true` stays
    /// on (the presence check distinguishes the two cases the same way the other readers do).
    static func lock(from defaults: UserDefaults = .standard) -> Bool {
        guard defaults.object(forKey: lockDefaultsKey) != nil else { return defaultLock }
        return defaults.bool(forKey: lockDefaultsKey)
    }
}

// MARK: - Mouse movement threshold

/// How far the cursor may drift, in points, during the hold-delay window before the in-progress
/// pursuit is cancelled and the buffered click is replayed as a normal click/drag (Bringr-93j.103).
/// Before this knob, the threshold was a hard-coded 1 point — chosen to avoid stalling fast window
/// drags (Bringr-93j.94) but too aggressive for genuinely-still holds: a stray-pixel-twitch under
/// the user's still finger would cancel the activation. Making the threshold adjustable lets the
/// user pick a value that fits their device and how steadily they hold.
///
/// Stored in points so the Preferences slider/field bind to it directly; readers return it as a
/// `CGFloat` ready to compare with the squared distance from the press position. Read fresh per
/// drag event, so a Preferences change applies on the next gesture without a relaunch.
enum MouseActivationMoveThreshold {
    /// `UserDefaults` key backing the persisted threshold.
    static let defaultsKey = "activation.mouse.moveThresholdPoints"

    /// 5 points by default — comfortably above the still-finger jitter envelope on a typical
    /// trackpad/mouse, well below the few-tens-of-pixels a window drag clears in its first frame.
    /// "5 points" matches the threshold macOS uses internally for several other touch-vs-drag
    /// decisions (text-selection drag, etc.), so the feel sits inside familiar territory.
    static let defaultPoints: Double = 5

    /// The slider/field bounds, in points. 0 = restore the previous "any movement cancels"
    /// behaviour; 50 is a generous upper bound — anything larger and a deliberate hold-and-drag
    /// would feel like the click is "stuck" until the drag starts.
    static let pointRange: ClosedRange<Double> = 0...50

    /// The persisted threshold in points, clamped to the range, ready for a distance comparison.
    static func current(from defaults: UserDefaults = .standard) -> CGFloat {
        CGFloat(points(from: defaults))
    }

    /// The persisted threshold in points (the stored unit), clamped to the range. An absent
    /// key yields the default; `double(forKey:)` alone returns 0 for a missing key — which
    /// would silently flip the default to "any movement cancels" — so the presence check
    /// distinguishes "absent" from "user explicitly chose 0".
    static func points(from defaults: UserDefaults = .standard) -> Double {
        guard defaults.object(forKey: defaultsKey) != nil else { return defaultPoints }
        return clampPoints(defaults.double(forKey: defaultsKey))
    }

    /// Clamp a raw point value into `pointRange`, so a stray stored or typed value never
    /// produces an absurd threshold.
    static func clampPoints(_ value: Double) -> Double {
        min(max(value, pointRange.lowerBound), pointRange.upperBound)
    }
}

// MARK: - Mouse hold delay

/// How long the activation buttons must be held before the wheel opens (Bringr-93j.96 — the
/// mouse counterpart of the keyboard's `ActivationHoldDelay`). 0 ms means "fire as soon as a
/// method's required buttons are all held"; higher values let the user dismiss a stray combo
/// by releasing before the delay completes.
///
/// Stored in milliseconds so the Preferences slider and numeric field bind to it directly;
/// `current(from:)` returns it in seconds, ready to feed the press-delay timer.
enum MouseActivationHoldDelay {
    /// `UserDefaults` key backing the persisted delay. Distinct from the keyboard's key
    /// (`activation.holdDelayMilliseconds`) so each input source carries its own delay.
    static let defaultsKey = "activation.mouse.holdDelayMilliseconds"

    /// 150 ms by default (Bringr-93j.113). The previous 0 ms default suited the left+right
    /// chord (pressing two specific buttons together is already an intentional signal); with
    /// the fresh-install default now Middle alone, a hold delay is what separates a normal
    /// middle-click from a deliberate summon — without it, picking Middle as the activation
    /// method would silently break normal middle-click. 150 ms is well above the tap envelope
    /// of a normal click while still feeling fast for a deliberate hold. The user can drop it
    /// back to 0 if they want immediate summons, in which case the single-button floor below
    /// kicks in for single-button methods so click-vs-hold still works.
    static let defaultMilliseconds: Double = 150

    /// The slider/field bounds, in milliseconds. 0 = no delay (fire on simultaneous press);
    /// 1000 ms is the spec's upper bound.
    static let millisecondRange: ClosedRange<Double> = 0...1000

    /// The persisted delay in **seconds**, clamped to the range, ready for a timer.
    static func current(from defaults: UserDefaults = .standard) -> TimeInterval {
        milliseconds(from: defaults) / 1000
    }

    /// Floor applied to the configured hold delay when the matched method fires on a single
    /// button and the user has left the delay at 0 ms (Bringr-93j.100). A normal mouse click
    /// completes in well under 100 ms, so 200 ms is comfortably above the tap envelope while
    /// still feeling fast for a deliberate hold — without this floor, picking Middle as the
    /// activation method silently breaks normal middle-click (the press fires the wheel before
    /// the focused app ever sees it). An explicit non-zero delay is always respected as-is:
    /// the user opted into that latency.
    static let singleButtonMinimumMilliseconds: Double = 200

    /// The effective hold delay (seconds) the detector and monitor should use for `method`,
    /// applying `singleButtonMinimumMilliseconds` only when the method is single-button and
    /// the user-configured delay is exactly 0. Both the detector (deciding `.summon` vs
    /// `.hold`) and the monitor (scheduling the hold-delay timer) call this so they agree on
    /// the same effective value for the same method.
    static func effective(for method: MouseActivationMethod, configured: TimeInterval) -> TimeInterval {
        guard method.isSingleButton, configured == 0 else { return configured }
        return singleButtonMinimumMilliseconds / 1000
    }

    /// The persisted delay in milliseconds (the stored unit), clamped to the range. An
    /// absent key yields the default; `double(forKey:)` alone returns 0 for a missing key,
    /// which would silently keep the new default ("0 ms") in place even after a value is
    /// cleared, so the presence check guards against silent regressions.
    static func milliseconds(from defaults: UserDefaults = .standard) -> Double {
        guard defaults.object(forKey: defaultsKey) != nil else { return defaultMilliseconds }
        return clampMilliseconds(defaults.double(forKey: defaultsKey))
    }

    /// Clamp a raw millisecond value into `millisecondRange`, so a stray stored or typed
    /// value never produces an absurd delay.
    static func clampMilliseconds(_ value: Double) -> Double {
        min(max(value, millisecondRange.lowerBound), millisecondRange.upperBound)
    }
}
