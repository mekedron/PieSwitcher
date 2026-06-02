import XCTest
@testable import PieSwitcher

/// Covers `MigrationPlanner` and `KeyboardShortcutStore.runMigrationIfNeeded` — the pure
/// decision that derives the new two-slot state from the pre-Bringr-93j.111
/// `activation.keyboard.modifiers` bitmask. Tested headless so the migration code can
/// be exercised without an Xcode session or a launched app.
final class KeyboardShortcutMigrationTests: XCTestCase {

    func testFreshInstallProducesRightOptionDefault() {
        let plan = MigrationPlanner.plan(reading: makeDefaults())
        XCTAssertEqual(plan.kind, .freshInstall)
        XCTAssertEqual(plan.slot1?.modifiers, [SidedModifier(.option, .right)])
        XCTAssertEqual(plan.slot1?.sideAgnostic, false)
        XCTAssertNil(plan.slot2)
        XCTAssertNil(plan.notice)
    }

    func testSingleLegacyModifierMigratesToSideAgnosticSlot1() {
        let defaults = makeDefaults()
        defaults.set(ModifierCombination.function.rawValue, forKey: ModifierActivation.keyboardDefaultsKey)
        let plan = MigrationPlanner.plan(reading: defaults)
        XCTAssertEqual(plan.kind, .migratedSingleModifier)
        XCTAssertEqual(plan.slot1?.modifiers, [SidedModifier(.function, .either)])
        XCTAssertEqual(plan.slot1?.sideAgnostic, true,
                       "migrated shortcuts must fire on either side to preserve old behaviour")
        XCTAssertNil(plan.slot2)
        XCTAssertNil(plan.notice, "single-modifier migration is silent — no notice needed")
    }

    func testMultipleLegacyModifiersSplitAcrossSlotsInDeterministicOrder() {
        let defaults = makeDefaults()
        let combo: ModifierCombination = [.command, .option, .shift]
        defaults.set(combo.rawValue, forKey: ModifierActivation.keyboardDefaultsKey)
        let plan = MigrationPlanner.plan(reading: defaults)
        XCTAssertEqual(plan.kind, .migratedMultipleModifiers)
        XCTAssertEqual(plan.slot1?.modifiers, [SidedModifier(.option, .either)])
        XCTAssertEqual(plan.slot2?.modifiers, [SidedModifier(.shift, .either)])
        XCTAssertEqual(plan.slot1?.sideAgnostic, true)
        XCTAssertEqual(plan.slot2?.sideAgnostic, true)
        XCTAssertNotNil(plan.notice, "dropping a modifier must surface a notice")
    }

    func testTwoLegacyModifiersFitWithoutNoticeBeyondDropped() {
        let defaults = makeDefaults()
        let combo: ModifierCombination = [.command, .option]
        defaults.set(combo.rawValue, forKey: ModifierActivation.keyboardDefaultsKey)
        let plan = MigrationPlanner.plan(reading: defaults)
        XCTAssertEqual(plan.kind, .migratedMultipleModifiers)
        XCTAssertEqual(plan.slot1?.modifiers, [SidedModifier(.option, .either)])
        XCTAssertEqual(plan.slot2?.modifiers, [SidedModifier(.command, .either)])
    }

    func testExplicitlyClearedLegacyMigratesToBothDisabled() {
        let defaults = makeDefaults()
        defaults.set(0, forKey: ModifierActivation.keyboardDefaultsKey)
        let plan = MigrationPlanner.plan(reading: defaults)
        XCTAssertEqual(plan.kind, .migratedDisabled)
        XCTAssertNil(plan.slot1, "an explicitly disabled legacy key stays disabled")
        XCTAssertNil(plan.slot2)
    }

    func testRunMigrationIfNeededIsIdempotent() {
        let defaults = makeDefaults()
        XCTAssertEqual(KeyboardShortcutStore.runMigrationIfNeeded(in: defaults), .freshInstall)
        XCTAssertEqual(KeyboardShortcutStore.runMigrationIfNeeded(in: defaults), .alreadyDone,
                       "a second run must be a no-op")
    }

    func testRunMigrationWritesSlotsAndNotice() {
        let defaults = makeDefaults()
        let combo: ModifierCombination = [.option, .command, .shift, .control]
        defaults.set(combo.rawValue, forKey: ModifierActivation.keyboardDefaultsKey)
        XCTAssertEqual(
            KeyboardShortcutStore.runMigrationIfNeeded(in: defaults),
            .migratedMultipleModifiers
        )
        XCTAssertNotNil(KeyboardShortcutStore.slot1(from: defaults))
        XCTAssertNotNil(KeyboardShortcutStore.slot2(from: defaults))
        XCTAssertNotNil(KeyboardShortcutStore.consumeMigrationNotice(in: defaults))
        // Once consumed, the notice is gone.
        XCTAssertNil(KeyboardShortcutStore.consumeMigrationNotice(in: defaults))
    }

    private func makeDefaults() -> UserDefaults {
        let suiteName = "KeyboardShortcutMigrationTests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            fatalError("could not create a test UserDefaults suite")
        }
        return defaults
    }
}
