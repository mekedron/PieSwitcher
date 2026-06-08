import CoreGraphics
import XCTest
@testable import PieSwitcher

/// Covers the appearance model (US-014): the persisted-defaults round-trip read
/// fresh at summon (AC2), clamping of stray values, the ring geometry it derives,
/// the fill-opacity emphasis ladder, and — the load-bearing AC3 property — that
/// hit-testing still round-trips at every size the UI can persist. Pure values and
/// an ephemeral defaults suite, never the live system or `.standard`.
final class RadialAppearanceTests: XCTestCase {
    private let accuracy: CGFloat = 0.0001
    private let opacityAccuracy = 0.0001

    // MARK: - Defaults & persistence round-trip (AC2)

    func testCurrentReturnsDefaultWhenNothingPersisted() {
        XCTAssertEqual(RadialAppearance.current(from: makeDefaults()), .default)
    }

    func testCurrentReadsPersistedValues() {
        let defaults = makeDefaults()
        defaults.set(200.0, forKey: RadialAppearance.radiusDefaultsKey)
        defaults.set(0.4, forKey: RadialAppearance.opacityDefaultsKey)
        defaults.set(true, forKey: RadialAppearance.showsAppLabelsDefaultsKey)
        defaults.set(false, forKey: RadialAppearance.showsWindowLabelsDefaultsKey)
        defaults.set(RadialGlassStyle.off.rawValue, forKey: RadialAppearance.glassStyleDefaultsKey)
        defaults.set(40.0, forKey: RadialAppearance.innerPaddingDefaultsKey)

        let appearance = RadialAppearance.current(from: defaults)
        XCTAssertEqual(appearance.outerRadius, 200, accuracy: accuracy)
        XCTAssertEqual(appearance.fillOpacity, 0.4, accuracy: opacityAccuracy)
        XCTAssertTrue(appearance.showsAppLabels)
        XCTAssertFalse(appearance.showsWindowLabels)
        XCTAssertEqual(appearance.glassStyle, .off)
        XCTAssertEqual(appearance.innerRadiusPadding, 40, accuracy: accuracy)
    }

    func testGlassStyleDefaultsClearAndRoundTrips() {
        // Bringr-93j.115: ships as clear glass, the most see-through Liquid Glass variant.
        XCTAssertEqual(RadialAppearance.default.glassStyle, .clear)
        XCTAssertEqual(RadialAppearance.current(from: makeDefaults()).glassStyle, .clear)

        // Persists every option, so the picker sticks.
        let defaults = makeDefaults()
        for style in RadialGlassStyle.allCases {
            defaults.set(style.rawValue, forKey: RadialAppearance.glassStyleDefaultsKey)
            XCTAssertEqual(RadialAppearance.current(from: defaults).glassStyle, style)
        }
    }

    func testGlassStyleMigratesFromPreviousBoolKey() {
        // Pre-picker (Bringr-93j.65) the setting was a single on/off bool. An existing user
        // with the default-on bool should land on the new `.clear` default; one who turned
        // it off should land on `.off`, preserving their fallback preference.
        let onlyTrue = makeDefaults()
        onlyTrue.set(true, forKey: RadialAppearance.glassDefaultsKey)
        XCTAssertEqual(RadialAppearance.current(from: onlyTrue).glassStyle, .clear)

        let onlyFalse = makeDefaults()
        onlyFalse.set(false, forKey: RadialAppearance.glassDefaultsKey)
        XCTAssertEqual(RadialAppearance.current(from: onlyFalse).glassStyle, .off)

        // Once the picker is touched the new key wins; the old bool no longer overrides.
        let both = makeDefaults()
        both.set(true, forKey: RadialAppearance.glassDefaultsKey)
        both.set(RadialGlassStyle.regular.rawValue, forKey: RadialAppearance.glassStyleDefaultsKey)
        XCTAssertEqual(RadialAppearance.current(from: both).glassStyle, .regular)
    }

