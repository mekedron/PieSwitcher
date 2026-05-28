import XCTest
@testable import Bringr

/// The all-Spaces collection dimension of `WindowEnumerator` (Bringr-93j.48). Split from
/// `WindowEnumerationTests` to keep that class within SwiftLint's `type_body_length`; it
/// reuses the target-internal `FakeWindowEnumerationSource` and copies the small `raw`
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

        // The default is current-Space only — the source is asked without all-Spaces, so the
        // live source's `.optionOnScreenOnly` (current-Space) query is preserved.
        XCTAssertEqual(source.lastIncludedAllSpaces, false)
    }

    func testEnumerateForwardsAllSpacesFlagToSource() {
        let source = FakeWindowEnumerationSource(selfPID: selfPID, windows: [
            raw(number: 1, pid: 10, name: "Chrome")
        ])
        _ = WindowEnumerator(source: source).enumerate(allSpaces: true)

        XCTAssertEqual(source.lastIncludedAllSpaces, true)
    }

    func testAllSpacesServesTheWiderWindowList() {
        // The wider all-Spaces query surfaces a window the current-Space query does not.
        let source = FakeWindowEnumerationSource(
            selfPID: selfPID,
            windows: [raw(number: 1, pid: 10, name: "Chrome")],
            allSpacesWindows: [
                raw(number: 1, pid: 10, name: "Chrome"),
                raw(number: 2, pid: 20, name: "Mail")
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
            allSpacesWindows: [
                raw(number: 1, pid: 10, name: "Chrome", x: 100, y: 100),   // on A
                raw(number: 2, pid: 20, name: "Mail", x: 1600, y: 100)     // off A
            ]
        )
        let apps = WindowEnumerator(source: source).enumerate(onScreen: screenA, allSpaces: true)

        XCTAssertEqual(apps.map(\.name), ["Chrome"])
    }

    private func raw(
        number: Int, pid: pid_t, name: String,
        x: CGFloat = 0, y: CGFloat = 0, width: CGFloat = 800, height: CGFloat = 600
    ) -> RawWindow {
        RawWindow(
            windowNumber: number,
            ownerPID: pid,
            ownerName: name,
            title: "",
            layer: 0,
            alpha: 1,
            bounds: CGRect(x: x, y: y, width: width, height: height)
        )
    }
}
