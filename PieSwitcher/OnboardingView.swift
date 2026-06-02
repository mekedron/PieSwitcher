import AppKit
import SwiftUI

// MARK: - Screen identifier

/// The two screens of the onboarding flow (Bringr-93j.112). Screen 1 is the
/// activation-shortcut setup and "try it" confirmation; screen 2 is the
/// mouse-button hint tailored to the user's hardware. `back`/`next` navigation
/// is part of the parent view's state, not a navigation stack — the flow is
/// strictly linear and there are only two screens, so a switch is simpler.
enum OnboardingScreen: Hashable {
    case shortcut
    case mouseHint
}

// MARK: - Root

/// Root SwiftUI view for the onboarding window (Bringr-93j.112). Lays out the
/// two pages and the navigation controls; each screen pulls from the same
/// `@AppStorage` slots and `KeyboardShortcutStore` the Preferences picker uses,
/// so any change made here applies on the next summon just like changes from
/// Preferences.
struct OnboardingRootView: View {
    @ObservedObject var permissions: PermissionsManager
    /// Called when the user clicks "Done" or the close button. The presenter
    /// uses this to dismiss the window and mark onboarding as completed.
    let onFinish: () -> Void

    @State private var screen: OnboardingScreen = .shortcut
    /// Detection variant for screen 2. Snapshotted the moment screen 2 first
    /// appears so an unplug while it's open doesn't live-update (AC: "Plugging
    /// in or unplugging an external mouse while screen 2 is open does NOT have
    /// to live-update the text").
    @State private var mouseVariant: OnboardingMouseVariant?

    var body: some View {
        VStack(spacing: 0) {
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider()

            footer
                .padding(.horizontal, 28)
                .padding(.vertical, 14)
        }
        .frame(minWidth: 560, idealWidth: 600, minHeight: 520, idealHeight: 560)
    }

    @ViewBuilder
    private var content: some View {
        switch screen {
        case .shortcut:
            OnboardingShortcutScreen(permissions: permissions)
        case .mouseHint:
            OnboardingMouseHintScreen(variant: mouseVariant ?? .generic)
                .onAppear {
                    if mouseVariant == nil {
                        mouseVariant = OnboardingMouseDetector.detectLive()
                    }
                }
        }
    }