    func testSkipSingleWindowLevelDefaultsOnAndRoundTrips() {
        // Bringr-93j.93: ships on, so a single-window (or empty) app commits straight to its
        // window with no pointless second ring.
        XCTAssertTrue(RadialAppearance.default.skipSingleWindowLevel)
        XCTAssertTrue(RadialAppearance.current(from: makeDefaults()).skipSingleWindowLevel)

        // Persists both ways, so the toggle sticks.
        let defaults = makeDefaults()
        defaults.set(false, forKey: RadialAppearance.skipSingleWindowLevelDefaultsKey)
        XCTAssertFalse(RadialAppearance.current(from: defaults).skipSingleWindowLevel)
        defaults.set(true, forKey: RadialAppearance.skipSingleWindowLevelDefaultsKey)
        XCTAssertTrue(RadialAppearance.current(from: defaults).skipSingleWindowLevel)
    }

    func testEachFieldFallsBackToItsDefaultIndependently() {
        // Only the apps-ring label was explicitly toggled; every other field falls back to
        // its own default (Bringr-93j.110: window labels stay on by default for discoverability).
        let defaults = makeDefaults()
        defaults.set(false, forKey: RadialAppearance.showsAppLabelsDefaultsKey)

        let appearance = RadialAppearance.current(from: defaults)
        XCTAssertEqual(appearance.outerRadius, RadialAppearance.defaultOuterRadius, accuracy: accuracy)
        XCTAssertEqual(appearance.fillOpacity, RadialAppearance.defaultFillOpacity, accuracy: opacityAccuracy)
        XCTAssertFalse(appearance.showsAppLabels)
        XCTAssertTrue(appearance.showsWindowLabels)
        XCTAssertEqual(appearance.glassStyle, RadialAppearance.defaultGlassStyle)
        XCTAssertEqual(
            appearance.innerRadiusPadding, RadialAppearance.defaultInnerRadiusPadding, accuracy: accuracy
        )
        XCTAssertEqual(
            appearance.glassShadowOpacity, RadialAppearance.defaultGlassShadowOpacity, accuracy: opacityAccuracy
        )
        XCTAssertEqual(
            appearance.contentShadowOpacity, RadialAppearance.defaultContentShadowOpacity, accuracy: opacityAccuracy
        )
    }

    // MARK: - Shadow opacities (Bringr-93j.66)

    func testRestingRimRoundTripsAndClamps() {
        // Round-trip both fields together so a user's custom hairline sticks.
        let defaults = makeDefaults()
        defaults.set(0.32, forKey: RadialAppearance.restingRimOpacityDefaultsKey)
        defaults.set(1.5, forKey: RadialAppearance.restingRimWidthDefaultsKey)
        let appearance = RadialAppearance.current(from: defaults)
        XCTAssertEqual(appearance.restingRimOpacity, 0.32, accuracy: opacityAccuracy)
        XCTAssertEqual(appearance.restingRimWidth, 1.5, accuracy: accuracy)

        // Stray out-of-range values clamp into the configured slider bounds.
        let stray = makeDefaults()
        stray.set(-1, forKey: RadialAppearance.restingRimOpacityDefaultsKey)
        stray.set(99, forKey: RadialAppearance.restingRimWidthDefaultsKey)
        let clamped = RadialAppearance.current(from: stray)
        XCTAssertEqual(clamped.restingRimOpacity, RadialAppearance.restingRimOpacityRange.lowerBound, accuracy: opacityAccuracy)
        XCTAssertEqual(clamped.restingRimWidth, RadialAppearance.restingRimWidthRange.upperBound, accuracy: accuracy)

        // Defaults applied when unset — subtle hairline so the wheel reads as glass.
        let empty = RadialAppearance.current(from: makeDefaults())
        XCTAssertEqual(empty.restingRimOpacity, RadialAppearance.defaultRestingRimOpacity, accuracy: opacityAccuracy)
        XCTAssertEqual(empty.restingRimWidth, RadialAppearance.defaultRestingRimWidth, accuracy: accuracy)
    }

    func testShadowOpacitiesRoundTrip() {
        let defaults = makeDefaults()
        defaults.set(0.7, forKey: RadialAppearance.glassShadowDefaultsKey)
        defaults.set(0.2, forKey: RadialAppearance.contentShadowDefaultsKey)

        let appearance = RadialAppearance.current(from: defaults)
        XCTAssertEqual(appearance.glassShadowOpacity, 0.7, accuracy: opacityAccuracy)
        XCTAssertEqual(appearance.contentShadowOpacity, 0.2, accuracy: opacityAccuracy)
    }

