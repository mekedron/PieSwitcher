import Carbon.HIToolbox
import XCTest
@testable import PieSwitcher

/// Covers the pure cores behind the position shortcuts (Bringr-dk3): position → ring index,
/// persistence and ordering, and the per-binding rising-edge detector the live tap drives.
final class PositionShortcutResolverTests: XCTestCase {

    func testFirstPositionMapsToFirstIndex() {
        XCTAssertEqual(PositionShortcutResolver.index(forPosition: 1, count: 5), 0)
    }

    func testLastPositionMapsToLastIndex() {
        XCTAssertEqual(PositionShortcutResolver.index(forPosition: 5, count: 5), 4)
    }

    func testPositionPastTheRingIsNil() {
        XCTAssertNil(PositionShortcutResolver.index(forPosition: 6, count: 5))
    }

    func testEmptyRingHasNoPositions() {
        XCTAssertNil(PositionShortcutResolver.index(forPosition: 1, count: 0))
    }

    func testZeroAndNegativePositionsAreRejected() {
        XCTAssertNil(PositionShortcutResolver.index(forPosition: 0, count: 5))
        XCTAssertNil(PositionShortcutResolver.index(forPosition: -1, count: 5))
    }
}

// MARK: - Storage

final class PositionShortcutStoreTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUp() {
        super.setUp()
        suiteName = "PositionShortcutStoreTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        super.tearDown()
    }

    private func combo(_ keyCode: Int) -> KeyboardShortcut {
        KeyboardShortcut(modifiers: [SidedModifier(.control, .right)], keyCode: keyCode)
    }

    func testBothListsStartEmpty() {
        XCTAssertTrue(PositionShortcutStore.bindings(.apps, from: defaults).isEmpty)
        XCTAssertTrue(PositionShortcutStore.bindings(.windows, from: defaults).isEmpty)
        XCTAssertTrue(PositionShortcutStore.armed(from: defaults).isEmpty)
    }

    func testBindingsRoundTrip() {
        let binding = PositionShortcutBinding(position: 3, shortcut: combo(kVK_ANSI_3))
        PositionShortcutStore.setBindings([binding], for: .apps, in: defaults)
        XCTAssertEqual(PositionShortcutStore.bindings(.apps, from: defaults), [binding])
    }

    func testListsAreIndependent() {
        PositionShortcutStore.setBindings(
            [PositionShortcutBinding(position: 1, shortcut: combo(kVK_ANSI_1))],
            for: .apps, in: defaults
        )
        XCTAssertTrue(PositionShortcutStore.bindings(.windows, from: defaults).isEmpty)
    }

    func testBindingsAreReadBackAscendingByPosition() {
        PositionShortcutStore.setBindings(
            [
                PositionShortcutBinding(position: 4, shortcut: combo(kVK_ANSI_4)),
                PositionShortcutBinding(position: 1, shortcut: combo(kVK_ANSI_1))
            ],
            for: .apps, in: defaults
        )
        XCTAssertEqual(PositionShortcutStore.bindings(.apps, from: defaults).map(\.position), [1, 4])
    }

    func testSeveralShortcutsMayShareOnePosition() {
        let first = PositionShortcutBinding(position: 1, shortcut: combo(kVK_ANSI_1))
        let second = PositionShortcutBinding(position: 1, shortcut: combo(kVK_F1))
        PositionShortcutStore.setBindings([first, second], for: .apps, in: defaults)
        let armed = PositionShortcutStore.armed(from: defaults)
        XCTAssertEqual(armed.count, 2)
        XCTAssertEqual(armed.map(\.position), [1, 1])
        // Ties keep their stored order, so the rows don't swap under the user between reads.
        XCTAssertEqual(armed.map(\.id), [first.id, second.id])
    }

    func testRowsWithoutAShortcutAreNotArmed() {
        PositionShortcutStore.setBindings(
            [PositionShortcutBinding(position: 1, shortcut: nil)], for: .apps, in: defaults
        )
        XCTAssertEqual(PositionShortcutStore.bindings(.apps, from: defaults).count, 1)
        XCTAssertTrue(PositionShortcutStore.armed(from: defaults).isEmpty)
    }

    func testModifierOnlyShortcutIsClearedOnRead() {
        // A bare modifier bound before the key requirement existed must stop firing, but the
        // row stays so the user can see what needs re-recording.
        let bare = PositionShortcutBinding(
            position: 1,
            shortcut: KeyboardShortcut(modifiers: [SidedModifier(.option, .left)], keyCode: nil)
        )
        PositionShortcutStore.setBindings([bare], for: .apps, in: defaults)
        let read = PositionShortcutStore.bindings(.apps, from: defaults)
        XCTAssertEqual(read.count, 1)
        XCTAssertNil(read.first?.shortcut)
        XCTAssertTrue(PositionShortcutStore.armed(from: defaults).isEmpty)
    }

    func testComboShortcutSurvivesRead() {
        let combo = PositionShortcutBinding(position: 1, shortcut: self.combo(kVK_ANSI_1))
        PositionShortcutStore.setBindings([combo], for: .apps, in: defaults)
        XCTAssertEqual(PositionShortcutStore.bindings(.apps, from: defaults).first?.shortcut,
                       combo.shortcut)
    }

    func testOutOfRangePositionsAreDroppedOnRead() {
        PositionShortcutStore.setBindings(
            [
                PositionShortcutBinding(position: 0, shortcut: combo(kVK_ANSI_1)),
                PositionShortcutBinding(
                    position: PositionShortcutStore.maxPosition + 1, shortcut: combo(kVK_ANSI_2)
                ),
                PositionShortcutBinding(position: 2, shortcut: combo(kVK_ANSI_3))
            ],
            for: .apps, in: defaults
        )
        XCTAssertEqual(PositionShortcutStore.bindings(.apps, from: defaults).map(\.position), [2])
    }

    func testArmedPutsAppsBeforeWindows() {
        PositionShortcutStore.setBindings(
            [PositionShortcutBinding(position: 9, shortcut: combo(kVK_ANSI_9))], for: .apps, in: defaults
        )
        PositionShortcutStore.setBindings(
            [PositionShortcutBinding(position: 1, shortcut: combo(kVK_ANSI_1))], for: .windows, in: defaults
        )
        XCTAssertEqual(PositionShortcutStore.armed(from: defaults).map(\.list), [.apps, .windows])
    }
}

