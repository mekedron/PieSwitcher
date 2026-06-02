import Carbon.HIToolbox
import CoreGraphics
import XCTest
@testable import PieSwitcher

/// Covers the Bringr-93j.111 two-slot keyboard-shortcut activation: the value types, the
/// pure matcher, capture state machine, migration planner, and persistence — all in
/// isolation from the live event tap.
final class KeyboardShortcutTypesTests: XCTestCase {

    // MARK: - SidedModifier

    func testFunctionAlwaysCollapsesToEitherSide() {
        let left = SidedModifier(.function, .left)
        let right = SidedModifier(.function, .right)
        XCTAssertEqual(left.side, .either, "Fn has no left/right hardware distinction")
        XCTAssertEqual(right.side, .either)
    }

    func testSidedModifierKeepsSideForSidedFamilies() {
        XCTAssertEqual(SidedModifier(.option, .left).side, .left)
        XCTAssertEqual(SidedModifier(.command, .right).side, .right)
        XCTAssertEqual(SidedModifier(.shift, .either).side, .either)
    }

    func testCapLabelDisambiguatesLeftAndRight() {
        XCTAssertEqual(SidedModifier(.option, .left).capLabel, "L⌥")
        XCTAssertEqual(SidedModifier(.option, .right).capLabel, "R⌥")
        XCTAssertEqual(SidedModifier(.option, .either).capLabel, "⌥")
        // Fn has no side, so no badge ever.
        XCTAssertEqual(SidedModifier(.function, .left).capLabel, "fn")
    }

    // MARK: - KeyboardShortcut display

    func testCapLabelsOrderingMatchesModifierConvention() {
        let combo = KeyboardShortcut(
            modifiers: [
                SidedModifier(.command, .right),
                SidedModifier(.option, .left),
                SidedModifier(.shift, .right)
            ],
            keyCode: kVK_ANSI_K
        )
        XCTAssertEqual(combo.capLabels, ["L⌥", "R⇧", "R⌘", "K"], "modifiers ordered Fn ⌃ ⌥ ⇧ ⌘, then key")
    }

    func testCapLabelsForBareModifierShortcut() {
        let bare = KeyboardShortcut(modifiers: [SidedModifier(.option, .right)])
        XCTAssertEqual(bare.capLabels, ["R⌥"])
    }

    func testEmptyShortcutHasNoLabels() {
        XCTAssertTrue(KeyboardShortcut(modifiers: []).capLabels.isEmpty)
    }

    // MARK: - Persistence

    func testShortcutRoundTripsThroughJSON() throws {
        let original = KeyboardShortcut(
            modifiers: [SidedModifier(.option, .right), SidedModifier(.shift, .left)],
            keyCode: kVK_Space,
            sideAgnostic: true
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(KeyboardShortcut.self, from: data)
        XCTAssertEqual(decoded, original)
    }

    func testSlotPersistencePreservesShortcutAndSideAgnosticFlag() {
        let defaults = makeDefaults()
        let shortcut = KeyboardShortcut(
            modifiers: [SidedModifier(.option, .right)],
            keyCode: kVK_Space,
            sideAgnostic: false
        )
        KeyboardShortcutStore.setSlot1(shortcut, in: defaults)
        XCTAssertEqual(KeyboardShortcutStore.slot1(from: defaults), shortcut)
        XCTAssertNil(KeyboardShortcutStore.slot2(from: defaults))
    }

    func testClearingASlotPersistsAsExplicitNotSet() {
        let defaults = makeDefaults()
        KeyboardShortcutStore.setSlot1(KeyboardShortcut(modifiers: [SidedModifier(.command, .left)]), in: defaults)
        KeyboardShortcutStore.setSlot1(nil, in: defaults)
        XCTAssertNil(KeyboardShortcutStore.slot1(from: defaults), "explicit clear should round-trip as nil")
    }

    func testArmedShortcutsSkipsEmptyAndUnsetSlots() {
        let defaults = makeDefaults()
        KeyboardShortcutStore.setSlot1(KeyboardShortcut(modifiers: [SidedModifier(.option, .right)]), in: defaults)
        XCTAssertEqual(KeyboardShortcutStore.armedShortcuts(from: defaults).count, 1)
        KeyboardShortcutStore.setSlot2(KeyboardShortcut(modifiers: [SidedModifier(.command, .left)]), in: defaults)
        XCTAssertEqual(KeyboardShortcutStore.armedShortcuts(from: defaults).count, 2)
        KeyboardShortcutStore.setSlot1(nil, in: defaults)
        XCTAssertEqual(KeyboardShortcutStore.armedShortcuts(from: defaults).count, 1, "unset slot drops out")
    }

    // MARK: - Fixtures

    private func makeDefaults() -> UserDefaults {
        let suiteName = "KeyboardShortcutTests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            fatalError("could not create a test UserDefaults suite")
        }
        return defaults
    }
}

