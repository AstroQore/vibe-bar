# AGENTS.md — Vibe Bar Project Guide for AI Agents

This file is the single source of truth for AI coding agents (Claude Code,
Codex, Cursor, Aider, etc.) working on Vibe Bar. It is **self-contained**:
an agent with no prior knowledge of this project should be able to read
it top-to-bottom and end with a working build, a clean PR, and no
sandbox-related regressions.

Humans are welcome here too. The shorter, human-focused version is
[CONTRIBUTING.md](CONTRIBUTING.md).

## Document Map

| File | Audience | Purpose |
| --- | --- | --- |
| [AGENTS.md](AGENTS.md) (this file) | AI agents (and curious humans) | Comprehensive operating manual: orientation, build, conventions, sandbox rule, PR, release. |
| [AGENT-DEPLOY.md](AGENT-DEPLOY.md) | AI agents | Focused "clone → build → smoke-test → optional install" walkthrough. |
| [AGENT-PR.md](AGENT-PR.md) | AI agents | Focused "branch → verify → push → open PR" walkthrough. |
| [CONTRIBUTING.md](CONTRIBUTING.md) | Humans | Short version of this file's project rules. |
| [SECURITY.md](SECURITY.md) | Anyone | Security disclosure policy and what not to paste in reports. |
| [README.md](README.md) / [README.zh-CN.md](README.zh-CN.md) | End users | What Vibe Bar is and how to install it. |
| [CLAUDE.md](CLAUDE.md) | Claude Code | Auto-loaded entry point that points back to this file. |

If this file ever conflicts with `CONTRIBUTING.md`, the human-facing doc
wins and this file should be updated to match.

## 1. What Vibe Bar Is

Vibe Bar is a native macOS menu-bar app for developers who use OpenAI/Codex
and Anthropic/Claude Code (often side-by-side) and want subscription
quota, usage pace, local token cost, and provider service status visible
in one quiet desktop surface — without opening multiple dashboards.

It is a pure Swift package, distributed as **source only**. There is no
Xcode workspace, no installer, no notarized release, and no production
server. The "deploy" target is the user's own Mac (and optionally
`/Applications`); the "publish" target is GitHub.

Key product surfaces:

- Menu-bar quota indicators for OpenAI/Codex and Anthropic/Claude Code.
- Overview dashboard (quota pace, status, cost history, token totals).
- Provider detail pages (utilization, model rankings, heatmaps, hourly
  burn rate, live service status).
- Mini floating window with regular and compact layouts.
- Local-first cost tracking from CLI session logs.
- Privacy controls for retention, clearing derived cost data, and
  disabling cost-history persistence.

## 2. Repository Layout

Single SwiftPM package, two product targets and one test target:

```text
.
├── Package.swift                  # SwiftPM manifest, macOS 26 + Swift 6.2
├── Sources/
│   ├── VibeBarApp/                # AppKit/SwiftUI menu-bar UI (executable)
│   │   ├── AppDelegate.swift
│   │   ├── AppEnvironment.swift
│   │   ├── StatusItemController.swift
│   │   ├── MiniQuotaWindowController.swift
│   │   ├── ServiceStatusController.swift
│   │   ├── ClaudeWebLoginController.swift
│   │   ├── ClaudeRoutineBudgetWebViewFetcher.swift
│   │   ├── LoginItemController.swift
│   │   ├── ProviderBrandIcon.swift
│   │   ├── VibeBarApp.swift
│   │   ├── Controllers/           # SwiftUI host controllers
│   │   └── Views/                 # SwiftUI view tree
│   └── VibeBarCore/               # Pure-Swift testable library
│       ├── Adapters/              # Provider quota + response parsers
│       ├── Credentials/           # CLI credential readers + Keychain store
│       ├── Models/                # Plain data types (settings, quotas, cost)
│       ├── Services/              # Cost scanner, quota refresh, status fetch
│       ├── Storage/               # Local-store roots, caches, settings
│       ├── Utilities/             # Privacy helpers, real-home, formatters
│       └── Vendored/
├── Tests/
│   └── VibeBarCoreTests/          # `swift test` target (~90 tests)
├── Resources/
│   ├── Info.plist                 # Bundle ID, version, LSUIElement
│   ├── VibeBar.entitlements       # Sandbox + network + home-relative paths
│   ├── AppIcon.icns / AppIcon.png
│   └── README/                    # Screenshots used by README.md
├── Scripts/
│   └── build_app.sh               # Release packaging + ad-hoc codesign
├── .github/
│   ├── ISSUE_TEMPLATE/
│   └── pull_request_template.md
├── AGENTS.md / AGENT-DEPLOY.md / AGENT-PR.md
├── CONTRIBUTING.md / SECURITY.md
├── README.md / README.zh-CN.md
├── LICENSE                        # AGPL-3.0-only
└── CLAUDE.md
```

