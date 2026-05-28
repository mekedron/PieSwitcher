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
/// with the ring band they occupy and the angular layout that places them. Level 0
/// is the apps ring; level 1 is the hovered app's windows sub-wheel (US-010).
///
/// The `layout` is computed once when the ring is built and shared by both rendering
/// (`RadialRingView`) and hit-testing (`RadialNavigator.region`), so the two can
/// never desync — the load-bearing invariant for the uneven US-016 sub-wheel.
struct RadialRing: Identifiable {
    let level: Int
    let geometry: RadialGeometry
    let nodes: [MenuNode]
    let layout: RadialLayout

    var id: Int { level }
}

/// What the user actually committed from the wheel. Window selections carry the
/// exact chosen window; app selections mean "activate this app's current front
/// window" without changing remembered per-window selection.
enum RadialCommitResult: Equatable {
    case app(AppID)
    case window(WindowID)
    /// A curated "My Apps" entry with no window to focus was started by bundle id
    /// (Bringr-93j.39) — distinct from `.app`, which activates a running app's front window.
    case launch(bundleIdentifier: String)
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
    /// In an overflow window sub-wheel (more windows than apps), the index of the
    /// window currently magnified to a full app-arc (the US-016 fisheye focus), or
    /// `nil` when there is no overflow — i.e. every window slice is already a full
    /// app-arc and focus has no geometric effect.
    private(set) var focusedWindowIndex: Int?
    /// The window slice to pre-highlight — the app's remembered last selection —
    /// while its sub-wheel is open, or `.none` when nothing is remembered. Distinct
    /// from `hovered`: it suggests a choice before the cursor reaches it. (US-012 AC4)
    private(set) var prehighlighted: HoverRegion = .none
    /// Whether the optional second-level cursor lock (Bringr-93j.29) is currently
    /// confining the pointer to the open app's windows sub-wheel and its parent app
    /// arc. Engaged when the cursor first enters the windows ring (level 1); released
    /// when it returns to the apps ring — the parent app arc being the only level-0
    /// slice reachable while confined. Always false when the setting is disabled. The
    /// controller reads it to decide whether to snap a stray move back.
    private(set) var cursorLockEngaged = false
    /// Whether the cursor-lock setting is on for this summon. Pushed in before `open`
    /// from the persisted setting (mirroring the strategy/geometry setters), so a
    /// Preferences change applies on the next open. When false the lock never engages.
    private var cursorLockEnabled = false

    private let windowControl: WindowController
    /// Starts a curated app that has no window to focus (Bringr-93j.39), behind a seam
    /// so the launch branch of `commitApp` is testable without launching real apps.
    private let appLauncher: AppLaunching
    private let store: LastSelectionStore
    /// Base ring size for the apps ring. Re-set per summon from the persisted
    /// appearance (US-014), so a Preferences size change applies on the next open.
    private var baseGeometry: RadialGeometry
    private let maxDepth: Int

