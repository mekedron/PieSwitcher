import XCTest
@testable import Bringr

/// The all-Spaces collection dimension of `WindowEnumerator` (Bringr-93j.48). Split from
/// `WindowEnumerationTests` to keep that class within SwiftLint's `type_body_length`; it
/// reuses the target-internal `FakeWindowEnumerationSource` and the file-scoped `raw`
/// helper, mirroring `WindowEnumeratorRecencyTests`.
@MainActor
final class WindowEnumeratorSpacesTests: XCTestCase {
    private let selfPID: pid_t = 1000
    /// Display A in CoreGraphics-global space; windows with centre x ≥ 1440 live off A.
    private let screenA = CGRect(x: 0, y: 0, width: 1440, height: 900)

    func testEnumerateKeepsCurrentSpaceByDefault() {
        let source = FakeWindowEnumerationSource(selfPID: selfPID, windows: [
            raw(number: 1, pid: 10, name: "Chrome")
        ])
        _ = WindowEnumerator(source: source).enumerate()

        // No broadening flag set, so the source is asked for the narrow current-Space list —
        // the live source keeps its `.optionOnScreenOnly` query.
        XCTAssertEqual(source.lastIncludedOffscreen, false)
    }

    func testEnumerateForwardsAllSpacesFlagToSource() {
        let source = FakeWindowEnumerationSource(selfPID: selfPID, windows: [
            raw(number: 1, pid: 10, name: "Chrome")
        ])
        _ = WindowEnumerator(source: source).enumerate(allSpaces: true)

        XCTAssertEqual(source.lastIncludedOffscreen, true)
    }

    func testAllSpacesServesTheWiderWindowList() {
        // The wider query surfaces an off-Space window the current-Space query does not.
        let source = FakeWindowEnumerationSource(
            selfPID: selfPID,
            windows: [raw(number: 1, pid: 10, name: "Chrome")],
            offscreenWindows: [
                raw(number: 1, pid: 10, name: "Chrome"),
                raw(number: 2, pid: 20, name: "Mail", isOnscreen: false)
            ]
        )

        XCTAssertEqual(WindowEnumerator(source: source).enumerate().map(\.name), ["Chrome"])
        XCTAssertEqual(
            WindowEnumerator(source: source).enumerate(allSpaces: true).map(\.name),
            ["Chrome", "Mail"]
        )
    }

    func testScreenAndSpaceScopesComposeIndependently() {
        // An all-Spaces window list still gets screen-filtered: Mail lives off screen A, so
        // even spanning every Space, a ring scoped to A omits it — the two dimensions compose.
        let source = FakeWindowEnumerationSource(
            selfPID: selfPID,
            windows: [raw(number: 1, pid: 10, name: "Chrome", x: 100, y: 100)],
            offscreenWindows: [
                raw(number: 1, pid: 10, name: "Chrome", x: 100, y: 100),                  // on A
                raw(number: 2, pid: 20, name: "Mail", x: 1600, y: 100, isOnscreen: false)  // off A
            ]
        )
        let apps = WindowEnumerator(source: source).enumerate(onScreen: screenA, allSpaces: true)

        XCTAssertEqual(apps.map(\.name), ["Chrome"])
    }
}

/// The minimized/hidden collection flags (Bringr-93j.50): an off-screen window the broadened
/// query surfaces is kept only when the caller asked for its category, with hidden taking
/// precedence over minimized. A sibling class in the same file (not a new build-file) so the
/// "Spaces" class above keeps its narrow focus; both share the file-scoped `raw` helper.
@MainActor
final class WindowEnumeratorVisibilityTests: XCTestCase {
    private let selfPID: pid_t = 1000

    func testIncludeMinimizedGathersMinimizedWindows() {
        let source = FakeWindowEnumerationSource(
            selfPID: selfPID,
            windows: [raw(number: 1, pid: 10, name: "Chrome")],
            offscreenWindows: [
                raw(number: 1, pid: 10, name: "Chrome"),
                raw(number: 2, pid: 20, name: "Ghostty", isOnscreen: false, isMinimized: true)
            ]
        )

        XCTAssertEqual(
            WindowEnumerator(source: source).enumerate(includeMinimized: true).map(\.name),
            ["Chrome", "Ghostty"]
        )
    }

    func testMinimizedStayOutWhenOnlyBroadeningSpaces() {
        // The fix for the Bringr-93j.48 coupling: spanning Spaces no longer drags minimized
        // windows in — only the genuine off-Space window rides on `allSpaces`.
        let source = FakeWindowEnumerationSource(
            selfPID: selfPID,
            windows: [raw(number: 1, pid: 10, name: "Chrome")],
            offscreenWindows: [
                raw(number: 1, pid: 10, name: "Chrome"),
                raw(number: 2, pid: 20, name: "Ghostty", isOnscreen: false, isMinimized: true),
                raw(number: 3, pid: 30, name: "Mail", isOnscreen: false)
            ]
        )

        XCTAssertEqual(
            WindowEnumerator(source: source).enumerate(allSpaces: true).map(\.name),
            ["Chrome", "Mail"]
        )
    }