Targets:

- **`VibeBar`** — executable, built from `Sources/VibeBarApp`. The actual
  app binary that goes inside `.build/Vibe Bar.app/Contents/MacOS/VibeBar`.
- **`VibeBarCore`** — library, built from `Sources/VibeBarCore`.
  Testable, pure Swift, no AppKit/SwiftUI imports.
- **`VibeBarCoreTests`** — `swift test` target.

Boundary rule: heavy logic lives in `VibeBarCore`; UI glue lives in
`VibeBarApp`. If you find yourself adding parsers, scanners, or storage
to `VibeBarApp`, that's a sign it should move down to Core.

## 3. Toolchain Prerequisites

All must be true on the build machine:

- **macOS 26 (Tahoe) or newer.** `sw_vers -productVersion`.
- **Xcode 26 with the Swift 6.2 toolchain.**
  - `xcode-select -p` must point at a working Xcode app, not just
    `CommandLineTools`. If wrong:
    `sudo xcode-select -s /Applications/Xcode.app`.
  - `swift --version` must report Swift 6.2 or newer.
- **`git`, `codesign`** on `PATH`. **`gh`** is only required if you will
  also open a PR.

You do **not** need an Apple Developer account. The packaging script
ad-hoc signs the bundle so it runs on the local machine.

## 4. Build, Test, Package, Install (zero to running)

This sequence assumes a fresh checkout and ends with a runnable Vibe Bar.

### 4.1 Get the source

```sh
git clone https://github.com/AstroQore/vibe-bar.git
cd vibe-bar
```

If you already have a clone:

```sh
cd /path/to/vibe-bar
git status
git rev-parse --abbrev-ref HEAD
```

### 4.2 Verify the toolchain

```sh
sw_vers -productVersion        # 26.x or newer
xcode-select -p                # /Applications/Xcode.app/...
swift --version                # 6.2.x or newer
```

If any check fails, stop and surface the failure rather than letting the
build fail in a more confusing place later.

### 4.3 Run unit tests

```sh
swift test
```

About 90 tests run; **all** must pass. If any fail, stop and surface the
failure to the user. Packaging on top of broken core logic produces a
broken app.

### 4.4 Build and package the `.app` bundle

```sh
./Scripts/build_app.sh           # default configuration = release
./Scripts/build_app.sh debug     # faster compile, slower runtime
./Scripts/build_app.sh release   # what end users get
```

What the script does (so each phase in its output is recognizable):

1. `swift build -c <config>`.
2. Resolves the executable path with
   `swift build -c <config> --show-bin-path`.
3. Deletes any old `.build/Vibe Bar.app` and creates a fresh bundle
   skeleton at `.build/Vibe Bar.app/Contents/{MacOS,Resources}`.
4. Copies the freshly built `VibeBar` executable into
   `Contents/MacOS/VibeBar`.
5. Copies `Resources/Info.plist` and `Resources/AppIcon.icns` into the
   bundle.
6. Writes `Contents/PkgInfo`.
7. `codesign --force --deep --sign - --entitlements Resources/VibeBar.entitlements ".build/Vibe Bar.app"`.

The output bundle is `.build/Vibe Bar.app` (the bundle name has a
literal space).

### 4.5 Verify the bundle's entitlements

```sh
codesign -d --entitlements - ".build/Vibe Bar.app"
codesign --verify --deep --strict ".build/Vibe Bar.app"
```

The entitlement output **must** include all of:

- `com.apple.security.app-sandbox`
- `com.apple.security.network.client`
- `com.apple.security.temporary-exception.files.home-relative-path.read-only`
  with at least `/.codex/`, `/.claude/`, `/.config/claude/`.
