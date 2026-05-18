# AGENTS.md — Vibe Bar Project Guide for AI Agents

This file is the single source of truth for AI coding agents (Claude Code,
Codex, Cursor, Aider, etc.) working on Vibe Bar. It is **self-contained**:
an agent with no prior knowledge of this project should be able to read
it top-to-bottom and end with a working build and a clean PR.

Humans are welcome here too. The shorter, human-focused version is
[CONTRIBUTING.md](CONTRIBUTING.md).

## Document Map

| File | Audience | Purpose |
| --- | --- | --- |
| [AGENTS.md](AGENTS.md) (this file) | AI agents (and curious humans) | Comprehensive operating manual: orientation, build, conventions, home-directory rule, PR, release. |
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
│   ├── VibeBar.entitlements       # Empty plist — vibe-bar runs unsandboxed (see § 6)
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

Vibe Bar runs **unsandboxed**. The entitlement output should be an
empty `<dict/>` plist (see `Resources/VibeBar.entitlements`). It must
**not** contain `com.apple.security.app-sandbox`. If
`app-sandbox` reappears in the output, something in
`Resources/VibeBar.entitlements` or `Scripts/build_app.sh` has
regressed — stop and surface the regression rather than shipping a
sandboxed bundle (the misc-providers integration depends on
non-sandboxed file/process access — see § 6).

### 4.6 Smoke-test the bundle

```sh
open ".build/Vibe Bar.app"
```

A menu-bar item should appear on the right of the macOS menu bar. If
macOS reports the bundle as damaged, see **§ 10. Common Build/Run Failures**.

After it launches, confirm the sandbox container is **not** being
created:

```sh
ls ~/Library/Containers/com.astroqore.VibeBar/Data/ 2>&1
```

This should error with `No such file or directory` because the app
runs unsandboxed. If the directory does exist and contains any
real-home contents (e.g. a parallel `.codex/`, `.claude/`, or
`.vibebar/`), a previous sandboxed build left it behind — delete it:

```sh
rm -rf ~/Library/Containers/com.astroqore.VibeBar/
```

Confirm the real persistence root is healthy:

```sh
ls -la ~/.vibebar/
```

The directory should hold the regular `settings.json`, `quotas/`,
`cost_history.json`, etc. See **§ 6. Home Directory** for the rationale.

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

Keychain stores Vibe Bar-owned OpenAI / Claude Web cookies, split by
source (`browser` vs `WebView`), plus the resolved Claude organization
ID — those are not in `~/.vibebar/`. Legacy plaintext cookie files under
`~/.vibebar/cookies/` may be read once for migration and must be deleted
immediately afterward. The app reads (never writes) Codex and Claude CLI
credential files and their session JSONL logs. Treat those as read-only
inputs.

## 6. Home Directory (and why we no longer sandbox)

Vibe Bar runs **unsandboxed**. Every Foundation home API returns the
real `/Users/<you>` directly. The earlier sandboxed builds had a
silent failure mode — `NSHomeDirectory()` and friends returned the
container path, the app would write to a shadow tree, and Codex /
Claude would show as logged out — that no longer applies once the
sandbox is off.

### 6.1 Why the sandbox is off

The misc-providers feature (see § 12 below) needs:

- to read other browsers' cookie SQLite databases from
  `~/Library/Application Support/...` and decrypt them via the
  Keychain "Chrome Safe Storage" entry;
- to spawn `lsof -p <pid>` and parse another process's command line,
  so we can find the AntiGravity language-server port and CSRF token.

Both capabilities are blocked by `com.apple.security.app-sandbox`
even with file-access exceptions; the Keychain is identity-scoped and
the process introspection requires entitlements Apple does not
publicly grant. Codexbar (the reference project) explicitly drops the
sandbox for the same reasons. Vibe Bar follows suit.

`Resources/VibeBar.entitlements` is therefore an empty `<dict/>`
plist. The trade-offs:

- **No Mac App Store distribution.** Vibe Bar is source-distributed
  today and was never on MAS, so this is a no-op.
