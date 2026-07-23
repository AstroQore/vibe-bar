# Deployment Guide for Agents

Read this first if you are an AI coding agent (Claude Code, Codex, Cursor,
Aider, etc.) and you have been asked to build, run, or package Vibe Bar
locally. This document is **self-contained**: an agent with no prior
knowledge of this project should be able to follow it top-to-bottom and
end with a working app.

## What Vibe Bar is

A native macOS menu-bar app for monitoring AI subscription quota, reset
forecasts, local token cost, model usage, and provider status across
ChatGPT/Codex, Claude Code, Gemini/AntiGravity, Grok, and other coding plans.
It is a pure Swift package with no Xcode workspace required. The package
produces:

- `VibeBar` — executable target, the actual app binary.
- `VibeBarApp` — AppKit/SwiftUI menu-bar UI module.
- `VibeBarCore` — testable library for parsers, storage, privacy helpers,
  cost/usage logic.
- `VibeBarCoreTests` — `swift test` target.

GitHub Releases provides an ad-hoc-signed Apple-silicon ZIP. Sparkle handles
signed in-app updates after the first Sparkle-enabled version has been
installed, but the public build is not notarized. This guide covers the
reproducible source path: build, verify, ad-hoc sign, and run locally. See
`RELEASING.md` for the tag-driven release and appcast workflow.

## Prerequisites

All of the following must be true on the target Mac before you start:

- **macOS 26 (Tahoe) or newer.** Check with `sw_vers -productVersion`.
- **Xcode 26 with the Swift 6.2 toolchain installed.** Check with:
  - `xcode-select -p` — must point at a working Xcode app, not just
    `CommandLineTools`. If it points at CommandLineTools, fix with
    `sudo xcode-select -s /Applications/Xcode.app`.
  - `swift --version` — must report Swift 6.2 or newer.
- **`git`, `codesign`, and (only if you will also open a PR) `gh`** all
  available on `PATH`.

You do **not** need an Apple Developer account. The packaging script ad-hoc
signs the bundle so it runs on the local machine.

## Build, package, and install (zero-to-running)

Follow these steps in order. An agent with no prior context should be
able to execute them end-to-end and finish with a running, optionally
installed Vibe Bar. If anything fails, see **Common build/run failures**
below.

### 1. Get the source

If the repository is not already on disk:

```sh
git clone https://github.com/AstroQore/vibe-bar.git
cd vibe-bar
```

If you already have a clone, switch into it and confirm it is on the
branch you intend to build:

```sh
cd /path/to/vibe-bar
git status
git rev-parse --abbrev-ref HEAD
```

### 2. Verify the toolchain

```sh
sw_vers -productVersion        # must be 26.x or newer
xcode-select -p                # must point at /Applications/Xcode.app/...
swift --version                # must be 6.2.x or newer
```

If any of these are wrong, stop and tell the user — the build will fail
later in a more confusing way.

### 3. Run unit tests

```sh
swift test
```

The full test suite must pass. If any test fails, stop and surface the failure
to the user before continuing. Packaging on top of broken core logic produces
a broken app.

### 4. Build and package the `.app` bundle

```sh
./Scripts/build_app.sh           # default configuration = release
```

Or pick a configuration explicitly:

```sh
./Scripts/build_app.sh debug     # faster compile, slower runtime
./Scripts/build_app.sh release   # what end users get
```

What the script does (so you can recognize each phase in its output):

1. Runs `swift build -c <config>`.
2. Resolves the executable path with
   `swift build -c <config> --show-bin-path`.
3. Deletes any old `.build/Vibe Bar.app` and creates a fresh bundle
   skeleton under `.build/Vibe Bar.app/Contents`.
4. Copies the freshly built `VibeBar` executable into
   `Contents/MacOS/VibeBar`.
5. Copies SwiftPM's generated `VibeBar_VibeBarCore.bundle` into
   `Contents/Resources`; `PricingResolver` checks this installed-app
   location before falling back to `Bundle.module`.
6. Copies and preserves SwiftPM's versioned
   `Sparkle.framework` symlinks under `Contents/Frameworks`.
7. Copies `Resources/Info.plist` and `Resources/AppIcon.icns` into the
   bundle.
8. Writes `Contents/PkgInfo`.
9. Signs Sparkle's helper components from the inside out, then signs the
   outer app with `Resources/VibeBar.entitlements`.
10. Runs strict deep signature verification on the completed bundle.

The output bundle is `.build/Vibe Bar.app` (the bundle name has a literal
space).

