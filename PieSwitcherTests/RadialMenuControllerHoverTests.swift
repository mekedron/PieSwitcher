import AppKit
import XCTest
@testable import PieSwitcher

/// Covers the while-open monitor wiring for the radial menu (Bringr-93j.19): hover
/// must be driven by BOTH a global and a local NSEvent monitor so it keeps working
/// after the interaction mode is switched to click-to-stay, where cursor moves are
/// delivered to our own overlay and a global-only monitor never fires.
///
/// The live monitors can't be exercised without a real event stream, so an injected
/// `EventMonitorInstaller` records exactly what the controller wires up on summon.
@MainActor
final class RadialMenuControllerHoverTests: XCTestCase {

    // MARK: - The regression: hover wiring in both modes

    func testHoverWiredWithGlobalAndLocalMonitorsInBothModes() {
        for mode in InteractionMode.allCases {
            let recorder = MonitorRecorder()
            let controller = makeController(mode: mode, installer: recorder.installer())

            controller.triggerPressed(for: .mouseChord, at: CGPoint(x: 100, y: 100))

            let hoverMonitors = recorder.installed.filter { $0.mask.contains(.mouseMoved) }
            XCTAssertTrue(
                hoverMonitors.contains { $0.kind == .global },
                "\(mode): hover needs a global monitor (hold-to-select path)"
            )
            XCTAssertTrue(
                hoverMonitors.contains { $0.kind == .local },
                "\(mode): hover needs a local monitor (click-to-stay path) — the regression"
            )
        }
    }

    func testLocalHoverMonitorPassesEventsThrough() {
        let recorder = MonitorRecorder()
        let controller = makeController(mode: .clickToStay, installer: recorder.installer())
        controller.triggerPressed(for: .mouseChord, at: CGPoint(x: 100, y: 100))

        guard let localHover = recorder.installed.first(where: {
            $0.kind == .local && $0.mask.contains(.mouseMoved)
        })?.localHandler else {
            return XCTFail("expected a local hover monitor")
        }
        guard let moved = NSEvent.mouseEvent(
            with: .mouseMoved, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: 0, context: nil, eventNumber: 0, clickCount: 0, pressure: 0
        ) else {
            return XCTFail("could not synthesise a mouseMoved event")
        }
        // The local monitor must return the event so the overlay's SwiftUI gesture and
        // the app underneath still see it — consuming it would break clicks/tracking.
        XCTAssertTrue(localHover(moved) === moved)
    }

    func testDismissMonitorIsGlobalOnly() {
        let recorder = MonitorRecorder()
        let controller = makeController(mode: .clickToStay, installer: recorder.installer())
        controller.triggerPressed(for: .mouseChord, at: CGPoint(x: 100, y: 100))

        // A click *on* the wheel is handled by the SwiftUI gesture; a local mouse-down
        // monitor would double-handle it as a cancel, so dismiss stays global-only.
        let localDismiss = recorder.installed.filter {
            $0.kind == .local && $0.mask.contains(.leftMouseDown)
        }
        XCTAssertTrue(localDismiss.isEmpty, "dismiss must not have a local mouse-down monitor")
    }

    func testDismissRemovesEveryInstalledMonitor() {
        let recorder = MonitorRecorder()
        let controller = makeController(mode: .clickToStay, installer: recorder.installer())
        controller.triggerPressed(for: .mouseChord, at: CGPoint(x: 100, y: 100))
        XCTAssertFalse(recorder.installed.isEmpty)

        controller.escapePressed()

        XCTAssertEqual(Set(recorder.removed), Set(recorder.installed.map(\.token)),
                       "every monitor installed on summon must be removed on dismiss")
    }

    // MARK: - Keyboard-navigation gate (Bringr-93j.71/.72)

