import Foundation

/// The user's app exclusion list (Bringr-93j.59): apps that must never appear in the wheel,
/// no matter what — for background or Dock-lingering utilities that own a tile (or a stray
/// window) yet are never worth switching to. Stored as one comma-separated string (the
/// manual-entry format the Preferences field edits); each entry is either a bundle identifier
/// (com.apple.Safari) or an app name (Safari), and the Add picker appends bundle ids to that
/// same string. Read fresh at each summon (mirroring `CuratedApps` / `RevealStrategy`), so an
/// edit applies on the next open without a relaunch.
///
/// Matching is the pure part, unit-tested directly; the live resolution of a window's owning
/// app to a bundle id / name lives in `CGWindowSource`.
struct AppIgnoreList: Equatable, Sendable {
    /// Parsed, normalized entries (trimmed, lowercased, blanks dropped). Each is matched against
    /// both an app's bundle id and its name, so we never need to track which kind it is.
    let entries: [String]

    /// `UserDefaults` key backing the persisted comma-separated text. Single source of truth
    /// shared by the Preferences `@AppStorage` and `current(from:)`, so the two cannot drift.
    /// The `collection.` prefix groups it with the sibling collection-scope settings.
    static let defaultsKey = "collection.ignoreList"

    /// Build from the raw comma-separated text the user typed (or the picker appended to).
    init(text: String) {
        entries = Self.parse(text)
    }

    /// Build directly from already-normalized entries — for tests.
    init(entries: [String]) {
        self.entries = entries
    }

    /// The persisted list, or an empty list when nothing is stored (the first-run default —
    /// nothing excluded). An empty list excludes nothing, so collection is left unchanged.
    static func current(from defaults: UserDefaults = .standard) -> AppIgnoreList {
        AppIgnoreList(text: defaults.string(forKey: defaultsKey) ?? "")
    }

    /// Whether anything is excluded — lets callers skip all per-app resolution on the common
    /// empty-list path.
    var isEmpty: Bool { entries.isEmpty }

    /// Split the comma-separated text into normalized entries: trim whitespace, lowercase for
    /// case-insensitive matching, drop blanks (so trailing commas and stray spaces are
    /// harmless). App names containing commas aren't supported — an accepted v1 limitation,
    /// since the comma is the separator and reverse-DNS bundle ids never contain one.
    static func parse(_ text: String) -> [String] {
        text.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .filter { !$0.isEmpty }
    }

    /// Whether an app with this bundle id and display name is excluded. An entry matches if it
    /// equals (case-insensitively) either the bundle id or the name, so the user can list
    /// whichever they know. Exact full-string match, not substring, so "Mail" never hides
    /// "Mailplane".
    func excludes(bundleID: String?, name: String) -> Bool {
        guard !entries.isEmpty else { return false }
        let candidates = [bundleID?.lowercased(), name.lowercased()].compactMap { $0 }
        return entries.contains { candidates.contains($0) }
    }

    /// Append `entry` (a bundle id or name) to the comma-separated `text`, unless an equivalent
    /// entry is already present (case-insensitive) or `entry` is blank — so the picker can't
    /// create duplicates. Returns the new text; the caller persists it to `defaultsKey`.
    static func appending(_ entry: String, to text: String) -> String {
        let trimmed = entry.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !parse(text).contains(trimmed.lowercased()) else { return text }
        // Trim trailing/leading commas as well as whitespace so a stored "com.x," doesn't
        // produce a double comma ("com.x,, com.y") when the picker appends.
        let separators = CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: ","))
        let base = text.trimmingCharacters(in: separators)
        return base.isEmpty ? trimmed : "\(base), \(trimmed)"
    }
}
