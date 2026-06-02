import SwiftUI

// MARK: - Suggestion

/// One suggested shortcut shown as a chip on the onboarding screen 1
/// (Bringr-93j.112). The `shortcut` is the canonical persisted value; the
/// `id`/`label` exist so SwiftUI can render the row without re-deriving labels
/// from the shortcut on every redraw.
struct OnboardingShortcutSuggestion: Hashable {
    let id: String
    let label: String
    let shortcut: KeyboardShortcut

    /// True when this suggestion matches the user's current Shortcut 1 closely
    /// enough that the chip should highlight: same modifier family + side and
    /// no extra non-modifier key.
    func matches(_ slot: KeyboardShortcut?) -> Bool {
        guard let slot, slot.keyCode == nil else { return false }
        return slot.modifiers == shortcut.modifiers
    }

    /// The fixed suggestion list shown on screen 1. Order matters — left to
    /// right is the order the chips render.
    static let all: [OnboardingShortcutSuggestion] = [
        OnboardingShortcutSuggestion(
            id: "right-option",
            label: "Right Option",
            shortcut: KeyboardShortcut(
                modifiers: [SidedModifier(.option, .right)],
                keyCode: nil,
                sideAgnostic: false
            )
        ),
        OnboardingShortcutSuggestion(
            id: "fn",
            label: "Fn",
            shortcut: KeyboardShortcut(
                modifiers: [SidedModifier(.function, .either)],
                keyCode: nil,
                sideAgnostic: false
            )
        ),
        OnboardingShortcutSuggestion(
            id: "right-command",
            label: "Right Command",
            shortcut: KeyboardShortcut(
                modifiers: [SidedModifier(.command, .right)],
                keyCode: nil,
                sideAgnostic: false
            )
        )
    ]
}

// MARK: - Chip

/// A clickable pill for one suggested shortcut. The active state is the chip
/// whose shortcut equals the user's current Shortcut 1 — gives the user an
/// at-a-glance confirmation that their suggestion took effect.
struct OnboardingSuggestionChip: View {
    let suggestion: OnboardingShortcutSuggestion
    let isActive: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if isActive {
                    Image(systemName: "checkmark.circle.fill")
                        .imageScale(.small)
                        .foregroundStyle(.tint)
                }
                Text(suggestion.label)
                    .font(.callout)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(
                Capsule()
                    .fill(isActive ? Color.accentColor.opacity(0.18) : Color.secondary.opacity(0.12))
            )
            .overlay(
                Capsule()
                    .strokeBorder(isActive ? Color.accentColor : Color.clear, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .help(suggestion.label)
    }
}

// MARK: - Card

/// A simple card wrapper used by both onboarding screens so the section
/// backgrounds match the Logic-Pro-ish look of the Preferences `Form` rows
/// without forcing the onboarding into the same `Form` constraints. Plain
/// `RoundedRectangle` on the background-secondary fill, rounded corners, soft
/// border.
struct OnboardingCard<Content: View>: View {
    @ViewBuilder let content: () -> Content

    var body: some View {
        content()
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.secondary.opacity(0.08))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(Color.secondary.opacity(0.18), lineWidth: 0.5)
            )
    }
}
