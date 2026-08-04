import AppKit
import CoreGraphics
import Foundation
import os

/// What a position shortcut did, so the caller (and the tests) can tell a hit from a
/// position the wheel currently has nothing at.
enum PositionActivationResult: Equatable, Sendable {
    /// Activated the running app in that slot — its front window is now focused.
    case app(AppID)
    /// Focused the window in that slot of the frontmost app's list.
    case window(WindowID)
    /// Started (or reopened) a curated / Dock entry that had no window to focus.
    case launch(bundleIdentifier: String)
    /// The wheel has no such position right now — nothing was touched.
    case outOfRange
    /// The list this shortcut addresses couldn't be resolved at all (no frontmost app for
    /// a window shortcut, no menu tree for an app shortcut).
    case unavailable
}

/// Activates a wheel position directly, without ever showing the wheel (Bringr-dk3).
///
/// It resolves the exact same tree the wheel would: the apps ring comes from the same
/// `MenuDefinition` the summon path uses, and the windows list from the same
/// `WindowEnumerator` read the sub-wheel's dynamic provider makes, at the same collection
/// scope. So "position 3" means the third slice the user would have seen, and the two can
/// only drift if the wheel itself does.
///
/// Nothing is revealed and nothing is restored: there is no hover phase to undo, so the
/// activator drives `WindowController`'s commit primitives against a controller that never
/// opens a session. That also keeps it off the reveal journal — a position shortcut leaves
/// no state a crash could strand.
@MainActor
final class PositionActivator {
    /// The wheel's top-level definition, shared with the summon path so both rings resolve
    /// identically. Held as the definition rather than reached through `MenuRegistry` so no
    /// trigger has to be invented for a path that never opens a menu.
    private let menu: any MenuDefinition
    /// The same enumerator the menu reads through, so the windows list a position shortcut
    /// walks is the one the sub-wheel would show — including its caches.
    private let enumerator: WindowEnumerator
    /// Commit primitives only. Constructed without a `RevealStateStore`, so no baseline is
    /// journalled and `endSession()` inside `commit` is a no-op.
    private let windowControl: WindowController
    private let appLauncher: AppLaunching
    /// Read fresh per press, mirroring the summon path, so a Preferences change to scope
    /// applies at once.
    private let collectionProvider: () -> CollectionPreferences
    /// The display to scope collection against. The cursor's display, like a summon — the
    /// wheel would have opened there, so the same slices are in play. `@MainActor` because
    /// the live implementation reads `NSScreen`.
    private let displayProvider: @MainActor () -> CGRect?
    /// The app whose window list a `.windows` position addresses: the one the user is in.
    private let frontmostAppProvider: () -> AppID?

    private static let log = Logger(subsystem: "com.mekedron.PieSwitcher", category: "PositionShortcuts")

    init(
        menu: any MenuDefinition,
        enumerator: WindowEnumerator,
        windowControl: WindowController? = nil,
        appLauncher: AppLaunching? = nil,
        collectionProvider: @escaping () -> CollectionPreferences = { CollectionPreferences.current() },
        displayProvider: @escaping @MainActor () -> CGRect? = {
            ScreenLocator.displayBounds(forCursor: NSEvent.mouseLocation)
        },
        frontmostAppProvider: @escaping () -> AppID? = {
            NSWorkspace.shared.frontmostApplication.map { AppID(pid: $0.processIdentifier) }
        }
    ) {
        self.menu = menu
        self.enumerator = enumerator
        self.windowControl = windowControl ?? WindowController()
        self.appLauncher = appLauncher ?? LiveAppLauncher()
        self.collectionProvider = collectionProvider
        self.displayProvider = displayProvider
        self.frontmostAppProvider = frontmostAppProvider
    }

    /// Act on `position` in `list`. Called straight from the event tap's callback, so the
    /// whole path is measured — an overrun here is felt as the keyboard sticking.
    @discardableResult
    func activate(_ list: PositionShortcutList, position: Int) -> PositionActivationResult {
        SlowStep.measure("position shortcut \(list.rawValue) #\(position)") {
            switch list {
            case .apps: return activateApp(position: position)
            case .windows: return activateWindow(position: position)
            }
        }
    }

    // MARK: - Apps ring

    private func activateApp(position: Int) -> PositionActivationResult {
        let display = displayProvider()
        let collection = collectionProvider()
        let nodes = menu.makeRoot(
            appsScope: collection.appsScope(forDisplay: display),
            windowsScope: collection.windowsScope(forDisplay: display)
        ).resolvedChildren()
        guard let index = PositionShortcutResolver.index(forPosition: position, count: nodes.count) else {
            Self.log.info("app position \(position) out of range (\(nodes.count) slices)")
            return .outOfRange
        }
        let node = nodes[index]
        Self.log.info("app position \(position) → \(node.title, privacy: .public)")

        // A curated / Dock entry with no window to focus starts the app instead, exactly as
        // committing its slice in the wheel would (Bringr-93j.39).
        if case .launchApp(let bundleIdentifier) = node.action {
            appLauncher.launch(bundleIdentifier: bundleIdentifier)
            return .launch(bundleIdentifier: bundleIdentifier)
        }
        guard let appID = node.representedApp else { return .unavailable }
        windowControl.commit(appID)
        return .app(appID)
    }

    // MARK: - Windows sub-wheel

    /// The windows of the app the user is currently in, read at the windows scope with no
    /// Accessibility title probes — a position shortcut renders nothing, so it never pays
    /// for titles. `freshSummon` because this read starts its own interaction and must not
    /// serve a previous summon's broadened cache (Bringr-93j.53).
    private func activateWindow(position: Int) -> PositionActivationResult {
        guard let frontmost = frontmostAppProvider() else { return .unavailable }
        let scope = collectionProvider().windowsScope(forDisplay: displayProvider())
        let windows = enumerator.enumerate(
            onScreen: scope.screenBounds, allSpaces: scope.allSpaces,
            includeMinimized: scope.includeMinimized, includeHidden: scope.includeHidden,
            validatesOnscreen: scope.validatesOnscreen,
            freshSummon: true, axTitles: .none
        ).first { $0.id == frontmost }?.windows ?? []
        // No entry for the frontmost app means the wheel wouldn't show it either — it is on
        // the Hidden list, or has no window inside the scope. Either way there is no
        // sub-wheel to index into, so the press does nothing rather than guessing.
        guard let index = PositionShortcutResolver.index(forPosition: position, count: windows.count) else {
            Self.log.info("window position \(position) out of range (\(windows.count) windows)")
            return windows.isEmpty ? .unavailable : .outOfRange
        }
        let windowID = windows[index].id
        Self.log.info("window position \(position) → pid \(windowID.app.pid) #\(windowID.token)")
        windowControl.commit(windowID)
        return .window(windowID)
    }
}