    @ViewBuilder
    private var footer: some View {
        HStack {
            if screen == .mouseHint {
                Button {
                    screen = .shortcut
                } label: {
                    Label("Back", systemImage: "chevron.left")
                }
                .buttonStyle(.bordered)
            }

            Spacer()

            switch screen {
            case .shortcut:
                Button("Next") {
                    screen = .mouseHint
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            case .mouseHint:
                Button("Done") {
                    onFinish()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
        }
    }
}

// MARK: - Screen 1

/// Screen 1: the activation-shortcut setup with the embedded picker, a row of
/// suggestion chips, and a "Try it" prompt. Reuses `KeyboardShortcutSlotView`
/// directly so the picker behavior is identical to Preferences (single source
/// of truth — AC).
struct OnboardingShortcutScreen: View {
    @ObservedObject var permissions: PermissionsManager
    @AppStorage(KeyboardShortcutStore.slot1Key)
    private var slot1Data: Data?

    private var slot1: KeyboardShortcut? { decode(slot1Data) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                header

                shortcutCard

                suggestionsCard

                tryItCard
            }
            .padding(.horizontal, 28)
            .padding(.vertical, 24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Welcome to PieSwitcher")
                .font(.largeTitle.bold())
            Text("Summon a wheel of your open windows from anywhere.")
                .font(.title3)
                .foregroundStyle(.secondary)
        }
    }

    private var shortcutCard: some View {
        OnboardingCard {
            VStack(alignment: .leading, spacing: 12) {
                Text("Your activation shortcut")
                    .font(.headline)

                HStack(spacing: 12) {
                    Text("Current:")
                        .foregroundStyle(.secondary)
                    if let slot1, !slot1.isEmpty {
                        HStack(spacing: 6) {
                            ForEach(Array(slot1.capLabels.enumerated()), id: \.offset) { _, text in
                                KeyCapBadge(text: text)
                            }
                        }
                    } else {
                        Text("Not set")
                            .foregroundStyle(.secondary)
                            .italic()
                    }
                }

                KeyboardShortcutSlotView(
                    label: "Shortcut",
                    shortcut: slot1,
                    placeholder: "Click to record",
                    onCommit: { KeyboardShortcutStore.setSlot1($0) },
                    onClear: slot1 == nil ? nil : { KeyboardShortcutStore.setSlot1(nil) },
                    onReset: { KeyboardShortcutStore.setSlot1(KeyboardShortcutStore.freshInstallSlot1) }
                )
                .padding(.top, 4)
            }
        }
    }

    private var suggestionsCard: some View {
        OnboardingCard {
            VStack(alignment: .leading, spacing: 12) {
                Text("Suggestions")
                    .font(.headline)
                Text("Tap a suggestion to use it as your shortcut.")
                    .font(.callout)
                    .foregroundStyle(.secondary)

                HStack(spacing: 10) {
                    ForEach(OnboardingShortcutSuggestion.all, id: \.id) { suggestion in
                        OnboardingSuggestionChip(
                            suggestion: suggestion,
                            isActive: suggestion.matches(slot1)
                        ) {
                            KeyboardShortcutStore.setSlot1(suggestion.shortcut)
                        }
                    }
                    Spacer(minLength: 0)
                }
            }
        }
    }

    private var tryItCard: some View {
        OnboardingCard {
            VStack(alignment: .leading, spacing: 10) {
                Label("Try it now", systemImage: "hand.point.up.left.fill")
                    .font(.headline)
                if let slot1, !slot1.isEmpty {
                    Text("Hold \(slot1.displayName) anywhere on screen to summon the wheel.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    Text("Set a shortcut above, then hold it anywhere on screen to summon the wheel.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if !permissions.isTrusted {
                    permissionWarning
                }
            }
        }
    }

    private var permissionWarning: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 6) {
                Text("Accessibility access is required")
                    .font(.subheadline.bold())
                Text("PieSwitcher needs Accessibility access to read your shortcut and switch windows.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Open System Settings") {
                    permissions.openAccessibilitySettings()
                }
                .buttonStyle(.bordered)
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.orange.opacity(0.10))
        )
    }

    private func decode(_ data: Data?) -> KeyboardShortcut? {
        guard let data else { return nil }
        struct Box: Codable { let value: KeyboardShortcut? }
        return (try? JSONDecoder().decode(Box.self, from: data))?.value
    }
}

// MARK: - Screen 2

/// Screen 2: the mouse-button hint. The copy adapts to whether a non-Apple
/// external mouse is plugged in at the moment the screen first appears (AC).
struct OnboardingMouseHintScreen: View {
    let variant: OnboardingMouseVariant

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                header

                explanationCard

                whereToConfigureCard
            }
            .padding(.horizontal, 28)
            .padding(.vertical, 24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(headline)
                .font(.largeTitle.bold())
                .fixedSize(horizontal: false, vertical: true)
            Text("PieSwitcher can also be summoned by a mouse button.")
                .font(.title3)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var headline: String {
        switch variant {
        case .externalNonAppleMouse: return "Got a mouse?"
        case .generic: return "More ways to summon"
        }
    }

    private var explanationCard: some View {
        OnboardingCard {
            VStack(alignment: .leading, spacing: 10) {
                Image(systemName: "computermouse.fill")
                    .font(.system(size: 32))
                    .foregroundStyle(.tint)
                Text(explanation)
                    .font(.callout)
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var explanation: String {
        switch variant {
        case .externalNonAppleMouse:
            return "Looks like you have an external mouse — you can summon the pie menu "
                + "with a mouse button too. The default is Left + Right click together, "
                + "but Middle click, Forward, Backward, or any combination work and "
                + "leave the other buttons free for their normal use."
        case .generic:
            return "If you ever connect a mouse with extra buttons, you can summon the "
                + "pie menu with one of them too. The default mouse trigger is Left + "
                + "Right click together; Middle click, Forward, Backward, and combinations "
                + "are also available."
        }
    }

    private var whereToConfigureCard: some View {
        OnboardingCard {
            VStack(alignment: .leading, spacing: 8) {
                Label("Where to configure it", systemImage: "gearshape")
                    .font(.headline)
                Text("Open Preferences → Activation → Mouse to pick a button and tune the hold delay.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

#Preview("Onboarding") {
    OnboardingRootView(
        permissions: PermissionsManager(probe: { true }),
        onFinish: {}
    )
}
