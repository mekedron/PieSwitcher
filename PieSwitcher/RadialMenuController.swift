import AppKit
import os
import SwiftUI

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
    /// Whether the live highlight was last moved by keyboard vs mouse, for the focus tint
    /// (Bringr-93j.71). Set by the mouse hover path and the +Keyboard extension.
    @Published var highlightSource: HighlightSource = .mouse
    /// Dwell-to-activate state (Bringr-93j.105): the slice the user is dwelling on and
    /// the 0..1 fill of the progress arc on that slice's outer border. Driven by the
    /// `+Dwell` extension; rendered by `RadialMenuView`. `.none`/0 when no dwell is armed.
    @Published var dwellRegion: HoverRegion = .none
    @Published var dwellProgress: Double = 0

    /// Overlay side length for the current base size, fit to every concentric ring
    /// at full depth.
    var overallDiameter: CGFloat { navigator.overallDiameter }
    /// Keyboard-navigation settings resolved at summon time, read by the +Keyboard extension (Bringr-93j.71).
    var keyboardConfig: KeyboardNavigationConfig = .disabled

    /// Pre-rasterized slice icons for the pre-built `RadialMenuView`: a summon renders
    /// from this cache, never decoding an icon on the main thread. Pre-warmed at launch.
    let icons = AppIconStore()
    private let registry: MenuRegistry
    let navigator: RadialNavigator
    /// Internal (not private) so the cursor → offset helpers can live in
    /// `RadialMenuController+Cursor.swift`, where `offset(forGlobalCursor:)` reads its frame.
    let window: RadialMenuWindow
    var machine = InteractionStateMachine()
    /// Reads the persisted interaction mode at summon time so a Preferences change
    /// takes effect on the next summon without a relaunch (AC3 of US-009). Takes the
    /// trigger so the mouse and keyboard can carry independent modes (Bringr-93j.91).
    private let modeProvider: (MenuTrigger) -> InteractionMode
    /// Reads the persisted appearance at summon time, mirroring `modeProvider`, so a
    /// Preferences appearance change applies on the next summon without a relaunch
    /// (US-014 AC2).
    private let appearanceProvider: () -> RadialAppearance
    /// Reads the persisted reveal strategy at summon time, mirroring `modeProvider`,
    /// so a Preferences strategy change applies on the next summon without a relaunch
    /// (US-013 AC4).
    private let strategyProvider: () -> RevealStrategy
    /// Reads the persisted "leave only my selection on screen" setting at summon time,
    /// mirroring `modeProvider`, so a Preferences change applies on the next summon
    /// without a relaunch (Bringr-93j.27).
    private let hideOnCommitProvider: () -> Bool
    /// Reads the persisted apps/windows collection scope at summon time (Bringr-93j.48),
    /// mirroring `modeProvider`, so a Preferences change applies on the next summon.
    private let collectionProvider: () -> CollectionPreferences
    /// Reads the persisted dwell-to-activate config at summon time (Bringr-93j.105),
    /// mirroring `modeProvider`. Internal so the `+Dwell` extension and tests can reach it.
    let dwellConfigProvider: () -> DwellActivation.Config
    /// Owns the optional trackpad-haptic-on-hover policy (Bringr-93j.44): resolves whether
    /// haptics fire for the summon (setting on + no external mouse) and taps as hover moves
    /// to a new slice. Resolved per summon like the other read-fresh settings.
    private let haptics: HapticController
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
    /// Observes background Accessibility probes while open, so an open windows sub-wheel
    /// picks up real titles the moment they resolve (Bringr-jud).
    private var axStateObserver: (any NSObjectProtocol)?
    /// Windows-sub-wheel retry state (Bringr-93j.31): see `scheduleSubWheelRetry`.
    private var subWheelRetry: DispatchWorkItem?
    private var subWheelRetriesLeft = 0
    /// Dwell-to-activate timer (Bringr-93j.105) and the frozen config it runs against;
    /// managed by the `+Dwell` extension. The config is frozen at summon so a mid-open
    /// Preferences change can't half-flip the timer.
    var dwellTimer: Timer?
    var dwellConfig: DwellActivation.Config = .init(enabled: false, duration: 0, duringDragOnly: false)

    /// macOS virtual key code for Esc.
    private static let escapeKeyCode: UInt16 = 53

    init(
        registry: MenuRegistry,
        geometry: RadialGeometry = .default,
        windowControl: WindowController? = nil,
        modeProvider: @escaping (MenuTrigger) -> InteractionMode = { InteractionMode.current(for: $0) },
        appearanceProvider: @escaping () -> RadialAppearance = { RadialAppearance.current() },
        strategyProvider: @escaping () -> RevealStrategy = { RevealStrategy.current() },
        hideOnCommitProvider: @escaping () -> Bool = { HideOnCommit.isEnabled() },
        collectionProvider: @escaping () -> CollectionPreferences = { CollectionPreferences.current() },
        dwellConfigProvider: @escaping () -> DwellActivation.Config = { DwellActivation.current() },
        monitorInstaller: EventMonitorInstaller = .live,
        haptics: HapticController? = nil
    ) {
        self.registry = registry
        self.modeProvider = modeProvider
        self.appearanceProvider = appearanceProvider
        self.strategyProvider = strategyProvider
        self.hideOnCommitProvider = hideOnCommitProvider
        self.collectionProvider = collectionProvider
        self.dwellConfigProvider = dwellConfigProvider
        self.monitorInstaller = monitorInstaller
        self.haptics = haptics ?? HapticController()
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

    /// A hold-capable trigger (mouse chord, keyboard shortcut) fired. Opens in the
    /// persisted mode for that trigger (Bringr-93j.91 — mouse and keyboard each
    /// carry their own mode), or dismisses if already open (toggle parity).
    func triggerPressed(for trigger: MenuTrigger, at cursor: CGPoint) {
        press(trigger: trigger, mode: modeProvider(trigger), at: cursor)
    }

    /// The menu-bar fallback: a single click with no "hold", so it always opens in
    /// click-to-stay regardless of the persisted mode, and a second click dismisses.
    func summonFromMenuBar(at cursor: CGPoint) {
        press(trigger: .mouseChord, mode: .clickToStay, at: cursor)
    }

    /// A hold-capable trigger was released. Hold-to-select commits on what the
    /// cursor is over; click-to-stay ignores the release and keeps the menu open.
    func triggerReleased(at cursor: CGPoint) {
        if commitPendingAppOnRelease() { return } // numeric no-window-choice app commit (Bringr-93j.73)
        let region = navigator.region(forOffset: offset(forGlobalCursor: cursor))
        route(machine.handle(.triggerReleased(over: sliceTarget(region))), region: region)
    }

    /// A click inside the overlay. Selects the slice under the cursor, or cancels on a
    /// dead-zone click — in either interaction mode, since Bringr-93j.91 made
    /// click-to-activate always-on so a click always commits.
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
        // Resolve the interaction mode fresh while closed, so a Preferences change applies on
        // the next open rather than mid-session (AC3 of US-009).
        if !machine.isOpen {
            machine.mode = mode
        }
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

    /// Render the wheel once, invisibly, so the first real summon pays no first-render
    /// cost. The SwiftUI host, Liquid Glass material, and text caches are all built
    /// lazily at the window's first on-screen draw — which, without this pass, is the
    /// first summon's opening frame. Orders the pre-warmed window in at alpha 0,
    /// off-screen, with a live-resolved tree (which also warms the first window-list
    /// enumeration), forces a draw, and tears back down on the next run-loop tick.
    /// Touches no interaction state: no monitors, no state machine, `isVisible` stays
    /// false, and `navigator.close()` with nothing revealed restores nothing — so a
    /// summon landing mid-pass simply takes over (the tick's guard skips teardown, and
    /// `summon` resets the frame and alpha).
    func prewarmFirstRender() {
        guard !isVisible, !machine.isOpen else { return }
        let clock = PhaseClock()
        // Resolve the same collection scopes a real summon would (at the current cursor's
        // display), so the pass warms the exact enumeration path the first summon takes —
        // including the broadened scan's cold AX probes, which land here, invisibly at
        // launch, instead of inside the first real open (Bringr-3qp).
        let display = ScreenLocator.displayBounds(forCursor: NSEvent.mouseLocation)
        let collection = collectionProvider()
        guard let root = registry.makeMenu(
            for: .mouseChord,
            appsScope: collection.appsScope(forDisplay: display),
            windowsScope: collection.windowsScope(forDisplay: display)
        ) else { return }
        appearance = appearanceProvider()
        navigator.setBaseGeometry(appearance.geometry)
        navigator.open(appNodes: root.resolvedChildren())
        syncFromNavigator()
        clock.lap("resolve+open")
        let side = navigator.overallDiameter
        window.alphaValue = 0
        window.setFrame(
            NSRect(x: -side * 2, y: -side * 2, width: side, height: side), display: true
        )
        window.orderFrontRegardless()
        window.contentView?.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        clock.lap("first-draw")
        clock.report(to: Self.perfLog, label: "prewarm-render")
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.isVisible else { return }
            self.window.orderOut(nil)
            self.window.alphaValue = 1
            self.navigator.close()
            self.syncFromNavigator()
        }
    }

    /// Show the menu registered for `trigger` centred at `cursor` (the global mouse
    /// location). Resolves the tree fresh so the wheel reflects live state, and
    /// starts tracking the cursor so hover can drill into apps.
    private func summon(trigger: MenuTrigger, at cursor: CGPoint) {
        let clock = PhaseClock()
        // Resolve the persisted apps/windows collection scope (Bringr-93j.48) against the
        // display under the cursor; each level scopes screens/Spaces independently, and a
        // `nil` display (headless host) reduces to "all displays" rather than hiding all.
        let display = ScreenLocator.displayBounds(forCursor: cursor)
        let collection = collectionProvider()
        let appsScope = collection.appsScope(forDisplay: display)
        let windowsScope = collection.windowsScope(forDisplay: display)
        guard let root = registry.makeMenu(
            for: trigger, appsScope: appsScope, windowsScope: windowsScope
        ) else { return }
        clock.lap("scope+menu")
        // Apply the persisted appearance before resolving the tree: the size feeds
        // both the rendered rings and the navigator's hit-testing through one shared
        // geometry, so they stay in lock-step at any size (US-014 AC3).
        appearance = appearanceProvider()
        navigator.setBaseGeometry(appearance.geometry)
        // Apply the persisted skip-single-window-level option for this summon (Bringr-93j.75).
        navigator.setSkipSingleWindowLevel(appearance.skipSingleWindowLevel)
        // Apply the persisted reveal strategy for this summon too (US-013 AC4), so a
        // Preferences change takes effect on the next open without a relaunch.
        navigator.setRevealStrategy(strategyProvider())
        // Apply the persisted "leave only my selection on screen" setting for this summon
        // so a commit can clear everything else away (Bringr-93j.27).
        navigator.setHideOnCommitEnabled(hideOnCommitProvider())
        // Resolve the trackpad-haptic state once for this summon (Bringr-93j.44), like the
        // other read-fresh settings; the per-hover check then reads only this cheap state.
        haptics.resolveForSummon()
        // Resolve the optional keyboard-navigation settings for this summon (Bringr-93j.71), like
        // the other read-fresh settings; the live tap then consults `acceptsKeyboardNav`.
        keyboardConfig = KeyboardNavigationConfig.current()
        // Resolve dwell config once per summon (Bringr-93j.105), like the other read-fresh
        // settings, so the per-hover dwell logic reads frozen state.
        dwellConfig = dwellConfigProvider()
        highlightSource = .mouse
        clock.lap("settings")
        let appNodes = root.resolvedChildren()
        clock.lap("resolve-tree")
        navigator.open(appNodes: appNodes)
        syncFromNavigator()
        clock.lap("navigator-open")
        let side = navigator.overallDiameter
        let size = NSSize(width: side, height: side)
        let origin = RadialMenuPlacement.windowOrigin(forCursor: cursor, windowSize: size)
        window.setFrame(NSRect(origin: origin, size: size), display: false)
        // The invisible pre-render pass (`prewarmFirstRender`) leaves alpha at 0 until
        // its teardown tick; a summon landing inside that window must show at full alpha.
        window.alphaValue = 1
        window.orderFrontRegardless()
        isVisible = true
        startMenuMonitors()
        clock.lap("order-front")
        clock.report(to: Self.perfLog, label: "summon (\(appNodes.count) apps)")
        // The published rings render, and the frame reaches the screen, on the run
        // loop's next passes — so these two marks bracket the SwiftUI body + layout
        // and the first frame commit that the laps above cannot see.
        DispatchQueue.main.async {
            clock.lap("swiftui-render")
            CATransaction.setCompletionBlock {
                clock.lap("frame-commit")
                clock.report(to: Self.perfLog, label: "summon to first frame")
            }
        }
    }

    /// Timing log for the summon hot path, at `.info` so it persists in the unified
    /// log: `log show --info --predicate 'subsystem == "com.mekedron.PieSwitcher"'`.
    static let perfLog = Logger(subsystem: "com.mekedron.PieSwitcher", category: "summon-perf")

    /// Commit the slice under `region`: app slices activate the app, window slices
    /// raise and focus the chosen window, and both restore everything else to its
    /// pre-summon state (US-012). If `region` is not selectable, fall back to a
    /// cancel-restore. Either way the overlay goes away.
    private func commitSelection(region: HoverRegion) {
        SlowStep.measure("commit \(region)") { performCommit(region: region) }
    }

    private func performCommit(region: HoverRegion) {
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
        SlowStep.measure("dismiss-restore") { navigator.close() }
        hideOverlay()
    }

    /// Tear down the on-screen overlay and stop tracking the cursor, without
    /// touching window state — used after a commit, where the navigator has already
    /// restored and focused.
    func hideOverlay() {
        stopMenuMonitors()
        syncFromNavigator()
        window.orderOut(nil)
        isVisible = false
    }

    func syncFromNavigator() {
        rings = navigator.rings
        hovered = navigator.hovered
        prehighlighted = navigator.prehighlighted
        // Dwell rides every hover change (mouse hover, keyboard nav) — Bringr-93j.105.
        applyDwell(for: navigator.hovered)
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
        // The sub-wheel draws from the last Accessibility snapshot rather than blocking a hover
        // on IPC (Bringr-jud), so a first-ever hover onto an app can show fallback titles for a
        // frame or two. When the probe behind them lands, rebuild that ring in place.
        axStateObserver = NotificationCenter.default.addObserver(
            forName: AXWindowStateCache.didUpdateNotification, object: nil, queue: .main
        ) { [weak self] note in
            MainActor.assumeIsolated {
                guard let pid = note.userInfo?[AXWindowStateCache.pidUserInfoKey] as? pid_t else { return }
                self?.refreshSubWheel(forPID: pid)
            }
        }
    }

    /// Rebuild the open windows sub-wheel if it belongs to `pid`, so freshly probed titles
    /// replace the fallback labels without disturbing the hover, the reveal, or the fisheye.
    private func refreshSubWheel(forPID pid: pid_t) {
        guard isVisible, navigator.expandedAppID?.pid == pid else { return }
        navigator.refreshExpandedSubWheel()
        syncFromNavigator()
    }

    private func stopMenuMonitors() {
        subWheelRetry?.cancel()
        subWheelRetry = nil
        // Dwell rides the wheel — stop the timer so a stale fire can't commit into a
        // closed wheel (Bringr-93j.105).
        cancelDwell()
        for monitor in eventMonitors { monitorInstaller.remove(monitor) }
        eventMonitors.removeAll()
        if let spaceObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(spaceObserver)
        }
        spaceObserver = nil
        if let axStateObserver {
            NotificationCenter.default.removeObserver(axStateObserver)
        }
        axStateObserver = nil
    }

    /// Route a global key/mouse-down that bypassed the overlay to a cancel: Esc in
    /// either mode, or a click outside the wheel — which, after Bringr-93j.91 made
    /// click-to-activate always-on, cancels in either mode (a `click(over: .none)`
    /// resolves to `.cancel`).
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

    private func updateHover(forGlobalCursor cursor: CGPoint, isRetry: Bool = false) {
        let layoutOffset = offset(forGlobalCursor: cursor)
        let previousHover = navigator.hovered
        highlightSource = .mouse
        // Hover runs on the main thread while the activation tap is also served there, so an
        // overrun here is felt as the pointer sticking, not merely as a slow wheel — worth
        // naming in the log when it happens (Bringr-jud).
        SlowStep.measure("hover \(navigator.region(forOffset: layoutOffset))") {
            navigator.updateHover(navigator.region(forOffset: layoutOffset))
        }
        haptics.hoverChanged(from: previousHover, to: navigator.hovered)
        syncFromNavigator()
        scheduleSubWheelRetry(isRetry: isRetry)
    }

    /// Re-run a hover that landed on an app slice whose sub-wheel didn't open, so it
    /// shows even if the cursor holds still while the just-un-hidden app's windows
    /// settle into the live scan (Bringr-93j.31). Cursor motion refills the budget; a
    /// now-window-less app stops once it's spent. Cancelled on dismiss.
    private func scheduleSubWheelRetry(isRetry: Bool) {
        subWheelRetry?.cancel()
        subWheelRetry = nil
        if !isRetry { subWheelRetriesLeft = 6 }
        guard isVisible, subWheelRetriesLeft > 0,
              case .slice(level: 0, _) = navigator.hovered,
              !navigator.hasWindowSubWheel, !navigator.subWheelSuppressed else { return }
        subWheelRetriesLeft -= 1
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.isVisible else { return }
            self.updateHover(forGlobalCursor: NSEvent.mouseLocation, isRetry: true)
        }
        subWheelRetry = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.03, execute: work)
    }
}
