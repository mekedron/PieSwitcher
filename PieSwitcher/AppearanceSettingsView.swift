import SwiftUI

/// The "Appearance" Preferences pane (US-014): the wheel's size, distance from the
/// summon point, slice fill opacity, glass and content shadows (Bringr-93j.66), label
/// visibility (Bringr-93j.110 splits this into app names on the ring and real window
/// titles on the sub-wheel), the Liquid Glass toggle (Bringr-93j.65), and the
/// skip-single-window shortcut. Bringr-93j.106 reorganised this into a
/// `PreferencesPane`-backed `Form` with three sections so the controls align in a
/// clean two-column layout (label on the right, slider/toggle on the left), matching
/// Logic Pro's Preferences screens. Every key is read fresh by
/// `RadialAppearance.current` at each summon, so a change applies on the next open
/// without a relaunch.
struct AppearanceSettings: View {
    @AppStorage(RadialAppearance.radiusDefaultsKey)
    private var outerRadius = Double(RadialAppearance.defaultOuterRadius)
    @AppStorage(RadialAppearance.opacityDefaultsKey)
    private var fillOpacity = RadialAppearance.defaultFillOpacity
    @AppStorage(RadialAppearance.showsAppLabelsDefaultsKey)
    private var showsAppLabels = RadialAppearance.defaultShowsAppLabels
    @AppStorage(RadialAppearance.showsWindowLabelsDefaultsKey)
    private var showsWindowLabels = RadialAppearance.defaultShowsWindowLabels
    @AppStorage(RadialAppearance.glassDefaultsKey)
    private var usesLiquidGlass = RadialAppearance.defaultUsesLiquidGlass
    @AppStorage(RadialAppearance.innerPaddingDefaultsKey)
    private var innerRadiusPadding = Double(RadialAppearance.defaultInnerRadiusPadding)
    @AppStorage(RadialAppearance.glassShadowDefaultsKey)
    private var glassShadowOpacity = RadialAppearance.defaultGlassShadowOpacity
    @AppStorage(RadialAppearance.contentShadowDefaultsKey)
    private var contentShadowOpacity = RadialAppearance.defaultContentShadowOpacity
    @AppStorage(RadialAppearance.skipSingleWindowLevelDefaultsKey)
    private var skipSingleWindowLevel = RadialAppearance.defaultSkipSingleWindowLevel

    var body: some View {
        PreferencesPane {
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

            Section {
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
            } header: {
                Text("Style")
            } footer: {
                Text("Slice fill is the colour layered on each wedge. Glass shadow falls "
                     + "behind the wheel itself; text & icon shadow sits behind the slice "
                     + "labels for legibility on busy backgrounds.")
            }

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

            Section {
                Toggle("Liquid Glass effect", isOn: $usesLiquidGlass)
                Toggle("Skip the windows ring for single-window apps", isOn: $skipSingleWindowLevel)
            } header: {
                Text("Display")
            } footer: {
                Text("Liquid Glass renders the wheel with the macOS 26 translucent material; "
                     + "turn it off for a plain frosted look. Skip the windows ring jumps "
                     + "straight to a single-window app's window instead of opening a second "
                     + "ring. Changes apply the next time you summon the wheel.")
            }
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
}
