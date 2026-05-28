import CoreGraphics
import Foundation

/// Where the cursor currently sits on the (possibly multi-ring) wheel: a slice at
/// a given concentric `level` and `index`, or nothing — the central dead zone or
/// anywhere outside every ring.
enum HoverRegion: Equatable, Sendable {
    case slice(level: Int, index: Int)
    case none
}

/// One concentric ring of the wheel: the menu nodes shown at a given depth, paired
/// with the ring band they occupy. Level 0 is the apps ring; level 1 is the
/// hovered app's windows sub-wheel (US-010).
struct RadialRing: Identifiable {
    let level: Int
    let geometry: RadialGeometry
    let nodes: [MenuNode]

    var id: Int { level }
}

/// Hover-driven navigation through the menu tree, drawn as concentric rings.
///
/// Holds no AppKit window — only the rings to render, the hovered region, and the
/// reveal side effects (through `WindowController`). That keeps the whole drill-in
/// / re-target / collapse policy unit-testable against a fake window system, the
/// same pure-core / thin-shell split as `InteractionStateMachine` and
/// `MouseChordDetector`.
///
/// Nesting is driven by the US-005 tree, not a hard-coded two-level scheme (AC5):
/// expanding a slice appends `node.resolvedChildren()` as the next concentric
/// ring, re-resolved from live state on every (re-)target so the sub-wheel always
/// reflects the app's current windows.
@MainActor
final class RadialNavigator {
    /// Rings to render, innermost first. Empty when the wheel is closed.
    private(set) var rings: [RadialRing] = []
    /// The region the cursor is currently over, for highlighting.
    private(set) var hovered: HoverRegion = .none
    /// Index of the expanded slice on the apps ring, or `nil` when collapsed to
    /// apps-only. Drives re-target detection (hovering the same app is a no-op).
    private(set) var expandedAppIndex: Int?
    /// Index of the isolated slice on the windows ring, or `nil` when no single
    /// window is isolated. Drives window re-isolation (hovering the same window is
    /// a no-op) and the un-isolate when the cursor leaves the windows ring.
    private(set) var expandedWindowIndex: Int?
    /// The window slice to pre-highlight — the app's remembered last selection —
    /// while its sub-wheel is open, or `.none` when nothing is remembered. Distinct
    /// from `hovered`: it suggests a choice before the cursor reaches it. (US-012 AC4)
    private(set) var prehighlighted: HoverRegion = .none

    private let windowControl: WindowController
    private let store: LastSelectionStore
    private let baseGeometry: RadialGeometry
    private let maxDepth: Int

    init(
        windowControl: WindowController,
        baseGeometry: RadialGeometry = .default,
        maxDepth: Int = 2,
        store: LastSelectionStore? = nil
    ) {
        self.windowControl = windowControl
        self.baseGeometry = baseGeometry
        self.maxDepth = max(1, maxDepth)
        self.store = store ?? LastSelectionStore()
    }

    // MARK: - Concentric geometry

    /// Ring band for concentric `level`. Each level sits just outside the previous
    /// one, reusing the base ring's thickness, so level 0 matches the single ring
    /// US-006 shipped and the rings touch (no gap to fall through while gliding
    /// outward from an app to its windows).
    func ringGeometry(forLevel level: Int) -> RadialGeometry {
        let thickness = baseGeometry.outerRadius - baseGeometry.innerRadius
        let inner = baseGeometry.innerRadius + CGFloat(level) * thickness
        return RadialGeometry(innerRadius: inner, outerRadius: inner + thickness)
    }

    /// Side length of the square overlay needed to fit every concentric ring at
    /// full depth — the pre-warm size, fixed so a summon never resizes the window.
    var overallDiameter: CGFloat { 2 * ringGeometry(forLevel: maxDepth - 1).outerRadius }

    // MARK: - Lifecycle

    /// Begin a summon: show the apps ring, nothing expanded, nothing revealed.
    func open(appNodes: [MenuNode]) {
        rings = [RadialRing(level: 0, geometry: ringGeometry(forLevel: 0), nodes: appNodes)]
        expandedAppIndex = nil
        expandedWindowIndex = nil
        hovered = .none
        prehighlighted = .none
    }

    /// End the interaction: restore every hidden app/window to its pre-summon state
    /// and clear the wheel. Safe with nothing revealed (restore is a no-op then).
    func close() {
        windowControl.restore()
        clearState()
    }

    private func clearState() {
        rings = []
        expandedAppIndex = nil
        expandedWindowIndex = nil
        hovered = .none
        prehighlighted = .none
    }

    // MARK: - Hit-testing

    /// Map a cursor `offset` (from the ring centre, +x right / +y down) to the
    /// region it falls in. Rings are checked innermost-first; their bands touch, so
    /// at most one matches.
    func region(forOffset offset: CGPoint) -> HoverRegion {
        for ring in rings {
            let layout = RadialLayout(itemCount: ring.nodes.count, geometry: ring.geometry)
            if let index = layout.hitTest(offset) {
                return .slice(level: ring.level, index: index)
            }
        }
        return .none
    }

    // MARK: - Hover

