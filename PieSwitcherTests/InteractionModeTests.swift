import XCTest
@testable import PieSwitcher

/// Exercises the interaction-mode state machine in isolation (AC5): every test
/// drives `InteractionStateMachine` with synthetic inputs and asserts the outcome,
/// plus the persistence helpers behind the per-source Preferences settings
/// (Bringr-93j.91 split the single shared mode into a Mouse mode and a Keyboard mode).
final class InteractionModeTests: XCTestCase {
    // MARK: - Opening

    func testTriggerPressedOpensWhenClosed() {
        var machine = InteractionStateMachine(mode: .holdToSelect)
        XCTAssertFalse(machine.isOpen)
        XCTAssertEqual(machine.handle(.triggerPressed), .open)
        XCTAssertTrue(machine.isOpen)
    }

    func testReTriggerWhileOpenDismisses() {
        var machine = InteractionStateMachine(mode: .clickToStay)
        XCTAssertEqual(machine.handle(.triggerPressed), .open)
        XCTAssertEqual(machine.handle(.triggerPressed), .cancel, "a second trigger toggles the wheel closed")
        XCTAssertFalse(machine.isOpen)
    }

    func testInputsWhileClosedDoNothing() {
        var machine = InteractionStateMachine(mode: .holdToSelect)
        XCTAssertEqual(machine.handle(.triggerReleased(over: .slice(0))), .none)
        XCTAssertEqual(machine.handle(.click(over: .slice(0))), .none)
        XCTAssertEqual(machine.handle(.escape), .none)
        XCTAssertFalse(machine.isOpen)
    }

    // MARK: - AC1: hold-to-select

    func testHoldToSelectReleaseOverSliceSelects() {
        var machine = InteractionStateMachine(mode: .holdToSelect)
        XCTAssertEqual(machine.handle(.triggerPressed), .open)
        XCTAssertEqual(machine.handle(.triggerReleased(over: .slice(3))), .select(3))
        XCTAssertFalse(machine.isOpen, "the wheel closes once a selection is committed")
    }

    func testHoldToSelectReleaseInDeadZoneCancels() {
        var machine = InteractionStateMachine(mode: .holdToSelect)
        _ = machine.handle(.triggerPressed)
        XCTAssertEqual(machine.handle(.triggerReleased(over: .none)), .cancel)
        XCTAssertFalse(machine.isOpen)
    }

    // MARK: - AC2: click-to-stay

    func testClickToStayIgnoresReleaseAndStaysOpen() {
        var machine = InteractionStateMachine(mode: .clickToStay)
        XCTAssertEqual(machine.handle(.triggerPressed), .open)
        XCTAssertEqual(machine.handle(.triggerReleased(over: .slice(0))), .none, "the menu remains open after release")
        XCTAssertTrue(machine.isOpen)
    }

    func testClickToStayClickSelects() {
        var machine = InteractionStateMachine(mode: .clickToStay)
        _ = machine.handle(.triggerPressed)
        _ = machine.handle(.triggerReleased(over: .none))
        XCTAssertEqual(machine.handle(.click(over: .slice(2))), .select(2))
        XCTAssertFalse(machine.isOpen)
    }

    func testClickToStayClickOffSliceCancels() {
        var machine = InteractionStateMachine(mode: .clickToStay)
        _ = machine.handle(.triggerPressed)
        XCTAssertEqual(machine.handle(.click(over: .none)), .cancel)
        XCTAssertFalse(machine.isOpen)
    }

    func testEscapeCancelsInBothModes() {
        for mode in InteractionMode.allCases {
            var machine = InteractionStateMachine(mode: mode)
            _ = machine.handle(.triggerPressed)
            XCTAssertEqual(machine.handle(.escape), .cancel, "\(mode) should cancel on Esc")
            XCTAssertFalse(machine.isOpen)
        }
    }

    // MARK: - US-015: trigger-loss force-cancels like Esc, in either mode

    func testTriggerLostCancelsInBothModesWhenOpen() {
        for mode in InteractionMode.allCases {
            var machine = InteractionStateMachine(mode: mode)
            _ = machine.handle(.triggerPressed)
            XCTAssertEqual(machine.handle(.triggerLost), .cancel, "\(mode) should cancel on trigger-loss")
            XCTAssertFalse(machine.isOpen)
        }
    }

