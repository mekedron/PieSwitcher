import CoreGraphics
import Foundation

/// The user-tunable look of the radial wheel (US-014): overall size (the apps
/// ring's outer radius), how far the ring sits out from the summon point (the
/// inner-radius padding), the resting slice fill opacity, whether text labels
/// show, and whether the Liquid Glass material is used. A pure value type with no
/// AppKit/SwiftUI dependency, so the defaults round-trip and the geometry it
/// derives are unit-tested directly.
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
    /// Whether the wheel renders with the genuine Liquid Glass material (macOS 26+).
    /// When off — or on any OS before macOS 26, which has no Liquid Glass — it uses
    /// the same frosted `.ultraThinMaterial` fallback: a plain look for users who
    /// prefer it, and a way to exercise that fallback on a current OS without an
    /// older machine.
    var usesLiquidGlass: Bool = defaultUsesLiquidGlass
    /// Extra distance, in points, between the summon point and the slices — added to
    /// both the dead-zone (inner) and outer radius, so the whole ring slides outward
    /// at constant thickness while staying centred on the cursor. Beyond taste this
    /// is a usability knob: a larger outer radius widens each slice's outer arc, so
    /// there is more room to land on a slice and aiming is more forgiving.
    var innerRadiusPadding: CGFloat = defaultInnerRadiusPadding
    /// Opacity (0–1) of the drop shadow cast by the whole glass wheel onto the desktop
    /// behind it, which seats the wheel as a floating object. Tunable from off to fully
    /// opaque (Bringr-93j.66); independent of the content shadow.
    var glassShadowOpacity: Double = defaultGlassShadowOpacity
    /// Opacity (0–1) of the shadow behind slice icons and labels (the content layer),
    /// which keeps them legible over the translucent ring on busy backgrounds. Tunable
    /// independently of the glass wheel's own shadow (Bringr-93j.66).
    var contentShadowOpacity: Double = defaultContentShadowOpacity
    /// Whether an app with no windows or only a single window skips the windows
    /// sub-wheel (Bringr-93j.75): with it on, hovering such an app opens no second level
    /// and committing the app acts on its one window directly, so there is no pointless
    /// extra ring when there is nothing to choose between. Apps with two or more windows
    /// still open the sub-wheel.
    var skipSingleWindowLevel: Bool = defaultSkipSingleWindowLevel

    static let defaultOuterRadius: CGFloat = RadialGeometry.default.outerRadius
    /// Zero by default — pure glass, so the genuine Liquid Glass material shows through
    /// at rest with no frost on top; the user dials it up for a more filled, frosted ring.
    static let defaultFillOpacity = 0.0
    /// Off by default — labels are optional and ride on top of the icon + window index
    /// that always show, so the wheel ships icon-only and the user opts into labels.
    static let defaultShowsLabels = false
    /// On by default, so the wheel ships with the Liquid Glass look; the user opts
    /// out to the plain frosted fallback.
    static let defaultUsesLiquidGlass = true
    /// Zero by default, so the wheel ships exactly where US-006 placed it; the user
    /// opts into pushing it further out.
    static let defaultInnerRadiusPadding: CGFloat = 0
    /// Zero by default — no glass drop shadow, so the wheel sits flush on the desktop;
    /// the user dials it up for a stronger floating-object look.
    static let defaultGlassShadowOpacity = 0.0
    /// Zero by default — no shadow behind icons and labels; the user raises it for more
    /// legibility on busy backgrounds.
    static let defaultContentShadowOpacity = 0.0
    /// On by default (Bringr-93j.93) — an app with no windows or just one skips the
    /// windows sub-wheel, so choosing it goes straight to its window with no pointless
    /// extra ring. Apps with two or more windows still open the sub-wheel.
    static let defaultSkipSingleWindowLevel = true

    static let `default` = RadialAppearance(
        outerRadius: defaultOuterRadius,
        fillOpacity: defaultFillOpacity,
        showsLabels: defaultShowsLabels,
        usesLiquidGlass: defaultUsesLiquidGlass,
        innerRadiusPadding: defaultInnerRadiusPadding,
        glassShadowOpacity: defaultGlassShadowOpacity,
        contentShadowOpacity: defaultContentShadowOpacity,
        skipSingleWindowLevel: defaultSkipSingleWindowLevel
    )

    /// Slider bounds shared by Preferences and the clamp on read, so the UI can
    /// never persist a value the model would have to reject.
    static let radiusRange: ClosedRange<CGFloat> = 110...260
    /// Spans pure glass (`0`, no fill — the genuine material shows through) to a
    /// near-solid frosted slice (`1`), so the one knob takes the ring from clear
    /// glass to heavily filled and visibly tunes how glassy the arc looks.
    static let opacityRange: ClosedRange<Double> = 0...1
    static let innerPaddingRange: ClosedRange<CGFloat> = 0...150
    /// Both shadow opacities span fully transparent (`0`, no shadow) to fully opaque
    /// (`1`), so each knob runs the shadow from off to its strongest.
    static let shadowOpacityRange: ClosedRange<Double> = 0...1

    /// `UserDefaults` keys — the single source of truth shared by the Preferences
    /// `@AppStorage` bindings and `current(from:)` so the two cannot drift.
    static let radiusDefaultsKey = "appearance.outerRadius"
    static let opacityDefaultsKey = "appearance.fillOpacity"
    static let labelsDefaultsKey = "appearance.showsLabels"
    static let glassDefaultsKey = "appearance.usesLiquidGlass"
    static let innerPaddingDefaultsKey = "appearance.innerRadiusPadding"
    static let glassShadowDefaultsKey = "appearance.glassShadowOpacity"
    static let contentShadowDefaultsKey = "appearance.contentShadowOpacity"
    static let skipSingleWindowLevelDefaultsKey = "appearance.skipSingleWindowLevel"

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
        if defaults.object(forKey: glassDefaultsKey) != nil {
            appearance.usesLiquidGlass = defaults.bool(forKey: glassDefaultsKey)
        }
        if defaults.object(forKey: innerPaddingDefaultsKey) != nil {
            let stored = defaults.double(forKey: innerPaddingDefaultsKey)
            appearance.innerRadiusPadding = clampedInnerPadding(CGFloat(stored))
        }
        if defaults.object(forKey: glassShadowDefaultsKey) != nil {
            appearance.glassShadowOpacity = clampedShadowOpacity(defaults.double(forKey: glassShadowDefaultsKey))
        }
        if defaults.object(forKey: contentShadowDefaultsKey) != nil {
            appearance.contentShadowOpacity = clampedShadowOpacity(defaults.double(forKey: contentShadowDefaultsKey))
        }
        if defaults.object(forKey: skipSingleWindowLevelDefaultsKey) != nil {
            appearance.skipSingleWindowLevel = defaults.bool(forKey: skipSingleWindowLevelDefaultsKey)
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

    private static func clampedShadowOpacity(_ value: Double) -> Double {
        min(max(value, shadowOpacityRange.lowerBound), shadowOpacityRange.upperBound)
    }
}