    func testShadowOpacitiesAreClampedIntoRange() {
        let low = RadialAppearance.shadowOpacityRange.lowerBound
        let high = RadialAppearance.shadowOpacityRange.upperBound
        XCTAssertEqual(readingGlassShadow(-1), low, accuracy: opacityAccuracy)
        XCTAssertEqual(readingGlassShadow(9), high, accuracy: opacityAccuracy)
        XCTAssertEqual(readingContentShadow(-1), low, accuracy: opacityAccuracy)
        XCTAssertEqual(readingContentShadow(9), high, accuracy: opacityAccuracy)
    }

    // MARK: - Clamping a stray value (AC3 — never a degenerate ring)

    func testRadiusIsClampedIntoRange() {
        XCTAssertEqual(readingRadius(10), RadialAppearance.radiusRange.lowerBound, accuracy: accuracy)
        XCTAssertEqual(readingRadius(99_999), RadialAppearance.radiusRange.upperBound, accuracy: accuracy)
    }

    func testOpacityIsClampedIntoRange() {
        XCTAssertEqual(readingOpacity(-1), RadialAppearance.opacityRange.lowerBound, accuracy: opacityAccuracy)
        XCTAssertEqual(readingOpacity(5), RadialAppearance.opacityRange.upperBound, accuracy: opacityAccuracy)
    }

    func testInnerPaddingIsClampedIntoRange() {
        XCTAssertEqual(readingInnerPadding(-50), RadialAppearance.innerPaddingRange.lowerBound, accuracy: accuracy)
        XCTAssertEqual(readingInnerPadding(99_999), RadialAppearance.innerPaddingRange.upperBound, accuracy: accuracy)
    }

    // MARK: - Derived geometry

    func testDefaultGeometryMatchesTheShippedRing() {
        XCTAssertEqual(RadialAppearance.default.geometry, RadialGeometry.default)
    }

    func testGeometryScalesProportionally() {
        let small = appearance(radius: 120).geometry
        let large = appearance(radius: 240).geometry
        // The dead zone stays a constant fraction of the outer radius at any size.
        XCTAssertEqual(
            small.innerRadius / small.outerRadius,
            large.innerRadius / large.outerRadius,
            accuracy: accuracy
        )
        // Always a real ring: a positive dead zone strictly inside the outer edge.
        for geometry in [small, large] {
            XCTAssertGreaterThan(geometry.innerRadius, 0)
            XCTAssertLessThan(geometry.innerRadius, geometry.outerRadius)
        }
    }

    // MARK: - Inner-radius padding pushes the ring out at constant thickness

    func testInnerPaddingShiftsBothEdgesOutwardKeepingThickness() {
        let base = appearance(radius: 160).geometry
        let pushed = appearance(radius: 160, padding: 40).geometry

        // Both edges move out by exactly the padding…
        XCTAssertEqual(pushed.innerRadius, base.innerRadius + 40, accuracy: accuracy)
        XCTAssertEqual(pushed.outerRadius, base.outerRadius + 40, accuracy: accuracy)
        // …so the ring keeps its thickness (concentric levels stay touching).
        XCTAssertEqual(
            pushed.outerRadius - pushed.innerRadius,
            base.outerRadius - base.innerRadius,
            accuracy: accuracy
        )
    }

    func testInnerPaddingWidensTheSliceOuterArc() {
        // Outer arc length = outerRadius × sliceSpan; sliceSpan depends only on the
        // item count, so a larger outer radius is what makes a slice easier to hit.
        let layout = RadialLayout(itemCount: 6)
        let base = appearance(radius: 160).geometry
        let pushed = appearance(radius: 160, padding: 60).geometry
        XCTAssertGreaterThan(
            pushed.outerRadius * layout.sliceSpan,
            base.outerRadius * layout.sliceSpan
        )
    }

    func testZeroPaddingLeavesGeometryUntouched() {
        XCTAssertEqual(appearance(radius: 160, padding: 0).geometry, appearance(radius: 160).geometry)
        XCTAssertEqual(RadialAppearance.default.geometry, RadialGeometry.default)
    }