    func testTriggerLostWhileClosedDoesNothing() {
        var machine = InteractionStateMachine(mode: .holdToSelect)
        XCTAssertEqual(machine.handle(.triggerLost), .none)
        XCTAssertFalse(machine.isOpen)
    }

    // MARK: - AC4: both modes share the select/cancel paths

    func testBothModesSelectTheSameSliceFromTheirCommitGesture() {
        var hold = InteractionStateMachine(mode: .holdToSelect)
        _ = hold.handle(.triggerPressed)
        XCTAssertEqual(hold.handle(.triggerReleased(over: .slice(4))), .select(4))

        var stay = InteractionStateMachine(mode: .clickToStay)
        _ = stay.handle(.triggerPressed)
        XCTAssertEqual(stay.handle(.click(over: .slice(4))), .select(4))
    }

    func testBothModesCancelFromTheirCommitGestureOffAnySlice() {
        var hold = InteractionStateMachine(mode: .holdToSelect)
        _ = hold.handle(.triggerPressed)
        XCTAssertEqual(hold.handle(.triggerReleased(over: .none)), .cancel)

        var stay = InteractionStateMachine(mode: .clickToStay)
        _ = stay.handle(.triggerPressed)
        XCTAssertEqual(stay.handle(.click(over: .none)), .cancel)
    }

    // MARK: - Clean recovery & re-summon with a new mode

    func testFreshSummonAfterSelect() {
        var machine = InteractionStateMachine(mode: .holdToSelect)
        _ = machine.handle(.triggerPressed)
        _ = machine.handle(.triggerReleased(over: .slice(0)))
        XCTAssertEqual(machine.handle(.triggerPressed), .open, "the machine reopens cleanly after a selection")
    }

    func testReopeningPicksUpANewMode() {
        var machine = InteractionStateMachine(mode: .holdToSelect)
        _ = machine.handle(.triggerPressed)
        _ = machine.handle(.triggerReleased(over: .none))
        XCTAssertFalse(machine.isOpen)
        // The controller sets the mode while closed; the next session honours it.
        machine.mode = .clickToStay
        _ = machine.handle(.triggerPressed)
        XCTAssertEqual(machine.handle(.triggerReleased(over: .slice(1))), .none, "click-to-stay ignores release")
        XCTAssertEqual(machine.handle(.click(over: .slice(1))), .select(1))
    }

    // MARK: - Bringr-93j.91: per-source persistence helpers

    func testDefaultsAreSplitPerSource() {
        XCTAssertEqual(InteractionMode.defaultForMouse, .holdToSelect)
        // Bringr-93j.93: the keyboard now also defaults to hold-to-select — same fluid flow
        // as the mouse (hold, glide, release) — backed by the hold delay so a quick modifier
        // tap (e.g. Fn to switch input language) doesn't summon.
        XCTAssertEqual(InteractionMode.defaultForKeyboard, .holdToSelect)
    }

    func testDefaultsKeysAreStableAndDistinct() {
        XCTAssertEqual(InteractionMode.mouseDefaultsKey, "interactionMode.mouse")
        XCTAssertEqual(InteractionMode.keyboardDefaultsKey, "interactionMode.keyboard")
        XCTAssertNotEqual(InteractionMode.mouseDefaultsKey, InteractionMode.keyboardDefaultsKey)
    }

    func testCurrentReadsPersistedMouseMode() {
        let defaults = makeDefaults()
        defaults.set(InteractionMode.clickToStay.rawValue, forKey: InteractionMode.mouseDefaultsKey)
        XCTAssertEqual(InteractionMode.current(for: .mouseChord, from: defaults), .clickToStay)
    }

    func testCurrentReadsPersistedKeyboardMode() {
        // Set the non-default value so the read isn't masked by the per-source default.
        let defaults = makeDefaults()
        defaults.set(InteractionMode.clickToStay.rawValue, forKey: InteractionMode.keyboardDefaultsKey)
        XCTAssertEqual(InteractionMode.current(for: .modifierHold, from: defaults), .clickToStay)
    }

    func testCurrentFallsBackToPerSourceDefaultsWhenUnset() {
        let defaults = makeDefaults()
        XCTAssertEqual(InteractionMode.current(for: .mouseChord, from: defaults), .defaultForMouse)
        XCTAssertEqual(InteractionMode.current(for: .modifierHold, from: defaults), .defaultForKeyboard)
    }

