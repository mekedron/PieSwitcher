import AppKit
import SwiftUI

/// The "Appearance" Preferences pane (US-014): the wheel's size, slice style, the Liquid
/// Glass variant + tint (Bringr-93j.117), label visibility, and the skip-single-window
/// shortcut. Bringr-93j.106 reorganised this into a `PreferencesPane`-backed `Form` so
/// the controls align in a clean two-column layout matching Logic Pro's Preferences
/// screens. Every key is read fresh by `RadialAppearance.current` at each summon, so a
/// change applies on the next open without a relaunch.
struct AppearanceSettings: View {
    @AppStorage(RadialAppearance.radiusDefaultsKey)
    private var outerRadius = Double(RadialAppearance.defaultOuterRadius)
    @AppStorage(RadialAppearance.opacityDefaultsKey)
    private var fillOpacity = RadialAppearance.defaultFillOpacity
    @AppStorage(RadialAppearance.showsAppLabelsDefaultsKey)
    private var showsAppLabels = RadialAppearance.defaultShowsAppLabels
    @AppStorage(RadialAppearance.showsWindowLabelsDefaultsKey)
    private var showsWindowLabels = RadialAppearance.defaultShowsWindowLabels
    @AppStorage(RadialAppearance.glassStyleDefaultsKey)
    private var glassStyle = RadialAppearance.defaultGlassStyle
    @AppStorage(RadialAppearance.innerPaddingDefaultsKey)
    private var innerRadiusPadding = Double(RadialAppearance.defaultInnerRadiusPadding)
    @AppStorage(RadialAppearance.glassShadowDefaultsKey)
    private var glassShadowOpacity = RadialAppearance.defaultGlassShadowOpacity
    @AppStorage(RadialAppearance.contentShadowDefaultsKey)
    private var contentShadowOpacity = RadialAppearance.defaultContentShadowOpacity
    @AppStorage(RadialAppearance.skipSingleWindowLevelDefaultsKey)
    private var skipSingleWindowLevel = RadialAppearance.defaultSkipSingleWindowLevel
    @AppStorage(RadialAppearance.restingRimOpacityDefaultsKey)
    private var restingRimOpacity = RadialAppearance.defaultRestingRimOpacity
    @AppStorage(RadialAppearance.restingRimWidthDefaultsKey)
    private var restingRimWidth = Double(RadialAppearance.defaultRestingRimWidth)
    @AppStorage(RadialAppearance.hoverRimOpacityDefaultsKey)
    private var hoverRimOpacity = RadialAppearance.defaultHoverRimOpacity
    @AppStorage(RadialAppearance.hoverRimWidthDefaultsKey)
    private var hoverRimWidth = Double(RadialAppearance.defaultHoverRimWidth)
    @AppStorage(RadialAppearance.prehighlightRimOpacityDefaultsKey)
    private var prehighlightRimOpacity = RadialAppearance.defaultPrehighlightRimOpacity
    @AppStorage(RadialAppearance.prehighlightRimWidthDefaultsKey)
    private var prehighlightRimWidth = Double(RadialAppearance.defaultPrehighlightRimWidth)
    @AppStorage(RadialAppearance.glassTintDefaultsKey)
    private var glassTintHex = RadialAppearance.defaultGlassTint.hex
    @AppStorage(RadialAppearance.sliceFillColorDefaultsKey)
    private var sliceFillColorHex = RadialAppearance.defaultSliceFillColor.hex
    @AppStorage(RadialAppearance.offMaterialThicknessDefaultsKey)
    private var offMaterialThickness = RadialAppearance.defaultOffMaterialThickness

    var body: some View {
        PreferencesPane {
            sizeSection
            styleSection
            liquidGlassSection
            labelsSection
            displaySection
        }
    }

