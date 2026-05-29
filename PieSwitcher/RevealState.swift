import Foundation

/// A persisted record of every app/window a reveal session moved out of the way,
/// each paired with the state it held *before* the summon. Written to disk while a
/// reveal is in flight so that if PieSwitcher is killed mid-reveal (a crash, a force
/// quit) the next launch can put everything back — the restore-on-launch safety
/// net (US-015 AC3). Cleared the instant an in-process restore finishes, so its
/// mere presence at launch means a previous session never got to clean up.
///
/// Identifiers are raw pids / window numbers rather than `AppID`/`WindowID` so the
/// snapshot is trivially `Codable`. The other apps keep their pids across a PieSwitcher
/// crash (only PieSwitcher died, not them), so the ids still resolve on the next launch.
struct RevealSnapshot: Codable, Equatable, Sendable {
    struct AppEntry: Codable, Equatable, Sendable {
        let pid: pid_t
        let wasHidden: Bool
    }

    struct WindowEntry: Codable, Equatable, Sendable {
        let pid: pid_t
        let token: Int
        let wasMinimized: Bool
    }

    /// The app that was frontmost before the summon, to re-activate on restore.
    var frontmostPID: pid_t?
    /// Every app whose visibility was captured, with its pre-summon hidden state.
    var apps: [AppEntry]
    /// Every window whose minimized-state was captured, with its pre-summon value.
    var windows: [WindowEntry]

    /// Nothing was moved out of the way, so there is nothing to journal.
    var isEmpty: Bool { apps.isEmpty && windows.isEmpty }
}

/// Persists the in-flight `RevealSnapshot` across process death, backed by
/// `UserDefaults`. Injectable defaults (mirroring `LastSelectionStore`) so the
/// safety-net logic is unit-tested against an ephemeral suite, never `.standard`.
@MainActor
final class RevealStateStore {
    private let defaults: UserDefaults
    private static let key = "revealSnapshot"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// Persist `snapshot` as the in-flight reveal, replacing any previous one.
    func save(_ snapshot: RevealSnapshot) {
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        defaults.set(data, forKey: Self.key)
    }

    /// The persisted in-flight reveal, or `nil` when none is stored (or it cannot
    /// be decoded) — the normal case when the previous session restored cleanly.
    func load() -> RevealSnapshot? {
        guard let data = defaults.data(forKey: Self.key) else { return nil }
        return try? JSONDecoder().decode(RevealSnapshot.self, from: data)
    }

    /// Drop the persisted reveal — called the instant an in-process restore finishes.
    func clear() {
        defaults.removeObject(forKey: Self.key)
    }
}
