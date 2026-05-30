import XCTest
@testable import PieSwitcher

/// Covers the trackpad-haptic-on-hover feature (Bringr-93j.44): the persisted setting, the
/// pure "should this move tap?" rule, and the `HapticController` policy that ties them to a
/// recording performer. The live haptic engine and IOKit mouse scan are build-and-run shells.
final class TrackpadHapticsTests: XCTestCase {

    // MARK: - Persisted setting

    func testDefaultsKeysAreStable() {
        XCTAssertEqual(TrackpadHaptics.enabledKey, "trackpad.haptics.enabled")
        XCTAssertEqual(TrackpadHaptics.intensityKey, "trackpad.haptics.intensity")
    }

    func testEnabledDefaultsToOn() {
        // Bringr-93j.93: the tactile tap is on out of the box so the trackpad-driven summon
        // reads as a slice-to-slice cursor click; the user opts out for a silent ring.
        XCTAssertTrue(TrackpadHaptics.enabledDefault)
        XCTAssertTrue(TrackpadHaptics.isEnabled(from: makeDefaults()))
    }

    func testIsEnabledReadsTheStoredValue() {
        for value in [true, false] {
            let defaults = makeDefaults()
            defaults.set(value, forKey: TrackpadHaptics.enabledKey)
            XCTAssertEqual(TrackpadHaptics.isEnabled(from: defaults), value)
        }
    }

    func testIntensityDefaultsToStrongWhenUnsetOrUnrecognized() {
        // Bringr-93j.93: the firmest tick reads most clearly above background trackpad noise.
        XCTAssertEqual(HapticIntensity.default, .strong)
        XCTAssertEqual(TrackpadHaptics.intensity(from: makeDefaults()), .strong)

        let defaults = makeDefaults()
        defaults.set("bogus", forKey: TrackpadHaptics.intensityKey)
        XCTAssertEqual(TrackpadHaptics.intensity(from: defaults), .strong)
    }

    func testIntensityReadsTheStoredValue() {
        for value in HapticIntensity.allCases {
            let defaults = makeDefaults()
            defaults.set(value.rawValue, forKey: TrackpadHaptics.intensityKey)
            XCTAssertEqual(TrackpadHaptics.intensity(from: defaults), value)
        }
    }

    // MARK: - Hover transition rule (pure)

    func testTapsOnlyWhenAdvancingToADifferentSlice() {
        let first = HoverRegion.slice(level: 0, index: 0)
        let second = HoverRegion.slice(level: 0, index: 1)
        let window = HoverRegion.slice(level: 1, index: 0)

        // A new slice (including landing from the dead zone, or crossing rings) taps.
        XCTAssertTrue(HoverHapticTrigger.shouldTap(from: first, to: second))
        XCTAssertTrue(HoverHapticTrigger.shouldTap(from: .none, to: first))
        XCTAssertTrue(HoverHapticTrigger.shouldTap(from: first, to: window))

        // The same slice (jitter / a sub-wheel retry) and leaving to the dead zone do not.
        XCTAssertFalse(HoverHapticTrigger.shouldTap(from: first, to: first))
        XCTAssertFalse(HoverHapticTrigger.shouldTap(from: first, to: .none))
        XCTAssertFalse(HoverHapticTrigger.shouldTap(from: .none, to: .none))
    }

    // MARK: - HapticController policy

    @MainActor
    func testActiveControllerTapsWithResolvedIntensityOnNewSlice() {
        let performer = RecordingPerformer()
        let controller = HapticController(
            enabledProvider: { true }, intensityProvider: { .strong },
            externalMouseProvider: { false }, performer: performer
        )
        controller.resolveForSummon()

        controller.hoverChanged(from: .none, to: .slice(level: 0, index: 0))
        controller.hoverChanged(from: .slice(level: 0, index: 0), to: .slice(level: 0, index: 1))

        XCTAssertEqual(performer.taps, [.strong, .strong])
    }

    @MainActor
    func testNoTapWhenHoverStaysOnTheSameSlice() {
        let performer = RecordingPerformer()
        let controller = HapticController(
            enabledProvider: { true }, intensityProvider: { .medium },
            externalMouseProvider: { false }, performer: performer
        )
        controller.resolveForSummon()

        controller.hoverChanged(from: .slice(level: 0, index: 0), to: .slice(level: 0, index: 0))

        XCTAssertTrue(performer.taps.isEmpty)
    }

    @MainActor
    func testDisabledControllerNeverTaps() {
        let performer = RecordingPerformer()
        let controller = HapticController(
            enabledProvider: { false }, intensityProvider: { .medium },
            externalMouseProvider: { false }, performer: performer
        )
        controller.resolveForSummon()

        controller.hoverChanged(from: .none, to: .slice(level: 0, index: 0))

        XCTAssertTrue(performer.taps.isEmpty)
    }

    @MainActor
    func testExternalMouseSuppressesHaptics() {
        let performer = RecordingPerformer()
        let controller = HapticController(
            enabledProvider: { true }, intensityProvider: { .medium },
            externalMouseProvider: { true }, performer: performer
        )
        controller.resolveForSummon()

        controller.hoverChanged(from: .none, to: .slice(level: 0, index: 0))

        XCTAssertTrue(performer.taps.isEmpty, "a connected mouse must suppress the trackpad tap")
    }

    @MainActor
    func testResolveForSummonRereadsTheSettingEachSummon() {
        let performer = RecordingPerformer()
        var enabled = true
        let controller = HapticController(
            enabledProvider: { enabled }, intensityProvider: { .medium },
            externalMouseProvider: { false }, performer: performer
        )

        controller.resolveForSummon()
        controller.hoverChanged(from: .none, to: .slice(level: 0, index: 0))
        XCTAssertEqual(performer.taps.count, 1)

        // Turning the setting off applies on the next summon, not retroactively.
        enabled = false
        controller.resolveForSummon()
        controller.hoverChanged(from: .none, to: .slice(level: 0, index: 1))
        XCTAssertEqual(performer.taps.count, 1, "disabling between summons stops further taps")
    }

    // MARK: - Fixtures

    /// An isolated `UserDefaults` suite so persistence tests never touch the real domain.
    private func makeDefaults() -> UserDefaults {
        let suiteName = "TrackpadHapticsTests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            fatalError("could not create a test UserDefaults suite")
        }
        return defaults
    }
}

/// Records the intensities it was asked to play, so the controller's hover→tap policy is
/// asserted without a real haptic engine.
private final class RecordingPerformer: HapticPerforming {
    private(set) var taps: [HapticIntensity] = []
    func perform(_ intensity: HapticIntensity) { taps.append(intensity) }
}