// MARK: - Detector

final class PositionShortcutDetectorTests: XCTestCase {
    private let rightControl = SidedModifier(.control, .right)

    private func armed(
        _ list: PositionShortcutList, _ position: Int, keyCode: Int?
    ) -> ArmedPositionShortcut {
        ArmedPositionShortcut(
            id: UUID(), list: list, position: position,
            shortcut: KeyboardShortcut(modifiers: [rightControl], keyCode: keyCode)
        )
    }

    private func held(_ keyCode: Int?) -> HeldKeys {
        HeldKeys(modifiers: [rightControl], nonModifierKey: keyCode)
    }

    func testFiresOnTheRisingEdge() {
        var detector = PositionShortcutDetector()
        let one = armed(.apps, 1, keyCode: kVK_ANSI_1)
        XCTAssertEqual(detector.handle(held: held(kVK_ANSI_1), armed: [one])?.position, 1)
    }

    func testDoesNotRefireWhileStillHeld() {
        var detector = PositionShortcutDetector()
        let one = armed(.apps, 1, keyCode: kVK_ANSI_1)
        _ = detector.handle(held: held(kVK_ANSI_1), armed: [one])
        XCTAssertNil(detector.handle(held: held(kVK_ANSI_1), armed: [one]))
    }

    func testFiresAgainAfterRelease() {
        var detector = PositionShortcutDetector()
        let one = armed(.apps, 1, keyCode: kVK_ANSI_1)
        _ = detector.handle(held: held(kVK_ANSI_1), armed: [one])
        _ = detector.handle(held: held(nil), armed: [one])
        XCTAssertEqual(detector.handle(held: held(kVK_ANSI_1), armed: [one])?.position, 1)
    }

    func testSlidingBetweenTwoBindingsFiresEach() {
        var detector = PositionShortcutDetector()
        let one = armed(.apps, 1, keyCode: kVK_ANSI_1)
        let two = armed(.apps, 2, keyCode: kVK_ANSI_2)
        XCTAssertEqual(detector.handle(held: held(kVK_ANSI_1), armed: [one, two])?.position, 1)
        XCTAssertEqual(detector.handle(held: held(kVK_ANSI_2), armed: [one, two])?.position, 2)
    }

    func testOnlyOneBindingFiresWhenTwoShareAShortcut() {
        var detector = PositionShortcutDetector()
        let first = armed(.apps, 1, keyCode: kVK_ANSI_1)
        let second = armed(.windows, 1, keyCode: kVK_ANSI_1)
        let fired = detector.handle(held: held(kVK_ANSI_1), armed: [first, second])
        XCTAssertEqual(fired?.id, first.id)
        XCTAssertEqual(detector.activeIDs, [first.id, second.id])
    }

    func testEmptyArmedListNeverFires() {
        var detector = PositionShortcutDetector()
        XCTAssertNil(detector.handle(held: held(kVK_ANSI_1), armed: []))
    }

