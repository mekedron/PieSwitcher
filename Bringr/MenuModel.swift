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
    let children: MenuChildren

    init(
        id: MenuNodeID,
        title: String,
        action: MenuAction,
        representedApp: AppID? = nil,
        children: MenuChildren = .static([])
    ) {
        self.id = id
        self.title = title
        self.action = action
        self.representedApp = representedApp
        self.children = children
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
    /// Three-finger trackpad press (US-008).
    case threeFingerPress
}

/// An instantiable menu definition: it knows how to build a fresh tree each time
/// it is summoned. Concrete menus (the v1 window switcher; future URL/file menus)
/// conform. There is no shared, mutable menu singleton — every summon calls
/// `makeRoot()` for a clean tree.
@MainActor
protocol MenuDefinition {
    func makeRoot() -> MenuNode
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
    func makeMenu(for trigger: MenuTrigger) -> MenuNode? {
        definitions[trigger]?.makeRoot()
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

    func makeRoot() -> MenuNode {
        let enumerator = self.enumerator
        return MenuNode(
            id: MenuNodeID("root:apps"),
            title: "Applications",
            action: .expand,
            children: .dynamic {
                enumerator.enumerate().map { Self.appNode($0, enumerator: enumerator) }
            }
        )
    }

    private static func appNode(_ app: AppWindows, enumerator: WindowEnumerator) -> MenuNode {
        let appID = app.id
        return MenuNode(
            id: MenuNodeID("app:\(appID.pid)"),
            title: app.name,
            action: .expand,
            representedApp: appID,
            children: .dynamic {
                let current = enumerator.enumerate().first { $0.id == appID }
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
