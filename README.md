# PieSwitcher

A focused radial / pie-menu window switcher for macOS. PieSwitcher lives in the
menu bar (no Dock icon, no main window) and does one thing well:

**Switch fast between multiple windows of the same app, without touching the keyboard.**

You summon a wheel at your cursor, glide to an app, glide to one of its
windows, and let go. That window comes forward, focus follows, and everything
else snaps back to where it was. No Cmd-Tab, no Mission Control, no clicking
around the Dock guessing which Chrome window has the tab you wanted.

## Why another one?

There are already plenty of radial launchers on macOS — Launchy, Pieoneer,
OrbitRing, Kando, DockDoor, and so on. They all try to do *everything*: open
files, fire URLs, run scripts, switch windows, paste snippets, control music.
That's fine, but for me it dilutes the one thing I actually want from this kind
of tool. PieSwitcher's first and only job is same-app window switching. Files,
folders, URLs, custom commands — maybe later (see [Out of scope](#out-of-scope)).

## The core interaction

1. **Summon** the wheel at your cursor (see [Summoning the wheel](#summoning-the-wheel)).
2. The top ring shows every app that currently has on-screen windows, ordered
   like ⌘-Tab (most recently used first) by default.
3. **Hover an app** — say Google Chrome — and everything that isn't Chrome
   gets out of the way (the exact effect is the [reveal strategy](#reveal),
   "hide others" by default). A sub-wheel opens with one slice per Chrome window.
4. **Hover a window** — every other Chrome window gets out of the way too,
   leaving only the one under your cursor on screen. Instant visual confirmation.
5. **Commit** — that window comes forward, its app activates, focus follows, and
   every app/window that was pushed aside is restored to exactly where it was.

PieSwitcher remembers which window you picked for each app and pre-highlights it the
next time you open that app's sub-wheel.

Backing out is always safe: Esc, clicking the centre dead zone, clicking
outside, or releasing the trigger off any slice all cancel cleanly and restore
your windows. If PieSwitcher is ever force-quit mid-reveal, it restores any stranded
window the next time it launches.

> **v1 note:** window slices show a number and title, not a captured thumbnail.
> Live previews need Screen Recording permission and are [future work](#out-of-scope).

## Summoning the wheel

PieSwitcher offers two global triggers, both configurable in Preferences:

- **Mouse** — *Left + right click together* (the default). Normal single clicks
  pass through untouched.
- **Keyboard** — *hold a modifier combination* (defaults to **Fn**). No click or
  tap needed; just hold the keys. On a laptop without an external mouse, this is
  the only way to summon the wheel.

You can also open the wheel from the menu-bar icon via **Open Window Switcher**.

How a release behaves depends on the interaction mode:

- **Hold to select** (default): the wheel stays open while you hold the trigger;
  release over a slice to choose it, release on the centre to cancel.
- **Click to stay open**: the wheel stays after you release; click a slice to
  choose it, or click the centre / press Esc to cancel.

## Preferences

Open **Preferences…** from the menu-bar icon (⌘,). Every setting is persisted
and takes effect on the **next summon** — no relaunch needed.

| Section | What it controls |
| --- | --- |
| **Permissions** | Accessibility status, with **Open System Settings** and **Re-check** actions. |
| **Mouse** | *Left + right click together* to summon. |
| **Keyboard** | The modifier combination to hold (default **Fn**), with a Fn / Control / Option / Shift / Command picker and a hold delay. The only way to summon on a laptop without an external mouse. |
| **Startup** | Launch PieSwitcher at login. |
| **Interaction** | *Hold to select* (default) vs *Click to stay open*. |
| **Reveal** | How other apps/windows get out of the way (see [below](#reveal)). |
| **Sorting** | Apps: *Recently used (⌘-Tab order)* (default) or *By name*. Windows: *Recently used* (default) or *Fixed position*. |
| **Appearance** | Wheel size, slice fill opacity, and label visibility. |

### Reveal

The reveal strategy applies at both wheel levels — hovering an app reveals it
against the other apps, and hovering a window reveals it against its app's other
windows:

- **Hide others** (default) — hide everything except the hovered app/window, so
  only it remains on screen.
- **Raise to front** — bring the hovered app/window forward, leaving everything
  else in place (the most reversible option, nothing is hidden).

## Permissions

PieSwitcher needs **Accessibility** access to enumerate windows, switch between them,
and observe its global activation triggers. On first launch it detects the
current state and, if access is missing, points you to the right System Settings
pane. Until access is granted the activation triggers are inert (the app never
crashes), and PieSwitcher picks up the change automatically once you grant it — no
relaunch required.

## Requirements

- macOS 14.0 or later
- Accessibility permission (see above)

## Out of scope

PieSwitcher v1 is deliberately narrow. The following are explicitly **not** part of
v1 (the architecture leaves room for them, but none ship today):

- Live / captured window-preview thumbnails (needs Screen Recording permission)
- Opening files, folders, or URLs
- Custom commands and scripts
- A UI for building or reordering your own menus
- Animations
- Cross-restart preview fidelity (remembered selections match best-effort by
  title or position, not by an exact window id)

## Stack

- Pure Swift, latest toolchain
- SwiftUI for the menu bar, About, and Preferences windows; AppKit / Core
  Graphics / Accessibility (AXUIElement) for the overlay, window enumeration,
  control, and global event taps
- Xcode project — open `PieSwitcher.xcodeproj` and press ⌘R

## Building & running

```sh
# Build — must end in "** BUILD SUCCEEDED **"
xcodebuild -project PieSwitcher.xcodeproj -scheme PieSwitcher -configuration Debug -derivedDataPath build build

# Run (always pkill first so the fresh build launches, not a stale instance)
pkill -x PieSwitcher 2>/dev/null; open build/Build/Products/Debug/PieSwitcher.app
```

Or just open the project in Xcode and press ⌘R. PieSwitcher has no Dock icon — look
for the hexagon-grid icon in the menu bar.

## Quality gates

All three commands must pass before any change is considered done:

```sh
# 1. Compile — must end in "** BUILD SUCCEEDED **"
xcodebuild -project PieSwitcher.xcodeproj -scheme PieSwitcher -configuration Debug -derivedDataPath build build

# 2. Lint — must report zero violations (warnings fail under --strict)
swiftlint lint --strict

# 3. Test — all XCTest cases must pass
xcodebuild test -project PieSwitcher.xcodeproj -scheme PieSwitcher -destination 'platform=macOS'
```

SwiftLint is a separate binary; install it with `brew install swiftlint`. Its
rules live in [`.swiftlint.yml`](.swiftlint.yml). Unit tests live in the
`PieSwitcherTests` target (a host-based bundle loaded into `PieSwitcher.app`).

## Releasing

Releases are produced by `.github/workflows/release.yml`, which triggers on
any pushed `v*.*.*` tag, builds a universal `PieSwitcher.app`, codesigns it
with a Developer ID Application certificate, notarizes it with Apple, wraps
it in a DMG, signs the DMG with the Sparkle EdDSA key, publishes a GitHub
Release, and (optionally) updates a Homebrew tap.

First-time setup is a two-step process:

1. Follow [`docs/release-setup.md`](docs/release-setup.md) to generate the
   Apple Developer certificate, the App Store Connect API key, and (optionally)
   the Homebrew tap PAT.
2. From the repo root, run:

   ```sh
   ./scripts/bootstrap-release-secrets.sh
   # …or, if you do not have a Homebrew tap yet:
   ./scripts/bootstrap-release-secrets.sh --skip-homebrew
   ```

   The script uploads every needed `gh secret` and tells you exactly which
   ones were set, reused, regenerated, or skipped.

After both steps, push a tag (e.g., `git tag v0.1.0 && git push origin v0.1.0`)
to cut a release.

## Repository

<https://github.com/mekedron/PieSwitcher>
