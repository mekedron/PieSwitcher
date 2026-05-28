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
- **Parking a window off-screen resizes it.** The window-level hide-others reveal parks siblings
  at `offScreenPoint` via AX `setPosition`; macOS's `NSWindow` title-bar constraint then **clamps
  the window's height** (not width) so it stays reachable. Always capture AND restore a window's
  *size* alongside its position when parking — `WindowSnapshot.originalSize`, restored in
  `restoreWindowBaseline`/`restoreCapturedFrame` and the crash-recovery `RevealSnapshot`.

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

