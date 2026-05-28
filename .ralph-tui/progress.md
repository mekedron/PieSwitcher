# Ralph Progress Log

This file tracks progress across iterations. Agents update this file
after each iteration and it's included in prompts for context.

## Codebase Patterns (Study These First)

- **One shared `RadialLayout` per ring.** `RadialRing` stores its `layout`; both rendering
  (`RadialRingView`/`RadialWedge`) and hit-testing (`RadialNavigator.region`) read it, so they
  cannot desync. Never build a `RadialLayout` ad-hoc at a call site.
- **`RadialLayout` is a per-slice arc table** (`[SliceArc]` of `start`+`span`, clockwise from top,
  y-down). `init(itemCount:)` builds an equal division (apps ring, back-compat). `windowRing(...)`
  builds the US-016 window arcs: each window = one app-arc fanning from the parent, or an overflow
  fisheye (focused window full app-arc, rest compressed). `hitTest` finds the arc by modulo-2π
  containment (`normalized(angle - arc.start) < arc.span`) so arcs may wrap the seam and gaps return nil.
- **`region(forOffset:)` empty-sector no-op:** when the cursor is inside a ring band but over an
  uncovered angular gap, return the current `hovered` (a no-op) instead of `.none`, so the sub-wheel
  doesn't collapse. `.none` is reserved for the dead centre / outside every band.
- **Adding an XCTest file = 4 manual edits to `Bringr.xcodeproj/project.pbxproj`** (no synchronized
  groups): PBXBuildFile, PBXFileReference, the PBXGroup child list, and the PBXSourcesBuildPhase list.
  UUIDs follow the sequential `1A0000000000000000000XX` scheme — pick the next free value.
- **SwiftLint `--strict` gotchas:** test files cap at 400 lines / 250-line type body (split big
  suites into topic files, each with its own private fixtures); identifiers must be >= 2 chars
  (no `i` loop vars; `x`/`y`/`id` excepted); lines <= 120. **`file_length` caps ALL files at 400**
  too — `WindowControl.swift` sits right at it, so any addition there must be paid for by
  condensing comments / using single-line `if let x = … { … }` (the codebase style).
- **Park windows off-screen on X only — never off the bottom.** The window-level hide-others
  reveal parks siblings at `offScreenPoint` via AX `setPosition`. macOS's title-bar-reachability
  constraint **clamps a window's height** (not width) when its title bar is moved off the *bottom*
  of every screen, and reapplying the height on restore *races* that clamp (~50/50 — Bringr-93j.32).
  So `offScreenPoint` keeps `y` on-screen (`x` far right ⇒ window fully hidden) so the clamp never
  fires and there is no height to lose. Size is still captured/restored (`WindowSnapshot.originalSize`,
  in `restoreWindowBaseline`/`restoreCapturedFrame`/crash-recovery `RevealSnapshot`) as a safety net.

---

## 2026-05-28 - Bringr-93j.25

US-016: window sub-wheel — app-aligned arcs with overflow fisheye.

- Generalised `RadialLayout` from an even N-division to an explicit `[SliceArc]` table.
  `init(itemCount:)` reproduces the old equal layout byte-for-byte (apps ring untouched);
  added `init(arcs:)`, `span(ofSliceAt:)`, and the `windowRing(...)` factory. Rewrote
  `hitTest` to modulo-2π arc containment so uneven/wrapping arcs and empty gaps work.
- `RadialRing` now carries a stored `layout` (shared by render + hit-test). `RadialNavigator`
  builds it once in `open`/`expandApp` and added `focusedWindowIndex` + `focusWindowSlice(at:)`
  so the overflow fisheye focus follows the hovered window live. `region(forOffset:)` returns
  the current `hovered` (no-op) for an empty outer sector instead of collapsing.
- `RadialMenuView` reads `ring.layout` instead of constructing one.
- Files: `Bringr/RadialLayout.swift`, `Bringr/RadialNavigator.swift`, `Bringr/RadialMenuView.swift`,
  new `BringrTests/RadialNavigatorFisheyeTests.swift` (wired into `project.pbxproj`),
  `BringrTests/RadialLayoutTests.swift`, `BringrTests/RadialNavigatorCommitTests.swift`.
- Quality gates: build SUCCEEDED, `swiftlint lint --strict` 0 violations (44 files),
  `xcodebuild test` 224 tests pass. App relaunched and left running.
- **Learnings:**
  - Fisheye anchoring: the focused slice keeps its ordinal slot and grows in place (don't
    recenter over the parent), so it stays under the cursor when it pops — no focus flicker.
  - `focusedWindowIndex != nil` is the single source of truth for "overflow fisheye active";
    set it only when `windowCount > appCount && appCount > 1` (single-app falls back to equal
    division, no zero-width slices), and reset on collapse/re-target.
  - The empty-sector no-op relies on every `updateHover` branch being idempotent for the same
    region, so returning the last `hovered` from `region(forOffset:)` is safe.
  - Splitting the navigator tests into a Fisheye file kept both under SwiftLint's caps.

---

## 2026-05-28 - Bringr-93j.28