// MARK: - Matcher tests

/// Covers `KeyboardShortcutMatcher`: side-specific, side-agnostic, combo, and exact-modifier
/// match rules — the runtime decision the live monitor depends on.
final class KeyboardShortcutMatcherTests: XCTestCase {

    func testRightOptionFiresOnlyOnRightOption() {
        let shortcut = KeyboardShortcut(modifiers: [SidedModifier(.option, .right)])
        XCTAssertTrue(matches(modifiers: [SidedModifier(.option, .right)], shortcut: shortcut))
        XCTAssertFalse(matches(modifiers: [SidedModifier(.option, .left)], shortcut: shortcut),
                       "Left Option must NOT match a Right-Option-only shortcut")
    }

    func testLeftCommandFiresOnlyOnLeftCommand() {
        let shortcut = KeyboardShortcut(modifiers: [SidedModifier(.command, .left)])
        XCTAssertTrue(matches(modifiers: [SidedModifier(.command, .left)], shortcut: shortcut))
        XCTAssertFalse(matches(modifiers: [SidedModifier(.command, .right)], shortcut: shortcut))
    }

    func testSideAgnosticMatchesEitherSide() {
        let shortcut = KeyboardShortcut(
            modifiers: [SidedModifier(.option, .either)],
            keyCode: nil,
            sideAgnostic: true
        )
        XCTAssertTrue(matches(modifiers: [SidedModifier(.option, .left)], shortcut: shortcut))
        XCTAssertTrue(matches(modifiers: [SidedModifier(.option, .right)], shortcut: shortcut))
        XCTAssertTrue(
            matches(modifiers: [SidedModifier(.option, .left), SidedModifier(.option, .right)], shortcut: shortcut),
            "holding both sides also matches a side-agnostic shortcut")
    }

    func testExtraModifierBreaksMatch() {
        let shortcut = KeyboardShortcut(modifiers: [SidedModifier(.option, .right)])
        XCTAssertFalse(
            matches(modifiers: [SidedModifier(.option, .right), SidedModifier(.shift, .left)], shortcut: shortcut),
            "holding Right Option + Left Shift is not just Right Option")
    }

    func testComboShortcutRequiresExactKey() {
        let shortcut = KeyboardShortcut(
            modifiers: [SidedModifier(.option, .right)],
            keyCode: kVK_Space
        )
        XCTAssertTrue(matches(
            modifiers: [SidedModifier(.option, .right)],
            keyCode: kVK_Space,
            shortcut: shortcut
        ))
        XCTAssertFalse(matches(modifiers: [SidedModifier(.option, .right)], shortcut: shortcut),
                       "Right Option alone does not match a Right Option + Space combo")
        XCTAssertFalse(matches(
            modifiers: [SidedModifier(.option, .right)],
            keyCode: kVK_Return,
            shortcut: shortcut
        ), "Right Option + Return is not Right Option + Space")
    }

    func testBareModifierShortcutDoesNotFireWithNonModifierKeyHeld() {
        let bare = KeyboardShortcut(modifiers: [SidedModifier(.option, .right)])
        XCTAssertFalse(matches(
            modifiers: [SidedModifier(.option, .right)],
            keyCode: kVK_Space,
            shortcut: bare
        ), "pressing a non-modifier key must end a bare-modifier shortcut")
    }