    func testIncludeHiddenGathersHiddenAppWindows() {
        let source = FakeWindowEnumerationSource(
            selfPID: selfPID,
            windows: [raw(number: 1, pid: 10, name: "Chrome")],
            offscreenWindows: [
                raw(number: 1, pid: 10, name: "Chrome"),
                raw(number: 2, pid: 20, name: "Slack", isOnscreen: false, isHidden: true)
            ]
        )

        XCTAssertEqual(
            WindowEnumerator(source: source).enumerate(includeHidden: true).map(\.name),
            ["Chrome", "Slack"]
        )
    }

    func testHiddenStayOutWhenOnlyBroadeningSpaces() {
        let source = FakeWindowEnumerationSource(
            selfPID: selfPID,
            windows: [raw(number: 1, pid: 10, name: "Chrome")],
            offscreenWindows: [
                raw(number: 1, pid: 10, name: "Chrome"),
                raw(number: 2, pid: 20, name: "Slack", isOnscreen: false, isHidden: true),
                raw(number: 3, pid: 30, name: "Mail", isOnscreen: false)
            ]
        )

        XCTAssertEqual(
            WindowEnumerator(source: source).enumerate(allSpaces: true).map(\.name),
            ["Chrome", "Mail"]
        )
    }

    func testHiddenTakesPrecedenceOverMinimized() {
        // A window of a hidden app that is also minimized counts as hidden, so "include
        // minimized" alone leaves it out and "include hidden" brings it (its whole app) back.
        let source = FakeWindowEnumerationSource(
            selfPID: selfPID,
            windows: [],
            offscreenWindows: [
                raw(number: 1, pid: 20, name: "Hiddo", isOnscreen: false, isMinimized: true, isHidden: true)
            ]
        )

        XCTAssertTrue(
            WindowEnumerator(source: source).enumerate(includeMinimized: true).isEmpty
        )
        XCTAssertEqual(
            WindowEnumerator(source: source).enumerate(includeHidden: true).map(\.name),
            ["Hiddo"]
        )
    }

    func testAnyVisibilityFlagBroadensTheSourceQuery() {
        func source() -> FakeWindowEnumerationSource {
            FakeWindowEnumerationSource(selfPID: selfPID, windows: [raw(number: 1, pid: 10, name: "Chrome")])
        }
        let baseline = source()
        _ = WindowEnumerator(source: baseline).enumerate()
        XCTAssertEqual(baseline.lastIncludedOffscreen, false)

        let minimized = source()
        _ = WindowEnumerator(source: minimized).enumerate(includeMinimized: true)
        XCTAssertEqual(minimized.lastIncludedOffscreen, true)

        let hidden = source()
        _ = WindowEnumerator(source: hidden).enumerate(includeHidden: true)
        XCTAssertEqual(hidden.lastIncludedOffscreen, true)
    }

    func testPhantomOffScreenWindowWithoutAXBackingIsDropped() {
        // Bringr-93j.52: the broadened query surfaces a record with no matching AX window
        // (Chrome/Ghostty keep such background surfaces) — selecting it can't focus anything,
        // so it must not appear even with every broadening flag on. A real off-Space window
        // (AX-backed) is still kept, so the feature isn't gutted.
        let source = FakeWindowEnumerationSource(
            selfPID: selfPID,
            windows: [raw(number: 1, pid: 10, name: "Chrome")],
            offscreenWindows: [
                raw(number: 1, pid: 10, name: "Chrome"),
                raw(number: 2, pid: 10, name: "Chrome", isOnscreen: false, isAXBacked: false),
                raw(number: 3, pid: 20, name: "Mail", isOnscreen: false)
            ]
        )

        let apps = WindowEnumerator(source: source)
            .enumerate(allSpaces: true, includeMinimized: true, includeHidden: true)
        XCTAssertEqual(apps.map(\.name), ["Chrome", "Mail"])
        XCTAssertEqual(apps[0].windows.map(\.id.token), [1])
    }

    func testOnscreenWindowKeptEvenWhenNotAXBacked() {
        // The AX-backing drop applies only to the off-screen records broadening adds; an
        // on-screen record is always real and is kept (the keep-rule checks onscreen first).
        let source = FakeWindowEnumerationSource(
            selfPID: selfPID,
            windows: [raw(number: 1, pid: 10, name: "Chrome")],
            offscreenWindows: [raw(number: 1, pid: 10, name: "Chrome", isAXBacked: false)]
        )

        XCTAssertEqual(
            WindowEnumerator(source: source).enumerate(allSpaces: true).map(\.name),
            ["Chrome"]
        )
    }
}

/// Shared fixture builder for both classes in this file. `isOnscreen` defaults to a plain
/// on-screen window; off-Space / minimized / hidden fixtures set the relevant flags so the
/// keep-rule can be exercised without the live `CGWindowList`.
@MainActor
private func raw(
    number: Int, pid: pid_t, name: String,
    x: CGFloat = 0, y: CGFloat = 0, width: CGFloat = 800, height: CGFloat = 600,
    isOnscreen: Bool = true, isMinimized: Bool = false, isHidden: Bool = false,
    isAXBacked: Bool = true
) -> RawWindow {
    RawWindow(
        windowNumber: number,
        ownerPID: pid,
        ownerName: name,
        title: "",
        layer: 0,
        alpha: 1,
        bounds: CGRect(x: x, y: y, width: width, height: height),
        isOnscreen: isOnscreen,
        isMinimized: isMinimized,
        isHidden: isHidden,
        isAXBacked: isAXBacked
    )
}