- **Wider local file access.** Vibe Bar can technically read anything
  the user can read. The privacy rules (§ 8) and `SafeLog` /
  `EmailMasker` discipline still apply — *don't* abuse this. Browser
  cookies imported for OpenAI / Claude must be minimized to the smallest
  useful header and stored only in Keychain, never as new plaintext files
  in `~/.vibebar/`.
- **Re-enabling the sandbox is a one-PR change.** If a future
  requirement (e.g. someone wants a sandboxed fork for MAS) makes
  this worthwhile, restore the sandbox key + the four
  home-relative-path exceptions to `VibeBar.entitlements`, drop the
  misc-providers' browser-cookie and AntiGravity-probe paths, and
  re-introduce the regression checks below.

### 6.2 Why `RealHomeDirectory` still exists

`Sources/VibeBarCore/Utilities/RealHomeDirectory.swift` is the
canonical entry point for any path under the real user home —
`~/.codex/`, `~/.claude/`, `~/.config/claude/`, `~/.vibebar/`,
`~/.gemini/`. Without the sandbox it is functionally equivalent to
`NSHomeDirectory()`, but keeping every call site routed through one
helper means re-enabling the sandbox later (or porting to a sandboxed
fork) does not require auditing every credential read again.

The empirical probe table that justified the helper originally is
preserved in case the sandbox returns:

| API                                                | Returned (sandboxed) | Returned (unsandboxed) |
| -------------------------------------------------- | -------------------- | ---------------------- |
| `NSHomeDirectory()`                                | container            | `/Users/<you>`         |
| `FileManager.default.homeDirectoryForCurrentUser`  | container            | `/Users/<you>`         |
| `URL.homeDirectory` (macOS 13+)                    | container            | `/Users/<you>`         |
| `NSHomeDirectoryForUser(NSUserName())`             | container            | `/Users/<you>`         |
| `ProcessInfo.processInfo.environment["HOME"]`      | container            | `/Users/<you>`         |
| `getpwuid(getuid()).pointee.pw_dir`                | `/Users/<you>` ✓     | `/Users/<you>` ✓       |

Only `getpwuid` was correct in both regimes; that is what
`RealHomeDirectory` uses. Do not "simplify" it to one of the others.

### 6.3 The rule

- Any path under the user's real home goes through
  `RealHomeDirectory`. Don't reach for `NSHomeDirectory()`,
  `FileManager.default.homeDirectoryForCurrentUser`,
  `NSHomeDirectoryForUser`, `URL.homeDirectory`, or
  `getenv("HOME")` in product code.
- Before you commit, grep:

  ```sh
  grep -rn 'NSHomeDirectory()\|homeDirectoryForCurrentUser\|URL\.homeDirectory\|NSHomeDirectoryForUser\|getenv("HOME")' Sources
  ```

  Every hit must either be inside `RealHomeDirectory` itself, an
  explicit "scratch lives in tmp" call site
  (`NSTemporaryDirectory()` is fine), or a `homeDirectory:` test
  parameter.
- After `./Scripts/build_app.sh release` and a real run, confirm the
  sandbox container is not being created:

  ```sh
  ls ~/Library/Containers/com.astroqore.VibeBar/Data/ 2>&1
  ```

  This should error with `No such file or directory`. If it exists,
  a previous sandboxed build left it behind — delete with
  `rm -rf ~/Library/Containers/com.astroqore.VibeBar/`.

### 6.4 `homeDirectory:` parameters in `CostUsageService` / `CostUsageScanner` / `CostUsageScanCache`

These exist for **test isolation only** — tests pass a synthetic
temp directory so fixtures land somewhere disposable. The default
value should still be the real-home helper, not `NSHomeDirectory()`.
Tests keep working because they pass an explicit value.

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
  runs unsandboxed (see § 6) — that is *not* a license to read or write
  anything you feel like. Treat the user's filesystem with the same
  discipline a sandboxed app would: read only the credential / cookie /
  config files you actually need, never write outside `~/.vibebar/`,
  and never log raw secrets.
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
- Persisting OpenAI / Claude Web cookies, session keys, or resolved
  organization IDs in plaintext. Use the Vibe Bar-owned Keychain service;
  `~/.vibebar/cookies/` is migration-only.
