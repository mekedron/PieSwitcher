import CoreGraphics
import XCTest
@testable import PieSwitcher

/// The app exclusion list (Bringr-93j.59): the pure parse / match / append logic and the
/// `UserDefaults` round-trip. Persistence uses an ephemeral suite (never `.standard`),
/// mirroring `CuratedAppsTests`.
final class AppIgnoreListTests: XCTestCase {

    // MARK: - parse

    func testParseTrimsLowercasesAndDropsBlanks() {
        XCTAssertEqual(AppIgnoreList.parse(" Com.Apple.Safari , , Safari ,"),
                       ["com.apple.safari", "safari"])
    }

    func testParseEmptyTextIsEmpty() {
        XCTAssertEqual(AppIgnoreList.parse(""), [])
        XCTAssertEqual(AppIgnoreList.parse("   ,  , "), [])
    }

    // MARK: - excludes

    func testEmptyListExcludesNothing() {
        let list = AppIgnoreList(text: "")
        XCTAssertTrue(list.isEmpty)
        XCTAssertFalse(list.excludes(bundleID: "com.apple.Safari", name: "Safari"))
    }

    func testMatchesBundleIDCaseInsensitively() {
        let list = AppIgnoreList(text: "com.apple.safari")
        XCTAssertTrue(list.excludes(bundleID: "com.apple.Safari", name: "Safari"))
    }

    func testMatchesNameCaseInsensitively() {
        let list = AppIgnoreList(text: "dell display manager")
        XCTAssertTrue(list.excludes(bundleID: "com.dell.dm", name: "Dell Display Manager"))
    }

    func testMatchesNameEvenWithoutABundleID() {
        let list = AppIgnoreList(text: "safari")
        XCTAssertTrue(list.excludes(bundleID: nil, name: "Safari"))
    }

    func testMatchesEitherBundleIDOrName() {
        let byID = AppIgnoreList(text: "com.dell.dm")
        let byName = AppIgnoreList(text: "Dell Display Manager")
        XCTAssertTrue(byID.excludes(bundleID: "com.dell.dm", name: "Dell Display Manager"))
        XCTAssertTrue(byName.excludes(bundleID: "com.dell.dm", name: "Dell Display Manager"))
    }

    func testDoesNotMatchOnSubstring() {
        let list = AppIgnoreList(text: "mail")
        XCTAssertFalse(list.excludes(bundleID: "com.uglyapps.mailplane", name: "Mailplane"),
                       "exact match only — 'mail' must not hide 'Mailplane'")
        XCTAssertFalse(list.excludes(bundleID: "com.apple.mail", name: "Mail-ish"),
                       "the bundle id is not a substring match either")
    }

    func testNonMatchingAppIsNotExcluded() {
        let list = AppIgnoreList(text: "com.dell.dm, Logi Options")
        XCTAssertFalse(list.excludes(bundleID: "com.google.Chrome", name: "Google Chrome"))
    }

    // MARK: - appending

    func testAppendingToEmptyTextIsJustTheEntry() {
        XCTAssertEqual(AppIgnoreList.appending("com.dell.dm", to: ""), "com.dell.dm")
    }

    func testAppendingJoinsWithCommaSpace() {
        XCTAssertEqual(AppIgnoreList.appending("com.b", to: "com.a"), "com.a, com.b")
    }

    func testAppendingSkipsCaseInsensitiveDuplicate() {
        XCTAssertEqual(AppIgnoreList.appending("COM.A", to: "com.a"), "com.a",
                       "an equivalent entry already present is a no-op")
    }

    func testAppendingBlankIsANoOp() {
        XCTAssertEqual(AppIgnoreList.appending("   ", to: "com.a"), "com.a")
    }

    func testAppendingTrimsStrayTrailingComma() {
        XCTAssertEqual(AppIgnoreList.appending("com.b", to: "com.a, "), "com.a, com.b")
        XCTAssertEqual(AppIgnoreList.appending("com.b", to: "com.a,"), "com.a, com.b")
    }

    // MARK: - persistence

    func testCurrentIsEmptyWhenUnset() {
        XCTAssertTrue(AppIgnoreList.current(from: makeDefaults()).isEmpty)
    }