    /// The live `KeyboardNavMonitor` only consumes keys while `acceptsKeyboardNav` is true, so the
    /// controller must resolve the per-summon setting and gate on it: keys are handled while the
    /// wheel is open with the feature on, and pass straight through once it closes. (The focus
    /// movement and apps-ring accent it drives are covered against live rings in
    /// `RadialNavigatorKeyboardTests`.)
    func testAcceptsKeyboardNavTracksVisibilityWhenEnabled() {
        setKeyboardNavEnabled()
        let controller = makeController(mode: .clickToStay, installer: MonitorRecorder().installer())
        XCTAssertFalse(controller.acceptsKeyboardNav, "closed wheel never consumes keys")

        controller.triggerPressed(for: .mouseChord, at: CGPoint(x: 400, y: 400))
        XCTAssertTrue(controller.acceptsKeyboardNav, "open wheel with the feature on handles keys")

        controller.escapePressed()
        XCTAssertFalse(controller.acceptsKeyboardNav, "a closed wheel passes keys through again")
    }

    func testDoesNotAcceptKeyboardNavWhenFeatureOff() {
        // The feature defaults off, so even an open wheel must let keys pass through untouched.
        let controller = makeController(mode: .clickToStay, installer: MonitorRecorder().installer())
        controller.triggerPressed(for: .mouseChord, at: CGPoint(x: 400, y: 400))
        XCTAssertFalse(controller.acceptsKeyboardNav)
    }

    /// Close-on-unused (Bringr-93j.95) is independent of the main switch: with only the policy on,
    /// the monitor still has to fire so it can close the wheel on every key (all are unused while
    /// the nav feature is off).
    func testAcceptsKeyboardNavWhenOnlyCloseOnUnsupportedIsOn() {
        setCloseOnUnsupportedEnabled()
        let controller = makeController(mode: .clickToStay, installer: MonitorRecorder().installer())
        controller.triggerPressed(for: .mouseChord, at: CGPoint(x: 400, y: 400))
        XCTAssertTrue(
            controller.acceptsKeyboardNav,
            "with only close-on-unused on, the monitor must still consume keys to close the wheel"
        )
    }

    /// With the main switch off and close-on-unused on, every keyboard-nav key (arrows, numbers,
    /// Enter, Escape, Space) and every other key is unused — pressing any of them must close the
    /// wheel (Bringr-93j.95). The handler returns true to signal it consumed the key.
    func testEveryKeyClosesWheelWhenMainSwitchOffAndCloseOnUnsupportedOn() {
        setCloseOnUnsupportedEnabled()
        let keysThatShouldClose: [KeyboardNavKey] = [
            .arrow(.left), .arrow(.right), .arrow(.up), .arrow(.down),
            .digit(1), .digit(0), .confirm, .escape, .unsupported
        ]
        for key in keysThatShouldClose {
            let controller = makeController(mode: .clickToStay, installer: MonitorRecorder().installer())
            controller.triggerPressed(for: .mouseChord, at: CGPoint(x: 400, y: 400))
            XCTAssertTrue(controller.acceptsKeyboardNav, "\(key): expected the monitor to be active")
            XCTAssertTrue(
                controller.handleKeyboardNavKey(key),
                "\(key): expected the key to close the wheel"
            )
            XCTAssertFalse(controller.isVisible, "\(key): the wheel must be hidden after the close")
        }
    }

    /// With the main switch on, arrows off, and close-on-unused on (Bringr-93j.95), an arrow key
    /// is unused → closes; a digit (numbers default on) is supported → handled. Confirms the rule
    /// is "supported = currently has a function".
    func testDisabledArrowsCloseWheelWhenCloseOnUnsupportedOn() {
        setKeyboardNavEnabled()
        setCloseOnUnsupportedEnabled()
        // Arrows ship off (Bringr-93j.93), so the default with the master switch on is exactly this.
        let controller = makeController(mode: .clickToStay, installer: MonitorRecorder().installer())
        controller.triggerPressed(for: .mouseChord, at: CGPoint(x: 400, y: 400))

        XCTAssertTrue(
            controller.handleKeyboardNavKey(.arrow(.left)),
            "an arrow with arrow mode off counts as unused and closes the wheel"
        )
        XCTAssertFalse(controller.isVisible)
    }