### 5. Verify the bundle's entitlements

```sh
codesign -d --entitlements - ".build/Vibe Bar.app"
```

Vibe Bar runs **unsandboxed**. The output should be an empty
`<dict/>` plist (see `Resources/VibeBar.entitlements`) and must **not**
contain `com.apple.security.app-sandbox`. If `app-sandbox` reappears,
something in `Resources/VibeBar.entitlements` or `Scripts/build_app.sh`
has regressed — stop and surface the regression rather than shipping
a sandboxed bundle (the misc-providers integration depends on
non-sandboxed file/process access).

### 6. Launch the app for a smoke test

```sh
open ".build/Vibe Bar.app"
```

A menu-bar item should appear on the right-hand side of the macOS menu
bar. If macOS reports the bundle as damaged, see **Common build/run
failures**.

### 7. Offer to install into `/Applications`

After step 6 succeeds, **ask the user whether to install Vibe Bar into
the macOS Applications folder.** Do not move the bundle without asking —
the user may prefer to keep the build output inside the repo (for
example, while iterating on the build).

A suggested prompt:

> Build succeeded and Vibe Bar launched from `.build/Vibe Bar.app`. Want
> me to install it to `/Applications/Vibe Bar.app` so it shows up in
> Launchpad and Spotlight?

If the user agrees, install with:

```sh
# Quit any running instance first
osascript -e 'tell application "Vibe Bar" to quit' 2>/dev/null || true

# Remove any previously installed copy
rm -rf "/Applications/Vibe Bar.app"

# Move the freshly built bundle into /Applications
mv ".build/Vibe Bar.app" "/Applications/Vibe Bar.app"

# Launch from its new home
open "/Applications/Vibe Bar.app"
```

If the user declines, leave the bundle at `.build/Vibe Bar.app` and tell
them how to launch it from there
(`open ".build/Vibe Bar.app"`).

This step is macOS-only (Vibe Bar does not build for any other
platform), so `/Applications` is always the right destination when the
user says yes.

## Quick reference

If you only need a fast compile-check (no bundle, no signing):

```sh
swift build
```

If you only want to re-verify an existing bundle:

```sh
codesign -d --entitlements - ".build/Vibe Bar.app"
codesign --verify --deep --strict ".build/Vibe Bar.app"
```

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

If you are debugging weird behavior, that directory is the place to
look. Deleting it resets the app to first-run state. Vibe Bar-owned cookies
and provider secrets live in one versioned Keychain Vault — they are not in
`~/.vibebar/`.

The app reads (never writes) provider-owned CLI credential files and local
session/usage records. Treat those as read-only inputs.

## Common build/run failures

- **`error: unable to find Xcode-select`** — Xcode is not installed or
  `xcode-select` points at CommandLineTools. Run
  `sudo xcode-select -s /Applications/Xcode.app`.
- **`Vibe Bar.app is damaged and can't be opened`** — Gatekeeper
  rejected the ad-hoc signature. Right-click → Open the first time, or
  `xattr -d com.apple.quarantine ".build/Vibe Bar.app"`.
- **`The application can't be opened because the macOS version is too
  old`** — the deployment target is macOS 26. Older systems are not
  supported.
- **`swift test` failures referencing fixtures** — fixtures live under
  `Tests/VibeBarCoreTests/Fixtures/`. They use `/Users/example/...`
  paths on purpose; do not "fix" them to your own home path.
- **The `.app` launches but Codex/Claude show as logged out and all
  numbers are zero** — usually a leftover sandbox container from an
  older build is intercepting reads. Confirm with
  `ls ~/Library/Containers/com.astroqore.VibeBar/Data/ 2>&1`; if the
  directory exists, `rm -rf ~/Library/Containers/com.astroqore.VibeBar/`
  and relaunch. See `AGENTS.md` → "Home Directory" for the grep
  recipe.

## What you should not change without explicit instruction

- The license. AGPL-3.0-only is a board decision, not a code style
  choice.
- The bundle ID `com.astroqore.VibeBar`.
- The sandbox state in `Resources/VibeBar.entitlements`. The plist is
  intentionally empty so the misc-providers feature can read browser
  cookies and probe AntiGravity. Don't re-add `app-sandbox` without
  coordinating those features.
- The persistence root `~/.vibebar/`. New persistent state goes through
  `VibeBarLocalStore`.

## When in doubt

`README.md` and `CONTRIBUTING.md` are the human-facing references. This
file is the agent-facing distillation of them. If they conflict, the
human-facing docs win and this file should be updated.