    func testSideSpecificShortcutIgnoresTheOtherSide() {
        var detector = PositionShortcutDetector()
        let one = armed(.apps, 1, keyCode: kVK_ANSI_1)
        let leftHeld = HeldKeys(
            modifiers: [SidedModifier(.control, .left)], nonModifierKey: kVK_ANSI_1
        )
        XCTAssertNil(detector.handle(held: leftHeld, armed: [one]))
    }

    func testBareModifierBindingFiresWithNoKey() {
        var detector = PositionShortcutDetector()
        let bare = armed(.apps, 1, keyCode: nil)
        XCTAssertEqual(detector.handle(held: held(nil), armed: [bare])?.position, 1)
    }

    func testResetClearsLatchedMatches() {
        var detector = PositionShortcutDetector()
        let one = armed(.apps, 1, keyCode: kVK_ANSI_1)
        _ = detector.handle(held: held(kVK_ANSI_1), armed: [one])
        detector.reset()
        XCTAssertTrue(detector.activeIDs.isEmpty)
        XCTAssertEqual(detector.handle(held: held(kVK_ANSI_1), armed: [one])?.position, 1)
    }
}

// MARK: - Monitor state machine

/// Covers the swallow/latch interplay across a real press–release sequence, which the pure
/// detector tests above can't see: the monitor swallows a fired combo's keyUp, and the
/// detector must still observe that release or its latch survives and the NEXT press of the
/// same combo reads as still held — unfired, and leaked through to the app underneath.
@MainActor
final class PositionShortcutMonitorTests: XCTestCase {
    private let leftOption = SidedModifier(.option, .left)

    private func makeMonitor(fireCount: @escaping () -> Void) -> PositionShortcutMonitor {
        let binding = ArmedPositionShortcut(
            id: UUID(), list: .windows, position: 1,
            shortcut: KeyboardShortcut(modifiers: [leftOption], keyCode: kVK_ANSI_Z)
        )
        return PositionShortcutMonitor(
            onFire: { _, _ in fireCount() },
            armedProvider: { [binding] },
            isSuppressed: { false }
        )
    }

    /// Press ⌥Z twice in a row: both presses must fire and be swallowed. This is the
    /// regression test for the every-second-press leak.
    func testEachRepeatedPressFiresAndIsSwallowed() {
        var fires = 0
        let monitor = makeMonitor { fires += 1 }

        XCTAssertTrue(monitor.step(type: .flagsChanged, keyCode: kVK_Option, modifiers: [leftOption]))

        XCTAssertFalse(monitor.step(type: .keyDown, keyCode: kVK_ANSI_Z, modifiers: [leftOption]),
                       "first press: fires and is swallowed")
        XCTAssertEqual(fires, 1)
        XCTAssertFalse(monitor.step(type: .keyUp, keyCode: kVK_ANSI_Z, modifiers: [leftOption]),
                       "the fired combo's release is swallowed too")

        XCTAssertFalse(monitor.step(type: .keyDown, keyCode: kVK_ANSI_Z, modifiers: [leftOption]),
                       "second press: must fire and be swallowed again, not leak to the app")
        XCTAssertEqual(fires, 2)
        XCTAssertFalse(monitor.step(type: .keyUp, keyCode: kVK_ANSI_Z, modifiers: [leftOption]))
    }

    func testAutoRepeatsOfAFiredComboAreSwallowedWithoutRefiring() {
        var fires = 0
        let monitor = makeMonitor { fires += 1 }

        _ = monitor.step(type: .flagsChanged, keyCode: kVK_Option, modifiers: [leftOption])
        XCTAssertFalse(monitor.step(type: .keyDown, keyCode: kVK_ANSI_Z, modifiers: [leftOption]))
        XCTAssertFalse(monitor.step(type: .keyDown, keyCode: kVK_ANSI_Z, modifiers: [leftOption]),
                       "a held combo's auto-repeat stays swallowed")
        XCTAssertEqual(fires, 1, "auto-repeat must not re-fire the binding")
    }

    func testUnmatchedKeysPassThroughUntouched() {
        var fires = 0
        let monitor = makeMonitor { fires += 1 }

        _ = monitor.step(type: .flagsChanged, keyCode: kVK_Option, modifiers: [leftOption])
        XCTAssertTrue(monitor.step(type: .keyDown, keyCode: kVK_ANSI_X, modifiers: [leftOption]),
                      "a key no binding claims reaches the app underneath")
        XCTAssertTrue(monitor.step(type: .keyUp, keyCode: kVK_ANSI_X, modifiers: [leftOption]))
        XCTAssertEqual(fires, 0)
    }
}

// MARK: - Key-required capture fields

