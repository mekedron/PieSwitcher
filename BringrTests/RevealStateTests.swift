import XCTest
@testable import Bringr

/// Covers the restore-on-launch safety net (US-015 AC3): the `RevealStateStore`
/// round-trip, that `WindowController` journals a reveal while it is in flight and
/// clears it on a clean restore/commit, and that `restoreFromSnapshotIfNeeded`
/// replays a journal a prior crash left behind. Runs against an ephemeral defaults
/// suite and the in-memory `FakeWindowSystem`, never the live system.
@MainActor
final class RevealStateTests: XCTestCase {
    // MARK: - Store round-trip

    func testStoreSaveLoadClearRoundTrip() throws {
        let store = makeStore()
        XCTAssertNil(store.load())

        let snapshot = RevealSnapshot(
            frontmostPID: 7,
            apps: [.init(pid: 1, wasHidden: false), .init(pid: 2, wasHidden: true)],
            windows: [.init(pid: 1, token: 10, wasMinimized: false)]
        )
        store.save(snapshot)
        XCTAssertEqual(try XCTUnwrap(store.load()), snapshot)

        store.clear()
        XCTAssertNil(store.load())
    }

    // MARK: - A reveal is journalled while in flight (AC3)

    func testHidingAppsPersistsThePreSummonBaseline() throws {
        let store = makeStore()
        let fake = FakeWindowSystem(
            apps: [appState(1), appState(2, hidden: true), appState(3)],
            frontmost: AppID(pid: 1)
        )
        let controller = WindowController(system: fake, store: store)

        controller.hideOtherApps(besides: AppID(pid: 1))

        let snapshot = try XCTUnwrap(store.load())
        XCTAssertEqual(snapshot.frontmostPID, 1)
        // Each app's *pre-summon* hidden state is captured, not the post-hide state.
        XCTAssertEqual(
            snapshot.apps.sorted { $0.pid < $1.pid },
            [
                RevealSnapshot.AppEntry(pid: 1, wasHidden: false),
                RevealSnapshot.AppEntry(pid: 2, wasHidden: true),
                RevealSnapshot.AppEntry(pid: 3, wasHidden: false)
            ]
        )
    }

    func testIsolatingWindowsPersistsTheWindowBaseline() throws {
        let store = makeStore()
        let appA = AppID(pid: 1)
        let fake = FakeWindowSystem(apps: [appState(1, windowTokens: [10, 11])], frontmost: appA)
        fake.apps[0].windows[0].position = CGPoint(x: 5, y: 6) // window 10's pre-summon spot
        fake.setMinimized(WindowID(app: appA, token: 11), true)
        let controller = WindowController(system: fake, store: store)

        controller.hideOtherWindows(besides: WindowID(app: appA, token: 10))

        let snapshot = try XCTUnwrap(store.load())
        // Window 10's origin is journalled so a crash can un-park it; window 11 was
        // already minimized, so it carries no position (it was never parked).
        XCTAssertEqual(
            snapshot.windows.sorted { $0.token < $1.token },
            [
                RevealSnapshot.WindowEntry(pid: 1, token: 10, wasMinimized: false,
                                           originalPosition: CGPoint(x: 5, y: 6)),
                RevealSnapshot.WindowEntry(pid: 1, token: 11, wasMinimized: true,
                                           originalPosition: nil)
            ]
        )
    }

    // MARK: - A clean exit leaves no stranded journal (AC2/AC5)

    func testRestoreClearsThePersistedSnapshot() {
        let store = makeStore()
        let fake = FakeWindowSystem(apps: [appState(1), appState(2)], frontmost: AppID(pid: 1))
        let controller = WindowController(system: fake, store: store)
        controller.hideOtherApps(besides: AppID(pid: 1))
        XCTAssertNotNil(store.load())

        controller.restore()

        XCTAssertNil(store.load(), "a clean restore must leave no stranded journal")
    }

    func testCommitClearsThePersistedSnapshot() {
        let store = makeStore()
        let appA = AppID(pid: 1)
        let fake = FakeWindowSystem(
            apps: [appState(1, windowTokens: [10, 11]), appState(2)],
            frontmost: appA
        )
        let controller = WindowController(system: fake, store: store)
        controller.hideOtherApps(besides: appA)
        controller.hideOtherWindows(besides: WindowID(app: appA, token: 11))
        XCTAssertNotNil(store.load())

        controller.commit(WindowID(app: appA, token: 11))

        XCTAssertNil(store.load())
    }

    // MARK: - Restore-on-launch replays a stranded reveal (AC3)