    /// Same rule applied to the number keys (Bringr-93j.95): with numbers off but close-on-unused
    /// on, a digit closes the wheel; without the policy it would pass through silently.
    func testDisabledNumbersCloseWheelWhenCloseOnUnsupportedOn() {
        setKeyboardNavEnabled()
        setCloseOnUnsupportedEnabled()
        let defaults = UserDefaults.standard
        defaults.set(false, forKey: KeyboardNavigation.numbersKey)
        addTeardownBlock { defaults.removeObject(forKey: KeyboardNavigation.numbersKey) }

        let controller = makeController(mode: .clickToStay, installer: MonitorRecorder().installer())
        controller.triggerPressed(for: .mouseChord, at: CGPoint(x: 400, y: 400))

        XCTAssertTrue(
            controller.handleKeyboardNavKey(.digit(1)),
            "a digit with number mode off counts as unused and closes the wheel"
        )
        XCTAssertFalse(controller.isVisible)
    }

    /// When the policy is off, a key with no function passes through silently — even when its
    /// category is disabled. Confirms close-on-unused still gates everything (Bringr-93j.95).
    func testDisabledCategoryStaysOpenWhenCloseOnUnsupportedOff() {
        setKeyboardNavEnabled() // arrows ship off; close-on-unused defaults off (Bringr-93j.93).
        let controller = makeController(mode: .clickToStay, installer: MonitorRecorder().installer())
        controller.triggerPressed(for: .mouseChord, at: CGPoint(x: 400, y: 400))

        XCTAssertFalse(
            controller.handleKeyboardNavKey(.arrow(.left)),
            "with the policy off, a disabled-category key passes through and leaves the wheel open"
        )
        XCTAssertTrue(controller.isVisible)
    }

    /// Releasing the trigger over a number-jumped multi-window app the user never picked a window in
    /// commits that app rather than reverting, when "don't require a window choice" is on
    /// (Bringr-93j.73). Driven through the controller's release entry point in hold-to-select.
    func testReleaseCommitsArmedAppWithoutWindowChoice() {
        let fake = FakeWindowSystem(
            apps: [
                FakeWindowSystem.AppState(id: AppID(pid: 10), hidden: false, windows: [win(10, 11), win(10, 12)]),
                FakeWindowSystem.AppState(id: AppID(pid: 20), hidden: false, windows: [win(20, 21)])
            ],
            frontmost: AppID(pid: 20) // the prior frontmost a plain release would revert to
        )
        let source = StubEnumerationSource(selfPID: 1, windows: [
            raw(number: 11, pid: 10, name: "Chrome", title: "Inbox"),
            raw(number: 12, pid: 10, name: "Chrome", title: "Docs"),
            raw(number: 21, pid: 20, name: "Ghostty", title: "Terminal")
        ])
        let registry = MenuRegistry()
        registry.register(WindowSwitcherMenu(enumerator: WindowEnumerator(source: source)), for: .mouseChord)
        let controller = RadialMenuController(
            registry: registry, windowControl: WindowController(system: fake),
            modeProvider: { _ in .holdToSelect }, appearanceProvider: { .default },
            monitorInstaller: MonitorRecorder().installer()
        )
        // Bypass summon — headless display scoping yields 0 apps — by opening a populated tree.
        let appNodes = WindowSwitcherMenu(enumerator: WindowEnumerator(source: source)).makeRoot().resolvedChildren()
        controller.navigator.open(appNodes: appNodes)
        _ = controller.navigator.keyboardNumber(1, requireConfirmation: false, autoCommitsApp: true) // arm Chrome
        XCTAssertEqual(controller.navigator.pendingAppCommit, 0)

        controller.triggerReleased(at: .zero)

        XCTAssertEqual(fake.frontmost, AppID(pid: 10), "release commits the armed app, not a revert to Ghostty")
        XCTAssertNil(controller.navigator.pendingAppCommit)
        XCTAssertTrue(controller.navigator.rings.isEmpty, "the wheel is cleared after the commit")
    }

