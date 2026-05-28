import AppKit
import SwiftUI

/// Pre-warmed overlay that hosts the radial wheel. Created once at launch and
/// shown/hidden — never rebuilt on the summon hot path (the < 16 ms budget).
///
/// A borderless, transparent, non-activating floating panel: it floats above the
/// app the user summoned it over without activating Bringr or deactivating that
/// app — which would disturb the very window state the switcher must preserve.
final class RadialMenuWindow: NSPanel {
    @MainActor
    init(contentSize: CGSize) {
        super.init(
            contentRect: NSRect(origin: .zero, size: contentSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = .floating
        isFloatingPanel = true
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        // Ask for cursor-move events so the overlay's local monitor has something to
        // catch in click-to-stay, where moves are delivered to us rather than the app
        // underneath (see `RadialMenuController.startMenuMonitors`).
        acceptsMouseMovedEvents = true
    }
}

/// Indirection over AppKit's event-monitor calls so the while-open monitor wiring is
/// unit-testable. Production wires `NSEvent`'s global *and* local monitors; a test
/// injects a recorder to assert hover gets both — the regression here was a
/// global-only hover monitor, which never fires for cursor moves the window server
/// routes to our own overlay (the click-to-stay case).
struct EventMonitorInstaller {
    /// Passive monitor for events sent to *other* apps. Returns an opaque token.
    var addGlobal: (NSEvent.EventTypeMask, @escaping (NSEvent) -> Void) -> Any?
    /// Monitor for events sent to *this* app; the handler returns the event to pass
    /// it through (or nil to consume it). Returns an opaque token.
    var addLocal: (NSEvent.EventTypeMask, @escaping (NSEvent) -> NSEvent?) -> Any?
    /// Tears down a monitor created by either installer.
    var remove: (Any) -> Void

    static let live = EventMonitorInstaller(
        addGlobal: { NSEvent.addGlobalMonitorForEvents(matching: $0, handler: $1) },
        addLocal: { NSEvent.addLocalMonitorForEvents(matching: $0, handler: $1) },
        remove: { NSEvent.removeMonitor($0) }
    )
}

/// Owns the pre-warmed overlay window and drives the menu for each summon.
///
/// The window and its SwiftUI host are built once in `init` (the pre-warm); a
/// summon only resolves the live tree, repositions the window at the cursor, and
/// orders it in — no allocation on the hot path. `rings`/`hovered` are published
/// so the pre-built `RadialMenuView` re-renders as hover drills through the tree.
///
/// Two pure cores carry the policy: `InteractionStateMachine` (US-009) decides
/// open/select/cancel, and `RadialNavigator` (US-010) decides app isolation and
/// the windows sub-wheel. The controller is the thin shell that feeds them live
/// triggers, clicks, and cursor moves and performs the side effects they ask for.
@MainActor
final class RadialMenuController: ObservableObject {
    /// Concentric rings to render for the current summon (apps, then the hovered
    /// app's windows). Mirrors `navigator.rings`.
    @Published private(set) var rings: [RadialRing] = []
    /// The slice the cursor is currently over, for highlighting. Mirrors
    /// `navigator.hovered`.
    @Published private(set) var hovered: HoverRegion = .none
    /// The slice to pre-highlight (the app's remembered last selection). Mirrors
    /// `navigator.prehighlighted`. (US-012 AC4)
    @Published private(set) var prehighlighted: HoverRegion = .none
    /// Whether the overlay is currently on screen.
    @Published private(set) var isVisible = false
    /// The appearance applied to the current summon (US-014): drives slice fill
    /// opacity and label visibility in `RadialMenuView`. Re-read from the persisted
    /// settings at each summon so a Preferences change takes effect next open (AC2).
    @Published private(set) var appearance: RadialAppearance = .default

    /// Overlay side length for the current base size, fit to every concentric ring
    /// at full depth.
    var overallDiameter: CGFloat { navigator.overallDiameter }

    private let registry: MenuRegistry
    private let navigator: RadialNavigator
    private let window: RadialMenuWindow
    private var machine = InteractionStateMachine()
    /// Reads the persisted interaction mode at summon time so a Preferences change
    /// takes effect on the next summon without a relaunch (AC3 of US-009).
    private let modeProvider: () -> InteractionMode
    /// Reads the persisted appearance at summon time, mirroring `modeProvider`, so a
    /// Preferences appearance change applies on the next summon without a relaunch
    /// (US-014 AC2).
    private let appearanceProvider: () -> RadialAppearance
    /// Installs the while-open NSEvent monitors. `.live` in production; a test injects
    /// a recorder to assert hover is wired with both a global and a local monitor.
    private let monitorInstaller: EventMonitorInstaller
    /// Global event monitors that live only while the menu is open: cursor moves/drags
    /// feed hover to the navigator (during a held chord the moves arrive as drags),
    /// and key/mouse-downs drive the Esc and click-outside cancels (US-015). Installed
    /// on summon, removed on dismiss.
    private var eventMonitors: [Any] = []
    /// Observes active-Space changes while open so a Space switch mid-reveal cancels
    /// cleanly rather than stranding hidden windows (US-015 trigger-loss).
    private var spaceObserver: (any NSObjectProtocol)?

    /// macOS virtual key code for Esc.
    private static let escapeKeyCode: UInt16 = 53

    init(
        registry: MenuRegistry,
        geometry: RadialGeometry = .default,
        windowControl: WindowController? = nil,
        modeProvider: @escaping () -> InteractionMode = { InteractionMode.current() },
        appearanceProvider: @escaping () -> RadialAppearance = { RadialAppearance.current() },
        monitorInstaller: EventMonitorInstaller = .live
    ) {
        self.registry = registry
        self.modeProvider = modeProvider
        self.appearanceProvider = appearanceProvider
        self.monitorInstaller = monitorInstaller
        self.navigator = RadialNavigator(
            windowControl: windowControl ?? WindowController(),
            baseGeometry: geometry
        )
        self.window = RadialMenuWindow(
            contentSize: CGSize(
                width: navigator.overallDiameter,
                height: navigator.overallDiameter
            )
        )
        // Pre-warm the SwiftUI host now so summon never allocates it.
        window.contentView = NSHostingView(rootView: RadialMenuView(controller: self))
    }

    // MARK: - Trigger entry points

    /// A hold-capable trigger (mouse chord, trackpad press) fired. Opens in the
    /// persisted mode, or dismisses if already open (toggle parity).
    func triggerPressed(for trigger: MenuTrigger, at cursor: CGPoint) {
        press(trigger: trigger, mode: modeProvider(), at: cursor)
    }

    /// The menu-bar fallback: a single click with no "hold", so it always opens in
    /// click-to-stay regardless of the persisted mode, and a second click dismisses.
    func summonFromMenuBar(at cursor: CGPoint) {
        press(trigger: .mouseChord, mode: .clickToStay, at: cursor)
    }

    /// A hold-capable trigger was released. Hold-to-select commits on what the
    /// cursor is over; click-to-stay ignores the release and keeps the menu open.
    func triggerReleased(at cursor: CGPoint) {
        let region = navigator.region(forOffset: offset(forGlobalCursor: cursor))
        route(machine.handle(.triggerReleased(over: sliceTarget(region))), region: region)
    }

    /// A click inside the overlay. In click-to-stay this selects the slice under the
    /// cursor, or cancels on a dead-zone/outside click; in hold-to-select it is ignored.
    func clickInOverlay(atLocalPoint local: CGPoint) {
        let region = navigator.region(forOffset: offset(forLocalPoint: local))
        route(machine.handle(.click(over: sliceTarget(region))), region: region)
    }

    /// Esc was pressed while the menu was open: cancel and restore, in either mode (US-015).
    func escapePressed() {
        route(machine.handle(.escape), region: .none)
    }

    /// The summon context was lost (active-Space change, etc.) while open: cancel and
    /// restore so no app/window is left hidden (US-015 trigger-loss).
    func triggerLost() {
        route(machine.handle(.triggerLost), region: .none)
    }

    private func press(trigger: MenuTrigger, mode: InteractionMode, at cursor: CGPoint) {
        if !machine.isOpen { machine.mode = mode }
        switch machine.handle(.triggerPressed) {
        case .open: summon(trigger: trigger, at: cursor)
        case .cancel: cancelInteraction()
        case .none, .select: break
        }
    }

    private func route(_ outcome: InteractionOutcome, region: HoverRegion) {
        switch outcome {
        case .select: commitSelection(region: region)
        case .cancel: cancelInteraction()
        case .none, .open: break
        }
    }

    // MARK: - Side effects

    /// Show the menu registered for `trigger` centred at `cursor` (the global mouse
    /// location). Resolves the tree fresh so the wheel reflects live state, and
    /// starts tracking the cursor so hover can drill into apps.
    private func summon(trigger: MenuTrigger, at cursor: CGPoint) {
        guard let root = registry.makeMenu(for: trigger) else { return }
        // Apply the persisted appearance before resolving the tree: the size feeds
        // both the rendered rings and the navigator's hit-testing through one shared
        // geometry, so they stay in lock-step at any size (US-014 AC3).
        appearance = appearanceProvider()
        navigator.setBaseGeometry(appearance.geometry)
        navigator.open(appNodes: root.resolvedChildren())
        syncFromNavigator()
        let side = navigator.overallDiameter
        let size = NSSize(width: side, height: side)
        let origin = RadialMenuPlacement.windowOrigin(forCursor: cursor, windowSize: size)
        window.setFrame(NSRect(origin: origin, size: size), display: false)
        window.orderFrontRegardless()
        isVisible = true
        startMenuMonitors()
    }

    /// Commit the slice under `region`: app slices activate the app, window slices
    /// raise and focus the chosen window, and both restore everything else to its
    /// pre-summon state (US-012). If `region` is not selectable, fall back to a
    /// cancel-restore. Either way the overlay goes away.
    private func commitSelection(region: HoverRegion) {
        if navigator.commit(region) == nil {
            dismiss() // not selectable — restore like a cancel
        } else {
            hideOverlay() // the navigator already restored, focused, and cleared
        }
    }

    /// Cancel the interaction, restoring the pre-summon window state.
    private func cancelInteraction() {
        dismiss()
    }

    /// Restore every app/window the hover moved out of the way, then hide the overlay.
    private func dismiss() {
        navigator.close()
        hideOverlay()
    }

    /// Tear down the on-screen overlay and stop tracking the cursor, without
    /// touching window state — used after a commit, where the navigator has already
    /// restored and focused.
    private func hideOverlay() {
        stopMenuMonitors()
        syncFromNavigator()
        window.orderOut(nil)
        isVisible = false
    }

    private func syncFromNavigator() {
        rings = navigator.rings
        hovered = navigator.hovered
        prehighlighted = navigator.prehighlighted
    }

    // MARK: - While-open monitors (hover + cancel paths)

    /// Install the global monitors that run only while the menu is open. The overlay
    /// is a non-activating panel, so events meant for the app underneath — cursor
    /// moves (hover), Esc, and clicks *outside* the wheel — arrive as global events;
    /// clicks *on* the wheel are local and handled by the SwiftUI gesture instead.
    private func startMenuMonitors() {
        guard eventMonitors.isEmpty else { return }
        // Hover needs BOTH a global and a local monitor. A global monitor sees only
        // events the window server routes to *other* apps: in hold-to-select the held
        // chord keeps the app underneath active, so cursor moves land there (as drags)
        // and the global monitor fires. But in click-to-stay the trigger is released
        // and the moves are delivered to our own non-activating overlay — a global
        // monitor never fires for those, so hover would die the moment the wheel
        // persists. The two are mutually exclusive per event (each event reaches
        // exactly one app), so installing both can't double-count; the local one
        // returns the event so the overlay's own gesture/tracking still runs.
        let hoverMask: NSEvent.EventTypeMask =
            [.mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged]
        if let globalHover = monitorInstaller.addGlobal(hoverMask, { [weak self] _ in
            self?.updateHover(forGlobalCursor: NSEvent.mouseLocation)
        }) {
            eventMonitors.append(globalHover)
        }
        if let localHover = monitorInstaller.addLocal(hoverMask, { [weak self] event in
            self?.updateHover(forGlobalCursor: NSEvent.mouseLocation)
            return event
        }) {
            eventMonitors.append(localHover)
        }
        // Dismiss stays global-only on purpose: a click *on* the wheel is our own
        // event, already handled by the SwiftUI gesture (`clickInOverlay`); a local
        // dismiss monitor would see that same click as a "click over none" and cancel
        // the selection the gesture is making. Only clicks/keys routed elsewhere —
        // i.e. outside the wheel — should reach this cancel path, and those are global.
        if let dismiss = monitorInstaller.addGlobal(
            [.keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown], { [weak self] event in
                self?.handleDismissEvent(event)
            }
        ) {
            eventMonitors.append(dismiss)
        }
        spaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.triggerLost() }
        }
    }