    /// React to the cursor moving to `region`:
    /// - apps ring (level 0): un-isolate any single window (its siblings reappear),
    ///   then drill into or re-target the hovered app;
    /// - windows ring (level 1): isolate the hovered window, hiding the app's other
    ///   windows so only it remains;
    /// - off every ring (dead zone / outside): collapse back to apps and restore.
    func updateHover(_ region: HoverRegion) {
        hovered = region
        switch region {
        case .slice(level: 0, let index):
            restoreWindowIsolation()
            expandApp(at: index)
        case .slice(level: 1, let index):
            isolateWindow(at: index)
        case .slice:
            break
        case .none:
            collapse()
        }
    }

    // MARK: - Commit (US-012)

    /// Commit the selection currently under `region`. When it resolves to a window
    /// leaf, remember it for its app (AC3), restore every app/window moved out of
    /// the way, and bring the chosen window to the front + focus it (AC1/AC2), then
    /// clear the wheel; returns the committed window. Returns `nil` for any
    /// non-window target — an app slice or the dead zone — without touching window
    /// state, so the caller can cancel-restore instead.
    @discardableResult
    func commit(_ region: HoverRegion) -> WindowID? {
        guard case .slice(level: 1, let index) = region, rings.count > 1 else { return nil }
        let windowsRing = rings[1]
        guard index >= 0, index < windowsRing.nodes.count,
              case .focusWindow(let windowID) = windowsRing.nodes[index].action else { return nil }

        if let appName = expandedAppNode?.title {
            store.remember(appName: appName, title: windowsRing.nodes[index].title, index: index)
        }
        windowControl.commit(windowID)
        clearState()
        return windowID
    }

    // MARK: - Transitions

    /// Isolate the app under the apps-ring slice at `index` and open (or rebuild)
    /// its windows sub-wheel. Re-targeting from another app reuses
    /// `WindowController`'s captured baseline, so a later restore still returns to
    /// the pre-summon state. Pre-highlights the app's remembered window, if any
    /// still matches the freshly resolved sub-wheel. (AC4)
    private func expandApp(at index: Int) {
        guard expandedAppIndex != index, let appsRing = rings.first,
              index >= 0, index < appsRing.nodes.count else { return }
        let appNode = appsRing.nodes[index]
        if let appID = appNode.representedApp {
            windowControl.hideOtherApps(besides: appID)
        }
        let windowNodes = appNode.resolvedChildren()
        let subRing = RadialRing(level: 1, geometry: ringGeometry(forLevel: 1), nodes: windowNodes)
        rings = [appsRing, subRing]
        expandedAppIndex = index
        prehighlighted = prehighlightRegion(forAppNamed: appNode.title, windowNodes: windowNodes)
    }

    /// The window slice to pre-highlight for the app named `appName`, matching its
    /// remembered selection against the live sub-wheel, or `.none`.
    private func prehighlightRegion(forAppNamed appName: String, windowNodes: [MenuNode]) -> HoverRegion {
        guard let index = store.prehighlightIndex(
            forAppName: appName, windowTitles: windowNodes.map(\.title)
        ) else { return .none }
        return .slice(level: 1, index: index)
    }

    /// Isolate the window under the windows-ring slice at `index`: hide every other
    /// window of the expanded app so only this one remains (AC1). Moving between
    /// window slices re-isolates the new target through the same call — the capture-
    /// once baseline makes the previously isolated window reappear and the new one
    /// stand alone (AC2). Idempotent for the already-isolated window.
    private func isolateWindow(at index: Int) {
        guard expandedWindowIndex != index, rings.count > 1 else { return }
        let windowsRing = rings[1]
        guard index >= 0, index < windowsRing.nodes.count,
              case .focusWindow(let windowID) = windowsRing.nodes[index].action else { return }
        windowControl.hideOtherWindows(besides: windowID)
        expandedWindowIndex = index
    }

    /// Un-isolate the single window, bringing the expanded app's other windows back
    /// (AC3), without un-hiding the other apps — the app stays isolated and its
    /// sub-wheel stays open. No-op when no window is isolated.
    private func restoreWindowIsolation() {
        guard expandedWindowIndex != nil, let appID = expandedAppID else {
            expandedWindowIndex = nil
            return
        }
        windowControl.restoreWindows(of: appID)
        expandedWindowIndex = nil
    }

    /// Drop the windows sub-wheel and restore the other apps (and any isolated
    /// window). No-op when already collapsed, so brushing the dead zone repeatedly
    /// costs nothing.
    private func collapse() {
        guard expandedAppIndex != nil else { return }
        windowControl.restore()
        rings = Array(rings.prefix(1))
        expandedAppIndex = nil
        expandedWindowIndex = nil
        prehighlighted = .none
    }

    /// The app node currently expanded on the apps ring, if any.
    private var expandedAppNode: MenuNode? {
        guard let index = expandedAppIndex, let appsRing = rings.first,
              index >= 0, index < appsRing.nodes.count else { return nil }
        return appsRing.nodes[index]
    }

    /// The app currently expanded on the apps ring, if any — the scope window
    /// isolation acts within.
    private var expandedAppID: AppID? {
        expandedAppNode?.representedApp
    }
}
