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
    /// Whether app slices on the apps ring show their application name label
    /// (Bringr-93j.110). Independent of `showsWindowLabels`, so the two wheel levels
    /// can convey different information. The app icon always shows, so a slice stays
    /// identifiable even with names off.
    var showsAppLabels: Bool
    /// Whether window slices on the windows sub-wheel show their real window title
    /// (Bringr-93j.110) — the same string macOS shows in Mission Control or the
    /// Window menu. Independent of `showsAppLabels`. The 1-based window index
    /// number always shows (windows have no icon), so a slice stays identifiable even
    /// with titles off. When a real title is unavailable (AX denied, off-Space, or
    /// blank), the displayed text falls back to "<App> — Window <N>" so a slice is
    /// never blank.
    var showsWindowLabels: Bool
    /// Which Liquid Glass variant the wheel renders with (macOS 26+), or off for the
    /// frosted `.ultraThinMaterial` fallback. `.clear` is the see-through glass the
    /// app ships with; `.regular` is Apple's heavier, more frosted variant; `.off` uses
    /// the fallback on any OS — also the only path on macOS < 26, where Liquid Glass
    /// doesn't exist — so the user can preview the pre-macOS-26 look on a current OS.
    var glassStyle: RadialGlassStyle = defaultGlassStyle
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
    /// Opacity (0–1) of the slice-divider hairline at rest (Bringr-93j.116) — the only
    /// non-glass element on a resting wheel with default fill, so it's the practical knob
    /// for how "pure glass" the wheel reads. Hover and pre-highlight rims are *not* affected,
    /// so the selection cue stays strong however low this goes (set it to 0 and slices only
    /// appear when hovered).
    var restingRimOpacity: Double = defaultRestingRimOpacity
    /// Width in points (0–3) of the resting slice-divider hairline (Bringr-93j.116).
    /// Pairs with `restingRimOpacity`: thinner + dimmer = more glass-slab feel, thicker +
    /// brighter = more visible slice structure at rest.
    var restingRimWidth: CGFloat = defaultRestingRimWidth
    /// Hover slice rim opacity (0–1) — the bright outline on the currently-hovered slice
    /// (Bringr-93j.117). Independent of the resting rim, so you can hide the resting
    /// hairline entirely and still get a strong selection cue on hover.
    var hoverRimOpacity: Double = defaultHoverRimOpacity
    /// Hover slice rim width in points (0–5) (Bringr-93j.117).
    var hoverRimWidth: CGFloat = defaultHoverRimWidth
    /// Pre-highlight slice rim opacity (0–1) — the medium outline on the slice that's
    /// about to be hovered if the cursor keeps moving in that direction (Bringr-93j.117).
    var prehighlightRimOpacity: Double = defaultPrehighlightRimOpacity
    /// Pre-highlight slice rim width in points (0–5) (Bringr-93j.117).
    var prehighlightRimWidth: CGFloat = defaultPrehighlightRimWidth
    /// Tint applied to the genuine Liquid Glass material (Bringr-93j.117) via `Glass.tint`.
    /// `alpha == 0` skips the tint entirely (the wheel renders untinted glass). Any positive
    /// alpha pushes the glass toward the tint colour — useful for cool/warm "frostiness"
    /// without leaving the `.clear` variant. Ignored on the `.off` fallback path.
    var glassTint: RadialColor = defaultGlassTint
    /// Colour layered onto each slice via `fillOpacity` (Bringr-93j.117). Replaces the
    /// hard-coded white shipped before this knob: paired with `fillOpacity == 0`, the
    /// colour is invisible at rest and ramps in on hover / pre-highlight using the
    /// existing emphasis ladder, so the wheel can take on any tint without losing the
    /// hover cue. Keyboard focus still overrides this with the accent colour.
    var sliceFillColor: RadialColor = defaultSliceFillColor
    /// Material used on the `.off` fallback path (Bringr-93j.117). Five steps from
    /// `.ultraThin` (most see-through) to `.ultraThick` (heaviest blur), so Off mode acts
    /// as a real blur-strength knob. Unused while the Liquid Glass variant is `.clear`
    /// or `.regular`.
    var offMaterialThickness: RadialMaterialThickness = defaultOffMaterialThickness

    static let defaultOuterRadius: CGFloat = RadialGeometry.default.outerRadius
    /// Zero by default — pure glass, so the genuine Liquid Glass material shows through
    /// at rest with no frost on top; the user dials it up for a more filled, frosted ring.
    static let defaultFillOpacity = 0.0
    /// Off by default for the apps ring — slices ship icon-only and the user opts into
    /// names (Bringr-93j.110). Mirrors the original `defaultShowsLabels` shipped before
    /// labels were split.
    static let defaultShowsAppLabels = false
    /// On by default for the windows sub-wheel — a fresh install reveals the real-window-
    /// titles feature without the user hunting through Preferences (Bringr-93j.110). The
    /// migration in `current(from:)` preserves an existing user's prior labels-off choice.
    static let defaultShowsWindowLabels = true
    /// Ships as clear glass — the most see-through variant, so the wheel reads as a
    /// genuine glass object at rest; the user dials it up to the heavier `.regular`
    /// frost, or off to the plain `.ultraThinMaterial` fallback.
    static let defaultGlassStyle: RadialGlassStyle = .clear
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
    /// Subtle by default — a near-invisible hairline (Bringr-93j.116) so a resting wheel
    /// reads as one continuous glass slab while still hinting at slice boundaries; the
    /// user raises it for more visible slice structure.
    static let defaultRestingRimOpacity = 0.06
    /// Half a point by default — a thin hairline at rest (Bringr-93j.116); the user
    /// widens it for a more structured look at rest.
    static let defaultRestingRimWidth: CGFloat = 0.5
    /// Defaults preserve the original shipped emphasis values (Bringr-93j.117): hover
    /// is the strongest cue, pre-highlight sits between resting and hover.
    static let defaultHoverRimOpacity = 0.85
    static let defaultHoverRimWidth: CGFloat = 2
    static let defaultPrehighlightRimOpacity = 0.5
    static let defaultPrehighlightRimWidth: CGFloat = 1.5
    /// No tint by default (alpha 0) — the genuine Liquid Glass material shows untinted.
    static let defaultGlassTint = RadialColor(red: 1, green: 1, blue: 1, alpha: 0)
    /// White by default — matches the pre-Bringr-93j.117 hard-coded slice fill colour,
    /// so an existing user sees no change until they pick a different colour.
    static let defaultSliceFillColor = RadialColor(red: 1, green: 1, blue: 1, alpha: 1)
    /// `.ultraThin` by default — the lightest fallback blur, closest to the genuine
    /// Liquid Glass look on the `.off` path.
    static let defaultOffMaterialThickness: RadialMaterialThickness = .ultraThin

    static let `default` = RadialAppearance(
        outerRadius: defaultOuterRadius,
        fillOpacity: defaultFillOpacity,
        showsAppLabels: defaultShowsAppLabels,
        showsWindowLabels: defaultShowsWindowLabels,
        glassStyle: defaultGlassStyle,
        innerRadiusPadding: defaultInnerRadiusPadding,
        glassShadowOpacity: defaultGlassShadowOpacity,
        contentShadowOpacity: defaultContentShadowOpacity,
        skipSingleWindowLevel: defaultSkipSingleWindowLevel,
        restingRimOpacity: defaultRestingRimOpacity,
        restingRimWidth: defaultRestingRimWidth,
        hoverRimOpacity: defaultHoverRimOpacity,
        hoverRimWidth: defaultHoverRimWidth,
        prehighlightRimOpacity: defaultPrehighlightRimOpacity,
        prehighlightRimWidth: defaultPrehighlightRimWidth,
        glassTint: defaultGlassTint,
        sliceFillColor: defaultSliceFillColor,
        offMaterialThickness: defaultOffMaterialThickness
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
    /// Resting rim opacity spans invisible (`0`, no slice dividers — pure glass slab) to
    /// fully opaque (`1`, hard slice borders even at rest).
    static let restingRimOpacityRange: ClosedRange<Double> = 0...1
    /// Resting rim width spans 0 (invisible) to 3 points (chunky slice borders).
    static let restingRimWidthRange: ClosedRange<CGFloat> = 0...3
    /// Hover and pre-highlight rim widths share a wider range (0–5pt) so the cue can
    /// be made very loud at the top end (Bringr-93j.117).
    static let emphasisRimWidthRange: ClosedRange<CGFloat> = 0...5

    /// `UserDefaults` keys — the single source of truth shared by the Preferences
    /// `@AppStorage` bindings and `current(from:)` so the two cannot drift.
    static let radiusDefaultsKey = "appearance.outerRadius"
    static let opacityDefaultsKey = "appearance.fillOpacity"
    /// Pre-Bringr-93j.110 single labels toggle (`appearance.showsLabels`). Retained so
    /// `current(from:)` can migrate an existing user's choice into the two split keys
    /// below the first time the new code reads defaults: labels-on becomes app names + window
    /// titles on; labels-off becomes both off. A user who never set the old key gets the new
    /// defaults — window titles on for discoverability. Once either new key is set, the old
    /// key is no longer consulted for that field, so toggling one no longer flips the other.
    static let labelsDefaultsKey = "appearance.showsLabels"
    /// New apps-ring label key (Bringr-93j.110), independent of the windows sub-wheel.
    static let showsAppLabelsDefaultsKey = "appearance.showsAppLabels"
    /// New windows sub-wheel label key (Bringr-93j.110), independent of the apps ring.
    static let showsWindowLabelsDefaultsKey = "appearance.showsWindowLabels"
    /// Pre-picker on/off key. Retained so `current(from:)` can migrate an existing
    /// user's prior choice into the new three-way `glassStyleDefaultsKey`: `true` (the
    /// old default) becomes `.clear`, `false` becomes `.off`. Once the new key is set,
    /// the old key is no longer consulted, so the picker becomes the single source.
    static let glassDefaultsKey = "appearance.usesLiquidGlass"
    /// Three-way glass variant key (Bringr-93j.115). Stores the raw string of
    /// `RadialGlassStyle` so `@AppStorage` reads/writes it directly.
    static let glassStyleDefaultsKey = "appearance.glassStyle"
    static let innerPaddingDefaultsKey = "appearance.innerRadiusPadding"
    static let glassShadowDefaultsKey = "appearance.glassShadowOpacity"
    static let contentShadowDefaultsKey = "appearance.contentShadowOpacity"
    static let skipSingleWindowLevelDefaultsKey = "appearance.skipSingleWindowLevel"
    static let restingRimOpacityDefaultsKey = "appearance.restingRimOpacity"
    static let restingRimWidthDefaultsKey = "appearance.restingRimWidth"
    static let hoverRimOpacityDefaultsKey = "appearance.hoverRimOpacity"
    static let hoverRimWidthDefaultsKey = "appearance.hoverRimWidth"
    static let prehighlightRimOpacityDefaultsKey = "appearance.prehighlightRimOpacity"
    static let prehighlightRimWidthDefaultsKey = "appearance.prehighlightRimWidth"
    /// Stored as `#RRGGBBAA` so a single `@AppStorage(String)` binds the whole colour.
    static let glassTintDefaultsKey = "appearance.glassTint"
    static let sliceFillColorDefaultsKey = "appearance.sliceFillColor"
    /// Stores the raw value of `RadialMaterialThickness`.
    static let offMaterialThicknessDefaultsKey = "appearance.offMaterialThickness"

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
        // Bringr-93j.110: the new keys win when set, then the old unified key migrates the
        // user's prior choice into either field independently. The first new toggle in
        // Preferences writes a new key, after which the old key never overrides it again —
        // so the two settings become fully independent on first interaction. A fresh install
        // (neither key set) gets each field's default; window titles on by default makes the
        // feature discoverable without hunting through Preferences.
        appearance.showsAppLabels = readSplitLabel(
            from: defaults, newKey: showsAppLabelsDefaultsKey, default: defaultShowsAppLabels
        )
        appearance.showsWindowLabels = readSplitLabel(
            from: defaults, newKey: showsWindowLabelsDefaultsKey, default: defaultShowsWindowLabels
        )
        appearance.glassStyle = readGlassStyle(from: defaults)
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
        if defaults.object(forKey: restingRimOpacityDefaultsKey) != nil {
            appearance.restingRimOpacity = clamped(
                defaults.double(forKey: restingRimOpacityDefaultsKey), into: restingRimOpacityRange
            )
        }
        if defaults.object(forKey: restingRimWidthDefaultsKey) != nil {
            appearance.restingRimWidth = clamped(
                CGFloat(defaults.double(forKey: restingRimWidthDefaultsKey)), into: restingRimWidthRange
            )
        }
        if defaults.object(forKey: hoverRimOpacityDefaultsKey) != nil {
            appearance.hoverRimOpacity = clamped(
                defaults.double(forKey: hoverRimOpacityDefaultsKey), into: shadowOpacityRange
            )
        }
        if defaults.object(forKey: hoverRimWidthDefaultsKey) != nil {
            appearance.hoverRimWidth = clamped(
                CGFloat(defaults.double(forKey: hoverRimWidthDefaultsKey)), into: emphasisRimWidthRange
            )
        }
        if defaults.object(forKey: prehighlightRimOpacityDefaultsKey) != nil {
            appearance.prehighlightRimOpacity = clamped(
                defaults.double(forKey: prehighlightRimOpacityDefaultsKey), into: shadowOpacityRange
            )
        }
        if defaults.object(forKey: prehighlightRimWidthDefaultsKey) != nil {
            appearance.prehighlightRimWidth = clamped(
                CGFloat(defaults.double(forKey: prehighlightRimWidthDefaultsKey)), into: emphasisRimWidthRange
            )
        }
        if let hex = defaults.string(forKey: glassTintDefaultsKey), let color = RadialColor(hex: hex) {
            appearance.glassTint = color
        }
        if let hex = defaults.string(forKey: sliceFillColorDefaultsKey), let color = RadialColor(hex: hex) {
            appearance.sliceFillColor = color
        }
        if let raw = defaults.string(forKey: offMaterialThicknessDefaultsKey),
           let thickness = RadialMaterialThickness(rawValue: raw) {
            appearance.offMaterialThickness = thickness
        }
        return appearance
    }

    /// Generic clamp helper — extracted so the new rim sliders don't each grow their own
    /// near-identical `clampedFoo`; the older clamps below predate this and still call
    /// directly into `min`/`max` for clarity.
    private static func clamped<T: Comparable>(_ value: T, into range: ClosedRange<T>) -> T {
        min(max(value, range.lowerBound), range.upperBound)
    }

    /// Resolve the glass variant (Bringr-93j.115): the new `glassStyleDefaultsKey` wins
    /// when set; otherwise migrate from the pre-picker `glassDefaultsKey` so an upgrade
    /// preserves the user's prior choice (`true` → `.clear`, `false` → `.off`); otherwise
    /// fall back to the shipped default.
    private static func readGlassStyle(from defaults: UserDefaults) -> RadialGlassStyle {
        if let raw = defaults.string(forKey: glassStyleDefaultsKey),
           let style = RadialGlassStyle(rawValue: raw) {
            return style
        }
        if defaults.object(forKey: glassDefaultsKey) != nil {
            return defaults.bool(forKey: glassDefaultsKey) ? .clear : .off
        }
        return defaultGlassStyle
    }

    /// Resolve one half of the split labels setting (Bringr-93j.110): the new per-level key
    /// wins when set; otherwise migrate from the pre-split `labelsDefaultsKey` so an upgrade
    /// preserves the user's prior choice; otherwise fall back to the field's default.
    private static func readSplitLabel(
        from defaults: UserDefaults, newKey: String, default fallback: Bool
    ) -> Bool {
        if defaults.object(forKey: newKey) != nil {
            return defaults.bool(forKey: newKey)
        }
        if defaults.object(forKey: labelsDefaultsKey) != nil {
            return defaults.bool(forKey: labelsDefaultsKey)
        }
        return fallback
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

/// Pure-value RGBA colour (Bringr-93j.117), persisted by `RadialAppearance` as a hex
/// string so a single `@AppStorage` binds the whole picker. Keeps `RadialAppearance`
/// SwiftUI-free; the view layer (`RadialMenuView`, `AppearanceSettingsView`) converts
/// to/from `SwiftUI.Color` via the bridge defined alongside the views.
struct RadialColor: Equatable, Sendable {
    var red: Double
    var green: Double
    var blue: Double
    var alpha: Double

    /// `#RRGGBB` (alpha defaults to 1) or `#RRGGBBAA`. Anything else returns nil so a
    /// corrupt stored value falls back to the field default rather than rendering wrong.
    init?(hex: String) {
        var trimmed = hex
        if trimmed.hasPrefix("#") { trimmed.removeFirst() }
        guard trimmed.count == 6 || trimmed.count == 8 else { return nil }
        guard let value = UInt64(trimmed, radix: 16) else { return nil }
        let alphaHex: UInt64
        let rgb: UInt64
        if trimmed.count == 8 {
            rgb = value >> 8
            alphaHex = value & 0xFF
        } else {
            rgb = value
            alphaHex = 0xFF
        }
        self.red = Double((rgb >> 16) & 0xFF) / 255
        self.green = Double((rgb >> 8) & 0xFF) / 255
        self.blue = Double(rgb & 0xFF) / 255
        self.alpha = Double(alphaHex) / 255
    }

    init(red: Double, green: Double, blue: Double, alpha: Double) {
        self.red = red
        self.green = green
        self.blue = blue
        self.alpha = alpha
    }

    /// `#RRGGBBAA` lowercase, so equal colours always serialise to the same string.
    var hex: String {
        let channels = [red, green, blue, alpha].map { component -> Int in
            let clamped = min(max(component, 0), 1)
            return Int((clamped * 255).rounded())
        }
        return String(format: "#%02x%02x%02x%02x", channels[0], channels[1], channels[2], channels[3])
    }
}

/// Five-step blur picker for the `.off` fallback (Bringr-93j.117). Raw strings match the
/// SwiftUI `Material` names so a future migration to a `Material`-typed binding stays
/// readable. Unused while the Liquid Glass variant is `.clear` or `.regular`.
enum RadialMaterialThickness: String, CaseIterable, Equatable, Sendable {
    case ultraThin
    case thin
    case regular
    case thick
    case ultraThick
}

/// The three Liquid Glass options the Appearance picker exposes (Bringr-93j.115).
/// Persisted as a raw string so `@AppStorage` binds directly. `.clear` is the most
/// see-through variant and the new default; `.regular` is Apple's heavier frosted
/// variant; `.off` skips Liquid Glass entirely and renders the pre-macOS-26 frosted
/// `.ultraThinMaterial` fallback — also the only path on macOS < 26.
enum RadialGlassStyle: String, CaseIterable, Equatable, Sendable {
    case clear
    case regular
    case off
}
