import XCTest
@testable import Bringr

/// Exercises the last-selection persistence and the pure pre-highlight matching
/// (US-012 AC3/AC4/AC5). The store is always backed by an ephemeral, per-test
/// `UserDefaults` suite — never `.standard` — so tests stay isolated.
@MainActor
final class WindowMemoryTests: XCTestCase {

    // MARK: - RememberedSelection.matchIndex (pure pre-highlight logic, AC4/AC5)

    func testMatchPrefersTitleOverPositionWhenWindowsReorder() {
        let remembered = RememberedSelection(title: "Inbox", index: 0)
        // The "Inbox" window has moved to position 1; the title match follows it.
        XCTAssertEqual(remembered.matchIndex(in: ["Docs", "Inbox"]), 1)
    }

    func testMatchFallsBackToIndexWhenTitleIsGone() {
        let remembered = RememberedSelection(title: "Closed Window", index: 1)
        XCTAssertEqual(remembered.matchIndex(in: ["A", "B", "C"]), 1)
    }

    func testMatchUsesIndexWhenNoTitleWasRecorded() {
        // Placeholder/empty titles are common without Screen Recording, so order is
        // the only signal — fall straight to the remembered position.
        let remembered = RememberedSelection(title: "", index: 2)
        XCTAssertEqual(remembered.matchIndex(in: ["A", "B", "C"]), 2)
    }

    func testMatchReturnsNilWhenIndexOutOfRangeAndNoTitleMatch() {
        let remembered = RememberedSelection(title: "", index: 5)
        XCTAssertNil(remembered.matchIndex(in: ["A", "B"]))
    }

    func testMatchReturnsNilForNegativeIndexAndEmptyList() {
        XCTAssertNil(RememberedSelection(title: "", index: -1).matchIndex(in: ["A"]))
        XCTAssertNil(RememberedSelection(title: "", index: 0).matchIndex(in: []))
    }

    // MARK: - LastSelectionStore persistence (AC3/AC5)

    func testRememberThenRecallRoundTrips() {
        withStore { store in
            store.remember(appName: "Chrome", title: "Inbox", index: 0)
            XCTAssertEqual(store.remembered(forAppName: "Chrome"),
                           RememberedSelection(title: "Inbox", index: 0))
        }
    }

    func testRememberedIsNilForUnknownApp() {
        withStore { store in
            XCTAssertNil(store.remembered(forAppName: "Ghostty"))
        }
    }

    func testRememberOverwritesPreviousChoiceForSameApp() {
        withStore { store in
            store.remember(appName: "Chrome", title: "Inbox", index: 0)
            store.remember(appName: "Chrome", title: "Docs", index: 1)
            XCTAssertEqual(store.remembered(forAppName: "Chrome"),
                           RememberedSelection(title: "Docs", index: 1))
        }
    }

    func testDifferentAppsAreRememberedIndependently() {
        withStore { store in
            store.remember(appName: "Chrome", title: "Inbox", index: 0)
            store.remember(appName: "Ghostty", title: "Terminal", index: 2)
            XCTAssertEqual(store.remembered(forAppName: "Chrome")?.title, "Inbox")
            XCTAssertEqual(store.remembered(forAppName: "Ghostty")?.index, 2)
        }
    }

    // MARK: - prehighlightIndex (store + matching together, AC4)

    func testPrehighlightIndexMatchesRememberedWindowByTitle() {
        withStore { store in
            store.remember(appName: "Chrome", title: "Docs", index: 1)
            XCTAssertEqual(
                store.prehighlightIndex(forAppName: "Chrome", windowTitles: ["Inbox", "Docs"]),
                1
            )
        }
    }

    func testPrehighlightIndexFollowsTitleWhenWindowsReorder() {
        withStore { store in
            store.remember(appName: "Chrome", title: "Inbox", index: 0)
            XCTAssertEqual(
                store.prehighlightIndex(forAppName: "Chrome", windowTitles: ["Docs", "Inbox"]),
                1
            )
        }
    }

    func testPrehighlightIndexIsNilForAppWithNoMemory() {
        withStore { store in
            XCTAssertNil(store.prehighlightIndex(forAppName: "Mail", windowTitles: ["A", "B"]))
        }
    }

    // MARK: - Fixtures

    /// Run `test` with a store backed by a throwaway suite that is torn down after,
    /// so persistence tests never read or write the real `.standard` defaults.
    private func withStore(_ test: (LastSelectionStore) -> Void) {
        let suite = "BringrTests.WindowMemory.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        test(LastSelectionStore(defaults: defaults))
    }
}