    private var sizeSection: some View {
        Section("Size") {
            PreferencesSliderRow(
                title: "Wheel size",
                value: $outerRadius,
                range: doubleRange(RadialAppearance.radiusRange),
                unit: "pt"
            )
            PreferencesSliderRow(
                title: "Distance from center",
                value: $innerRadiusPadding,
                range: doubleRange(RadialAppearance.innerPaddingRange),
                unit: "pt"
            )
        }
    }

    private var styleSection: some View {
        Section {
            ColorPicker(
                "Slice fill color",
                selection: colorBinding($sliceFillColorHex, fallback: RadialAppearance.defaultSliceFillColor),
                supportsOpacity: false
            )
            PreferencesSliderRow(
                title: "Slice fill opacity",
                value: percentBinding($fillOpacity),
                range: percentRange(RadialAppearance.opacityRange),
                unit: "%"
            )
            PreferencesSliderRow(
                title: "Glass shadow",
                value: percentBinding($glassShadowOpacity),
                range: percentRange(RadialAppearance.shadowOpacityRange),
                unit: "%"
            )
            PreferencesSliderRow(
                title: "Text & icon shadow",
                value: percentBinding($contentShadowOpacity),
                range: percentRange(RadialAppearance.shadowOpacityRange),
                unit: "%"
            )
            PreferencesSliderRow(
                title: "Slice border opacity (rest)",
                value: percentBinding($restingRimOpacity),
                range: percentRange(RadialAppearance.restingRimOpacityRange),
                unit: "%"
            )
            PreferencesSliderRow(
                title: "Slice border width (rest)",
                value: $restingRimWidth,
                range: doubleRange(RadialAppearance.restingRimWidthRange),
                unit: "pt"
            )
            PreferencesSliderRow(
                title: "Slice border opacity (pre-highlight)",
                value: percentBinding($prehighlightRimOpacity),
                range: percentRange(RadialAppearance.shadowOpacityRange),
                unit: "%"
            )
            PreferencesSliderRow(
                title: "Slice border width (pre-highlight)",
                value: $prehighlightRimWidth,
                range: doubleRange(RadialAppearance.emphasisRimWidthRange),
                unit: "pt"
            )
            PreferencesSliderRow(
                title: "Slice border opacity (hover)",
                value: percentBinding($hoverRimOpacity),
                range: percentRange(RadialAppearance.shadowOpacityRange),
                unit: "%"
            )
            PreferencesSliderRow(
                title: "Slice border width (hover)",
                value: $hoverRimWidth,
                range: doubleRange(RadialAppearance.emphasisRimWidthRange),
                unit: "pt"
            )
        } header: {
            Text("Style")
        } footer: {
            Text("Slice fill is the colour layered on each wedge — slice fill opacity controls "
                 + "how much shows at rest, and hover/pre-highlight automatically step it up. "
                 + "Glass shadow falls behind the wheel itself; text & icon shadow sits behind "
                 + "the slice labels for legibility on busy backgrounds. Slice borders are the "
                 + "outlines drawn around each wedge — rest is the resting hairline (drop to 0% "
                 + "for a pure glass slab), pre-highlight is the medium cue on the slice about "
                 + "to be hovered, and hover is the bright cue on the currently-hovered slice.")
        }
    }

    private var liquidGlassSection: some View {
        Section {
            Picker("Liquid Glass", selection: $glassStyle) {
                Text("Clear").tag(RadialGlassStyle.clear)
                Text("Regular").tag(RadialGlassStyle.regular)
                Text("Off").tag(RadialGlassStyle.off)
            }
            .pickerStyle(.segmented)

            ColorPicker(
                "Glass tint",
                selection: colorBinding($glassTintHex, fallback: RadialAppearance.defaultGlassTint),
                supportsOpacity: true
            )
            .disabled(glassStyle == .off)

            Picker("Off-mode material", selection: $offMaterialThickness) {
                Text("Ultra thin").tag(RadialMaterialThickness.ultraThin)
                Text("Thin").tag(RadialMaterialThickness.thin)
                Text("Regular").tag(RadialMaterialThickness.regular)
                Text("Thick").tag(RadialMaterialThickness.thick)
                Text("Ultra thick").tag(RadialMaterialThickness.ultraThick)
            }
            .disabled(glassStyle != .off)
        } header: {
            Text("Liquid Glass")
        } footer: {
            Text("Clear is the most see-through variant; Regular is Apple's heavier frosted "
                 + "variant; Off uses a plain frosted material (also forced on macOS before 26). "
                 + "Glass tint adds a coloured wash to the genuine Liquid Glass — set opacity to "
                 + "0% to skip the tint entirely; disabled in Off mode. Off-mode material is the "
                 + "blur strength used when Liquid Glass is Off — from ultra-thin (lightest) to "
                 + "ultra-thick (heaviest); disabled in Clear/Regular.")
        }
    }

