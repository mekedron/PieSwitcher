import SwiftUI

/// Onboarding screen for the position shortcuts (Bringr-dk3): what they do, a worked
/// example, and one button that installs the starter set.
///
/// Nothing is bound unless the user presses that button. The screen exists to make the
/// feature discoverable, not to configure the app behind their back — these shortcuts
/// consume their keys system-wide, so arriving with them already on would change how the
/// keyboard behaves for someone who only wanted a pie menu.
struct OnboardingPositionsScreen: View {
    /// Re-read after each install/remove so the button reflects what is actually stored,
    /// rather than a local guess that could drift from the Positions pane.
    @State private var isInstalled = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                header
                exampleCard
                recommendationCard
            }
            .padding(.horizontal, 28)
            .padding(.vertical, 24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .onAppear { refresh() }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Skip the wheel entirely")
                .font(.largeTitle.bold())
                .fixedSize(horizontal: false, vertical: true)
            Text("Bind a key to a slot in the wheel and go straight there.")
                .font(.title3)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var exampleCard: some View {
        OnboardingCard {
            VStack(alignment: .leading, spacing: 12) {
                Label("How it works", systemImage: "number")
                    .font(.headline)

                Text("The wheel lists your apps in a fixed order. A position shortcut acts "
                     + "on a slot in that list without opening the wheel at all.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                VStack(alignment: .leading, spacing: 8) {
                    exampleRow(
                        keys: PositionShortcutPreset.capLabels(for: .apps) + ["1"],
                        text: "activates the first app in your wheel."
                    )
                    exampleRow(
                        keys: PositionShortcutPreset.capLabels(for: .windows) + ["2"],
                        text: "focuses the second window of the app you are already in."
                    )
                }
                .padding(.top, 2)
            }
        }
    }

    private func exampleRow(keys: [String], text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            HStack(spacing: 4) {
                ForEach(Array(keys.enumerated()), id: \.offset) { _, key in
                    KeyCapBadge(text: key)
                }
            }
            Text(text)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
    }

    private var recommendationCard: some View {
        OnboardingCard {
            VStack(alignment: .leading, spacing: 12) {
                Label("A set to start with", systemImage: "sparkles")
                    .font(.headline)

                Text(recommendationSummary)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Text("They use the left Option only, so the right one keeps typing the "
                     + "characters it always did. Nothing is bound unless you add them, and "
                     + "you can change or remove them any time in Preferences → Positions.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                if isInstalled {
                    installedControls
                } else {
                    Button("Use recommended shortcuts", action: install)
                        .buttonStyle(.borderedProminent)
                        .padding(.top, 2)
                }
            }
        }
    }

    private var installedControls: some View {
        HStack(spacing: 12) {
            Label("Added", systemImage: "checkmark.circle.fill")
                .font(.callout)
                .foregroundStyle(.tint)
            Button("Remove", action: remove)
                .buttonStyle(.borderless)
            Spacer(minLength: 0)
        }
        .padding(.top, 2)
    }

    /// Built as a plain string rather than inline in the `Text`: four interpolations
    /// concatenated inside a view builder is more than the type-checker will chew through
    /// in reasonable time.
    private var recommendationSummary: String {
        let count = PositionShortcutPreset.positionCount
        let apps = PositionShortcutPreset.summary(for: .apps)
        let windows = PositionShortcutPreset.summary(for: .windows)
        return "\(apps) for your first \(count) apps, and \(windows) for the first "
            + "\(count) windows of whichever app you are in."
    }

    // MARK: - Actions

    private func install() {
        for list in PositionShortcutList.allCases {
            PositionShortcutPreset.install(list)
        }
        refresh()
    }

    private func remove() {
        for list in PositionShortcutList.allCases {
            PositionShortcutPreset.remove(list)
        }
        refresh()
    }

    private func refresh() {
        isInstalled = PositionShortcutList.allCases.allSatisfy {
            PositionShortcutPreset.isInstalled($0)
        }
    }
}

#Preview("Onboarding — positions") {
    OnboardingPositionsScreen()
        .frame(width: 600, height: 560)
}