- `com.apple.security.temporary-exception.files.home-relative-path.read-write`
  with at least `/.vibebar/`.

If anything is missing, something in `Resources/VibeBar.entitlements` or
`Scripts/build_app.sh` has regressed. Stop and surface the regression
rather than shipping a broken bundle.

### 4.6 Smoke-test the bundle

```sh
open ".build/Vibe Bar.app"
```

A menu-bar item should appear on the right of the macOS menu bar. If
macOS reports the bundle as damaged, see **§ 10. Common Build/Run Failures**.

After it launches, confirm no shadow state tree appeared in the sandbox
container:

```sh
ls ~/Library/Containers/com.astroqore.VibeBar/Data/
```

The container should contain only `Library/`, `tmp/`, `SystemData/`, and
the standard `Desktop` / `Documents` / `Downloads` / `Movies` / `Music`
/ `Pictures` symlinks. Anything else (e.g. a parallel `.codex/`,
`.claude/`, or `.vibebar/` inside the container) means a call site is
still using a sandbox-rewritten home API. See **§ 6. Sandbox & Home
Directory**.

### 4.7 Offer to install into `/Applications`

After the smoke test succeeds, **ask the user whether to install Vibe
Bar into `/Applications`.** Do not move the bundle without asking — the
user may prefer to keep iterating from `.build/Vibe Bar.app`.

If the user agrees:

```sh
osascript -e 'tell application "Vibe Bar" to quit' 2>/dev/null || true
rm -rf "/Applications/Vibe Bar.app"
mv ".build/Vibe Bar.app" "/Applications/Vibe Bar.app"
open "/Applications/Vibe Bar.app"
```

If the user declines, leave the bundle at `.build/Vibe Bar.app` and tell
them how to launch it (`open ".build/Vibe Bar.app"`).

This step is macOS-only (Vibe Bar does not build for any other
platform), so `/Applications` is always the right destination when the
user says yes.

### 4.8 Quick reference

A fast compile-only check (no bundle, no signing):

```sh
swift build
```

Re-verify an existing bundle without rebuilding:

```sh
codesign -d --entitlements - ".build/Vibe Bar.app"
codesign --verify --deep --strict ".build/Vibe Bar.app"
```

## 5. Local Runtime State (where the app writes)

Vibe Bar persists derived data under the user's **real** home directory:

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

If you are debugging odd behavior, that directory is the place to look.
Deleting it resets the app to first-run state.

Keychain stores Claude session cookies and the resolved Claude
organization ID — those are not in `~/.vibebar/`. The app reads (never
writes) Codex and Claude CLI credential files and their session JSONL
logs. Treat those as read-only inputs.

## 6. Sandbox & Home Directory (CRITICAL — this has bitten us three times now)

Vibe Bar is a sandboxed app, and sandboxed macOS apps have **two
different "home directories"**. Confusing them is how the app silently
turns into a fresh-install lookalike — Codex and Claude show as logged
out, the cost/usage panels go blank, mini-window geometry and settings
roll back to defaults, all while the real `~/.codex/`, `~/.claude/`,
and `~/.vibebar/` are right there on disk and untouched.

**Almost every Foundation home API returns the container path when
the app is sandboxed. Apple's docs do not make this clear — assume
nothing, measure.** The probe `AppDelegate` ran on macOS 26 (Tahoe)
inside this exact bundle reported:

| API                                                | Returned in our sandbox                                           |
| -------------------------------------------------- | ----------------------------------------------------------------- |
| `NSHomeDirectory()`                                | `~/Library/Containers/com.astroqore.VibeBar/Data` (container)     |
| `FileManager.default.homeDirectoryForCurrentUser`  | container                                                         |
| `URL.homeDirectory` (macOS 13+)                    | container                                                         |
| `NSHomeDirectoryForUser(NSUserName())`             | container *(despite Apple docs implying real home)*               |
| `ProcessInfo.processInfo.environment["HOME"]`      | container                                                         |
| `getpwuid(getuid()).pointee.pw_dir`                | `/Users/<you>` (the **real** home) ✓                              |