    init(
        windowControl: WindowController,
        baseGeometry: RadialGeometry = .default,
        maxDepth: Int = 2,
        store: LastSelectionStore? = nil,
        appLauncher: AppLaunching? = nil
    ) {
        self.windowControl = windowControl
        self.baseGeometry = baseGeometry
        self.maxDepth = max(1, maxDepth)
        self.store = store ?? LastSelectionStore()
        self.appLauncher = appLauncher ?? LiveAppLauncher()
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

    /// Side length of the square overlay needed to fit every concentric ring at the
    /// current base size and full depth. The controller resizes the pre-warmed
    /// window to this on summon when the appearance changed (US-014) — a resize of
    /// the reused window, not an allocation, so the hot path stays cheap (FR-14).
    var overallDiameter: CGFloat { 2 * ringGeometry(forLevel: maxDepth - 1).outerRadius }

    /// Set the apps-ring base geometry for the next summon (US-014). Read fresh from
    /// the persisted appearance just before `open`, so a Preferences size change
    /// takes effect without a relaunch. Because rendering and hit-testing both derive
    /// from this one geometry, resizing can never desync them (AC3).
    func setBaseGeometry(_ geometry: RadialGeometry) {
        baseGeometry = geometry
    }

    /// Set the reveal strategy for the next summon (US-013). Read fresh from the
    /// persisted setting just before `open` (mirroring `setBaseGeometry`), so a
    /// Preferences change applies on the next summon without a relaunch (AC4). The
    /// navigator stays strategy-agnostic — `WindowController` maps the strategy onto
    /// its primitives — so the hover/drill-in policy is identical for all three.
    func setRevealStrategy(_ strategy: RevealStrategy) {
        windowControl.setStrategy(strategy)
    }

    /// Enable or disable the optional second-level cursor lock for the next summon
    /// (Bringr-93j.29). Read fresh from the persisted setting just before `open`
    /// (mirroring `setRevealStrategy`), so a Preferences change applies on the next
    /// summon without a relaunch. Disabling also clears any active engagement so the
    /// pointer is freed immediately rather than only on the next open.
    func setCursorLockEnabled(_ enabled: Bool) {
        cursorLockEnabled = enabled
        if !enabled { cursorLockEngaged = false }
    }

    // MARK: - Lifecycle

    /// Begin a summon: show the apps ring, nothing expanded, nothing revealed.
    func open(appNodes: [MenuNode]) {
        let geometry = ringGeometry(forLevel: 0)
        let layout = RadialLayout(itemCount: appNodes.count, geometry: geometry)
        rings = [RadialRing(level: 0, geometry: geometry, nodes: appNodes, layout: layout)]
        expandedAppIndex = nil
        expandedWindowIndex = nil
        focusedWindowIndex = nil
        hovered = .none
        prehighlighted = .none
        cursorLockEngaged = false
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
        focusedWindowIndex = nil
        hovered = .none
        prehighlighted = .none
        cursorLockEngaged = false
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
            // Back on the apps ring: the cursor reached the parent app arc, the gate
            // out of the lock (the only level-0 slice reachable while confined), so
            // release it (Bringr-93j.29).
            cursorLockEngaged = false
            restoreWindowIsolation()
            expandApp(at: index)
        case .slice(level: 1, let index):
            // Entering the windows sub-wheel engages the lock when the setting is on.
            if cursorLockEnabled { cursorLockEngaged = true }
            isolateWindow(at: index)
            focusWindowSlice(at: index)
        case .slice:
            break
        case .none:
            collapse()
        }
    }

    // MARK: - Commit (US-012)

    /// Commit the selection currently under `region`. Window leaves remember their
    /// selection for the app; app slices activate that app's current front window.
    /// Both paths restore every app/window moved out of the way before the final
    /// activation/focus, then clear the wheel. Returns `nil` only when nothing
    /// selectable was committed, so the caller can cancel-restore instead.
    @discardableResult
    func commit(_ region: HoverRegion) -> RadialCommitResult? {
        switch region {
        case .slice(level: 0, let index):
            return commitApp(at: index)
        case .slice(level: 1, let index):
            return commitWindow(at: index)
        case .slice, .none:
            return nil
        }
    }

    private func commitWindow(at index: Int) -> RadialCommitResult? {
        guard rings.count > 1 else { return nil }
        let windowsRing = rings[1]
        guard index >= 0, index < windowsRing.nodes.count,
              case .focusWindow(let windowID) = windowsRing.nodes[index].action else { return nil }

        if let appName = expandedAppNode?.title {
            store.remember(appName: appName, title: windowsRing.nodes[index].title, index: index)
        }
        windowControl.commit(windowID)
        clearState()
        return .window(windowID)
    }

