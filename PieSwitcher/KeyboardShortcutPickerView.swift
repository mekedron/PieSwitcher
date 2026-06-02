import AppKit
import SwiftUI

// MARK: - Slot picker

/// One shortcut-slot row in the Preferences picker (Bringr-93j.111). Renders the current
/// value as key caps, lights up while capturing, and exposes Clear / "Add second" actions
/// to the caller. The capture state machine lives in `state`; live `NSEvent` monitoring
/// runs only while the slot is in capture mode so we never intercept user keystrokes
/// outside the picker.
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

    @State private var capture = KeyboardShortcutCaptureMachine()
    @State private var liveSnapshot: HeldKeys?
    @State private var monitorToken: Any?

    private var capturedShortcut: KeyboardShortcut? {
        liveSnapshot.flatMap(KeyboardShortcutFromHeld.make)
    }

    var body: some View {
        HStack(spacing: 12) {
            Text(label)
                .frame(width: 90, alignment: .leading)

            Button(action: enterCaptureMode) {
                slotContent
            }
            .buttonStyle(.plain)
            .frame(minWidth: 220, alignment: .leading)
            .help(capture.isCapturing ? "Press a shortcut" : "Click to record a new shortcut")

            Spacer()

            if capture.isCapturing {
                Button("Cancel", action: cancelCapture)
                    .buttonStyle(.borderless)
            } else {
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
        .onDisappear { stopMonitoring() }
    }

    private var slotContent: some View {
        let labels = capture.isCapturing
            ? (capturedShortcut?.capLabels ?? [])
            : (shortcut?.capLabels ?? [])
        let isEmpty = labels.isEmpty
        return HStack(spacing: 6) {
            if isEmpty {
                Text(capture.isCapturing ? "Press a shortcut…" : placeholder)
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

    // MARK: - Capture lifecycle

    private func enterCaptureMode() {
        guard !capture.isCapturing else { return }
        capture = KeyboardShortcutCaptureMachine()
        capture.start()
        liveSnapshot = nil
        startMonitoring()
    }

    private func cancelCapture() {
        capture.cancel()
        liveSnapshot = nil
        stopMonitoring()
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
            liveSnapshot = nil
            stopMonitoring()
            return nil
        }
        let held = currentHeldKeys(after: event)
        capture.update(held: held)
        if let snap = capture.snapshot {
            liveSnapshot = snap
        }
        if case .committed = capture.state, let committed = capture.take() {
            if let shortcut = KeyboardShortcutFromHeld.make(from: committed) {
                onCommit(shortcut)
            }
            liveSnapshot = nil
            stopMonitoring()
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

// MARK: - Two-slot block

/// The shortcut block shown in the Keyboard Activation pane. Owns the two
/// `@AppStorage` Data slots, applies migration on appear (defence in depth so an
/// upgrader who heads straight to Preferences still gets the new defaults), and
/// surfaces the one-time migration notice (AC: "a one-time in-app notice").
struct KeyboardShortcutPicker: View {
    @AppStorage(KeyboardShortcutStore.slot1Key)
    private var slot1Data: Data?
    @AppStorage(KeyboardShortcutStore.slot2Key)
    private var slot2Data: Data?
    @AppStorage(KeyboardShortcutStore.initialisedKey)
    private var initialised = false
    @State private var showsAddSecond = false
    @State private var migrationNotice: String?

    private var slot1: KeyboardShortcut? { decode(slot1Data) }
    private var slot2: KeyboardShortcut? { decode(slot2Data) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            KeyboardShortcutSlotView(
                label: "Shortcut 1",
                shortcut: slot1,
                placeholder: "Not set",
                onCommit: { write(.slot1, $0) },
                onClear: slot1 == nil ? nil : { write(.slot1, nil) },
                onReset: { write(.slot1, KeyboardShortcutStore.freshInstallSlot1) }
            )

            if slot2 != nil || showsAddSecond {
                KeyboardShortcutSlotView(
                    label: "Shortcut 2",
                    shortcut: slot2,
                    placeholder: "Not set",
                    onCommit: { write(.slot2, $0) },
                    onClear: {
                        write(.slot2, nil)
                        showsAddSecond = false
                    },
                    onReset: nil
                )
            } else {
                Button {
                    showsAddSecond = true
                } label: {
                    Label("Add second shortcut", systemImage: "plus.circle")
                }
                .buttonStyle(.borderless)
            }

            if let notice = migrationNotice {
                migrationBanner(notice)
            }
        }
        .onAppear {
            KeyboardShortcutStore.runMigrationIfNeeded()
            migrationNotice = KeyboardShortcutStore.consumeMigrationNotice()
            // If the migration left an explicit Shortcut 2, reveal it now.
            showsAddSecond = slot2 != nil
        }
    }

    private func migrationBanner(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "info.circle.fill")
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 4) {
                Text(text)
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Got it") { migrationNotice = nil }
                    .buttonStyle(.borderless)
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.accentColor.opacity(0.10))
        )
    }

    // MARK: - Persistence helpers

    private enum SlotID { case slot1, slot2 }

    private func write(_ slot: SlotID, _ shortcut: KeyboardShortcut?) {
        switch slot {
        case .slot1: KeyboardShortcutStore.setSlot1(shortcut)
        case .slot2: KeyboardShortcutStore.setSlot2(shortcut)
        }
        // `@AppStorage` reads the underlying defaults on the next render — nudge it.
        if !initialised { initialised = true }
    }

    private func decode(_ data: Data?) -> KeyboardShortcut? {
        guard let data else { return nil }
        struct Box: Codable { let value: KeyboardShortcut? }
        return (try? JSONDecoder().decode(Box.self, from: data))?.value
    }
}