    func testHitTestRoundTripsWithPaddingApplied() {
        let geometry = appearance(radius: 160, padding: 80).geometry
        let layout = RadialLayout(itemCount: 6, geometry: geometry)
        for index in 0..<6 {
            XCTAssertEqual(layout.hitTest(layout.sliceCenterOffset(at: index)), index)
        }
        // The (now larger) dead zone still maps to nothing; just outside the ring too.
        XCTAssertNil(layout.hitTest(.zero))
        XCTAssertNil(layout.hitTest(CGPoint(x: 0, y: -(geometry.innerRadius - 1))))
        XCTAssertNil(layout.hitTest(CGPoint(x: 0, y: -(geometry.outerRadius + 1))))
    }

    // MARK: - Fill-opacity emphasis ladder

    func testFillOpacityOrdersRestingBelowPrehighlightBelowHover() {
        let look = appearance(radius: 160, opacity: 0.2)
        let resting = look.fillOpacity(hovered: false, prehighlighted: false)
        let pre = look.fillOpacity(hovered: false, prehighlighted: true)
        let hover = look.fillOpacity(hovered: true, prehighlighted: false)
        XCTAssertEqual(resting, 0.2, accuracy: opacityAccuracy)
        XCTAssertLessThan(resting, pre)
        XCTAssertLessThan(pre, hover)
    }

    func testFillOpacityNeverExceedsOne() {
        let look = appearance(radius: 160, opacity: 0.95)
        XCTAssertLessThanOrEqual(look.fillOpacity(hovered: true, prehighlighted: false), 1)
        XCTAssertLessThanOrEqual(look.fillOpacity(hovered: false, prehighlighted: true), 1)
    }

    // MARK: - AC3: any persistable size keeps hit-testing intact

    func testHitTestRoundTripsAtEverySize() {
        let radii: [CGFloat] = [
            RadialAppearance.radiusRange.lowerBound, 160, 210, RadialAppearance.radiusRange.upperBound
        ]
        for radius in radii {
            let geometry = appearance(radius: radius).geometry
            let layout = RadialLayout(itemCount: 6, geometry: geometry)
            for index in 0..<6 {
                XCTAssertEqual(
                    layout.hitTest(layout.sliceCenterOffset(at: index)), index,
                    "slice \(index) failed to round-trip at radius \(radius)"
                )
            }
            // The dead zone and outside still map to nothing at this size.
            XCTAssertNil(layout.hitTest(.zero))
            XCTAssertNil(layout.hitTest(CGPoint(x: 0, y: -(geometry.outerRadius + 1))))
        }
    }

    // MARK: - Helpers

    private func appearance(radius: CGFloat, opacity: Double = 0.2, padding: CGFloat = 0) -> RadialAppearance {
        RadialAppearance(
            outerRadius: radius, fillOpacity: opacity,
            showsAppLabels: true, showsWindowLabels: true, innerRadiusPadding: padding
        )
    }

    private func readingRadius(_ value: Double) -> CGFloat {
        let defaults = makeDefaults()
        defaults.set(value, forKey: RadialAppearance.radiusDefaultsKey)
        return RadialAppearance.current(from: defaults).outerRadius
    }

    private func readingInnerPadding(_ value: Double) -> CGFloat {
        let defaults = makeDefaults()
        defaults.set(value, forKey: RadialAppearance.innerPaddingDefaultsKey)
        return RadialAppearance.current(from: defaults).innerRadiusPadding
    }

    private func readingOpacity(_ value: Double) -> Double {
        let defaults = makeDefaults()
        defaults.set(value, forKey: RadialAppearance.opacityDefaultsKey)
        return RadialAppearance.current(from: defaults).fillOpacity
    }

    private func readingGlassShadow(_ value: Double) -> Double {
        let defaults = makeDefaults()
        defaults.set(value, forKey: RadialAppearance.glassShadowDefaultsKey)
        return RadialAppearance.current(from: defaults).glassShadowOpacity
    }

    private func readingContentShadow(_ value: Double) -> Double {
        let defaults = makeDefaults()
        defaults.set(value, forKey: RadialAppearance.contentShadowDefaultsKey)
        return RadialAppearance.current(from: defaults).contentShadowOpacity
    }

    /// An isolated `UserDefaults` suite so persistence tests never touch the real
    /// domain; torn down by suite name to stay Sendable-clean.
    private func makeDefaults() -> UserDefaults {
        let suite = "RadialAppearanceTests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else {
            fatalError("could not create a test UserDefaults suite")
        }
        addTeardownBlock { UserDefaults.standard.removePersistentDomain(forName: suite) }
        return defaults
    }
}
