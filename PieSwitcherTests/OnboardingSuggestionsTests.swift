import XCTest
@testable import PieSwitcher

/// Covers the suggestion-chip flow on the onboarding screen 1 (Bringr-93j.112):
/// the chips persist into the same `KeyboardShortcutStore` the Preferences
/// picker uses (single source of truth), and the `matches` predicate that
/// highlights the active suggestion lines up with the user's current slot.
final class OnboardingSuggestionsTests: XCTestCase {

    func testRightOptionSuggestionWritesToSlot1() {
        let defaults = makeDefaults()
        guard let suggestion = suggestion(withID: "right-option") else {
            return XCTFail("missing 'right-option' suggestion fixture")
        }

        KeyboardShortcutStore.setSlot1(suggestion.shortcut, in: defaults)

        let slot1 = KeyboardShortcutStore.slot1(from: defaults)
        XCTAssertEqual(slot1?.modifiers, [SidedModifier(.option, .right)])
        XCTAssertNil(slot1?.keyCode)
        XCTAssertFalse(slot1?.sideAgnostic ?? true)
    }

    func testFnSuggestionWritesToSlot1() {
        let defaults = makeDefaults()
        guard let suggestion = suggestion(withID: "fn") else {
            return XCTFail("missing 'fn' suggestion fixture")
        }

        KeyboardShortcutStore.setSlot1(suggestion.shortcut, in: defaults)

        let slot1 = KeyboardShortcutStore.slot1(from: defaults)
        XCTAssertEqual(slot1?.modifiers, [SidedModifier(.function, .either)])
        XCTAssertNil(slot1?.keyCode)
    }

    func testMatchesActiveOnMatchingSlot() {
        guard let suggestion = suggestion(withID: "right-option") else {
            return XCTFail("missing 'right-option' suggestion fixture")
        }
        XCTAssertTrue(suggestion.matches(suggestion.shortcut))
    }

    func testMatchesInactiveOnDifferentSide() {
        guard let suggestion = suggestion(withID: "right-option") else {
            return XCTFail("missing 'right-option' suggestion fixture")
        }
        let leftOption = KeyboardShortcut(
            modifiers: [SidedModifier(.option, .left)],
            keyCode: nil,
            sideAgnostic: false
        )
        XCTAssertFalse(
            suggestion.matches(leftOption),
            "Right Option chip must not light up for a Left Option slot"
        )
    }

    func testMatchesInactiveOnNilSlot() {
        guard let suggestion = suggestion(withID: "right-option") else {
            return XCTFail("missing 'right-option' suggestion fixture")
        }
        XCTAssertFalse(suggestion.matches(nil))
    }

    func testMatchesInactiveWhenSlotCarriesNonModifierKey() {
        guard let suggestion = suggestion(withID: "right-option") else {
            return XCTFail("missing 'right-option' suggestion fixture")
        }
        let withKey = KeyboardShortcut(
            modifiers: [SidedModifier(.option, .right)],
            keyCode: 49,
            sideAgnostic: false
        )
        XCTAssertFalse(
            suggestion.matches(withKey),
            "a chip must not match a slot that has a non-modifier key bound"
        )
    }

    func testSuggestionsAreInPresentationOrder() {
        let ids = OnboardingShortcutSuggestion.all.map(\.id)
        XCTAssertEqual(ids, ["right-option", "fn", "right-command"])
    }

    // MARK: -

    private func suggestion(withID id: String) -> OnboardingShortcutSuggestion? {
        OnboardingShortcutSuggestion.all.first(where: { $0.id == id })
    }

    private func makeDefaults() -> UserDefaults {
        let suiteName = "OnboardingSuggestionsTests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            fatalError("could not create a test UserDefaults suite")
        }
        return defaults
    }
}
