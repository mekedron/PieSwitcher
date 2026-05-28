import Foundation

/// A best-effort record of the last window a user picked for an app, kept so the
/// next summon can pre-highlight it (US-012 AC3/AC4).
///
/// Window ids are not stable across app restarts, and real titles are usually
/// unavailable without Screen Recording (a v1 non-goal), so the match is
/// best-effort: by title when a meaningful one was recorded, else by the window's
/// position in the app's list.
struct RememberedSelection: Equatable, Sendable, Codable {
    /// The chosen window's title when it was picked. May be a placeholder such as
    /// "Window 2" when a real title was unavailable.
    let title: String
    /// The chosen window's position in the app's front-to-back window list.
    let index: Int

    /// The index to pre-highlight among `titles` — the app's current windows in
    /// order — or `nil` when neither a title nor the remembered position matches.
    ///
    /// Prefers a title match (robust to the windows reordering between summons) and
    /// falls back to the remembered position when no title was recorded or the
    /// titled window is gone. (AC4)
    func matchIndex(in titles: [String]) -> Int? {
        if !title.isEmpty, let matched = titles.firstIndex(of: title) {
            return matched
        }
        return titles.indices.contains(index) ? index : nil
    }
}

/// Persists the last selected window per app across summons and restarts, backed
/// by `UserDefaults`.
///
/// Keyed by app *name*, not pid: a pid is reassigned every launch, so it cannot
/// identify "the same app" after a restart, whereas the name (as the enumeration
/// service reports it) is stable enough for the best-effort match the PRD asks
/// for. Mirrors the injectable-defaults design of `InteractionMode.current(from:)`
/// so the logic is unit-tested against an ephemeral suite, never `.standard`.
@MainActor
final class LastSelectionStore {
    private let defaults: UserDefaults
    private static let keyPrefix = "lastSelection."

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// Remember the window at `index` titled `title` as the last choice for the app
    /// named `appName`, replacing any previous choice for that app.
    func remember(appName: String, title: String, index: Int) {
        let selection = RememberedSelection(title: title, index: index)
        guard let data = try? JSONEncoder().encode(selection) else { return }
        defaults.set(data, forKey: Self.key(forAppName: appName))
    }

    /// The remembered selection for the app named `appName`, or `nil` if none is
    /// stored (or the stored value cannot be decoded).
    func remembered(forAppName appName: String) -> RememberedSelection? {
        guard let data = defaults.data(forKey: Self.key(forAppName: appName)) else { return nil }
        return try? JSONDecoder().decode(RememberedSelection.self, from: data)
    }

    /// The index to pre-highlight among an app's current window `titles`, matching
    /// the remembered selection best-effort, or `nil` when nothing is remembered
    /// for that app or nothing matches. (AC4)
    func prehighlightIndex(forAppName appName: String, windowTitles titles: [String]) -> Int? {
        remembered(forAppName: appName)?.matchIndex(in: titles)
    }

    private static func key(forAppName appName: String) -> String {
        keyPrefix + appName
    }
}
