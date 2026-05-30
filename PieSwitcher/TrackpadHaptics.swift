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

    /// Strong by default (Bringr-93j.93) — the firmest tick reads most clearly as a slice
    /// boundary crossing, since the gentler `.light` and `.medium` patterns can fade into
    /// the background trackpad noise.
    static let `default`: HapticIntensity = .strong

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
/// selection moves through the pie, plus its strength. On by default (Bringr-93j.93), so
/// the unset case needs an explicit presence check (mirroring `MouseChordActivation`) —
/// `bool(forKey:)` alone returns `false` for an absent key, which would silently flip the
/// intended default. Read fresh at each summon so a Preferences change applies on the next
/// open without a relaunch.
enum TrackpadHaptics {
    /// `UserDefaults` key for the on/off toggle. Single source of truth shared by the
    /// Preferences `@AppStorage` and `isEnabled(from:)` so the two cannot drift.
    static let enabledKey = "trackpad.haptics.enabled"
    /// `UserDefaults` key for the chosen strength.
    static let intensityKey = "trackpad.haptics.intensity"

    /// Default: ON (Bringr-93j.93) — the tactile tap pairs naturally with the trackpad-driven
    /// summon and reads as a slice-to-slice cursor click; the user opts out for a silent ring.
    static let enabledDefault = true

    /// Whether the hover haptic is enabled. Read fresh at each summon. Because the default is
    /// ON, the unset case is checked explicitly: `bool(forKey:)` alone returns `false` for an
    /// absent key, which would silently flip the default (mirroring `MouseChordActivation`).
    static func isEnabled(from defaults: UserDefaults = .standard) -> Bool {
        guard defaults.object(forKey: enabledKey) != nil else { return enabledDefault }
        return defaults.bool(forKey: enabledKey)
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
