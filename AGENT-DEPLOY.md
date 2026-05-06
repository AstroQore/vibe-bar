# Deployment Guide for Agents

Read this first if you are an AI coding agent (Claude Code, Codex, Cursor,
Aider, etc.) and you have been asked to build, run, or package Vibe Bar
locally. It is intentionally short and command-oriented.

## What Vibe Bar is

A native macOS menu-bar app for Codex and Claude Code users. Pure Swift
package, no Xcode workspace required. The package produces:

- `VibeBar` — executable target, the actual app binary.
- `VibeBarApp` — AppKit/SwiftUI menu-bar UI module.
- `VibeBarCore` — testable library for parsers, storage, privacy helpers,
  cost/usage logic.
- `VibeBarCoreTests` — `swift test` target.

There is no installer and no notarized release in this repo. Distribution is
"build from source, ad-hoc sign, run locally."

## Prerequisites

- macOS 26 (Tahoe) or newer.
- Xcode 26 with the Swift 6.2 toolchain installed (`xcode-select -p` should
  point at a working Xcode, not just CommandLineTools).
- `swift --version` should report 6.2 or higher.
- `git`, `codesign`, and `gh` (only needed if you also open a PR).

You do **not** need an Apple Developer account. The packaging script ad-hoc
signs the bundle so it runs on the local machine.

## Build, package, run

The canonical end-to-end sequence:

```sh
swift test                    # ~90 unit tests, must all pass
./Scripts/build_app.sh        # default target = release
open ".build/Vibe Bar.app"
```

The script accepts an explicit configuration:

```sh
./Scripts/build_app.sh debug      # faster compile, slower runtime
./Scripts/build_app.sh release    # what users get
```

It builds the SwiftPM executable, assembles `.build/Vibe Bar.app`, copies
`Resources/Info.plist` and `Resources/AppIcon.icns`, embeds the entitlements
in `Resources/VibeBar.entitlements`, then runs `codesign --sign -` against
the bundle.

If you only need a fast compile-check (no bundle, no signing):

```sh
swift build
```

## Verifying a build

After packaging, the bundle should report the expected entitlements:

```sh
codesign -d --entitlements - ".build/Vibe Bar.app"
```

Expected entitlements include the app sandbox, network client access, and
the home-relative-path entries the app needs to read CLI session logs. If
any of those go missing, something in `Resources/VibeBar.entitlements` or
`Scripts/build_app.sh` regressed.

## Running tests

```sh
swift test
```

Tests cover JSONL scanning, pricing, settings, privacy persistence, the
parsers, and small UI helpers. Add new tests under
`Tests/VibeBarCoreTests/` next to the area you changed. UI code in
`VibeBarApp` is mostly not unit-tested; manual smoke testing is fine for
SwiftUI tweaks but log what you tested.

## Local runtime state (where the app writes)

Vibe Bar persists derived data under the user's home directory:

```text
~/.vibebar/
├── settings.json
├── quotas/
├── cost_snapshots/
├── scan_cache/
├── service_status.json
├── cost_history.json
└── mini_window_geometry.json
```

If you are debugging weird behavior, that directory is the place to look.
Deleting it resets the app to first-run state. Keychain stores Claude
session cookies and the resolved Claude organization ID — those are not in
`~/.vibebar/`.

The app reads (never writes) Codex and Claude CLI credential files and
their session JSONL logs. Treat those as read-only inputs.

## Common build/run failures

- **`error: unable to find Xcode-select`** — Xcode isn't installed or
  `xcode-select` points at CommandLineTools. Run
  `sudo xcode-select -s /Applications/Xcode.app`.
- **`Vibe Bar.app is damaged and can't be opened`** — Gatekeeper rejected
  the ad-hoc signature. Right-click → Open the first time, or
  `xattr -d com.apple.quarantine ".build/Vibe Bar.app"`.
- **`The application can't be opened because the macOS version is too old`**
  — the deployment target is macOS 26. Older systems are not supported.
- **`swift test` failures referencing fixtures** — fixtures live under
  `Tests/VibeBarCoreTests/Fixtures/`. They use `/Users/example/...` paths
  on purpose; do not "fix" them to your own home path.

## What you should not change without explicit instruction

- The license. AGPL-3.0-only is a board decision, not a code style choice.
- The bundle ID `com.astroqore.VibeBar`.
- The sandbox state in `Resources/VibeBar.entitlements`. If a file path
  needs new access, add a narrow temporary exception, do not drop the
  sandbox.
- The persistence root `~/.vibebar/`. New persistent state goes through
  `VibeBarLocalStore`.

## When in doubt

`README.md` and `CONTRIBUTING.md` are the human-facing references. This
file is the agent-facing distillation of them. If they conflict, the
human-facing docs win and this file should be updated.