    /// Set up: enable keyboard navigation in the standard defaults the controller reads at summon,
    /// cleaning up after so the global domain isn't polluted for other tests.
    private func setKeyboardNavEnabled() {
        let defaults = UserDefaults.standard
        defaults.set(true, forKey: KeyboardNavigation.enabledKey)
        addTeardownBlock { defaults.removeObject(forKey: KeyboardNavigation.enabledKey) }
    }

    /// Set up: enable close-on-unused (Bringr-93j.95) in the standard defaults the controller reads
    /// at summon, cleaning up after.
    private func setCloseOnUnsupportedEnabled() {
        let defaults = UserDefaults.standard
        defaults.set(true, forKey: KeyboardNavigation.closeOnUnsupportedKey)
        addTeardownBlock { defaults.removeObject(forKey: KeyboardNavigation.closeOnUnsupportedKey) }
    }

    // MARK: - Fixtures

    private func makeController(
        mode: InteractionMode, installer: EventMonitorInstaller
    ) -> RadialMenuController {
        let source = StubEnumerationSource(selfPID: 1, windows: [
            raw(number: 11, pid: 10, name: "Chrome", title: "Inbox"),
            raw(number: 12, pid: 10, name: "Chrome", title: "Docs"),
            raw(number: 21, pid: 20, name: "Ghostty", title: "Terminal")
        ])
        let registry = MenuRegistry()
        registry.register(
            WindowSwitcherMenu(enumerator: WindowEnumerator(source: source)),
            for: .mouseChord
        )
        let fake = FakeWindowSystem(
            apps: [
                FakeWindowSystem.AppState(id: AppID(pid: 10), hidden: false,
                                          windows: [win(10, 11), win(10, 12)]),
                FakeWindowSystem.AppState(id: AppID(pid: 20), hidden: false,
                                          windows: [win(20, 21)])
            ],
            frontmost: AppID(pid: 10)
        )
        return RadialMenuController(
            registry: registry,
            windowControl: WindowController(system: fake),
            modeProvider: { _ in mode },
            appearanceProvider: { .default },
            monitorInstaller: installer
        )
    }

    private func win(_ pid: pid_t, _ token: Int) -> FakeWindowSystem.WindowState {
        FakeWindowSystem.WindowState(id: WindowID(app: AppID(pid: pid), token: token), minimized: false)
    }

    private func raw(number: Int, pid: pid_t, name: String, title: String = "") -> RawWindow {
        RawWindow(
            windowNumber: number, ownerPID: pid, ownerName: name, title: title,
            layer: 0, alpha: 1, bounds: CGRect(x: 0, y: 0, width: 800, height: 600)
        )
    }
}

/// Records what an `EventMonitorInstaller` is asked to install and remove, so a test
/// can assert the controller's monitor wiring without any live NSEvent stream.
@MainActor
private final class MonitorRecorder {
    enum Kind { case global, local }
    struct Installed {
        let kind: Kind
        let mask: NSEvent.EventTypeMask
        let token: Int
        let globalHandler: ((NSEvent) -> Void)?
        let localHandler: ((NSEvent) -> NSEvent?)?
    }

    private(set) var installed: [Installed] = []
    private(set) var removed: [Int] = []
    private var nextToken = 0

    func installer() -> EventMonitorInstaller {
        EventMonitorInstaller(
            addGlobal: { [weak self] mask, handler in
                self?.record(.global, mask, global: handler, local: nil)
            },
            addLocal: { [weak self] mask, handler in
                self?.record(.local, mask, global: nil, local: handler)
            },
            remove: { [weak self] token in
                if let token = token as? Int { self?.removed.append(token) }
            }
        )
    }

    private func record(
        _ kind: Kind, _ mask: NSEvent.EventTypeMask,
        global: ((NSEvent) -> Void)?, local: ((NSEvent) -> NSEvent?)?
    ) -> Any? {
        let token = nextToken
        nextToken += 1
        installed.append(Installed(kind: kind, mask: mask, token: token,
                                   globalHandler: global, localHandler: local))
        return token
    }
}
