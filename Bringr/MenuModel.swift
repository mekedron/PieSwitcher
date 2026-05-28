import CoreGraphics
import Foundation

// MARK: - Actions

/// What activating a menu node does. v1 ships two actions; future content types
/// (open URL/file/folder, run a command) are added here as new cases — the node
/// type and the registry do not change, only this enum and whatever executes it.
enum MenuAction: Equatable, Sendable {
    /// Reveal this node's children as a sub-wheel (apps → windows in v1).
    case expand
    /// Bring `window` to the front and focus it — the terminal action of the
    /// window-switcher tree.
    case focusWindow(WindowID)
    /// Start the curated "My Apps" app with this bundle identifier (Bringr-93j.39).
    /// The action of a listed entry that has no window to focus — it isn't running, or
    /// is running with no on-screen windows — so committing it starts/raises the app
    /// rather than expanding to (an empty) sub-wheel or focusing a window. A listed app
    /// that *is* running with windows keeps `.expand` and the existing focus path.
    case launchApp(bundleIdentifier: String)
}

// MARK: - Nodes

/// Stable, typed identifier for a menu node, stable across summons for the same
/// underlying subject (app pid / window number), so hit-testing (US-006) and a
/// remembered selection (US-012) can refer to a node reliably. The opaque string
/// payload keeps it open to any future node kind.
struct MenuNodeID: Hashable, Sendable {
    let rawValue: String

    init(_ rawValue: String) {
        self.rawValue = rawValue
    }
}

/// A node's children: either a fixed list, or produced on demand by a provider
/// that runs when the node is resolved. The dynamic form is what makes the wheel
/// live — "running apps" and "windows of app X" are computed at summon/hover
/// time, not baked in when the tree is first built.
enum MenuChildren {
    case `static`([MenuNode])
    case dynamic(@MainActor () -> [MenuNode])
}

/// One node in a radial menu tree. Nodes nest to arbitrary depth through
/// `children`, so deeper trees and entirely new menus reuse the same type rather
/// than special-casing levels.
struct MenuNode: Identifiable {
    let id: MenuNodeID
    let title: String
    let action: MenuAction
    /// The app this node stands for, when it stands for one (app slices), so a
    /// renderer can show that app's icon. `nil` for the root and window leaves.
    let representedApp: AppID?
    /// Bundle identifier of the app this node stands for, when known — set for curated
    /// "My Apps" slices so the wheel can render the app's icon from its on-disk bundle
    /// even when the app isn't running (no pid to look up) (Bringr-93j.38). Additive and
    /// independent of `representedApp`: a live-enumeration app node carries only
    /// `representedApp` and renders from the running pid, unchanged; a curated entry
    /// carries this, and may carry both when it is also running. `nil` for the root and
    /// window leaves.
    let bundleIdentifier: String?
    let children: MenuChildren

    init(
        id: MenuNodeID,
        title: String,
        action: MenuAction,
        representedApp: AppID? = nil,
        bundleIdentifier: String? = nil,
        children: MenuChildren = .static([])
    ) {
        self.id = id
        self.title = title
        self.action = action
        self.representedApp = representedApp
        self.bundleIdentifier = bundleIdentifier
        self.children = children
    }

    /// Whether this node stands for an application — it renders an app icon rather than a
    /// window index. True when it carries a running pid (`representedApp`) or a bundle id
    /// (`bundleIdentifier`, a curated app that may not be running) (Bringr-93j.38).
    var representsApp: Bool {
        representedApp != nil || bundleIdentifier != nil
    }

    /// This node's children, running the provider for dynamic content. Called on
    /// each expand so a sub-wheel reflects live state at hover time.
    @MainActor
    func resolvedChildren() -> [MenuNode] {
        switch children {
        case .static(let nodes):
            return nodes
        case .dynamic(let provider):
            return provider()
        }
    }
}

// MARK: - Triggers & Registry

/// How a menu is summoned. v1 has the two fixed triggers; more triggers (or
/// per-menu custom ones) are added as cases without touching the registry.
enum MenuTrigger: Hashable, Sendable {
    /// Simultaneous left+right mouse press (US-007).
    case mouseChord
    /// A held modifier-key combination — the mouse's modifier-key option and the
    /// trackpad's only trigger (Bringr-93j.35), replacing the three-finger press.
    case modifierHold
}

