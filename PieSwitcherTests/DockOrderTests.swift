import CoreGraphics
import XCTest
@testable import PieSwitcher

/// Covers the `.dockPosition` app sort and its "Keep Finder last" option (Bringr-93j.55):
/// the pure `DockOrder.sorted` ordering and the persisted toggle. The live Dock-order read
/// (`DockOrder.current`) is the untestable shell, so it isn't exercised here — every test
/// injects an explicit order, exactly as `WindowEnumerator` / `MyAppsMenu` feed it one.
final class DockOrderTests: XCTestCase {

    private let finder = DockOrder.finderBundleID
    private let chrome = "com.google.Chrome"
    private let mail = "com.apple.Mail"
    private let ghostty = "com.mitchellh.ghostty"

    // MARK: - Ordering by Dock position

    func testSortsByDockPosition() {
        let dock = [finder, mail, chrome]
        let result = DockOrder.sorted([chrome, finder, mail], bundleID: { $0 }, dockOrder: dock, keepFinderLast: false)
        XCTAssertEqual(result, [finder, mail, chrome])
    }

    func testUnpinnedAppsTrailThePinnedBlockInOriginalOrder() {
        // Only Chrome is pinned; the two unpinned apps keep their incoming relative order
        // (zoom before arc) and follow the pinned block — a stable sort by original index.
        let dock = [finder, chrome]
        let result = DockOrder.sorted(
            ["org.zoom", chrome, "company.arc"], bundleID: { $0 }, dockOrder: dock, keepFinderLast: false
        )
        XCTAssertEqual(result, [chrome, "org.zoom", "company.arc"])
    }

    func testItemsWithNoBundleIDTrailLikeUnpinned() {
        let dock = [finder, chrome]
        let items = [Item(bundle: nil), Item(bundle: chrome), Item(bundle: nil)]
        let result = DockOrder.sorted(items, bundleID: { $0.bundle }, dockOrder: dock, keepFinderLast: false)
        XCTAssertEqual(result.map(\.bundle), [chrome, nil, nil])
    }

    // MARK: - Finder placement

    func testFinderLeadsWhenKeepFinderLastOff() {
        let dock = [finder, chrome]
        let result = DockOrder.sorted([chrome, finder], bundleID: { $0 }, dockOrder: dock, keepFinderLast: false)
        XCTAssertEqual(result, [finder, chrome], "Finder takes its real first Dock slot")
    }

    func testKeepFinderLastSendsFinderAfterEvenUnpinnedApps() {
        // Dock: Finder, Chrome. Ghostty is unpinned. With the flag on, Finder must land last
        // of all — after the unpinned Ghostty, not merely after the pinned block.
        let dock = [finder, chrome]
        let result = DockOrder.sorted(
            [finder, ghostty, chrome], bundleID: { $0 }, dockOrder: dock, keepFinderLast: true
        )
        XCTAssertEqual(result, [chrome, ghostty, finder])
    }

    func testKeepFinderLastWithFinderAbsentIsHarmless() {
        let dock = [finder, chrome]
        let result = DockOrder.sorted([ghostty, chrome], bundleID: { $0 }, dockOrder: dock, keepFinderLast: true)
        XCTAssertEqual(result, [chrome, ghostty])
    }

    // MARK: - "Keep Finder last" persistence

    func testKeepsFinderLastDefaultsFalseWhenUnset() {
        XCTAssertFalse(DockOrder.keepsFinderLast(from: ephemeralDefaults()))
    }

    func testKeepsFinderLastReadsPersistedValue() {
        let defaults = ephemeralDefaults()
        defaults.set(true, forKey: DockOrder.keepFinderLastKey)
        XCTAssertTrue(DockOrder.keepsFinderLast(from: defaults))
    }

    // MARK: - Fixtures

    private struct Item { let bundle: String? }

    private func ephemeralDefaults() -> UserDefaults {
        let suite = "DockOrderTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }
}

/// `.dockPosition` driven through `WindowEnumerator` end to end: the injected Dock order and
/// pid→bundle-id resolver reorder the live, grouped apps, ignoring their z-order. A sibling
/// class so neither type's body approaches the SwiftLint `type_body_length` limit.
@MainActor
final class WindowEnumeratorDockSortTests: XCTestCase {

    func testDockPositionOrdersAppsByDockIgnoringZOrder() {
        // Live z-order: Ghostty, Chrome, Mail. Dock pins Mail then Chrome; Ghostty isn't
        // pinned, so it trails — proving the sort follows the Dock, not the front-to-back order.
        let source = FakeWindowEnumerationSource(selfPID: 1, windows: [
            raw(number: 1, pid: 20, name: "Ghostty"),
            raw(number: 2, pid: 10, name: "Chrome"),
            raw(number: 3, pid: 30, name: "Mail")
        ])
        let bundleByPID: [pid_t: String] = [
            10: "com.google.Chrome", 20: "com.mitchellh.ghostty", 30: "com.apple.Mail"
        ]
        let apps = WindowEnumerator(
            source: source, appOrder: { .dockPosition }, windowOrder: { .fixed },
            dockOrder: { [DockOrder.finderBundleID, "com.apple.Mail", "com.google.Chrome"] },
            keepFinderLast: { false }, appBundleID: { bundleByPID[$0] }
        ).enumerate()

        XCTAssertEqual(apps.map(\.name), ["Mail", "Chrome", "Ghostty"])
    }

    func testDockPositionKeepFinderLastSendsFinderToTheEnd() {
        let source = FakeWindowEnumerationSource(selfPID: 1, windows: [
            raw(number: 1, pid: 40, name: "Finder"),
            raw(number: 2, pid: 10, name: "Chrome"),
            raw(number: 3, pid: 20, name: "Ghostty")        // unpinned
        ])
        let bundleByPID: [pid_t: String] = [
            40: DockOrder.finderBundleID, 10: "com.google.Chrome", 20: "com.mitchellh.ghostty"
        ]
        let apps = WindowEnumerator(
            source: source, appOrder: { .dockPosition }, windowOrder: { .fixed },
            dockOrder: { [DockOrder.finderBundleID, "com.google.Chrome"] },
            keepFinderLast: { true }, appBundleID: { bundleByPID[$0] }
        ).enumerate()

        XCTAssertEqual(apps.map(\.name), ["Chrome", "Ghostty", "Finder"])
    }

    private func raw(number: Int, pid: pid_t, name: String) -> RawWindow {
        RawWindow(
            windowNumber: number, ownerPID: pid, ownerName: name, title: "",
            layer: 0, alpha: 1, bounds: CGRect(x: 0, y: 0, width: 800, height: 600)
        )
    }
}
