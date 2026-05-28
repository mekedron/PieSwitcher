import CoreGraphics
import XCTest
@testable import Bringr

@MainActor
final class MenuModelTests: XCTestCase {

    // MARK: - AC1: arbitrary depth

    func testTreeNestsToArbitraryDepth() {
        let level4 = MenuNode(id: MenuNodeID("d"), title: "D", action: .expand)
        let level3 = MenuNode(id: MenuNodeID("c"), title: "C", action: .expand,
                              children: .static([level4]))
        let level2 = MenuNode(id: MenuNodeID("b"), title: "B", action: .expand,
                              children: .static([level3]))
        let root = MenuNode(id: MenuNodeID("a"), title: "A", action: .expand,
                            children: .static([level2]))

        let lvl1 = root.resolvedChildren()
        let lvl2 = lvl1[0].resolvedChildren()
        let lvl3 = lvl2[0].resolvedChildren()
        XCTAssertEqual([root.title, lvl1[0].title, lvl2[0].title, lvl3[0].title],
                       ["A", "B", "C", "D"])
        XCTAssertTrue(lvl3[0].resolvedChildren().isEmpty)
    }

    // MARK: - AC2: static vs dynamic children

    func testStaticChildrenReturnFixedList() {
        let child = MenuNode(id: MenuNodeID("x"), title: "X", action: .expand)
        let node = MenuNode(id: MenuNodeID("p"), title: "P", action: .expand,
                            children: .static([child]))
        XCTAssertEqual(node.resolvedChildren().map(\.title), ["X"])
    }

    func testDynamicChildrenRunProviderEachResolve() {
        var calls = 0
        var payload = ["one"]
        let node = MenuNode(
            id: MenuNodeID("p"), title: "P", action: .expand,
            children: .dynamic {
                calls += 1
                return payload.map { MenuNode(id: MenuNodeID($0), title: $0, action: .expand) }
            }
        )

        XCTAssertEqual(node.resolvedChildren().map(\.title), ["one"])
        payload = ["one", "two"]
        XCTAssertEqual(node.resolvedChildren().map(\.title), ["one", "two"])
        XCTAssertEqual(calls, 2)
    }

    // MARK: - AC3: nodes carry actions

    func testNodesCarryActions() {
        let win = WindowID(app: AppID(pid: 7), token: 3)
        let expandNode = MenuNode(id: MenuNodeID("a"), title: "A", action: .expand)
        let focusNode = MenuNode(id: MenuNodeID("w"), title: "W", action: .focusWindow(win))

        XCTAssertEqual(expandNode.action, .expand)
        XCTAssertEqual(focusNode.action, .focusWindow(win))
    }

    // MARK: - AC4: registry keyed on trigger; no singleton

    func testRegistryResolvesMenuByTrigger() {
        let source = stub([raw(number: 1, pid: 10, name: "Chrome")])
        let menu = WindowSwitcherMenu(enumerator: WindowEnumerator(source: source))
        let registry = MenuRegistry()
        registry.register(menu, for: .mouseChord)

        XCTAssertNotNil(registry.definition(for: .mouseChord))
        XCTAssertNil(registry.definition(for: .threeFingerPress))
        XCTAssertNotNil(registry.makeMenu(for: .mouseChord))
        XCTAssertNil(registry.makeMenu(for: .threeFingerPress))
    }

    func testOneDefinitionCanAnswerMultipleTriggers() {
        let source = stub([raw(number: 1, pid: 10, name: "Chrome")])
        let menu = WindowSwitcherMenu(enumerator: WindowEnumerator(source: source))
        let registry = MenuRegistry()
        registry.register(menu, for: .mouseChord)
        registry.register(menu, for: .threeFingerPress)

        XCTAssertNotNil(registry.makeMenu(for: .mouseChord))
        XCTAssertNotNil(registry.makeMenu(for: .threeFingerPress))
    }