    func testCurrentFallsBackToPerSourceDefaultsWhenUnrecognized() {
        let defaults = makeDefaults()
        defaults.set("not-a-mode", forKey: InteractionMode.mouseDefaultsKey)
        defaults.set("also-not-a-mode", forKey: InteractionMode.keyboardDefaultsKey)
        XCTAssertEqual(InteractionMode.current(for: .mouseChord, from: defaults), .defaultForMouse)
        XCTAssertEqual(InteractionMode.current(for: .modifierHold, from: defaults), .defaultForKeyboard)
    }

    func testMouseAndKeyboardModesAreIndependent() {
        // Pick each side's non-default so a stray cross-binding can't slip past unnoticed.
        let defaults = makeDefaults()
        defaults.set(InteractionMode.clickToStay.rawValue, forKey: InteractionMode.mouseDefaultsKey)
        defaults.set(InteractionMode.clickToStay.rawValue, forKey: InteractionMode.keyboardDefaultsKey)
        XCTAssertEqual(InteractionMode.current(for: .mouseChord, from: defaults), .clickToStay)
        XCTAssertEqual(InteractionMode.current(for: .modifierHold, from: defaults), .clickToStay)

        // Flip just one side and the other holds.
        defaults.set(InteractionMode.holdToSelect.rawValue, forKey: InteractionMode.mouseDefaultsKey)
        XCTAssertEqual(InteractionMode.current(for: .mouseChord, from: defaults), .holdToSelect)
        XCTAssertEqual(InteractionMode.current(for: .modifierHold, from: defaults), .clickToStay,
                       "changing one source's mode must not flip the other")
    }

    func testDisplayNamesAreDistinctAndNonEmpty() {
        let mouseNames = InteractionMode.allCases.map(\.displayName)
        XCTAssertFalse(mouseNames.contains(where: \.isEmpty))
        XCTAssertEqual(Set(mouseNames).count, mouseNames.count)

        let keyboardNames = InteractionMode.allCases.map(\.keyboardDisplayName)
        XCTAssertFalse(keyboardNames.contains(where: \.isEmpty))
        XCTAssertEqual(Set(keyboardNames).count, keyboardNames.count)
    }

    func testKeyboardDisplayNameRenamesClickToStay() {
        XCTAssertEqual(InteractionMode.holdToSelect.keyboardDisplayName, "Hold to select",
                       "hold-to-select keeps its name on the keyboard")
        XCTAssertEqual(InteractionMode.clickToStay.keyboardDisplayName, "Press",
                       "click-to-stay reads as 'Press' on the keyboard — you don't 'click' a keyboard")
        XCTAssertNotEqual(InteractionMode.clickToStay.displayName,
                          InteractionMode.clickToStay.keyboardDisplayName,
                          "the rename must be keyboard-only — the mouse label still says 'Click to stay open'")
    }

    // MARK: - Bringr-93j.91: click-to-activate is always on

    func testClickInHoldModeSelectsTheSlice() {
        var machine = InteractionStateMachine(mode: .holdToSelect)
        _ = machine.handle(.triggerPressed)
        XCTAssertEqual(machine.handle(.click(over: .slice(2))), .select(2),
                       "click-to-activate is now always on: a click picks the slice even in hold mode")
        XCTAssertFalse(machine.isOpen)
    }

    func testClickInHoldModeOffSliceCancels() {
        var machine = InteractionStateMachine(mode: .holdToSelect)
        _ = machine.handle(.triggerPressed)
        XCTAssertEqual(machine.handle(.click(over: .none)), .cancel,
                       "a click off any slice cancels in hold mode too")
        XCTAssertFalse(machine.isOpen)
    }

    func testReleaseStillCommitsInHoldMode() {
        var machine = InteractionStateMachine(mode: .holdToSelect)
        _ = machine.handle(.triggerPressed)
        XCTAssertEqual(machine.handle(.triggerReleased(over: .slice(1))), .select(1),
                       "release-to-select still works alongside the always-on click-to-activate")
        XCTAssertFalse(machine.isOpen)
    }

    // MARK: - Helpers

    /// An isolated `UserDefaults` suite so persistence tests never touch the real domain.
    private func makeDefaults() -> UserDefaults {
        let suiteName = "InteractionModeTests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            fatalError("could not create a test UserDefaults suite")
        }
        return defaults
    }
}
