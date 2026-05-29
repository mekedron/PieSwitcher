import SwiftUI

/// The "Appearance" Preferences group (US-014): the wheel's size, how far it sits from
/// the summon point, the slice fill opacity, label visibility, and the Liquid Glass
/// toggle (Bringr-93j.65). Its own file (and own `@AppStorage` for the keys) so the
/// `PreferencesView` body stays within its length budget, mirroring `SortingSettings`.
/// The same keys are read fresh by `RadialAppearance.current` at each summon, so a change
/// here applies on the next open without a relaunch (AC2).
struct AppearanceSettings: View {
    @AppStorage(RadialAppearance.radiusDefaultsKey)
    private var outerRadius = Double(RadialAppearance.defaultOuterRadius)
    @AppStorage(RadialAppearance.opacityDefaultsKey)
    private var fillOpacity = RadialAppearance.defaultFillOpacity
    @AppStorage(RadialAppearance.labelsDefaultsKey)
    private var showsLabels = RadialAppearance.defaultShowsLabels
    @AppStorage(RadialAppearance.glassDefaultsKey)
    private var usesLiquidGlass = RadialAppearance.defaultUsesLiquidGlass
    @AppStorage(RadialAppearance.innerPaddingDefaultsKey)
    private var innerRadiusPadding = Double(RadialAppearance.defaultInnerRadiusPadding)

    var body: some View {
        let minRadius = Double(RadialAppearance.radiusRange.lowerBound)
        let maxRadius = Double(RadialAppearance.radiusRange.upperBound)
        let minPadding = Double(RadialAppearance.innerPaddingRange.lowerBound)
        let maxPadding = Double(RadialAppearance.innerPaddingRange.upperBound)
        let opacityRange = RadialAppearance.opacityRange

        return VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Size")
                Slider(value: $outerRadius, in: minRadius...maxRadius)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text("Distance from center")
                Slider(value: $innerRadiusPadding, in: minPadding...maxPadding)
                Text("Pushes the whole wheel out from where it opens. Larger slices are easier to aim at.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text("Slice fill opacity")
                Slider(value: $fillOpacity, in: opacityRange)
            }

            Toggle("Show labels", isOn: $showsLabels)

            VStack(alignment: .leading, spacing: 2) {
                Toggle("Liquid Glass effect", isOn: $usesLiquidGlass)
                Text("Render the wheel with the translucent Liquid Glass material (macOS 26 "
                     + "and later). Turn it off for a plain frosted look.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Text("Changes apply the next time you summon the wheel.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