- Re-enabling the app sandbox in `Resources/VibeBar.entitlements`
  *without coordinating the misc-providers feature first*. Vibe Bar is
  unsandboxed on purpose (see § 6) so the browser-cookie importer and
  AntiGravity local probe can work. If you genuinely need the sandbox
  back (e.g. for a MAS fork), pair the entitlement change with a
  documented deprecation of those features.

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

### 9.1 Branch and worktree rules

All maintenance work starts from an up-to-date `main`, then moves onto a
topic branch. Do not commit directly on `main`, and do not push directly
to `main` unless AQ explicitly asks for an emergency direct push.

Use short, descriptive branch names with a conventional prefix:

- `feat/<short-topic>` for new user-facing behavior.
- `fix/<short-topic>` for bug fixes.
- `docs/<short-topic>` for documentation-only changes.
- `test/<short-topic>` for test-only changes.
- `refactor/<short-topic>` for behavior-preserving restructuring.
- `release/<version-or-topic>` for release-prep branches.

Commit subjects still follow this repo's normal style: imperative,
plain-English, and no `feat:` / `fix:` / `chore:` prefix. The prefix is
for branch organization only.

Because multiple local AI agents may work in this checkout at once,
prefer creating a separate Git worktree for non-trivial changes:

```sh
git checkout main
git pull --ff-only origin main
git worktree add ../vibe-bar-<short-topic> -b <prefix>/<short-topic> main
cd ../vibe-bar-<short-topic>
```

If the user did not explicitly mention worktrees, do not stop just to
ask. Pick the safer path and keep moving: use a worktree when parallel
work, a dirty checkout, or a long-running branch would make isolation
useful; for tiny single-agent changes on a clean checkout, an in-place
topic branch is acceptable.

### 9.2 End-to-end PR flow

```sh
# 1. Branch from main
git checkout main
git pull --ff-only origin main
git checkout -b <prefix>/<short-topic>

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
git push -u origin <prefix>/<short-topic>

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

Do not replace the PR flow with a direct push to `main`. Push the topic
branch and open a PR against `main`.

### 9.3 Required local checks before pushing

| Check                                                         | Why it must pass                                              |
| ------------------------------------------------------------- | ------------------------------------------------------------- |
| `swift build`                                                 | Compiles cleanly under Swift 6.2 / macOS 26.                  |
| `swift test`                                                  | Core logic regressions are blocked.                           |
| `./Scripts/build_app.sh release`                              | The user-facing bundle still assembles.                       |
| `codesign -d --entitlements - ".build/Vibe Bar.app"`          | Entitlements plist is empty (no `app-sandbox`) — see § 6.    |

If you cannot run one of these (no macOS host, no Xcode, etc.), say so
explicitly in the PR description instead of skipping the checkbox.

### 9.4 Commit message style

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

### 9.5 After the PR is open

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
  numbers are zero** — usually a leftover sandbox container from an
  older build is intercepting reads. Confirm with
  `ls ~/Library/Containers/com.astroqore.VibeBar/Data/ 2>&1`; if the
  directory exists, `rm -rf ~/Library/Containers/com.astroqore.VibeBar/`
  and relaunch. If the symptom persists, see **§ 6. Home Directory**
  for the grep recipe to confirm every call site uses
  `RealHomeDirectory`.

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
  **§ 4.5** — empty `<dict/>`, no `app-sandbox` key.
- Run **§ 4.3 – § 4.6** before tagging or announcing a release.
- The license is AGPL-3.0-only; don't relicense without an explicit
  board decision.
- There is no notarization step (ad-hoc signed only) and no homebrew
  formula in this repo.

## 13. What You Should Not Change Without Explicit Instruction

- The license. AGPL-3.0-only is a board decision, not a code style
  choice.
- The bundle ID `com.astroqore.VibeBar`.
- The sandbox state in `Resources/VibeBar.entitlements`. The plist is
  intentionally empty (see § 6) so the misc-providers feature can read
  browser cookies and probe AntiGravity. Don't re-add
  `app-sandbox` without first coordinating those features.
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