Only `getpwuid` survives the redirect, because passwd lookups go
through an XPC service that doesn't apply the sandbox `HOME` rewrite.
This is what `Sources/VibeBarCore/Utilities/RealHomeDirectory.swift`
uses. **Do not "simplify" it to `NSHomeDirectoryForUser` — that breaks
the app silently.** If you doubt it, run the probe again: the snippet
in the AppDelegate git history (`git log -p -- Sources/VibeBarApp/AppDelegate.swift`)
writes a one-shot diagnostic to `NSTemporaryDirectory()/vibebar_probe.log`.

The temp-exception entitlements in `Resources/VibeBar.entitlements`
(`/.codex/`, `/.claude/`, `/.config/claude/`, `/.vibebar/`) grant
**permission** to read/write the real-home paths. They are not a path
redirect. If the code asks for `homeDirectoryForCurrentUser/.codex/...`,
sandbox happily resolves that to `~/Library/Containers/.../Data/.codex/`,
which doesn't exist, and you get "no credential found." The entitlement
does not save you.

### 6.1 How to recognize the regression

- Codex card says logged out / blank quota even though
  `~/.codex/auth.json` is on disk.
- Claude card behaves the same way despite `~/.claude/.credentials.json`.
- Cost / token totals are zero; "0 sessions found"; heatmaps are empty.
- Mini-window position, settings, and recent-data feel reset.
- Smoking gun: both `~/.vibebar/` and
  `~/Library/Containers/com.astroqore.VibeBar/Data/.vibebar/` exist, and
  the container copy is the small/empty one — the app is reading and
  writing the container while ignoring the real home.

### 6.2 The rule

- Any path under the **real** user home — `~/.codex/`, `~/.claude/`,
  `~/.config/claude/`, and `~/.vibebar/` itself — must resolve home
  through `RealHomeDirectory` (which calls
  `getpwuid(getuid()).pointee.pw_dir` internally). Never
  `NSHomeDirectory()`, `FileManager.default.homeDirectoryForCurrentUser`,
  `NSHomeDirectoryForUser`, `URL.homeDirectory`, or `getenv("HOME")` —
  every one of those is rewritten by the sandbox.
- The helper lives at `Sources/VibeBarCore/Utilities/RealHomeDirectory.swift`.
  One helper is the only way to keep the next refactor honest.
- Before you commit, grep:

  ```sh
  grep -rn 'NSHomeDirectory()\|homeDirectoryForCurrentUser\|URL\.homeDirectory\|NSHomeDirectoryForUser\|getenv("HOME")' Sources
  ```

  Every hit must either be inside `RealHomeDirectory` itself, an
  explicit "scratch lives in the sandbox" call site (e.g.
  `NSTemporaryDirectory()` for sandboxed scratch is fine), or a
  `homeDirectory:` test parameter. New hits in product code are bugs.
- After `./Scripts/build_app.sh release` and a real run, confirm the
  app did not silently create a parallel state tree:

  ```sh
  ls ~/Library/Containers/com.astroqore.VibeBar/Data/
  ```

  Anything other than `Library/`, `tmp/`, `SystemData/`, and the
  symlinks for Desktop/Documents/Downloads/Movies/Music/Pictures means
  some call site is still using the container-home API. Fix it; do not
  ship.

### 6.3 Adding a new path under real home

1. Add the path (with leading slash, e.g. `/.foo/`) to the matching
   `temporary-exception.files.home-relative-path.read-only` or
   `…read-write` array in `Resources/VibeBar.entitlements`.
2. Use the real-home helper to construct the URL.
3. `./Scripts/build_app.sh release`, then `codesign -d --entitlements -`
   on the bundle to confirm the new path made it in.
4. Run the app; check no shadow directory appeared inside
   `~/Library/Containers/com.astroqore.VibeBar/Data/`.

### 6.4 `homeDirectory:` parameters in `CostUsageService` / `CostUsageScanner` / `CostUsageScanCache`

These exist for **test isolation only** — tests pass a synthetic
temp directory so fixtures land somewhere disposable. The default value
(`= NSHomeDirectory()`) is exactly the bug surface above. Do not delete
the parameter; replace the default with the real-home helper. Tests
keep working because they pass an explicit value.

### 6.5 Why this keeps coming back

