import AppKit
import SwiftUI

// MARK: - Capture field

/// The recordable shortcut control on its own: a button that renders the current value as
/// key caps, lights up while capturing, and hands back the recorded shortcut. It carries no
/// label and no surrounding actions, so a caller can place it in whatever row it needs —
/// the two-slot activation picker below, or the position-shortcut rows (Bringr-dk3), which
/// lead with an editable index instead of a fixed label.
///
/// The capture state machine lives in `capture`; live `NSEvent` monitoring runs only while
/// the field is in capture mode, so we never intercept user keystrokes outside the picker.
struct KeyboardShortcutCaptureField: View {
    let shortcut: KeyboardShortcut?
    let placeholder: String
    let onCommit: (KeyboardShortcut) -> Void
    /// Minimum width of the key-cap area, so rows of slots line up whatever they hold.
    var minWidth: CGFloat = 220
    /// Fires whenever capture starts or ends, so a caller can hide its own trailing
    /// controls while the field is listening — the capture machine's state lives here, and
    /// a parent that re-derived it from the committed value would lag a keystroke behind.
    var onCaptureStateChange: (Bool) -> Void = { _ in }
    /// Whether a modifiers-only shortcut is refused for this field. See
    /// `KeyboardShortcutCaptureMachine.requiresNonModifierKey`.
    var requiresNonModifierKey = false

    @State private var capture = KeyboardShortcutCaptureMachine()
    @State private var liveSnapshot: HeldKeys?
    @State private var monitorToken: Any?
    /// This field's registration in `ShortcutCaptureSession`, stable for the field's
    /// lifetime so begin/end always refer to the same entry.
    @State private var sessionToken = UUID()
    /// Set once a shortcut has been settled but its keys are still down. See `handle(event:)`.
    @State private var isDrainingRelease = false

    /// Whether a capture is in flight, so a caller can swap its own trailing controls for a
    /// Cancel button while the field is listening.
    var isCapturing: Bool { capture.isCapturing }

    private var capturedShortcut: KeyboardShortcut? {
        liveSnapshot.flatMap(KeyboardShortcutFromHeld.make)
    }

    var body: some View {
        HStack(spacing: 8) {
            Button(action: enterCaptureMode) {
                slotContent
            }
            .buttonStyle(.plain)
            .frame(minWidth: minWidth, alignment: .leading)
            .help(capture.isCapturing ? "Press a shortcut" : "Click to record a new shortcut")

            if capture.isCapturing {
                Button("Cancel", action: cancelCapture)
                    .buttonStyle(.borderless)
            }
        }
        // Closing Preferences mid-capture must not leave the taps disarmed.
        .onDisappear { finishCapture() }
    }

    private var slotContent: some View {
        let labels = capture.isCapturing
            ? (capturedShortcut?.capLabels ?? [])
            : (shortcut?.capLabels ?? [])
        let isEmpty = labels.isEmpty
        return HStack(spacing: 6) {
            if isEmpty {
                Text(capture.isCapturing ? capturePrompt : placeholder)
                    .foregroundStyle(.secondary)
                    .italic(capture.isCapturing)
            } else {
                ForEach(Array(labels.enumerated()), id: \.offset) { _, text in
                    KeyCapBadge(text: text)
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(capture.isCapturing
                      ? Color.accentColor.opacity(0.18)
                      : Color.secondary.opacity(0.10))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(
                    capture.isCapturing ? Color.accentColor : Color.clear,
                    lineWidth: 1.5
                )
        )
    }

    /// What the empty slot says while listening. A refused modifiers-only attempt names the
    /// missing half outright, since "Press a shortcut…" is what the user thinks they just did.
    private var capturePrompt: String {
        capture.rejectedModifierOnly ? "Also press a key — ⌥, ⌘… alone won't do" : "Press a shortcut…"
    }

    // MARK: - Capture lifecycle

    private func enterCaptureMode() {
        guard !capture.isCapturing else { return }
        capture = KeyboardShortcutCaptureMachine(requiresNonModifierKey: requiresNonModifierKey)
        capture.start()
        liveSnapshot = nil
        startMonitoring()
        // Disarm every global shortcut tap for the duration, so the keys being recorded act
        // on this field and nothing else.
        ShortcutCaptureSession.begin(sessionToken)
        onCaptureStateChange(true)
    }

    private func cancelCapture() {
        capture.cancel()
        finishCapture()
        onCaptureStateChange(false)
    }

    /// Let go of the keyboard: stop listening and re-arm the global taps. Called once the
    /// user's fingers are actually off the keys, never merely once a value has been settled.
    private func finishCapture() {
        isDrainingRelease = false
        liveSnapshot = nil
        stopMonitoring()
        endCaptureSession()
    }

    private func endCaptureSession() {
        ShortcutCaptureSession.end(sessionToken)
    }

    private func startMonitoring() {
        stopMonitoring()
        let monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp, .flagsChanged]) { event in
            handle(event: event)
        }
        monitorToken = monitor
    }

    private func stopMonitoring() {
        if let monitorToken {
            NSEvent.removeMonitor(monitorToken)
        }
        monitorToken = nil
    }