    func testRestoreFromSnapshotUndoesAStrandedReveal() {
        let store = makeStore()
        let appA = AppID(pid: 1)
        // A previous session killed mid-reveal: app 2 left hidden, window 10 left
        // minimized, with a journal describing the pre-summon (all-visible) state.
        let fake = FakeWindowSystem(
            apps: [appState(1, windowTokens: [10, 11]), appState(2)],
            frontmost: appA
        )
        fake.setHidden(AppID(pid: 2), true)
        fake.setMinimized(WindowID(app: appA, token: 10), true)
        store.save(RevealSnapshot(
            frontmostPID: 1,
            apps: [.init(pid: 1, wasHidden: false), .init(pid: 2, wasHidden: false)],
            windows: [
                .init(pid: 1, token: 10, wasMinimized: false),
                .init(pid: 1, token: 11, wasMinimized: false)
            ]
        ))

        let recovered = WindowController(system: fake, store: store).restoreFromSnapshotIfNeeded()

        XCTAssertTrue(recovered)
        XCTAssertFalse(fake.isHidden(AppID(pid: 2)), "the stranded hidden app is shown again")
        XCTAssertFalse(
            fake.isMinimized(WindowID(app: appA, token: 10)),
            "the stranded minimized window is restored"
        )
        XCTAssertNil(store.load(), "the journal is cleared once replayed")
    }

    func testRestoreFromSnapshotMovesAParkedWindowBack() {
        // A previous session parked window 10 off-screen to isolate a sibling, then
        // died. The journal carries its pre-summon origin so the safety net restores it.
        let store = makeStore()
        let appA = AppID(pid: 1)
        let fake = FakeWindowSystem(apps: [appState(1, windowTokens: [10, 11])], frontmost: appA)
        fake.setPosition(WindowID(app: appA, token: 10), WindowController.offScreenPoint)
        store.save(RevealSnapshot(
            frontmostPID: 1,
            apps: [],
            windows: [
                .init(pid: 1, token: 10, wasMinimized: false, originalPosition: CGPoint(x: 100, y: 10)),
                .init(pid: 1, token: 11, wasMinimized: false, originalPosition: CGPoint(x: 110, y: 11))
            ]
        ))

        let recovered = WindowController(system: fake, store: store).restoreFromSnapshotIfNeeded()

        XCTAssertTrue(recovered)
        XCTAssertEqual(fake.position(of: WindowID(app: appA, token: 10)), CGPoint(x: 100, y: 10),
                       "the stranded off-screen window is moved back to its captured origin")
        XCTAssertNil(store.load(), "the journal is cleared once replayed")
    }

    func testRestoreFromSnapshotReturnsToPriorHiddenState() {
        // An app already hidden before the summon must stay hidden after the safety
        // net — restore is to the captured baseline, not a blanket show-everything.
        let store = makeStore()
        let fake = FakeWindowSystem(
            apps: [appState(1), appState(2, hidden: true)],
            frontmost: AppID(pid: 1)
        )
        // The reveal had un-hidden app 2 to isolate it; the journal says it was hidden.
        fake.setHidden(AppID(pid: 2), false)
        store.save(RevealSnapshot(
            frontmostPID: 1,
            apps: [.init(pid: 1, wasHidden: false), .init(pid: 2, wasHidden: true)],
            windows: []
        ))

        WindowController(system: fake, store: store).restoreFromSnapshotIfNeeded()

        XCTAssertTrue(fake.isHidden(AppID(pid: 2)), "a prior-hidden app returns to hidden")
    }

    func testRestoreFromSnapshotIsANoOpWithoutAJournal() {
        let store = makeStore()
        let fake = FakeWindowSystem(apps: [appState(1)], frontmost: AppID(pid: 1))

        XCTAssertFalse(WindowController(system: fake, store: store).restoreFromSnapshotIfNeeded())
    }

    func testRestoreFromSnapshotIsANoOpWithoutAStore() {
        let fake = FakeWindowSystem(apps: [appState(1)], frontmost: AppID(pid: 1))

        XCTAssertFalse(WindowController(system: fake).restoreFromSnapshotIfNeeded())
    }

    // MARK: - A controller with no store still reveals and restores (no persistence)

    func testWindowControllerWithoutAStoreStillRevealsAndRestores() {
        let fake = FakeWindowSystem(apps: [appState(1), appState(2)], frontmost: AppID(pid: 1))
        let controller = WindowController(system: fake) // no store injected

        controller.hideOtherApps(besides: AppID(pid: 1))
        XCTAssertTrue(fake.isHidden(AppID(pid: 2)))

        controller.restore()
        XCTAssertFalse(fake.isHidden(AppID(pid: 2)))
    }

    // MARK: - Helpers

    /// An isolated `UserDefaults` suite so persistence tests never touch the real
    /// domain; torn down by suite name to stay Sendable-clean.
    private func makeStore() -> RevealStateStore {
        let suite = "RevealStateTests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else {
            fatalError("could not create a test UserDefaults suite")
        }
        addTeardownBlock { UserDefaults.standard.removePersistentDomain(forName: suite) }
        return RevealStateStore(defaults: defaults)
    }

    private func appState(
        _ pid: pid_t, hidden: Bool = false, windowTokens: [Int] = []
    ) -> FakeWindowSystem.AppState {
        let appID = AppID(pid: pid)
        let windows = windowTokens.map {
            FakeWindowSystem.WindowState(id: WindowID(app: appID, token: $0), minimized: false)
        }
        return FakeWindowSystem.AppState(id: appID, hidden: hidden, windows: windows)
    }
}
