import Foundation

/// Persisted "the user has seen the welcome window" flag that gates the
/// first-launch auto-open (Bringr-93j.112). One flag is set the moment the
/// onboarding window appears for any reason — first-launch auto-open, a "Show
/// Welcome…" click, or a debug invocation — so closing the window without
/// finishing still counts as "seen" and the next launch does not re-trigger.
///
/// The pure decision (`shouldAutoOpen(from:)`) is unit-tested headless; the
/// writer (`markSeen(in:)`) is a thin shell around `UserDefaults.set` so the
/// auto-open path is observable in tests without any UI.
enum OnboardingState {
    /// `UserDefaults` key backing the seen-onboarding flag. Single source of truth
    /// shared by `AppDelegate.applicationDidFinishLaunching` and the onboarding
    /// presenter so the two cannot drift on which flag they read/write.
    static let completedKey = "onboarding.completed"

    /// Whether the onboarding window should auto-open on launch. True only when
    /// the user has never seen it (key absent) or someone explicitly cleared the
    /// flag for debugging. Idempotent — a freshly-installed app reads this once
    /// and the writer flips it the moment the window is shown.
    static func shouldAutoOpen(from defaults: UserDefaults = .standard) -> Bool {
        !defaults.bool(forKey: completedKey)
    }

    /// Mark the onboarding as seen so the next launch does not re-trigger it.
    /// Called from the presenter as soon as the window is presented (not when
    /// "Done" is clicked) so a user who closes early still doesn't get the
    /// window pushed in their face on the next launch.
    static func markSeen(in defaults: UserDefaults = .standard) {
        defaults.set(true, forKey: completedKey)
    }

    /// Clear the seen flag so the onboarding auto-opens on the next launch.
    /// Not surfaced in the user-facing UI; useful for QA and for tests that
    /// drive the first-launch path.
    static func clearSeen(in defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: completedKey)
    }
}