    func testCurrentReadsStoredText() {
        let defaults = makeDefaults()
        defaults.set("com.dell.dm, Logi Options", forKey: AppIgnoreList.defaultsKey)

        XCTAssertEqual(AppIgnoreList.current(from: defaults).entries,
                       ["com.dell.dm", "logi options"])
    }

    private func makeDefaults() -> UserDefaults {
        let suiteName = "AppIgnoreListTests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            fatalError("could not create a test UserDefaults suite")
        }
        return defaults
    }
}

/// `WindowEnumerator` drops windows the source stamped `isIgnored` (Bringr-93j.59) — the live
/// matching is `CGWindowSource`'s, so here a fixture is stamped directly and we assert the
/// pure keep-rule excludes it, even when on-screen (the strongest case, since on-screen windows
/// are otherwise always kept).
@MainActor
final class WindowEnumeratorIgnoreTests: XCTestCase {
    private let selfPID: pid_t = 1000

    func testIgnoredAppIsDroppedEvenWhenOnScreen() {
        let source = FakeWindowEnumerationSource(selfPID: selfPID, windows: [
            raw(number: 1, pid: 10, name: "Chrome"),
            raw(number: 2, pid: 20, name: "Dell Display Manager", isIgnored: true)
        ])

        XCTAssertEqual(WindowEnumerator(source: source).enumerate().map(\.name), ["Chrome"],
                       "an excluded app is filtered out of collection entirely")
    }

    func testNonIgnoredAppsAreUnaffected() {
        let source = FakeWindowEnumerationSource(selfPID: selfPID, windows: [
            raw(number: 1, pid: 10, name: "Chrome"),
            raw(number: 2, pid: 20, name: "Ghostty")
        ])

        XCTAssertEqual(WindowEnumerator(source: source).enumerate().map(\.name),
                       ["Chrome", "Ghostty"])
    }

    private func raw(number: Int, pid: pid_t, name: String, isIgnored: Bool = false) -> RawWindow {
        RawWindow(
            windowNumber: number, ownerPID: pid, ownerName: name, title: "",
            layer: 0, alpha: 1, bounds: CGRect(x: 0, y: 0, width: 800, height: 600),
            isIgnored: isIgnored
        )
    }
}

/// A curated ("My Apps") entry on the exclusion list never appears, even though it's pinned
/// (Bringr-93j.59): the explicit "never show" beats the pin.
@MainActor
final class MyAppsMenuIgnoreTests: XCTestCase {

    func testCuratedAppOnIgnoreListIsDropped() {
        let source = StubEnumerationSource(selfPID: 1, windows: [])
        let curated = [
            CuratedApp(bundleIdentifier: "com.dell.dm", name: "Dell Display Manager"),
            CuratedApp(bundleIdentifier: "com.google.Chrome", name: "Chrome")
        ]
        let menu = MyAppsMenu(
            enumerator: WindowEnumerator(source: source, appOrder: { .name }),
            curatedApps: { curated },
            showOtherRunningApps: { false },
            keepCuratedOrder: { true },
            ignoreList: { AppIgnoreList(text: "com.dell.dm") },
            runningPID: { _ in nil }
        )

        XCTAssertEqual(menu.makeRoot().resolvedChildren().map(\.title), ["Chrome"],
                       "the pinned-but-excluded Dell utility is dropped before any node is built")
    }

    func testCuratedAppExcludedByNameIsDropped() {
        let source = StubEnumerationSource(selfPID: 1, windows: [])
        let curated = [CuratedApp(bundleIdentifier: "com.dell.dm", name: "Dell Display Manager")]
        let menu = MyAppsMenu(
            enumerator: WindowEnumerator(source: source, appOrder: { .name }),
            curatedApps: { curated },
            showOtherRunningApps: { false },
            keepCuratedOrder: { true },
            ignoreList: { AppIgnoreList(text: "Dell Display Manager") },
            runningPID: { _ in nil }
        )

        XCTAssertTrue(menu.makeRoot().resolvedChildren().isEmpty,
                      "matching by app name excludes the curated entry too")
    }
}