    private func commitApp(at index: Int) -> RadialCommitResult? {
        guard let appsRing = rings.first,
              index >= 0, index < appsRing.nodes.count else { return nil }
        let appNode = appsRing.nodes[index]

        // A curated entry with no window to focus (not running, or running window-less)
        // launches by bundle id instead of activating a front window (Bringr-93j.39).
        // Restore first so any reveal left from hovering other apps is undone — this
        // node carried no pid, so its own hover never revealed anything — then start it;
        // the launched app comes forward on its own.
        if case .launchApp(let bundleIdentifier) = appNode.action {
            windowControl.restore()
            appLauncher.launch(bundleIdentifier: bundleIdentifier)
            clearState()
            return .launch(bundleIdentifier: bundleIdentifier)
        }

        guard let appID = appNode.representedApp else { return nil }
        windowControl.commit(appID)
        clearState()
        return .app(appID)
    }

    // MARK: - Transitions

    /// Isolate the app under the apps-ring slice at `index` and open (or rebuild)
    /// its windows sub-wheel. Re-targeting from another app reuses
    /// `WindowController`'s captured baseline, so a later restore still returns to
    /// the pre-summon state. Pre-highlights the app's remembered window, if any
    /// still matches the freshly resolved sub-wheel. (AC4)
    private func expandApp(at index: Int) {
        // Re-hovering the same app is a no-op only once its sub-wheel is populated. If
        // the windows came back empty — the live scan can momentarily return nothing
        // right after the reveal un-hides the app (Bringr-93j.31) — fall through so a
        // later hover (or the controller's retry) rebuilds it once the scan settles.
        // expandedAppIndex is still set on the empty pass, so a dead-zone collapse
        // still restores the reveal.
        guard !(expandedAppIndex == index && hasWindowSubWheel), let appsRing = rings.first,
              index >= 0, index < appsRing.nodes.count else { return }
        let appNode = appsRing.nodes[index]
        if let appID = appNode.representedApp {
            windowControl.revealApp(appID)
        }
        let windowNodes = appNode.resolvedChildren()
        let appCount = appsRing.nodes.count
        // Overflow (US-016 fisheye) only when there are genuinely more windows than
        // app-arcs to lay them on; with a single app there is no context arc, so the
        // ring falls back to equal division and focus has no effect.
        let overflow = windowNodes.count > appCount && appCount > 1
        let focus: Int? = overflow ? 0 : nil
        rings = [appsRing, makeWindowRing(windowNodes: windowNodes, parentIndex: index, focus: focus)]
        expandedAppIndex = index
        focusedWindowIndex = focus
        prehighlighted = prehighlightRegion(forAppNamed: appNode.title, windowNodes: windowNodes)
    }

    /// Build the level-1 windows ring for `windowNodes`, fanning out clockwise from
    /// the parent app at `parentIndex` with the US-016 app-aligned / fisheye layout.
    private func makeWindowRing(windowNodes: [MenuNode], parentIndex: Int, focus: Int?) -> RadialRing {
        let geometry = ringGeometry(forLevel: 1)
        let layout = RadialLayout.windowRing(
            windowCount: windowNodes.count,
            appCount: rings.first?.nodes.count ?? 0,
            parentIndex: parentIndex,
            focusedWindowIndex: focus,
            geometry: geometry
        )
        return RadialRing(level: 1, geometry: geometry, nodes: windowNodes, layout: layout)
    }

    /// Move the overflow fisheye focus to the window slice at `index`: the focused
    /// window grows to a full app-arc and the rest re-compress, live on hover. A no-op
    /// when there is no overflow (focus is `nil` and every slice is already full
    /// width) or when `index` is already focused, so it costs nothing per hover.
    private func focusWindowSlice(at index: Int) {
        guard rings.count > 1, focusedWindowIndex != nil, focusedWindowIndex != index else { return }
        let windowsRing = rings[1]
        guard index >= 0, index < windowsRing.nodes.count else { return }
        focusedWindowIndex = index
        rings[1] = makeWindowRing(
            windowNodes: windowsRing.nodes, parentIndex: expandedAppIndex ?? 0, focus: index
        )
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
        windowControl.revealWindow(windowID)
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
        focusedWindowIndex = nil
        prehighlighted = .none
        cursorLockEngaged = false
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