    private func stopMenuMonitors() {
        for monitor in eventMonitors { monitorInstaller.remove(monitor) }
        eventMonitors.removeAll()
        if let spaceObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(spaceObserver)
        }
        spaceObserver = nil
    }

    /// Route a global key/mouse-down that bypassed the overlay to a cancel: Esc in
    /// either mode, or a click outside the wheel which the state machine cancels in
    /// click-to-stay and ignores in hold-to-select (where the chord is still held).
    private func handleDismissEvent(_ event: NSEvent) {
        switch event.type {
        case .keyDown where event.keyCode == Self.escapeKeyCode:
            escapePressed()
        case .leftMouseDown, .rightMouseDown, .otherMouseDown:
            route(machine.handle(.click(over: .none)), region: .none)
        default:
            break
        }
    }

    private func updateHover(forGlobalCursor cursor: CGPoint) {
        navigator.updateHover(navigator.region(forOffset: offset(forGlobalCursor: cursor)))
        syncFromNavigator()
    }

    // MARK: - Cursor → target resolution

    /// Collapse a hover region to the commit vocabulary: any ring slice is a target,
    /// the dead zone / outside is none. The state machine only needs "a slice" vs
    /// "none" to pick select vs cancel; `commitSelection(region:)` reads the live
    /// region itself to resolve which window.
    private func sliceTarget(_ region: HoverRegion) -> SliceTarget {
        switch region {
        case .slice(_, let index): return .slice(index)
        case .none: return .none
        }
    }

    /// Offset from the ring centre for a global (AppKit y-up) cursor, flipped into
    /// the layout's y-down space.
    private func offset(forGlobalCursor cursor: CGPoint) -> CGPoint {
        let frame = window.frame
        return CGPoint(x: cursor.x - frame.midX, y: frame.midY - cursor.y)
    }

    /// Offset from the ring centre for a point in the overlay view's local (y-down,
    /// top-left origin) space.
    private func offset(forLocalPoint local: CGPoint) -> CGPoint {
        let center = overallDiameter / 2
        return CGPoint(x: local.x - center, y: local.y - center)
    }
}
