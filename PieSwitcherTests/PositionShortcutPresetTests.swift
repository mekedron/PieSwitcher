import Carbon.HIToolbox
import XCTest
@testable import PieSwitcher

/// Covers the one-click starter set (Bringr-dk3): what it binds, that it only ever binds
/// when asked, and that installing on top of the user's own rows keeps every one of them.
final class PositionShortcutPresetTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUp() {
        super.setUp()
        suiteName = "PositionShortcutPresetTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        super.tearDown()
    }

    // MARK: - Shape

    func testAppsPresetBindsOptionDigits() {
        let rows = PositionShortcutPreset.recommended(for: .apps)
        XCTAssertEqual(rows.count, PositionShortcutPreset.positionCount)
        XCTAssertEqual(rows.map(\.position), [1, 2, 3, 4])
        XCTAssertEqual(rows.first?.shortcut?.modifiers, [SidedModifier(.option, .left)])
        XCTAssertEqual(rows.map { $0.shortcut?.keyCode },
                       [kVK_ANSI_1, kVK_ANSI_2, kVK_ANSI_3, kVK_ANSI_4])
    }

    func testWindowsPresetBindsOptionShiftDigits() {
        let rows = PositionShortcutPreset.recommended(for: .windows)
        XCTAssertEqual(rows.first?.shortcut?.modifiers,
                       [SidedModifier(.option, .left), SidedModifier(.shift, .either)])
        XCTAssertEqual(rows.map { $0.shortcut?.keyCode },
                       [kVK_ANSI_1, kVK_ANSI_2, kVK_ANSI_3, kVK_ANSI_4])
    }

    func testPresetClaimsOnlyTheLeftOption() {
        // The right Option must keep typing ⌥1 = ©, ⌥2 = @ and friends, which is what makes
        // the starter set safe to hand to anyone regardless of keyboard layout.
        guard let shortcut = PositionShortcutPreset.recommended(for: .apps).first?.shortcut else {
            return XCTFail("preset should produce a shortcut")
        }
        let left = HeldKeys(modifiers: [SidedModifier(.option, .left)], nonModifierKey: kVK_ANSI_1)
        let right = HeldKeys(modifiers: [SidedModifier(.option, .right)], nonModifierKey: kVK_ANSI_1)
        XCTAssertTrue(KeyboardShortcutMatcher.matches(left, shortcut: shortcut))
        XCTAssertFalse(KeyboardShortcutMatcher.matches(right, shortcut: shortcut))
    }

    func testWindowsPresetAcceptsEitherShift() {
        guard let shortcut = PositionShortcutPreset.recommended(for: .windows).first?.shortcut else {
            return XCTFail("preset should produce a shortcut")
        }
        for side in [ModifierSide.left, .right] {
            let held = HeldKeys(
                modifiers: [SidedModifier(.option, .left), SidedModifier(.shift, side)],
                nonModifierKey: kVK_ANSI_1
            )
            XCTAssertTrue(KeyboardShortcutMatcher.matches(held, shortcut: shortcut),
                          "Shift only tells the lists apart — either one should do")
        }
    }

    func testPresetCarriesAKeySoItCanBeReRecorded() {
        // Modifiers-only position shortcuts are refused everywhere; the preset must not be
        // the one thing that sneaks one in.
        for list in PositionShortcutList.allCases {
            for row in PositionShortcutPreset.recommended(for: list) {
                XCTAssertTrue(row.shortcut?.hasNonModifierKey ?? false)
            }
        }
    }

    // MARK: - Opt-in

    func testNothingIsBoundUntilInstalled() {
        XCTAssertFalse(PositionShortcutPreset.isInstalled(.apps, in: defaults))
        XCTAssertTrue(PositionShortcutStore.armed(from: defaults).isEmpty)
    }

    func testInstallBindsTheWholeSet() {
        PositionShortcutPreset.install(.apps, in: defaults)
        XCTAssertTrue(PositionShortcutPreset.isInstalled(.apps, in: defaults))
        XCTAssertEqual(PositionShortcutStore.bindings(.apps, from: defaults).map(\.position),
                       [1, 2, 3, 4])
    }

    func testInstallingOneListLeavesTheOtherAlone() {
        PositionShortcutPreset.install(.apps, in: defaults)
        XCTAssertFalse(PositionShortcutPreset.isInstalled(.windows, in: defaults))
        XCTAssertTrue(PositionShortcutStore.bindings(.windows, from: defaults).isEmpty)
    }

    func testInstallIsIdempotent() {
        PositionShortcutPreset.install(.apps, in: defaults)
        PositionShortcutPreset.install(.apps, in: defaults)
        XCTAssertEqual(PositionShortcutStore.bindings(.apps, from: defaults).count,
                       PositionShortcutPreset.positionCount)
    }

    // MARK: - Merging with the user's own rows

    func testInstallKeepsRowsTheUserSetUp() {
        let mine = PositionShortcutBinding(
            position: 9,
            shortcut: KeyboardShortcut(modifiers: [SidedModifier(.control, .right)], keyCode: kVK_F9)
        )
        PositionShortcutStore.setBindings([mine], for: .apps, in: defaults)
        PositionShortcutPreset.install(.apps, in: defaults)
        let positions = PositionShortcutStore.bindings(.apps, from: defaults).map(\.position)
        XCTAssertEqual(positions, [1, 2, 3, 4, 9])
    }

    func testInstallSkipsAShortcutTheUserAlreadyBound() {
        // L⌥1 already points at position 7; adding it again at position 1 would leave one of
        // the two permanently unreachable, so the preset stands down for that row only.
        let mine = PositionShortcutBinding(
            position: 7,
            shortcut: KeyboardShortcut(modifiers: [SidedModifier(.option, .left)], keyCode: kVK_ANSI_1)
        )
        PositionShortcutStore.setBindings([mine], for: .apps, in: defaults)
        PositionShortcutPreset.install(.apps, in: defaults)
        let rows = PositionShortcutStore.bindings(.apps, from: defaults)
        XCTAssertEqual(rows.map(\.position), [2, 3, 4, 7])
        XCTAssertEqual(rows.filter { $0.shortcut?.keyCode == kVK_ANSI_1 }.count, 1)
    }

    // MARK: - Removal

    func testRemoveDropsOnlyThePresetRows() {
        let mine = PositionShortcutBinding(
            position: 9,
            shortcut: KeyboardShortcut(modifiers: [SidedModifier(.control, .right)], keyCode: kVK_F9)
        )
        PositionShortcutStore.setBindings([mine], for: .apps, in: defaults)
        PositionShortcutPreset.install(.apps, in: defaults)
        PositionShortcutPreset.remove(.apps, in: defaults)
        XCTAssertEqual(PositionShortcutStore.bindings(.apps, from: defaults), [mine])
        XCTAssertFalse(PositionShortcutPreset.isInstalled(.apps, in: defaults))
    }

    func testRemoveFindsARowMovedToAnotherPosition() {
        PositionShortcutPreset.install(.apps, in: defaults)
        var rows = PositionShortcutStore.bindings(.apps, from: defaults)
        rows[0].position = 12
        PositionShortcutStore.setBindings(rows, for: .apps, in: defaults)
        PositionShortcutPreset.remove(.apps, in: defaults)
        XCTAssertTrue(PositionShortcutStore.bindings(.apps, from: defaults).isEmpty,
                      "the preset is identified by its shortcut, not by where it points")
    }
}
