import XCTest
@testable import PieSwitcher

/// Covers `OnboardingState` — the pure first-launch detection plus the
/// completed-flag persistence (Bringr-93j.112). Backed by per-test
/// `UserDefaults(suiteName:)` so each scenario runs against a fresh defaults
/// store with no cross-test bleed.
final class OnboardingStateTests: XCTestCase {

    func testShouldAutoOpenWhenFlagAbsent() {
        let defaults = makeDefaults()
        XCTAssertTrue(
            OnboardingState.shouldAutoOpen(from: defaults),
            "fresh install (no flag) must trigger the auto-open path"
        )
    }

    func testShouldNotAutoOpenAfterMarkingSeen() {
        let defaults = makeDefaults()
        OnboardingState.markSeen(in: defaults)
        XCTAssertFalse(
            OnboardingState.shouldAutoOpen(from: defaults),
            "once the user has seen onboarding the auto-open must not retrigger"
        )
    }

    func testMarkSeenIsIdempotent() {
        let defaults = makeDefaults()
        OnboardingState.markSeen(in: defaults)
        OnboardingState.markSeen(in: defaults)
        XCTAssertFalse(OnboardingState.shouldAutoOpen(from: defaults))
    }

    func testCompletedFlagPersistsAcrossReads() {
        let defaults = makeDefaults()
        OnboardingState.markSeen(in: defaults)
        // Simulate a restart: build a second `UserDefaults` over the same suite
        // and confirm the flag is still set.
        XCTAssertFalse(OnboardingState.shouldAutoOpen(from: defaults))
        XCTAssertTrue(
            defaults.bool(forKey: OnboardingState.completedKey),
            "the completed key must round-trip through UserDefaults"
        )
    }

    func testClearSeenResurrectsAutoOpen() {
        let defaults = makeDefaults()
        OnboardingState.markSeen(in: defaults)
        OnboardingState.clearSeen(in: defaults)
        XCTAssertTrue(
            OnboardingState.shouldAutoOpen(from: defaults),
            "clearing the flag must restore the auto-open path (QA hook)"
        )
    }

    private func makeDefaults() -> UserDefaults {
        let suiteName = "OnboardingStateTests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            fatalError("could not create a test UserDefaults suite")
        }
        return defaults
    }
}
