import XCTest
@testable import Bringr

/// Exercises the interaction-mode state machine in isolation (AC5): every test
/// drives `InteractionStateMachine` with synthetic inputs and asserts the outcome,
/// plus the persistence helpers behind the Preferences setting (AC3).
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

    func testHoldToSelectIgnoresClicksAndStaysOpen() {
        var machine = InteractionStateMachine(mode: .holdToSelect)
        _ = machine.handle(.triggerPressed)
        XCTAssertEqual(machine.handle(.click(over: .slice(0))), .none, "hold mode commits on release, not on a click")
        XCTAssertTrue(machine.isOpen)
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

    // MARK: - AC3: mode persistence helpers

    func testDefaultModeIsHoldToSelect() {
        XCTAssertEqual(InteractionMode.default, .holdToSelect)
        XCTAssertEqual(InteractionStateMachine().mode, .holdToSelect)
    }

    func testDefaultsKeyIsStable() {
        XCTAssertEqual(InteractionMode.defaultsKey, "interactionMode")
    }

    func testCurrentReadsPersistedMode() {
        let defaults = makeDefaults()
        defaults.set(InteractionMode.clickToStay.rawValue, forKey: InteractionMode.defaultsKey)
        XCTAssertEqual(InteractionMode.current(from: defaults), .clickToStay)
    }

    func testCurrentFallsBackToDefaultWhenUnset() {
        XCTAssertEqual(InteractionMode.current(from: makeDefaults()), .default)
    }

    func testCurrentFallsBackToDefaultWhenUnrecognized() {
        let defaults = makeDefaults()
        defaults.set("not-a-mode", forKey: InteractionMode.defaultsKey)
        XCTAssertEqual(InteractionMode.current(from: defaults), .default)
    }

    func testDisplayNamesAreDistinctAndNonEmpty() {
        let names = InteractionMode.allCases.map(\.displayName)
        XCTAssertFalse(names.contains(where: \.isEmpty))
        XCTAssertEqual(Set(names).count, names.count)
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