The entitlement file looks "right" (it lists every path the app needs)
and a casual review of the code looks "right" too (it asks for
`~/.foo`). Both halves are individually reasonable; only the
combination is wrong, and the failure mode is silent — the app runs,
the popover renders, just with empty data. That's why this needs a
written rule with a grep recipe, not vibes.

## 7. Code Conventions

- **Swift package**, two targets: `VibeBarCore` (testable, pure) and
  `VibeBarApp` (AppKit/SwiftUI menu-bar app). Heavy logic lives in Core;
  UI glue in App.
- **No personal paths or IDs in source.** No `/Users/<name>`, no real
  org UUIDs, no real OAuth tokens, no real session cookies. Test
  fixtures use `/Users/example/...` and synthetic JWTs.
- **Don't write to `~/` directly from new code.** Storage paths go
  through `VibeBarLocalStore` and live under `~/.vibebar/`.
- **Privacy logging.** Never `print` raw tokens, cookies, JWT payloads,
  or email addresses. Use `SafeLog.sanitize` and `EmailMasker`. The app
  is sandboxed (`Resources/VibeBar.entitlements`) — keep it that way; if
  you need a new file path, add it to the temporary-exception list,
  don't drop the sandbox.
- **Performance.** Avoid `TimelineView(.periodic(...))` in deep view
  trees that may be eagerly instantiated; prefer scoping to the visible
  surface. The mini window's screen position is persisted to its own
  JSON file (`mini_window_geometry.json`) — don't fold it back into
  `AppSettings`, because every settings write fans out to every Combine
  subscriber.
- **JSONL parsing must be O(n).** See
  `CostUsageScanner.forEachJSONLLine`: use a moving cursor, not
  `removeSubrange`.

## 8. Privacy & Source-Content Rules

These apply regardless of who you commit as. The repo is public
AGPL-3.0-only — every commit, file, and diff is visible to the world.

What is **not** allowed in any commit:

- Personal emails, real org UUIDs, OAuth tokens, or session cookies
  inside source files, tests, fixtures, or log strings.
- `/Users/<name>` paths or machine hostnames in fixtures, examples, or
  output. Use `/Users/example/...` and synthetic JWTs.
- Logging raw credentials or email addresses. Route through
  `SafeLog.sanitize` and `EmailMasker`.
- Dropping the app sandbox in `Resources/VibeBar.entitlements`. If you
  need new file access, add a narrow temporary exception.

That is a source-content rule. It applies to what you commit, not to
who you commit as.

### 8.1 Commit identity

Use your own git identity. Vibe Bar is open source under AGPL-3.0 and
the git log is public, so contributor names and emails will be visible.
If you don't want your personal email in the public history, configure
GitHub's privacy email (`<id>+<login>@users.noreply.github.com`) for
this repo:

```sh
git config --local user.name  "Your GitHub Name"
git config --local user.email "<id>+<login>@users.noreply.github.com"
```

That keeps commits attributed to your GitHub profile without leaking a
personal mailbox. `Co-Authored-By:` trailers are still welcome when
more than one human or agent shaped a commit.

## 9. Pull Request Workflow

The repository is `AstroQore/vibe-bar` on GitHub. Default branch is
`main`. Any contribution is licensed under AGPL-3.0.

### 9.1 End-to-end PR flow

```sh
# 1. Branch from main
git checkout main
git pull --ff-only
git checkout -b <short-topic-branch-name>

# 2. Make your change. Keep edits scoped to the topic.

# 3. Verify locally — all of these must pass before pushing.
swift build
swift test
./Scripts/build_app.sh release
codesign -d --entitlements - ".build/Vibe Bar.app"

# 4. Commit with your own identity.
git add <files>
git commit -m "<imperative subject line>"

# 5. Push the branch.
git push -u origin <short-topic-branch-name>

# 6. Open the PR.
gh pr create --base main \
  --title "<imperative subject line>" \
  --body  "$(cat <<'EOF'
## Summary
- <one-line bullet>
- <another bullet>

## Test plan
- [ ] swift test
- [ ] ./Scripts/build_app.sh release
- [ ] manual smoke test (describe what you clicked / observed)
EOF
)"
```

### 9.2 Required local checks before pushing