    func testFnShortcutMatchesFnAlone() {
        let shortcut = KeyboardShortcut(modifiers: [SidedModifier(.function, .either)])
        XCTAssertTrue(matches(modifiers: [SidedModifier(.function, .either)], shortcut: shortcut))
        XCTAssertFalse(matches(modifiers: [SidedModifier(.option, .right)], shortcut: shortcut))
    }

    func testEmptyShortcutNeverFires() {
        let empty = KeyboardShortcut(modifiers: [])
        XCTAssertFalse(matches(modifiers: [], shortcut: empty))
        XCTAssertFalse(matches(modifiers: [SidedModifier(.option, .right)], shortcut: empty))
    }

    // MARK: - Helpers

    private func matches(
        modifiers: Set<SidedModifier>,
        keyCode: Int? = nil,
        shortcut: KeyboardShortcut
    ) -> Bool {
        let held = HeldKeys(modifiers: modifiers, nonModifierKey: keyCode)
        return KeyboardShortcutMatcher.matches(held, shortcut: shortcut)
    }
}

// MARK: - Detector edge tests

/// Covers `KeyboardShortcutDetector`'s rising/falling edge transitions. Exercises the
/// "any armed shortcut matches → active" semantics so two shortcuts can stay armed
/// simultaneously without re-firing.
final class KeyboardShortcutDetectorTests: XCTestCase {

    func testHoldingShortcutPressesThenReleases() {
        let armed = [KeyboardShortcut(modifiers: [SidedModifier(.option, .right)])]
        var detector = KeyboardShortcutDetector()
        XCTAssertEqual(
            detector.handle(held: HeldKeys(modifiers: [SidedModifier(.option, .right)]), armed: armed),
            .press
        )
        XCTAssertEqual(
            detector.handle(held: HeldKeys(modifiers: [SidedModifier(.option, .right)]), armed: armed),
            .none, "still held → no re-press"
        )
        XCTAssertEqual(detector.handle(held: .empty, armed: armed), .release)
    }

    func testBothSlotsActiveSimultaneouslyAndIndependently() {
        // Two armed shortcuts: AC requires that either independently triggers the menu.
        let armed = [
            KeyboardShortcut(modifiers: [SidedModifier(.option, .right)]),
            KeyboardShortcut(modifiers: [SidedModifier(.command, .left)])
        ]
        var detector = KeyboardShortcutDetector()
        XCTAssertEqual(
            detector.handle(held: HeldKeys(modifiers: [SidedModifier(.command, .left)]), armed: armed),
            .press
        )
        XCTAssertEqual(detector.handle(held: .empty, armed: armed), .release)
        XCTAssertEqual(
            detector.handle(held: HeldKeys(modifiers: [SidedModifier(.option, .right)]), armed: armed),
            .press,
            "the other slot fires independently"
        )
    }

    func testSlidingBetweenTwoMatchingShortcutsDoesNotRepress() {
        // Holding Right Option (matches slot 1), then pressing Space (matches slot 2 = combo).
        let armed = [
            KeyboardShortcut(modifiers: [SidedModifier(.option, .right)]),
            KeyboardShortcut(modifiers: [SidedModifier(.option, .right)], keyCode: kVK_Space)
        ]
        var detector = KeyboardShortcutDetector()
        XCTAssertEqual(
            detector.handle(held: HeldKeys(modifiers: [SidedModifier(.option, .right)]), armed: armed),
            .press
        )
        XCTAssertEqual(
            detector.handle(
                held: HeldKeys(modifiers: [SidedModifier(.option, .right)], nonModifierKey: kVK_Space),
                armed: armed
            ),
            .none,
            "still matching, just a different armed shortcut — no second press"
        )
        XCTAssertEqual(detector.handle(held: .empty, armed: armed), .release)
    }

