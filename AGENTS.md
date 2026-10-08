# Instructions for AI agents

PieSwitcher is a status-bar-only macOS app (`LSUIElement = true`, no Dock icon, no main window). The only visible UI is the menu-bar icon and the About and Preferences windows opened from it.

## Build

```sh
xcodebuild -project PieSwitcher.xcodeproj -scheme PieSwitcher -configuration Debug -derivedDataPath build build
```

`** BUILD SUCCEEDED **` on the last line = it compiled.

## Run

```sh
pkill -x PieSwitcher 2>/dev/null; open build/Build/Products/Debug/PieSwitcher.app
```

Always `pkill` first so the fresh build launches, not a stale instance.

## Confirm it's running

```sh
pgrep -x PieSwitcher
```

PID on stdout = running. No output = it didn't launch — run the binary directly to see stderr:

```sh
build/Build/Products/Debug/PieSwitcher.app/Contents/MacOS/PieSwitcher
```

## Clean up

`pkill -x PieSwitcher` before ending the session.


## Workflow

After completing each task, launch the application and keep it running for my personal use.