/// Covers the capture rule position shortcuts add (Bringr-dk3): a field that will swallow
/// its key refuses a modifiers-only shortcut, while the activation slots — built on bare
/// modifiers — are unaffected.
final class KeyboardShortcutKeyRequirementTests: XCTestCase {

    // MARK: - Release order

    /// The natural way to let go of ⌥1 is to lift the digit first. That release is itself a
    /// held state with no key in it, so a "latest held state wins" rule recorded a bare ⌥.
    func testReleasingTheKeyBeforeTheModifierKeepsTheCombo() {
        var machine = KeyboardShortcutCaptureMachine()
        machine.start()
        let option = SidedModifier(.option, .left)
        let combo = HeldKeys(modifiers: [option], nonModifierKey: kVK_ANSI_1)
        machine.update(held: HeldKeys(modifiers: [option]))
        machine.update(held: combo)
        machine.update(held: HeldKeys(modifiers: [option]))  // digit up, Option still down
        machine.update(held: .empty)                          // Option up
        XCTAssertEqual(machine.take(), combo)
    }

    func testReleasingTheModifierBeforeTheKeyKeepsTheCombo() {
        var machine = KeyboardShortcutCaptureMachine()
        machine.start()
        let option = SidedModifier(.option, .left)
        let combo = HeldKeys(modifiers: [option], nonModifierKey: kVK_ANSI_1)
        machine.update(held: HeldKeys(modifiers: [option]))
        machine.update(held: combo)
        machine.update(held: HeldKeys(modifiers: [], nonModifierKey: kVK_ANSI_1))
        machine.update(held: .empty)
        XCTAssertEqual(machine.take(), combo, "both release orders must record the same thing")
    }

    func testComboSettlesWhenItsKeyGoesDown() {
        var machine = KeyboardShortcutCaptureMachine()
        machine.start()
        let option = SidedModifier(.option, .left)
        machine.update(held: HeldKeys(modifiers: [option]))
        XCTAssertTrue(machine.isCapturing, "modifiers alone leave the recording open")
        machine.update(held: HeldKeys(modifiers: [option], nonModifierKey: kVK_ANSI_1))
        XCTAssertFalse(machine.isCapturing, "the key completes it — no release needed")
    }

    func testSwappingTheKeyBeforeReleasingRecordsTheFirstOne() {
        // Once settled, later presses belong to the next session, not this one.
        var machine = KeyboardShortcutCaptureMachine()
        machine.start()
        let option = SidedModifier(.option, .left)
        let first = HeldKeys(modifiers: [option], nonModifierKey: kVK_ANSI_1)
        machine.update(held: HeldKeys(modifiers: [option]))
        machine.update(held: first)
        machine.update(held: HeldKeys(modifiers: [option], nonModifierKey: kVK_ANSI_2))
        XCTAssertEqual(machine.take(), first)
    }

    // MARK: - Key requirement

    func testModifierOnlyReleaseIsRefusedWhenAKeyIsRequired() {
        var machine = KeyboardShortcutCaptureMachine(requiresNonModifierKey: true)
        machine.start()
        machine.update(held: HeldKeys(modifiers: [SidedModifier(.option, .left)]))
        machine.update(held: .empty)
        XCTAssertNil(machine.take(), "a bare modifier must not commit into a key-required field")
    }

    func testRefusedReleaseKeepsListeningAndFlagsTheReason() {
        var machine = KeyboardShortcutCaptureMachine(requiresNonModifierKey: true)
        machine.start()
        machine.update(held: HeldKeys(modifiers: [SidedModifier(.option, .left)]))
        machine.update(held: .empty)
        XCTAssertTrue(machine.isCapturing, "the field stays open so the user can just try again")
        XCTAssertTrue(machine.rejectedModifierOnly)
    }

    func testComboCommitsAfterARefusedModifierOnlyAttempt() {
        var machine = KeyboardShortcutCaptureMachine(requiresNonModifierKey: true)
        machine.start()
        machine.update(held: HeldKeys(modifiers: [SidedModifier(.option, .left)]))
        machine.update(held: .empty)
        let combo = HeldKeys(modifiers: [SidedModifier(.option, .left)], nonModifierKey: kVK_ANSI_K)
        machine.update(held: HeldKeys(modifiers: [SidedModifier(.option, .left)]))
        machine.update(held: combo)
        machine.update(held: .empty)
        XCTAssertEqual(machine.take(), combo)
    }

    func testModifierOnlyStillCommitsWhenNoKeyIsRequired() {
        var machine = KeyboardShortcutCaptureMachine()
        machine.start()
        let held = HeldKeys(modifiers: [SidedModifier(.command, .right)])
        machine.update(held: held)
        machine.update(held: .empty)
        XCTAssertEqual(machine.take(), held, "the activation slots are built on bare modifiers")
    }
}
