# Ralph Progress Log

This file tracks progress across iterations. Agents update this file
after each iteration and it's included in prompts for context.

## Codebase Patterns (Study These First)

- **Adding a source/test file = 4 pbxproj edits.** `Bringr.xcodeproj/project.pbxproj` is hand-managed with sequential `1A0000000000000000000NN` UUIDs (NOT file-system-synchronized groups), so a new file needs: (1) a `PBXBuildFile` entry, (2) a `PBXFileReference` entry, (3) an entry in the `BringrTests`/`Bringr` `PBXGroup` `children`, (4) an entry in the target's `PBXSourcesBuildPhase` `files`. Pick two fresh UUIDs above the current max (`grep -oE '1A0000000000000000000[0-9A-F]+' ... | sort -u | tail`). fileRef + buildFile are distinct UUIDs.
- **SwiftLint caps file length at 400 and type-body at 250** (`swiftlint lint --strict`, the gate). When a test file outgrows it, split by concern into a new file (e.g. `RadialNavigatorCommitTests.swift` for US-012) following the existing one-story-per-file naming — don't relax the config.
- **Pure-core / thin-shell + injected fakes.** State machines and navigators (`RadialNavigator`, `InteractionStateMachine`, `WindowController`) hold no AppKit window; they take seam protocols (`WindowControlling`, `WindowEnumerationSource`) so the whole policy is unit-tested against `FakeWindowSystem` (in WindowControlTests) and `StubEnumerationSource` (in MenuModelTests), both module-internal and reused across test files.
- **Stores take injectable `UserDefaults`.** `LastSelectionStore` / `InteractionMode.current(from:)` accept defaults so tests use an ephemeral suite, never `.standard`. Tear it down Sendable-cleanly by capturing only the suite *string*: `addTeardownBlock { UserDefaults.standard.removePersistentDomain(forName: suite) }`.
- **SourceKit single-file diagnostics lie.** "Cannot find type X" / "No such module 'XCTest'" from in-editor indexing are cross-file artifacts; trust `xcodebuild` for ground truth.
- **Overlay event routing splits local vs global.** The radial overlay is a `.nonactivatingPanel`, so clicks *on* it are LOCAL events (handled by the SwiftUI `DragGesture` in `RadialMenuView` → `clickInOverlay`), while clicks *outside* it, Esc, and cursor moves are GLOBAL events the app never receives as first responder. The controller observes those via `NSEvent.addGlobalMonitorForEvents`, installed on summon and torn down on dismiss (`RadialMenuController.startMenuMonitors`/`stopMenuMonitors`). Global monitors can't consume events (Esc also reaches the app underneath) and keyboard monitoring needs Input-Monitoring permission — both acceptable for v1. The mouse-chord `CGEventTap` *consumes* the L+R downs, so they never reach the global mouse-down monitor: a click-outside-cancels monitor is safe to run during a held chord.
- **Crash-recovery journal pattern.** `WindowController` mirrors its in-flight reveal baseline to `RevealStateStore` (UserDefaults, injectable suite) on each baseline capture, and clears it inside `restore()`/`commit()`. At launch `AppDelegate` calls `WindowController.restoreFromSnapshotIfNeeded()`, so a journal that survived means the prior session was killed mid-reveal and gets replayed. Other apps keep their pids across a *Bringr* crash, so raw pid/window-number ids in the snapshot still resolve. Inject the store explicitly (production path) — the navigator's default `WindowController()` has `store: nil` and journals nothing, which keeps fake-backed tests off `.standard`.

---

## 2026-05-28 - Bringr-93j.12 (US-012: Select and commit — focus and remember)

- Finalized the commit + remember + pre-highlight flow. The implementation already existed (scaffolded during US-011) but carried two `// needs to be reimagined/refactored` markers and had no tests at the navigator/primitive level. Reviewed it — the design is correct as-is — so I removed the markers and added the missing coverage rather than rewriting.
- **Files changed:**
  - `Bringr/WindowControl.swift` — removed the stale US-012 marker on `commit(_:)`. The primitive restores everything else first, then un-minimizes + raises + focuses the target (restore re-activates the prior frontmost app, so it must run *before* the raise or it steals focus back).
  - `Bringr/RadialNavigator.swift` — removed the stale US-012 marker on `commit(_:)`. It guards for a level-1 window leaf, remembers `(appName, title, index)`, delegates to `windowControl.commit`, clears state, returns the `WindowID` (nil for app slice / dead zone so the controller cancel-restores).
  - `BringrTests/WindowControlTests.swift` — +3 tests for `WindowController.commit` (restore-then-focus; un-minimize a pre-minimized target; no-session still raises/focuses).
  - `BringrTests/RadialNavigatorCommitTests.swift` — **new file** (+10 tests) for navigator commit + pre-highlight, with its own fake-backed fixture and an ephemeral store. Registered in the pbxproj.
  - `Bringr.xcodeproj/project.pbxproj` — 4 edits to add the new test file (UUIDs 0057/0058).