    func testMakeMenuBuildsFreshTreeEachSummon() {
        let source = stub([raw(number: 1, pid: 10, name: "Chrome")])
        let registry = MenuRegistry()
        registry.register(WindowSwitcherMenu(enumerator: WindowEnumerator(source: source)),
                          for: .mouseChord)

        let first = registry.makeMenu(for: .mouseChord)
        XCTAssertEqual(first?.resolvedChildren().map(\.title), ["Chrome"])

        source.windows = [raw(number: 1, pid: 10, name: "Chrome"),
                          raw(number: 2, pid: 20, name: "Ghostty")]
        let second = registry.makeMenu(for: .mouseChord)
        XCTAssertEqual(second?.resolvedChildren().map(\.title), ["Chrome", "Ghostty"])
    }

    // MARK: - AC5: apps→windows tree from enumeration fixtures

    func testBuildsAppsToWindowsTreeFromEnumeration() {
        let source = stub([
            raw(number: 11, pid: 10, name: "Chrome", title: "Inbox"),
            raw(number: 12, pid: 10, name: "Chrome", title: "Docs"),
            raw(number: 21, pid: 20, name: "Ghostty", title: "")
        ])
        let root = WindowSwitcherMenu(enumerator: WindowEnumerator(source: source)).makeRoot()

        // Level 1: apps, .expand, each carrying its AppID for icon rendering.
        let apps = root.resolvedChildren()
        XCTAssertEqual(apps.map(\.title), ["Chrome", "Ghostty"])
        XCTAssertEqual(apps.map(\.action), [.expand, .expand])
        XCTAssertEqual(apps.map(\.representedApp), [AppID(pid: 10), AppID(pid: 20)] as [AppID?])

        // Level 2: Chrome's windows, .focusWindow carrying the right WindowID.
        let chromeWindows = apps[0].resolvedChildren()
        XCTAssertEqual(chromeWindows.map(\.title), ["Inbox", "Docs"])
        XCTAssertEqual(chromeWindows.map(\.action), [
            .focusWindow(WindowID(app: AppID(pid: 10), token: 11)),
            .focusWindow(WindowID(app: AppID(pid: 10), token: 12))
        ])
        XCTAssertTrue(chromeWindows[0].resolvedChildren().isEmpty)

        // Ghostty's untitled window falls back to an index label.
        XCTAssertEqual(apps[1].resolvedChildren().map(\.title), ["Window 1"])
    }

    func testAppSubWheelRebuildsFromLiveStateOnResolve() {
        let source = stub([raw(number: 11, pid: 10, name: "Chrome", title: "Inbox")])
        let appNode = WindowSwitcherMenu(enumerator: WindowEnumerator(source: source))
            .makeRoot().resolvedChildren()[0]
        XCTAssertEqual(appNode.resolvedChildren().map(\.title), ["Inbox"])

        // A new Chrome window appears; re-resolving the same app node reflects it.
        source.windows.append(raw(number: 12, pid: 10, name: "Chrome", title: "Docs"))
        XCTAssertEqual(appNode.resolvedChildren().map(\.title), ["Inbox", "Docs"])
    }

    // MARK: - Fixtures

    private func stub(_ windows: [RawWindow], selfPID: pid_t = 1) -> StubEnumerationSource {
        StubEnumerationSource(selfPID: selfPID, windows: windows)
    }

    private func raw(number: Int, pid: pid_t, name: String, title: String = "") -> RawWindow {
        RawWindow(
            windowNumber: number,
            ownerPID: pid,
            ownerName: name,
            title: title,
            layer: 0,
            alpha: 1,
            bounds: CGRect(x: 0, y: 0, width: 800, height: 600)
        )
    }
}

/// In-memory enumeration source whose window list can be mutated between calls,
/// so tests can prove dynamic providers re-query live state on each resolve.
@MainActor
final class StubEnumerationSource: WindowEnumerationSource {
    let selfPID: pid_t
    var windows: [RawWindow]

    init(selfPID: pid_t, windows: [RawWindow]) {
        self.selfPID = selfPID
        self.windows = windows
    }

    func rawWindows() -> [RawWindow] { windows }
}