/// An instantiable menu definition: it knows how to build a fresh tree each time
/// it is summoned. Concrete menus (the v1 window switcher; future URL/file menus)
/// conform. There is no shared, mutable menu singleton — every summon calls
/// `makeRoot()` for a clean tree.
@MainActor
protocol MenuDefinition {
    /// Build a fresh tree for one summon. `screenBounds` (CoreGraphics-global, top-left
    /// origin) restricts content to the display the menu was summoned on (Bringr-93j.30);
    /// `nil` spans all displays. A menu that doesn't care about the display ignores it.
    func makeRoot(onScreen screenBounds: CGRect?) -> MenuNode
}

extension MenuDefinition {
    /// Build a tree spanning all displays — the default when a summon isn't scoped to one.
    func makeRoot() -> MenuNode { makeRoot(onScreen: nil) }
}

/// Maps triggers to menu definitions and builds a fresh tree per summon. Keying
/// on the trigger lets one definition answer several triggers (the v1 window
/// switcher is bound to both triggers) and lets new menus register without
/// changing existing ones.
@MainActor
final class MenuRegistry {
    private var definitions: [MenuTrigger: any MenuDefinition] = [:]

    func register(_ definition: any MenuDefinition, for trigger: MenuTrigger) {
        definitions[trigger] = definition
    }

    func definition(for trigger: MenuTrigger) -> (any MenuDefinition)? {
        definitions[trigger]
    }

    /// Build a fresh menu tree for `trigger`, or `nil` if none is registered.
    /// `screenBounds` scopes the tree to one display (Bringr-93j.30); `nil` spans all.
    func makeMenu(for trigger: MenuTrigger, onScreen screenBounds: CGRect? = nil) -> MenuNode? {
        definitions[trigger]?.makeRoot(onScreen: screenBounds)
    }
}

// MARK: - Window switcher menu (v1)

/// The v1 menu: a top-level wheel of apps that currently have on-screen windows,
/// each expanding to a sub-wheel of that app's windows. Built fresh on every
/// summon from the live `WindowEnumerator`, so it reflects current state; an
/// app's window list is a dynamic provider keyed on that app, so hovering an app
/// rebuilds its sub-wheel from live state.
@MainActor
struct WindowSwitcherMenu: MenuDefinition {
    private let enumerator: WindowEnumerator

    init(enumerator: WindowEnumerator) {
        self.enumerator = enumerator
    }

    func makeRoot(onScreen screenBounds: CGRect?) -> MenuNode {
        let enumerator = self.enumerator
        // Capture `screenBounds` in both the apps provider and each app's windows
        // provider so the whole menu — top-level ring and every sub-wheel — stays
        // locked to the display the menu was summoned on, even as hover re-resolves
        // sub-wheels from live state (Bringr-93j.30).
        return MenuNode(
            id: MenuNodeID("root:apps"),
            title: "Applications",
            action: .expand,
            children: .dynamic {
                enumerator.enumerate(onScreen: screenBounds).map {
                    Self.appNode($0, onScreen: screenBounds, enumerator: enumerator)
                }
            }
        )
    }

    private static func appNode(
        _ app: AppWindows, onScreen screenBounds: CGRect?, enumerator: WindowEnumerator
    ) -> MenuNode {
        let appID = app.id
        return MenuNode(
            id: MenuNodeID("app:\(appID.pid)"),
            title: app.name,
            action: .expand,
            representedApp: appID,
            children: .dynamic {
                let current = enumerator.enumerate(onScreen: screenBounds).first { $0.id == appID }
                return (current?.windows ?? []).map { Self.windowNode($0) }
            }
        )
    }

    private static func windowNode(_ window: WindowInfo) -> MenuNode {
        MenuNode(
            id: MenuNodeID("window:\(window.id.app.pid):\(window.id.token)"),
            title: window.title,
            action: .focusWindow(window.id)
        )
    }
}