    private var labelsSection: some View {
        Section {
            Toggle("Show application names", isOn: $showsAppLabels)
            Toggle("Show window titles", isOn: $showsWindowLabels)
        } header: {
            Text("Labels")
        } footer: {
            Text("Application names label each slice on the apps ring. Window titles "
                 + "label each slice on the windows sub-wheel with the same title "
                 + "macOS shows in Mission Control or the Window menu (e.g., the "
                 + "document name or browser tab); a window with no title falls back "
                 + "to a numbered label so the slice is never blank.")
        }
    }

    private var displaySection: some View {
        Section {
            Toggle("Skip the windows ring for single-window apps", isOn: $skipSingleWindowLevel)
        } header: {
            Text("Display")
        } footer: {
            Text("Skip the windows ring jumps straight to a single-window app's window "
                 + "instead of opening a second ring. Changes apply the next time you "
                 + "summon the wheel.")
        }
    }

    /// Bridges the model's `CGFloat` slider bounds to the `Double` the `@AppStorage`
    /// sliders use, so the model stays the single source of truth for the range.
    private func doubleRange(_ range: ClosedRange<CGFloat>) -> ClosedRange<Double> {
        Double(range.lowerBound)...Double(range.upperBound)
    }

    /// Two-way mapping between a stored 0–1 opacity and a 0–100 percentage shown in
    /// the slider/numeric field, so the row reads as "55%" without changing how the
    /// value is persisted.
    private func percentBinding(_ stored: Binding<Double>) -> Binding<Double> {
        Binding(
            get: { (stored.wrappedValue * 100).rounded() },
            set: { stored.wrappedValue = max(0, min(1, $0 / 100)) }
        )
    }

    private func percentRange(_ range: ClosedRange<Double>) -> ClosedRange<Double> {
        (range.lowerBound * 100)...(range.upperBound * 100)
    }

    /// Two-way mapping between a hex-encoded `RadialColor` in defaults and a SwiftUI
    /// `Color` (Bringr-93j.117). The fallback handles a corrupt or absent stored value
    /// so the picker always has a sensible starting colour; on write, an
    /// unrepresentable colour (vanishingly unlikely from `ColorPicker`) falls back to
    /// the default rather than persisting garbage.
    private func colorBinding(
        _ stored: Binding<String>, fallback: RadialColor
    ) -> Binding<Color> {
        Binding(
            get: { Color(RadialColor(hex: stored.wrappedValue) ?? fallback) },
            set: { newColor in
                stored.wrappedValue = (RadialColor(swiftUI: newColor) ?? fallback).hex
            }
        )
    }
}

/// Reverse bridge from SwiftUI `Color` to the pure-value `RadialColor` (Bringr-93j.117).
/// Lives here, next to the `ColorPicker` bindings, because the model layer has no
/// SwiftUI/AppKit dependency; only the Preferences UI needs to read a picker's value
/// back into hex storage.
extension RadialColor {
    init?(swiftUI color: Color) {
        guard let resolved = NSColor(color).usingColorSpace(.sRGB) else { return nil }
        self.init(
            red: Double(resolved.redComponent),
            green: Double(resolved.greenComponent),
            blue: Double(resolved.blueComponent),
            alpha: Double(resolved.alphaComponent)
        )
    }
}
