import XCTest
@testable import PieSwitcher

/// Covers the per-window title resolution `WindowEnumerator` performs at group time
/// (Bringr-93j.110): CG `kCGWindowName` first when populated, then the source's per-app
/// AX `kAXTitleAttribute` read for any window whose CG title is blank, then a synthetic
/// "<App> — Window <N>" fallback so a slice is never blank when window labels are on.
/// Split from `WindowEnumerationTests` to keep that class within SwiftLint's
/// `type_body_length`, mirroring the sibling `WindowEnumeratorSpacesTests` split.
@MainActor
final class WindowEnumeratorTitleTests: XCTestCase {
    private let selfPID: pid_t = 1000

    func testTitleFallsBackToAppNamePlusWindowIndexWhenEmpty() {
        // When neither CG nor AX yield a usable title, the synthetic fallback carries the
        // app name plus a 1-based disambiguator so a slice is never blank and two untitled
        // windows of one app stay distinguishable.
        let source = FakeWindowEnumerationSource(selfPID: selfPID, windows: [
            raw(number: 1, pid: 10, name: "Chrome", title: ""),
            raw(number: 2, pid: 10, name: "Chrome", title: "   ")
        ])
        let apps = WindowEnumerator(source: source).enumerate()

        XCTAssertEqual(apps[0].windows.map(\.title), ["Chrome — Window 1", "Chrome — Window 2"])
    }

    func testAxTitleFillsInWhenCGTitleIsBlank() {
        // Under Accessibility-only permission the CG title is normally empty, so the AX
        // title is what the user actually sees. The source's per-app AX read fills it in;
        // trimmed whitespace is dropped before display.
        let source = FakeWindowEnumerationSource(
            selfPID: selfPID,
            windows: [
                raw(number: 1, pid: 10, name: "Chrome", title: ""),
                raw(number: 2, pid: 10, name: "Chrome", title: "")
            ],
            axTitles: [10: [1: "Inbox — Mail", 2: "  Docs  "]]
        )
        let apps = WindowEnumerator(source: source).enumerate()

        XCTAssertEqual(apps[0].windows.map(\.title), ["Inbox — Mail", "Docs"])
    }

    func testCGTitleWinsOverAXTitleWhenBothAvailable() {
        // CG's title is what Mission Control shows when Screen Recording is granted —
        // prefer it over AX, which can be stale or differ for the few apps that report both.
        let source = FakeWindowEnumerationSource(
            selfPID: selfPID,
            windows: [raw(number: 1, pid: 10, name: "Chrome", title: "Inbox")],
            axTitles: [10: [1: "Stale title"]]
        )
        let apps = WindowEnumerator(source: source).enumerate()

        XCTAssertEqual(apps[0].windows.map(\.title), ["Inbox"])
    }

    func testWhitespaceOnlyAXTitleFallsThroughToAppNameFallback() {
        // An AX-reported title of only whitespace is treated as missing, mirroring the CG
        // path, so the synthetic fallback still appears (no slice ever displays a blank
        // string).
        let source = FakeWindowEnumerationSource(
            selfPID: selfPID,
            windows: [raw(number: 1, pid: 10, name: "Chrome", title: "")],
            axTitles: [10: [1: "   "]]
        )
        let apps = WindowEnumerator(source: source).enumerate()

        XCTAssertEqual(apps[0].windows.map(\.title), ["Chrome — Window 1"])
    }

    func testAXTitlesAreNotConsultedWhenEveryCGTitleIsPopulated() {
        // The per-app AX query is the cost we want to skip on summons where it adds
        // nothing — every populated CG title means Screen Recording is granted and AX
        // titles cannot be more accurate.
        let source = FakeWindowEnumerationSource(
            selfPID: selfPID,
            windows: [
                raw(number: 1, pid: 10, name: "Chrome", title: "Inbox"),
                raw(number: 2, pid: 10, name: "Chrome", title: "Docs")
            ],
            axTitles: [10: [1: "x", 2: "y"]]
        )
        _ = WindowEnumerator(source: source).enumerate()

        XCTAssertEqual(source.axTitlesCalls, [])
    }

    func testAXTitlesAreConsultedOncePerAppWithABlankCGTitle() {
        // The check trips per app, so one app with a blank CG title triggers one AX read
        // for that app — and an app whose CG titles are fully populated triggers none.
        let source = FakeWindowEnumerationSource(
            selfPID: selfPID,
            windows: [
                raw(number: 1, pid: 10, name: "Chrome", title: "Inbox"),
                raw(number: 2, pid: 10, name: "Chrome", title: ""),
                raw(number: 3, pid: 20, name: "Ghostty", title: "Term")
            ],
            axTitles: [10: [2: "Tabs"]]
        )
        _ = WindowEnumerator(source: source).enumerate()

        XCTAssertEqual(source.axTitlesCalls, [10])
    }

    private func raw(number: Int, pid: pid_t, name: String, title: String) -> RawWindow {
        RawWindow(
            windowNumber: number, ownerPID: pid, ownerName: name, title: title,
            layer: 0, alpha: 1, bounds: CGRect(x: 0, y: 0, width: 800, height: 600)
        )
    }
}
