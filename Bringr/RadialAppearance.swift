import CoreGraphics
import Foundation

/// The user-tunable look of the radial wheel (US-014): overall size (the apps
/// ring's outer radius), how far the ring sits out from the summon point (the
/// inner-radius padding), the resting slice fill opacity, and whether text labels
/// show. A pure value type with no AppKit/SwiftUI dependency, so the defaults
/// round-trip and the geometry it derives are unit-tested directly.
///
/// Read fresh at each summon (like `InteractionMode.current`), so a Preferences
/// change takes effect on the next summon without a relaunch (AC2). The geometry
/// it produces feeds *both* rendering and hit-testing, which read the same
/// `RadialGeometry`, so they can never diverge however the size is tuned (AC3);
/// the persisted values are clamped on read so a stray defaults entry can't yield
/// a degenerate (zero or inverted) ring.
struct RadialAppearance: Equatable, Sendable {
    /// Outer radius of the apps ring, in points — the wheel's overall size. The
    /// central dead zone scales with it (constant ratio), so the proportions that
    /// US-006 shipped hold at every size.
    var outerRadius: CGFloat
    /// Resting (un-hovered) slice fill opacity. Hovered and pre-highlighted slices
    /// step up from this by fixed deltas (clamped to 1), so this single knob moves
    /// the whole emphasis set together.
    var fillOpacity: Double
    /// Whether slices show their text labels (app name / window title). The app
    /// icon and the window index number always show, so a slice stays identifiable
    /// even with labels off.
    var showsLabels: Bool
    /// Extra distance, in points, between the summon point and the slices — added to
    /// both the dead-zone (inner) and outer radius, so the whole ring slides outward
    /// at constant thickness while staying centred on the cursor. Beyond taste this
    /// is a usability knob: a larger outer radius widens each slice's outer arc, so
    /// there is more room to land on a slice and aiming is more forgiving.
    var innerRadiusPadding: CGFloat = defaultInnerRadiusPadding

    static let defaultOuterRadius: CGFloat = RadialGeometry.default.outerRadius
    static let defaultFillOpacity = 0.18
    static let defaultShowsLabels = true
    /// Zero by default, so the wheel ships exactly where US-006 placed it; the user
    /// opts into pushing it further out.
    static let defaultInnerRadiusPadding: CGFloat = 0

    static let `default` = RadialAppearance(
        outerRadius: defaultOuterRadius,
        fillOpacity: defaultFillOpacity,
        showsLabels: defaultShowsLabels,
        innerRadiusPadding: defaultInnerRadiusPadding
    )

    /// Slider bounds shared by Preferences and the clamp on read, so the UI can
    /// never persist a value the model would have to reject.
    static let radiusRange: ClosedRange<CGFloat> = 110...260
    static let opacityRange: ClosedRange<Double> = 0.05...0.6
    static let innerPaddingRange: ClosedRange<CGFloat> = 0...150

    /// `UserDefaults` keys — the single source of truth shared by the Preferences
    /// `@AppStorage` bindings and `current(from:)` so the two cannot drift.
    static let radiusDefaultsKey = "appearance.outerRadius"
    static let opacityDefaultsKey = "appearance.fillOpacity"
    static let labelsDefaultsKey = "appearance.showsLabels"
    static let innerPaddingDefaultsKey = "appearance.innerRadiusPadding"

    /// Dead-zone-to-outer-radius ratio, taken from the shipped default so scaling
    /// the wheel preserves the original proportions.
    private static let innerRatio = RadialGeometry.default.innerRadius / RadialGeometry.default.outerRadius

    /// The base ring geometry this appearance produces. Fed into both the rendered
    /// rings and the hit-test layout, so they stay in lock-step at any size (AC3).
    /// `innerRadiusPadding` adds the same offset to both edges, so the ring keeps its
    /// thickness (and the navigator's concentric levels keep touching) while sliding
    /// outward from the summon point.
    var geometry: RadialGeometry {
        RadialGeometry(
            innerRadius: outerRadius * Self.innerRatio + innerRadiusPadding,
            outerRadius: outerRadius + innerRadiusPadding
        )
    }

    /// Fill opacity for a slice in the given emphasis state, derived from the
    /// resting `fillOpacity` so one knob tunes resting, pre-highlight, and hover at
    /// once. Hover is the strongest; pre-highlight sits between.
    func fillOpacity(hovered: Bool, prehighlighted: Bool) -> Double {
        if hovered { return min(1, fillOpacity + 0.24) }
        if prehighlighted { return min(1, fillOpacity + 0.12) }
        return fillOpacity
    }

    /// The persisted appearance, falling back to `.default` for any unset field and
    /// clamping every stored value into its valid range (AC3 — a bad value never
    /// yields a degenerate ring).
    static func current(from defaults: UserDefaults = .standard) -> RadialAppearance {
        var appearance = RadialAppearance.default
        if defaults.object(forKey: radiusDefaultsKey) != nil {
            appearance.outerRadius = clampedRadius(CGFloat(defaults.double(forKey: radiusDefaultsKey)))
        }
        if defaults.object(forKey: opacityDefaultsKey) != nil {
            appearance.fillOpacity = clampedOpacity(defaults.double(forKey: opacityDefaultsKey))
        }
        if defaults.object(forKey: labelsDefaultsKey) != nil {
            appearance.showsLabels = defaults.bool(forKey: labelsDefaultsKey)
        }
        if defaults.object(forKey: innerPaddingDefaultsKey) != nil {
            let stored = defaults.double(forKey: innerPaddingDefaultsKey)
            appearance.innerRadiusPadding = clampedInnerPadding(CGFloat(stored))
        }
        return appearance
    }

    private static func clampedRadius(_ value: CGFloat) -> CGFloat {
        min(max(value, radiusRange.lowerBound), radiusRange.upperBound)
    }

    private static func clampedInnerPadding(_ value: CGFloat) -> CGFloat {
        min(max(value, innerPaddingRange.lowerBound), innerPaddingRange.upperBound)
    }

    private static func clampedOpacity(_ value: Double) -> Double {
        min(max(value, opacityRange.lowerBound), opacityRange.upperBound)
    }
}