Bug: "Hide others" mode returned windows smaller — on a 4K monitor Chrome came back shorter
(height wrong, width fine).

- **Root cause:** the window-level hide-others reveal parks siblings off-screen with AX
  `setPosition` (Bringr-93j.24), but only captured/restored *position*. macOS's `NSWindow`
  title-bar constraint clamps a window's **height** when it's moved off the bottom of every
  screen, so restoring position alone left the window at the clamped (shorter) height.
- **Fix:** capture and restore window *size* as well. Added `size(of:)`/`setSize(_:_:)` to
  `WindowControlling` (+ `LiveWindowSystem` AX impl reading/writing `kAXSizeAttribute`, +
  `FakeWindowSystem`), `WindowSnapshot.originalSize`, and threaded it through
  `captureWindowBaselineIfNeeded`, `restoreWindowBaseline`, `restoreCapturedFrame` (renamed from
  `restoreCapturedPosition`), and the crash-recovery `RevealSnapshot.WindowEntry` + `applySnapshot`.
  Restore order is position-then-size so the window grows from its anchored top-left.
- Files: `Bringr/WindowControl.swift`, `Bringr/LiveWindowSystem.swift`, `Bringr/RevealState.swift`,
  `BringrTests/FakeWindowSystem.swift`, `BringrTests/RevealStrategyTests.swift` (2 new tests +
  `sizedApp` fixture), `BringrTests/RevealStateTests.swift` (1 new test + baseline assertion).
- Quality gates: build SUCCEEDED, `swiftlint lint --strict` 0 violations (44 files),
  `xcodebuild test` 227 tests pass. App relaunched and left running.
- **Learnings:**
  - The off-screen park itself triggers the resize; size capture/restore is a complete fix
    regardless of *why* the size changed, so I kept the park location unchanged (minimal change).
  - `WindowControl.swift` was exactly at the 400-line `file_length` ceiling, so the ~14 lines the
    fix legitimately needed had to be paid back by condensing existing doc comments and collapsing
    `if let position { … }` blocks to single lines (matches existing `if system.isMinimized(…) { … }`).
  - `var foo: T?` (optional, no default) gets an implicit `nil` default in a struct's synthesized
    memberwise init — so adding `var originalSize: CGSize?` to `RevealSnapshot.WindowEntry` didn't
    break existing `.init(…)` callsites that omit it (and old JSON decodes with it nil).

---

## 2026-05-28 - Bringr-93j.32

Follow-up to Bringr-93j.28: "Hide others" height restore was still intermittent (~50/50).

- **Root cause (the race):** Bringr-93j.28 *captured and reapplied* the window size on restore,
  but the reveal still parked siblings at `(50_000, 50_000)` — off the *bottom* of every screen.
  macOS's title-bar-reachability constraint clamps the window's HEIGHT (never width) when the title
  bar goes off the bottom. On restore the code does `setPosition` (always lands — moving on-screen
  is unconstrained) then `setSize`; the `setSize` *races* the clamp: if it is evaluated before the
  on-screen position commits, macOS re-applies the off-bottom clamp and the height grow is rejected.
  That's the ~50/50 — and it explains why *position* always came back but *height* didn't.
- **Fix:** stop triggering the clamp instead of trying to recover from it. `offScreenPoint` is now
  `(50_000, 100)` — `x` far off-screen-right (window still fully hidden) but `y` on the primary
  screen, so the title bar stays vertically reachable and macOS never shrinks the height. With no
  clamp, the captured size never differs from the live size, so restore's `setSize` is a confirming
  no-op and there is no race to win. Size capture/restore (Bringr-93j.28) is kept as a safety net.
- Files: `Bringr/WindowControl.swift` (one-constant change + comment, net-zero lines — file is at
  the 400-line `file_length` cap), new `BringrTests/WindowParkPointTests.swift` (park-point invariant
  guard, wired into `project.pbxproj` with the 4 edits, UUIDs `…75`/`…76`).
- Quality gates: build SUCCEEDED, `swiftlint lint --strict` 0 violations (45 files),
  `xcodebuild test` 228 tests pass. App relaunched and left running (PID confirmed).
- **Learnings:**
  - When a back-to-back AX `setPosition`→`setSize` is flaky, suspect an OS *constraint* that one
    op fights and the other doesn't — here position is unconstrained but size is clamped by the
    off-bottom title-bar rule. Prevention (don't enter the constrained state) beats a reapply race.
  - The clamp is purely *vertical*: x-off-screen never touched width in Bringr-93j.28, so keeping
    only `y` on-screen is sufficient to dodge it. A window parked at huge `x` is fully hidden
    regardless of `y`, so on-screen `y` costs nothing.
  - `WindowControlTests` and `RevealStrategyTests` are both at/near the 250-line `type_body_length`
    cap, so even a 6-line test must go in its own topic file (the documented split pattern).
  - The fake can't model the OS clamp, so the honest unit-level guard is the *park-point invariant*
    (x off-screen, y on-screen) — not a fake-driven "no clamp" assertion that would be vacuous.

---

