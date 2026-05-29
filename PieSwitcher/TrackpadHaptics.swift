import Foundation

// MARK: - Haptic intensity

/// How strong the trackpad tap is when hovering from one pie item to the next
/// (Bringr-93j.44). The public `NSHapticFeedbackManager` exposes three feedback
/// *patterns* rather than a continuous strength, so the strength the user picks maps
/// onto those three discrete feels — lightest to firmest. Pure (no AppKit) so the
/// settings round-trip is unit-tested; the live performer maps each case onto a
/// `FeedbackPattern`.
enum HapticIntensity: String, CaseIterable, Sendable {
    /// The softest tick (maps to the alignment feedback pattern).
    case light
    /// A medium tick (maps to the generic feedback pattern).
    case medium
    /// The firmest tick (maps to the level-change feedback pattern).
    case strong

    /// Medium by default — noticeable but unobtrusive.
    static let `default`: HapticIntensity = .medium

    /// Human-readable name for the Preferences picker.
    var displayName: String {
        switch self {
        case .light: return "Light"
        case .medium: return "Medium"
        case .strong: return "Strong"
        }
    }
}

// MARK: - Persisted setting

/// The trackpad-haptic-on-hover setting (Bringr-93j.44): an optional tactile tap as the
/// selection moves through the pie, plus its strength. Off by default — opt-in polish, so
/// `bool(forKey:)` (which returns false for an absent key) already yields the intended
/// default with no presence check, like `HideOnCommit`. Read fresh at each
/// summon so a Preferences change applies on the next open without a relaunch.
enum TrackpadHaptics {
    /// `UserDefaults` key for the on/off toggle. Single source of truth shared by the
    /// Preferences `@AppStorage` and `isEnabled(from:)` so the two cannot drift.
    static let enabledKey = "trackpad.haptics.enabled"
    /// `UserDefaults` key for the chosen strength.
    static let intensityKey = "trackpad.haptics.intensity"

    /// Default: OFF — a nice-to-have the user opts into.
    static let enabledDefault = false

    /// Whether the hover haptic is enabled. Read fresh at each summon.
    static func isEnabled(from defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: enabledKey)
    }

    /// The chosen strength, falling back to `.default` when unset or unrecognized.
    static func intensity(from defaults: UserDefaults = .standard) -> HapticIntensity {
        guard let raw = defaults.string(forKey: intensityKey),
              let value = HapticIntensity(rawValue: raw) else {
            return .default
        }
        return value
    }
}

// MARK: - Hover transition (pure)

/// Decides when a hover move should fire a haptic tick (Bringr-93j.44): only when the
/// cursor advanced onto a *different* slice. Moving to the dead zone / outside the wheel
/// (`.none`) never taps, and re-resolving the same slice — a held-still cursor or a
/// sub-wheel retry (Bringr-93j.31) — never taps, so the tick fires once per item, not per
/// event. Pure, so the rule is unit-tested independent of the live haptic engine.
enum HoverHapticTrigger {
    static func shouldTap(from previous: HoverRegion, to current: HoverRegion) -> Bool {
        guard case .slice = current else { return false }
        return previous != current
    }
}
