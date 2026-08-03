import AppKit
import SwiftUI

// MARK: - Visibility setting

/// Whether the hold-delay progress ring is drawn at all (Bringr-dp3). The ring is
/// pure feedback — the hold still works with it off — so users who find it noisy on
/// top of the UI under the cursor can switch it off without touching their delays.
///
/// Read fresh each time a hold arms, like the other settings, so a Preferences change
/// applies on the next press without a relaunch.
enum HoldProgressVisibility {
    /// `UserDefaults` key backing the toggle. Single source of truth shared by the
    /// Preferences `@AppStorage` and the reader so they cannot drift.
    static let defaultsKey = "appearance.showsHoldProgress"

    /// Shown by default: the ring is the only cue that a hold is being counted, so a
    /// fresh install explains its own delay.
    static let defaultShowsHoldProgress = true

    /// Whether the ring should be shown. An absent key yields the default —
    /// `bool(forKey:)` alone returns `false` for a missing key, which would hide the
    /// ring for everyone who never opened Preferences.
    static func isEnabled(from defaults: UserDefaults = .standard) -> Bool {
        guard defaults.object(forKey: defaultsKey) != nil else { return defaultShowsHoldProgress }
        return defaults.bool(forKey: defaultsKey)
    }
}

// MARK: - Window

/// Tiny transparent overlay that hosts the hold-delay progress circle
/// (Bringr-93j.103). Pre-warmed at launch (like `RadialMenuWindow`) so a hold
/// never allocates it on the hot path — show, animate, hide.
///
/// Click-through (`ignoresMouseEvents = true`): the indicator is purely visual
/// confirmation of how much longer the user has to hold; it must NOT intercept
/// the very mouse events whose delay it's visualising.
final class HoldProgressWindow: NSPanel {
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
        ignoresMouseEvents = true
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
    }

    /// Match `RadialMenuWindow`: don't let AppKit shove the frame back inside
    /// the visible screen rect. The indicator is small and harmless past an
    /// edge; what matters is that it stays centred on the cursor.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        frameRect
    }
}

// MARK: - View

/// The progress circle itself, animated by SwiftUI's implicit animation system
/// (`withAnimation(.linear(duration:))` on the controller's `progress` value).
/// Drawn over a thin track ring so the user can read "how full" at a glance
/// even at low progress.
struct HoldProgressView: View {
    @ObservedObject var controller: HoldProgressController

    var body: some View {
        ZStack {
            Circle()
                .stroke(Color.primary.opacity(0.18), lineWidth: HoldProgressController.lineWidth)
            Circle()
                .trim(from: 0, to: controller.progress)
                .stroke(
                    Color.accentColor.opacity(0.95),
                    style: StrokeStyle(lineWidth: HoldProgressController.lineWidth, lineCap: .round)
                )
                .rotationEffect(.degrees(-90))
        }
        .padding(HoldProgressController.lineWidth / 2 + 1)
        .shadow(color: .black.opacity(0.35), radius: 2, y: 0.5)
    }
}

// MARK: - Controller

/// Owns the pre-warmed progress window and drives the fill animation while a
/// hold-delay timer is running (Bringr-93j.103). The mouse and modifier monitors
/// both call `start(duration:)` when their timers arm and `cancel()` when they
/// cancel or complete, so the same visual lights up for both triggers.
@MainActor
final class HoldProgressController: ObservableObject {
    /// `0.0` → `1.0`, animated to 1.0 over the hold delay so the ring fills
    /// in lock-step with the timer. Read by `HoldProgressView`.
    @Published private(set) var progress: Double = 0

    /// Diameter of the indicator window, in points. Big enough to be obviously
    /// "around the cursor" without looking like a target reticle on top of fine
    /// UI underneath.
    static let diameter: CGFloat = 56
    /// Ring stroke width. Matches the visual weight of the wheel's hover rim
    /// so it reads as the same family of cue.
    static let lineWidth: CGFloat = 4

    private let window: HoldProgressWindow

    init() {
        window = HoldProgressWindow(
            contentSize: CGSize(width: Self.diameter, height: Self.diameter)
        )
        window.contentView = NSHostingView(rootView: HoldProgressView(controller: self))
    }