- AC5 coverage now spans three layers: `WindowMemoryTests` (store persistence + pure `matchIndex`), `RadialNavigatorCommitTests` (navigator remember-on-commit + set-prehighlight-on-expand, incl. AC3→AC4 round trip), `WindowControlTests` (the focus/restore primitive).
- Gates: build SUCCEEDED, `swiftlint --strict` 0 violations (31 files), `xcodebuild test` 144 tests / 0 failures. App launches and runs clean.
- **Learnings:**
  - The commit path's ordering is load-bearing: `restore()` re-activates the pre-summon frontmost app as its *last* step, so committing must restore **before** raise/focus, else the chosen window loses focus immediately.
  - Pre-highlight is purely visual (AC4) — it never auto-commits. Committing always requires the cursor to actually resolve to the window slice; `RadialNavigator.commit` reads the live region's index, not `expandedWindowIndex`, so it's robust to hover lag at release time.
  - `RadialNavigator.expandApp` already reads the store on every app-hover (for pre-highlight), so any test that hovers an app touches the injected store — inject an ephemeral one in fixtures or `.standard` leaks in.
  - Adding tests can trip the SwiftLint length gate even when the app builds; split into a per-story test file rather than relaxing the rule (see Codebase Patterns).

---

## 2026-05-28 - Bringr-93j.15 (US-015: Cancel and guaranteed state restoration)

- Completed the cancel/restore story. Two halves: (1) wire the remaining cancel sources (Esc, click-outside, trigger-loss) into the existing cancel→restore funnel — release-in-dead-zone was already done; (2) add a restore-on-launch safety net so a crash mid-reveal never strands a hidden window.
- **Files changed:**
  - `Bringr/RevealState.swift` — **new file.** `RevealSnapshot` (Codable; raw pid/window-number ids so it survives a relaunch) + `RevealStateStore` (UserDefaults, injectable suite, mirrors `LastSelectionStore`).
  - `Bringr/WindowControl.swift` — `WindowController` gains an optional `store`; `persistSnapshot()` mirrors the baseline to disk on each capture (off the summon hot path — once per app-hover / first window-isolation), `restore()`/`commit()` clear it, and `restoreFromSnapshotIfNeeded()` + `applySnapshot()` replay a stranded journal at launch (app-visibility first, re-enumerate to repopulate the AX cache, then minimized-state, then frontmost — same ordering as `restore()`).
  - `Bringr/InteractionMode.swift` — new `InteractionInput.triggerLost`, handled identically to `.escape` (`case .escape, .triggerLost:` → cancel when open).
  - `Bringr/RadialMenuWindow.swift` — `RadialMenuController` gains `escapePressed()`/`triggerLost()`; `startHoverTracking`/`stopHoverTracking` became `startMenuMonitors`/`stopMenuMonitors`, now also installing a global key/mouse-down monitor (Esc keyCode 53 → escape; click-outside → `.click(over: .none)`) and an `activeSpaceDidChangeNotification` observer (→ trigger-loss).
  - `Bringr/AppDelegate.swift` — `prewarmRadialMenu` builds a store-backed `WindowController`, runs `restoreFromSnapshotIfNeeded()` before the first summon, and injects it into the controller.
  - `BringrTests/RevealStateTests.swift` — **new file** (+10 tests): store round-trip, journal-on-hide/isolate, clear-on-restore/commit, replay-stranded-reveal (incl. prior-hidden state), no-op without journal/store, and no-store-still-works.
  - `BringrTests/InteractionModeTests.swift` — +2 tests for `.triggerLost` (cancel in both modes when open; no-op when closed).
  - `Bringr.xcodeproj/project.pbxproj` — 4 edits each for the two new files (UUIDs 0059/005A app, 005B/005C test).
- AC coverage: AC1 cancel sources — release-in-dead-zone (pre-existing), Esc/click-outside/trigger-loss (new wiring), state-machine cancel paths in `InteractionModeTests`. AC2 — every cancel funnels through `dismiss`→`navigator.close()`→`windowControl.restore()` (existing `WindowControlTests`). AC3 — `RevealStateTests` + AppDelegate launch hook. AC4 — state-machine + journal tests, build & run.
- Gates: build SUCCEEDED, `swiftlint --strict` 0 violations (33 files), `xcodebuild test` 156 tests / 0 failures. App launches and stays running; launch-time safety net is a no-op when no journal exists.
- **Learnings:**
  - The non-activating panel cleanly splits event routing: inside-clicks are local (SwiftUI gesture), outside-clicks/Esc/moves are global. This is *why* click-outside needs `addGlobalMonitorForEvents` and inside-clicks don't double-fire it (see Codebase Patterns).
  - The chord tap consumes its L+R downs (`MouseChordActivation` returns `nil`), so the new global mouse-down "click-outside cancels" monitor can't be spuriously tripped by the summon chord itself — verified by reading the tap before wiring it.
  - Routing click-outside as `.click(over: .none)` (not `.escape`) makes it mode-aware for free: it cancels in click-to-stay and is a no-op in hold-to-select (where the trigger is still physically held).
  - Restore-on-launch only needs to restore to the *captured baseline*, not blanket-show: `hideOtherApps` un-hides a prior-hidden target, so a crash could leave a normally-hidden app showing — the journal records each app's pre-summon `wasHidden` to put it back exactly.
  - Inject the journal store explicitly from AppDelegate; the navigator's default `WindowController()` keeps `store: nil` so the existing fake-backed tests never touch `.standard`.
---

