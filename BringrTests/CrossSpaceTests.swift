import XCTest
@testable import Bringr

/// Cross-Space collection (Bringr-93j.54). A genuine window on another Space is invisible to
/// `kAXWindowsAttribute` (which only enumerates the current Space), so it arrives AX-absent
/// (`isAXBacked == false`) yet stamped as living on a managed Space (`isManagedWindow == true`)
/// — and must be kept, where the Bringr-93j.52 AX-only phantom check would have dropped it. A
/// phantom helper surface is neither AX-backed nor managed and stays dropped. Its own file with a
/// local `raw` helper to stay clear of `WindowEnumeratorSpacesTests`' file-length cap.
@MainActor
final class WindowEnumeratorManagedSpaceTests: XCTestCase {
    private let selfPID: pid_t = 1000

    func testManagedOtherSpaceWindowKeptDespiteNoAXBacking() {
        // The motivating case: a Chrome window moved to another Space. AX (current-Space only)
        // can't enumerate it, so it isn't AX-backed, but the window server reports it on a
        // managed Space — so all-Spaces collection keeps it.
        let source = FakeWindowEnumerationSource(
            selfPID: selfPID,
            windows: [raw(number: 1, pid: 10, name: "Chrome")],
            offscreenWindows: [
                raw(number: 1, pid: 10, name: "Chrome"),
                raw(number: 2, pid: 10, name: "Chrome",
                    isOnscreen: false, isAXBacked: false, isManagedWindow: true)
            ]
        )

        let apps = WindowEnumerator(source: source).enumerate(allSpaces: true)
        XCTAssertEqual(apps.map(\.name), ["Chrome"])
        XCTAssertEqual(apps[0].windows.map(\.id.token), [1, 2])
    }

    func testPhantomDroppedWhenNeitherAXBackedNorManaged() {
        // Neither AX-backed nor on a managed Space → a phantom surface, dropped even with every
        // broadening flag on; the real managed other-Space window beside it survives.
        let source = FakeWindowEnumerationSource(
            selfPID: selfPID,
            windows: [raw(number: 1, pid: 10, name: "Chrome")],
            offscreenWindows: [
                raw(number: 1, pid: 10, name: "Chrome"),
                raw(number: 2, pid: 10, name: "Chrome", isOnscreen: false, isAXBacked: false),
                raw(number: 3, pid: 20, name: "Mail",
                    isOnscreen: false, isAXBacked: false, isManagedWindow: true)
            ]
        )

        let apps = WindowEnumerator(source: source)
            .enumerate(allSpaces: true, includeMinimized: true, includeHidden: true)
        XCTAssertEqual(apps.map(\.name), ["Chrome", "Mail"])
        XCTAssertEqual(apps[0].windows.map(\.id.token), [1])
    }

    func testManagedOtherSpaceWindowStillRidesOnAllSpacesFlag() {
        // Managed membership only rescues it from the phantom drop; it's still an off-Space
        // window, so it appears only when all-Spaces is on, not from a bare current-Space read.
        let source = FakeWindowEnumerationSource(
            selfPID: selfPID,
            windows: [raw(number: 1, pid: 10, name: "Chrome")],
            offscreenWindows: [
                raw(number: 1, pid: 10, name: "Chrome"),
                raw(number: 2, pid: 20, name: "Mail",
                    isOnscreen: false, isAXBacked: false, isManagedWindow: true)
            ]
        )

        XCTAssertEqual(
            WindowEnumerator(source: source).enumerate(includeMinimized: true).map(\.name),
            ["Chrome"]
        )
        XCTAssertEqual(
            WindowEnumerator(source: source).enumerate(allSpaces: true).map(\.name),
            ["Chrome", "Mail"]
        )
    }
}

/// Cross-Space commit fallback (Bringr-93j.54): a window on another Space has no cached AX
/// element, so the Accessibility raise/focus no-ops; commit must fall back to the window-server
/// cross-Space raise (by CG number), while a same-Space window keeps its proven AX path.
@MainActor
final class WindowControlCrossSpaceTests: XCTestCase {
    func testCommitOfWindowAbsentFromAXListUsesCrossSpaceRaise() {
        let appA = AppID(pid: 1)
        let offSpace = WindowID(app: appA, token: 99) // not among the app's enumerable windows
        let fake = FakeWindowSystem(apps: [app(1, tokens: [10])], frontmost: appA)
        let controller = WindowController(system: fake)
        fake.clearLog()

        controller.commit(offSpace)

        XCTAssertTrue(
            fake.operationLog.contains(.raiseAcrossSpaces(offSpace)),
            "an AX-absent (other-Space) window commits via the cross-Space raise"
        )
        XCTAssertEqual(fake.focusedWindow, offSpace)
    }

    func testCommitOfSameSpaceWindowSkipsCrossSpaceRaise() {
        let appA = AppID(pid: 1)
        let target = WindowID(app: appA, token: 11)
        let fake = FakeWindowSystem(apps: [app(1, tokens: [10, 11])], frontmost: appA)
        let controller = WindowController(system: fake)
        fake.clearLog()

        controller.commit(target)

        XCTAssertFalse(
            fake.operationLog.contains(.raiseAcrossSpaces(target)),
            "a same-Space window must not trigger the cross-Space fallback"
        )
    }

    private func app(_ pid: pid_t, tokens: [Int]) -> FakeWindowSystem.AppState {
        let appID = AppID(pid: pid)
        let windows = tokens.map {
            FakeWindowSystem.WindowState(id: WindowID(app: appID, token: $0), minimized: false)
        }
        return FakeWindowSystem.AppState(id: appID, hidden: false, windows: windows)
    }
}

/// Local fixture builder, mirroring the one in `WindowEnumeratorSpacesTests` but carrying the
/// `isManagedWindow` stamp this file exercises.
@MainActor
private func raw(
    number: Int, pid: pid_t, name: String,
    isOnscreen: Bool = true, isAXBacked: Bool = true, isManagedWindow: Bool = false
) -> RawWindow {
    RawWindow(
        windowNumber: number, ownerPID: pid, ownerName: name, title: "",
        layer: 0, alpha: 1, bounds: CGRect(x: 0, y: 0, width: 800, height: 600),
        isOnscreen: isOnscreen, isAXBacked: isAXBacked, isManagedWindow: isManagedWindow
    )
}