    func testNoArmedShortcutsNeverPresses() {
        var detector = KeyboardShortcutDetector()
        XCTAssertEqual(
            detector.handle(held: HeldKeys(modifiers: [SidedModifier(.option, .right)]), armed: []),
            .none
        )
    }

    func testResetClearsLatchedActivation() {
        let armed = [KeyboardShortcut(modifiers: [SidedModifier(.option, .right)])]
        var detector = KeyboardShortcutDetector()
        XCTAssertEqual(
            detector.handle(held: HeldKeys(modifiers: [SidedModifier(.option, .right)]), armed: armed),
            .press
        )
        detector.reset()
        XCTAssertEqual(
            detector.handle(held: HeldKeys(modifiers: [SidedModifier(.option, .right)]), armed: armed),
            .press, "after reset a still-held shortcut presses afresh"
        )
    }
}

// Parser tests live in `KeyboardShortcutParserTests.swift`.

// MARK: - Capture state machine

/// Covers `KeyboardShortcutCaptureMachine`: the picker's recording loop, including
/// listen-then-record, commit-on-release, Escape cancel, and the "no commit without a
/// real shortcut" guard.
final class KeyboardShortcutCaptureTests: XCTestCase {

    func testStartTransitionsToListening() {
        var machine = KeyboardShortcutCaptureMachine()
        machine.start()
        XCTAssertTrue(machine.isCapturing)
        XCTAssertNil(machine.snapshot)
    }

    func testFirstModifierStartsRecordingAndCapturesSnapshot() {
        var machine = KeyboardShortcutCaptureMachine()
        machine.start()
        let held = HeldKeys(modifiers: [SidedModifier(.option, .right)])
        machine.update(held: held)
        XCTAssertEqual(machine.snapshot, held)
    }

    func testReleaseCommitsLastSnapshot() {
        var machine = KeyboardShortcutCaptureMachine()
        machine.start()
        let held = HeldKeys(modifiers: [SidedModifier(.option, .right)])
        machine.update(held: held)
        machine.update(held: .empty)
        XCTAssertEqual(machine.take(), held, "all keys released → commit the last held state")
    }

    func testKeyComboCapturesNonModifier() {
        var machine = KeyboardShortcutCaptureMachine()
        machine.start()
        machine.update(held: HeldKeys(modifiers: [SidedModifier(.option, .right)]))
        let combo = HeldKeys(modifiers: [SidedModifier(.option, .right)], nonModifierKey: kVK_Space)
        machine.update(held: combo)
        // user releases everything
        machine.update(held: .empty)
        XCTAssertEqual(machine.take(), combo, "the snapshot at the moment of full release wins")
    }

    func testEscapeCancelsCapture() {
        var machine = KeyboardShortcutCaptureMachine()
        machine.start()
        machine.update(held: HeldKeys(modifiers: [SidedModifier(.option, .right)]))
        machine.handleEscape()
        XCTAssertNil(machine.take(), "cancel produces no commit")
    }

    func testNonModifierOnlyPressIsRejected() {
        var machine = KeyboardShortcutCaptureMachine()
        machine.start()
        // Press a letter without any modifier — picker should never commit a key-only shortcut.
        machine.update(held: HeldKeys(modifiers: [], nonModifierKey: kVK_ANSI_A))
        machine.update(held: .empty)
        XCTAssertNil(machine.take())
    }

    func testHeldToShortcutCollapsesDualSides() {
        let held = HeldKeys(
            modifiers: [SidedModifier(.shift, .left), SidedModifier(.shift, .right)],
            nonModifierKey: nil
        )
        let shortcut = KeyboardShortcutFromHeld.make(from: held)
        XCTAssertEqual(shortcut?.modifiers, [SidedModifier(.shift, .either)])
    }

    func testHeldToShortcutEmptyModifiersReturnsNil() {
        let held = HeldKeys(modifiers: [], nonModifierKey: kVK_ANSI_K)
        XCTAssertNil(KeyboardShortcutFromHeld.make(from: held))
    }
}

// Migration tests live in `KeyboardShortcutMigrationTests.swift` to keep this file
// under the SwiftLint file-length budget.