| Check                                                         | Why it must pass                                              |
| ------------------------------------------------------------- | ------------------------------------------------------------- |
| `swift build`                                                 | Compiles cleanly under Swift 6.2 / macOS 26.                  |
| `swift test`                                                  | Core logic regressions are blocked.                           |
| `./Scripts/build_app.sh release`                              | The user-facing bundle still assembles.                       |
| `codesign -d --entitlements - ".build/Vibe Bar.app"`          | Sandbox + network + home-relative entitlements still present. |

If you cannot run one of these (no macOS host, no Xcode, etc.), say so
explicitly in the PR description instead of skipping the checkbox.

### 9.3 Commit message style

Match what `git log` shows on `main`:

- Subject line is imperative, ≤ 70 characters, no trailing period.
- No type prefixes (`feat:`, `fix:`, `chore:`). Just write the change.
- Body wraps at ~72 chars, explains *why* and any non-obvious *how*.
  Skip the body for trivial changes.
- Mention `Co-Authored-By:` trailers at the end if you collaborated.

Example:

```text
Tint provider brand icons via SwiftUI color scheme

ProviderBrandIconView passed NSColor.labelColor without an NSAppearance,
so the dynamic color resolved against whatever appearance happened to
be current when the off-screen NSImage rendered. Forward the matching
.darkAqua / .aqua appearance so labelColor resolves correctly.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
```

### 9.4 After the PR is open

- CI may run additional checks. Address any failures.
- A maintainer may request changes. Push follow-up commits to the same
  branch — do not force-push unless asked, and never force-push `main`.
- Squash vs. merge is the maintainer's call; structure your commits so
  either works.

## 10. Common Build/Run Failures

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
  numbers are zero** — the build is reading from the sandbox container
  home instead of the real user home. See **§ 6. Sandbox & Home
  Directory** for the rule and the grep recipe to find the offending
  call site.

## 11. Implementation Rules That Have Bitten

- **JSONL scanning must be O(n).** See
  `CostUsageScanner.forEachJSONLLine`. Use a moving cursor, not
  `removeSubrange`.
- **Avoid `TimelineView(.periodic(...))` in deep view trees** that may
  be eagerly instantiated. Scope live timers to the visible surface.
- **New persistent state** goes through `VibeBarLocalStore` and lives
  under `~/.vibebar/`. Do not write to `~/` directly from new code.
- **Mini-window geometry stays in `mini_window_geometry.json`.** Do not
  fold it back into `AppSettings` — every settings write fans out to
  every Combine subscriber.
- **Bundle ID is `com.astroqore.VibeBar`.** For a release, bump
  `CFBundleShortVersionString` and `CFBundleVersion` in
  `Resources/Info.plist`.

## 12. Releases

- Bundle ID is `com.astroqore.VibeBar`. Bump
  `CFBundleShortVersionString` and `CFBundleVersion` in
  `Resources/Info.plist` for a new release.
- Confirm `Resources/VibeBar.entitlements` still matches the rule in
  **§ 4.5** (sandbox + network.client + home-relative paths).
- Run **§ 4.3 – § 4.6** before tagging or announcing a release.
- The license is AGPL-3.0-only; don't relicense without an explicit
  board decision.
- There is no notarization step (ad-hoc signed only) and no homebrew
  formula in this repo.

## 13. What You Should Not Change Without Explicit Instruction

- The license. AGPL-3.0-only is a board decision, not a code style
  choice.
- The bundle ID `com.astroqore.VibeBar`.
- The sandbox state in `Resources/VibeBar.entitlements`. If a file path
  needs new access, add a narrow temporary exception, do not drop the
  sandbox.
- The persistence root `~/.vibebar/`. New persistent state goes through
  `VibeBarLocalStore`.

## 14. When In Doubt

- For build / package / install only, [AGENT-DEPLOY.md](AGENT-DEPLOY.md)
  is the focused walkthrough.
- For PR-only work, [AGENT-PR.md](AGENT-PR.md) is the focused
  walkthrough.
- For human-facing rules, [CONTRIBUTING.md](CONTRIBUTING.md) wins on any
  conflict — update this file if it has drifted.
- For end-user product information, [README.md](README.md) and
  [README.zh-CN.md](README.zh-CN.md).
