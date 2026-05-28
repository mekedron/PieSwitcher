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
    }
}

/// Owns the pre-warmed overlay window and resolves the menu tree for each summon.
///
/// The window and its SwiftUI host are built once in `init` (the pre-warm); a
/// summon only resolves the live tree, repositions the window at the cursor, and
/// orders it in — no allocation on the hot path. `slices` is published so the
/// pre-built `RadialMenuView` re-renders when a new summon swaps the contents.
///
/// All open/select/cancel decisions are delegated to a pure `InteractionStateMachine`
/// (US-009): the controller only translates live triggers/clicks into machine inputs
/// and performs the side effects the machine asks for.
@MainActor
final class RadialMenuController: ObservableObject {
    /// The resolved top-level nodes shown as slices for the current summon.
    @Published private(set) var slices: [MenuNode] = []
    /// Whether the overlay is currently on screen.
    @Published private(set) var isVisible = false

    let geometry: RadialGeometry

    private let registry: MenuRegistry
    private let window: RadialMenuWindow
    private var machine = InteractionStateMachine()
    /// Reads the persisted interaction mode at summon time so a Preferences change
    /// takes effect on the next summon without a relaunch (AC3).
    private let modeProvider: () -> InteractionMode

    init(
        registry: MenuRegistry,
        geometry: RadialGeometry = .default,
        modeProvider: @escaping () -> InteractionMode = { InteractionMode.current() }
    ) {
        self.registry = registry
        self.geometry = geometry
        self.modeProvider = modeProvider
        self.window = RadialMenuWindow(
            contentSize: CGSize(width: geometry.diameter, height: geometry.diameter)
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
        route(machine.handle(.triggerReleased(over: target(forGlobalCursor: cursor))))
    }

    /// A click inside the overlay. In click-to-stay this selects the slice under the
    /// cursor, or cancels on a dead-zone/outside click; in hold-to-select it is ignored.
    func clickInOverlay(atLocalPoint local: CGPoint) {
        route(machine.handle(.click(over: target(forLocalPoint: local))))
    }

    private func press(trigger: MenuTrigger, mode: InteractionMode, at cursor: CGPoint) {
        if !machine.isOpen { machine.mode = mode }
        switch machine.handle(.triggerPressed) {
        case .open: summon(trigger: trigger, at: cursor)
        case .cancel: cancelInteraction()
        case .none, .select: break
        }
    }

    private func route(_ outcome: InteractionOutcome) {
        switch outcome {
        case .select(let index): commitSelection(at: index)
        case .cancel: cancelInteraction()
        case .none, .open: break
        }
    }

    // MARK: - Side effects

    /// Show the menu registered for `trigger` centred at `cursor` (the global mouse
    /// location). Resolves the tree fresh so the wheel reflects live state.
    private func summon(trigger: MenuTrigger, at cursor: CGPoint) {
        guard let root = registry.makeMenu(for: trigger) else { return }
        slices = root.resolvedChildren()
        let origin = RadialMenuPlacement.windowOrigin(forCursor: cursor, windowSize: window.frame.size)
        window.setFrameOrigin(origin)
        window.orderFrontRegardless()
        isVisible = true
    }

    /// Commit the slice at `index`. v1 just closes the wheel; US-010 (expand to a
    /// sub-wheel) and US-012 (focus the window + remember it) act on the selected
    /// node here.
    private func commitSelection(at index: Int) {
        _ = index
        dismiss()
    }

    /// Cancel the interaction. v1 just closes the wheel; US-015 restores the
    /// pre-summon window state here.
    private func cancelInteraction() {
        dismiss()
    }

    /// Hide the overlay.
    private func dismiss() {
        window.orderOut(nil)
        isVisible = false
    }

    // MARK: - Cursor → target resolution

    /// Resolve a global (AppKit y-up) cursor into the slice it falls in, flipping to
    /// the layout's y-down space relative to the window centre.
    private func target(forGlobalCursor cursor: CGPoint) -> SliceTarget {
        let frame = window.frame
        let offset = CGPoint(x: cursor.x - frame.midX, y: frame.midY - cursor.y)
        return target(forOffset: offset)
    }

    /// Resolve a point in the overlay view's local (y-down, top-left origin) space
    /// into the slice it falls in, relative to the ring centre.
    private func target(forLocalPoint local: CGPoint) -> SliceTarget {
        let center = geometry.diameter / 2
        let offset = CGPoint(x: local.x - center, y: local.y - center)
        return target(forOffset: offset)
    }

    private func target(forOffset offset: CGPoint) -> SliceTarget {
        let layout = RadialLayout(itemCount: slices.count, geometry: geometry)
        if let index = layout.hitTest(offset) { return .slice(index) }
        return .none
    }
}