    /// Show the ring centred on the current cursor and animate it from empty
    /// to full over `duration`. A zero or negative duration is a no-op — the
    /// indicator only makes sense when the user actually has to wait — and so is
    /// a hold when the ring is switched off in Preferences (Bringr-dp3).
    func start(duration: TimeInterval) {
        guard duration > 0, HoldProgressVisibility.isEnabled() else { return }
        // The ring must read as "this much of your hold is left", so it is anchored to when
        // the hold actually began, not to when the animation gets to run. Showing the window
        // and committing the first frame costs real time; at a 100 ms delay that is a large
        // share of the whole fill, and an animation started with the full duration from there
        // would still be short of the rim when the summon fires (Bringr-jud).
        let deadline = CFAbsoluteTimeGetCurrent() + duration
        // Snap to empty immediately, without animation, so a quick re-trigger
        // (release + re-press) doesn't show a half-filled stale state for the
        // first frame.
        progress = 0

        let cursor = NSEvent.mouseLocation
        let half = Self.diameter / 2
        let frame = NSRect(
            x: cursor.x - half,
            y: cursor.y - half,
            width: Self.diameter,
            height: Self.diameter
        )
        window.setFrame(frame, display: false)
        window.orderFrontRegardless()

        // Begin on the next pass, once the window is on screen, and start from however much
        // of the hold has already gone by — so whatever the show cost, the fill still tracks
        // the hold rather than lagging behind it by that cost.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let remaining = deadline - CFAbsoluteTimeGetCurrent()
            guard remaining > 0 else {
                self.progress = 1
                return
            }
            // The snap must not be swept into the fill: assigned plainly, SwiftUI merges both
            // changes into one transaction and animates from where the ring was, which is the
            // very lag being corrected for.
            var immediate = Transaction()
            immediate.disablesAnimations = true
            withTransaction(immediate) { self.progress = 1 - remaining / duration }
            // Close the ring a moment before the hold completes. Filling to the rim at exactly
            // the deadline means the closed circle is drawn in the same instant it is taken
            // away, so the user only ever sees an arc that stopped short — which reads as the
            // ring failing to keep up. Arriving early leaves the completed ring on screen long
            // enough to be seen, and "full, therefore firing" is what the cue is for.
            let margin = min(Self.completionMargin, remaining * 0.2)
            // SwiftUI's implicit animation runtime fills the ring smoothly over the time that
            // is left, without us managing a display link or per-frame timer.
            withAnimation(.linear(duration: remaining - margin)) {
                self.progress = 1.0
            }
            // What the ring was actually asked to do, so "it never reaches the rim" can be
            // checked against the numbers of a real hold rather than re-guessed.
            let startedAt = String(format: "%.2f", 1 - remaining / duration)
            let fill = String(format: "%.0f", (remaining - margin) * 1000)
            let full = String(format: "%.0f", margin * 1000)
            RadialMenuController.perfLog.info("""
                hold ring: starts at \(startedAt, privacy: .public), fills over \
                \(fill, privacy: .public)ms, stands full \(full, privacy: .public)ms
                """)
        }
    }

    /// How long the ring stands full before the hold fires. Long enough to register as a
    /// completed circle, short enough that it still reads as the end of the hold rather than
    /// as a pause.
    private static let completionMargin: TimeInterval = 0.08

    /// Draw the ring once, invisibly, so the first real hold doesn't spend its budget building
    /// the SwiftUI host. Mirrors the wheel's launch pre-render: order in off-screen and fully
    /// transparent, force a draw, tear back down on the next tick.
    func prewarm() {
        window.alphaValue = 0
        window.setFrame(
            NSRect(x: -Self.diameter * 4, y: -Self.diameter * 4,
                   width: Self.diameter, height: Self.diameter),
            display: true
        )
        window.orderFrontRegardless()
        window.contentView?.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.window.orderOut(nil)
            self.window.alphaValue = 1
        }
    }

    /// Hide the indicator and reset progress to 0. Safe to call when already
    /// hidden — `orderOut` and a no-op assignment.
    func cancel() {
        window.orderOut(nil)
        progress = 0
    }
}