    /// Returns the event unchanged when we want it to keep flowing (e.g. so the picker
    /// can still receive a click outside), or `nil` to consume it (so a real keystroke
    /// during capture doesn't trigger a menu command in Preferences).
    private func handle(event: NSEvent) -> NSEvent? {
        // Escape always cancels and stops the monitor. We swallow it so Preferences
        // doesn't close from the same key press.
        if event.type == .keyDown, event.keyCode == 53 { // 53 = kVK_Escape
            capture.handleEscape()
            finishCapture()
            onCaptureStateChange(false)
            return nil
        }
        let held = currentHeldKeys(after: event)

        // A combination settles the moment its key goes down, which leaves its keys still
        // held. Keep consuming until the keyboard is quiet: otherwise the trailing releases
        // reach whatever is behind Preferences, and re-arming the global taps while the
        // just-recorded keys are down would let them fire the very shortcut being edited.
        if isDrainingRelease {
            liveSnapshot = held
            if held.modifiers.isEmpty, held.nonModifierKey == nil { finishCapture() }
            return nil
        }

        capture.update(held: held)
        if let snap = capture.snapshot {
            liveSnapshot = snap
        }
        if case .committed = capture.state, let committed = capture.take() {
            // The machine already refuses a modifiers-only release for such a field; the
            // second check keeps the rule where the value is produced, so no future caller
            // can commit one past it.
            if let shortcut = KeyboardShortcutFromHeld.make(from: committed),
               !requiresNonModifierKey || shortcut.hasNonModifierKey {
                onCommit(shortcut)
            }
            onCaptureStateChange(false)
            if held.modifiers.isEmpty, held.nonModifierKey == nil {
                finishCapture()
            } else {
                isDrainingRelease = true
                liveSnapshot = held
            }
        }
        return nil
    }

    /// Build a `HeldKeys` from the current `NSEvent`. Modifier flags carry the live
    /// modifier set including the device-dependent left/right bits; the non-modifier
    /// key is the event's key code only on keyDown (and reset on keyUp).
    private func currentHeldKeys(after event: NSEvent) -> HeldKeys {
        let cgFlags = event.cgEvent?.flags ?? CGEventFlags(rawValue: UInt64(event.modifierFlags.rawValue))
        let modifiers = SidedModifierParser.modifiers(from: cgFlags)
        var nonModifier: Int? = liveSnapshot?.nonModifierKey
        switch event.type {
        case .keyDown:
            nonModifier = Int(event.keyCode)
        case .keyUp:
            // Only clear the non-modifier key if the released key matches what we were
            // tracking — releasing a different key shouldn't blank out the snapshot.
            if Int(event.keyCode) == nonModifier { nonModifier = nil }
        case .flagsChanged:
            // Modifiers changed; the non-modifier key (if any) stays the same.
            break
        default:
            break
        }
        return HeldKeys(modifiers: modifiers, nonModifierKey: nonModifier)
    }
}

// MARK: - Slot picker

/// One labelled shortcut-slot row in the activation picker (Bringr-93j.111): a fixed-width
/// label, the capture field, and the row's Reset / Clear actions. The actions hide while the
/// field is capturing, so the row reads as "press a shortcut" and nothing else.
struct KeyboardShortcutSlotView: View {
    let label: String
    let shortcut: KeyboardShortcut?
    let placeholder: String
    let onCommit: (KeyboardShortcut) -> Void
    /// If non-nil, a Clear button is shown that fires this callback. `nil` hides the
    /// button — used for the secondary slot's "Remove" action vs the primary's reset.
    let onClear: (() -> Void)?
    /// If non-nil, a Reset button is shown that fires this callback. Used by Shortcut 1
    /// to restore the fresh-install default (Right Command since Bringr-93j.113;
    /// pre-93j.113 it was Right Option).
    let onReset: (() -> Void)?

    @State private var isCapturing = false

    var body: some View {
        HStack(spacing: 12) {
            Text(label)
                .frame(width: 90, alignment: .leading)

            KeyboardShortcutCaptureField(
                shortcut: shortcut,
                placeholder: placeholder,
                onCommit: onCommit,
                onCaptureStateChange: { isCapturing = $0 }
            )

            Spacer()

            if !isCapturing {
                if let onReset {
                    Button("Reset", action: onReset)
                        .buttonStyle(.borderless)
                }
                if let onClear {
                    Button {
                        onClear()
                    } label: {
                        Image(systemName: "minus.circle")
                            .imageScale(.medium)
                    }
                    .buttonStyle(.borderless)
                    .help("Remove this shortcut")
                }
            }
        }
    }
}

// MARK: - Key cap

/// One key-cap pill rendered next to its siblings. Compact glyph treatment so a full
/// shortcut like "Right Option + Right Shift + K" stays readable in a Preferences row.
struct KeyCapBadge: View {
    let text: String
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Text(text)
            .font(.system(size: 12, weight: .semibold, design: .rounded))
            .foregroundStyle(colorScheme == .dark ? Color.white : Color.black)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(
                RoundedRectangle(cornerRadius: 4)
                    .fill(colorScheme == .dark
                          ? Color.white.opacity(0.15)
                          : Color.white)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 4)
                    .strokeBorder(Color.secondary.opacity(0.4), lineWidth: 0.5)
            )
    }
}
