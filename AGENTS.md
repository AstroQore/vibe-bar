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
| [docs/DESIGN.md](docs/DESIGN.md) | Anyone touching UI | The visual language: the one flat card recipe, density profiles, where the tokens live, and the mini window's Liquid Glass exception. |
| [RELEASING.md](RELEASING.md) | Maintainers | Tag → verified asset → draft GitHub Release, with optional Developer ID notarization. |
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

It is a pure Swift package with source-first distribution and an optional
tag-driven GitHub Release workflow. There is no Xcode workspace, installer,
or production server. The "deploy" target is the user's own Mac (and
optionally `/Applications`); the "publish" target is GitHub.

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
│   │   ├── AppUpdateController.swift
│   │   ├── StatusItemController.swift
│   │   ├── MiniQuotaWindowController.swift
│   │   ├── ServiceStatusController.swift
│   │   ├── ClaudeWebLoginController.swift
│   │   ├── ClaudeRoutineBudgetWebViewFetcher.swift
│   │   ├── LoginItemController.swift
│   │   ├── MCPController.swift    # Local MCP server's data source (see § 5.1)
│   │   ├── ProviderBrandIcon.swift
│   │   ├── VibeBarApp.swift
│   │   ├── Controllers/           # SwiftUI host controllers
│   │   └── Views/                 # SwiftUI view tree
│   └── VibeBarCore/               # Pure-Swift testable library
│       ├── Adapters/              # Provider quota + response parsers
│       ├── Compat/                # agent-session-kit re-export + host defaults
│       ├── Credentials/           # CLI credential readers + Keychain store
│       ├── MCP/                   # MCP dispatch, tools, DTOs (see § 5.1)
│       ├── Models/                # Plain data types (settings, quotas, cost)
│       ├── Services/              # Cost scanner, quota refresh, status fetch
│       ├── Storage/               # Local-store roots, caches, settings
│       ├── Utilities/             # Privacy helpers, formatters
│       └── Vendored/
├── Tests/
│   └── VibeBarCoreTests/          # `swift test` target (~90 tests)
├── Resources/
│   ├── Info.plist                 # Bundle ID, version, LSUIElement
│   ├── VibeBar.entitlements       # Empty plist — vibe-bar runs unsandboxed (see § 6)
│   └── AppIcon.icns / AppIcon.png
├── Scripts/
│   ├── build_app.sh               # App packaging + nested codesign
│   ├── release_app.sh             # ZIP, checksum, signed Sparkle appcast
│   ├── demo_home.py               # Builds the demo home README screenshots run on (§ 6.5)
│   ├── capture_demo_screenshots.sh# Captures every README surface from demo mode (§ 6.5)
│   └── optimize_screenshots.py    # Palette-quantises the captures (optional, Pillow)
├── docs/
│   ├── DESIGN.md
│   ├── screenshots/               # README images; regenerated, never hand-edited (§ 6.5)
│   └── agent-setup/               # One-line MCP setup an agent runs on itself
│       ├── prompt.md              # Addressed to the agent, not to a human
│       └── skill/vibe-bar/SKILL.md
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

### 2.1 What lives in agent-session-kit instead

Everything that reads a coding agent's **session store** was extracted
into [`agent-session-kit`](https://github.com/AstroQore/agent-session-kit)
and is a package dependency now:

- session discovery, parsing and the per-harness adapters (what used to
  be `Sources/VibeBarCore/Sessions/`),
- the FTS5 session index (`SessionIndexStore`, `SessionIndexService`),
- deletion planning (`SessionDeleter`) and `LiveSQLiteReader`,
- `Harness` / `HarnessCatalog` — the *usage* axis naming only,
- the MCP transports (`MCPSocketServer`, `MCPStdioBridge`) and the
  JSON-RPC primitives (`MCPJSON`, `MCPTool`, `MCPArguments`, …),
- `RealHomeDirectory`, `JSONLHeadTail`, `JSONLLineScanner`, `Base32`.

What stayed here is what needs Vibe Bar's *billing* vocabulary or its
app: `MCPServer` and its tool catalog, DTOs and resource catalog;
`Harness+Quota.swift`; `CostUsageScanner`; everything quota-shaped.

`Sources/VibeBarCore/Compat/AgentSessionKitReexport.swift` is the seam.
It `@_exported import`s the package — so no call site needs a second
import — and supplies the defaults the package refuses to invent for its
host: `~/.vibebar/mcp.sock`, the `--mcp-stdio` flag, `VIBEBAR_MCP_SOCKET`
and the "Vibe Bar is not running" message. Add host-shaped defaults
there, not in the package.

**Who owns which side of the line.**

| Concern | Lives in | Why |
| ------- | -------- | --- |
| Session discovery, per-harness adapters, transcript parsing | kit | Provider-agnostic, testable without a network, useful to any host. |
| `SessionIndexStore` / `SessionIndexService` (SQLite + FTS5) | kit | Same. The index location is a parameter, never a constant. |
| `SessionDeleter`, deletion planning, `LiveSQLiteReader` | kit | The containment and symlink rules belong next to the adapters that define the roots. |
| `Harness`, `HarnessCatalog` — the **usage** axis | kit | Naming a CLI is not naming a billing plan. |
| MCP transports + JSON-RPC primitives | kit | A socket and a byte pump have no opinions about Vibe Bar. |
| `RealHomeDirectory`, `JSONLLineScanner`, `JSONLHeadTail`, `Base32` | kit | Shared primitives with the same invariants on both sides. |
| `MCPServer`, its tool catalog, DTOs, resource catalog | here | Vibe Bar's own dispatch, over the kit's transport. |
| `Harness+Quota.swift`, `CostUsageScanner`, everything quota-shaped | here | The **billing** axis — plans, prices, companies, windows. |
| The `~/.vibebar/mcp.sock` default, `--mcp-stdio`, the "not running" message | here | Host-shaped defaults the package refuses to invent. |

**Where it comes from.** `Package.swift` pins the package to an exact
tag on GitHub (`.package(url: "https://github.com/AstroQore/agent-session-kit.git",
exact: "0.7.0")`), so a plain clone builds and a release build resolves the
same package the developer built against — `Package.resolved` is
gitignored here, and the exact pin is what stands in for it.

**It is linked statically.** The kit is compiled into `Vibe Bar.app`'s
executable. There is no framework in `Contents/Frameworks/`, no dylib, and
nothing on disk to swap. Two consequences that matter more than they look:

- The only way to know which kit is inside a build is
  `AgentSessionKitInfo.version`, a constant the package pins to its own
  changelog with a test.
- **A kit tag is not a Vibe Bar release.** Tagging `0.4.0` over there
  changes nothing for a single user until this repository bumps the pin
  *and* ships a build. After merging a bump, cut a dev build (§ 12) —
  otherwise the newest kit exists only in `main`.

**Bumping the pin.**

- *By hand:* edit the one line in `Package.swift`, edit the version named
  in this section, read the kit's release notes for anything that needs a
  call-site change, check `THIRD_PARTY_NOTICES.md` still describes it
  correctly, then run the full § 9.3 check list. Commit subject
  `Bump agent-session-kit to X.Y.Z`.
- *By workflow:* `.github/workflows/bump-agent-session-kit.yml` runs daily
  and on demand. It reads the current pin, asks GitHub for the kit's newest
  release, and — when that release is newer — opens
  `chore/bump-agent-session-kit-X.Y.Z` with both edits and the release
  notes linked in the body. It never merges anything.

  With the default `GITHUB_TOKEN`, GitHub **will not run CI on a
  bot-opened PR** (a deliberate loop-prevention rule). Close and reopen the
  PR, or push an empty commit to it, to get the checks. Adding a
  `VIBEBAR_BOT_TOKEN` repository secret — a PAT with `contents:write` and
  `pull_requests:write` — removes that step; the workflow prefers it when
  present.

**Where a user sees it.** Settings › System › **Components** shows
`agent-session-kit` with the bundled `AgentSessionKitInfo.version`, a
"bundled" badge, links to that release's notes and the repository, and a
**Check for kit updates** button. The button is the only thing that opens a
connection — no launch check, no timer, no check-when-the-pane-appears —
and `ComponentUpdateChecker` caches the answer in memory for six hours.
When a newer kit exists the row reads *"Newer kit X.Y.Z available — ships
with the next Vibe Bar build"*. Keep that phrasing, or an equivalent one
that is equally clear: the app cannot install a kit release, and a row that
sounds like it can is a bug in the copy.

**Working on both at once.** To build Vibe Bar against a local checkout of
the package (say, to try a kit change before it is tagged), use SwiftPM's
edit mode rather than editing `Package.swift`:

```sh
swift package edit agent-session-kit --path ../agent-session-kit
# … build, test …
swift package unedit agent-session-kit
```

`swift package edit` records the override in `.swiftpm/` (gitignored), so
it never reaches a commit, and `unedit` returns to the pinned tag. Never
commit a `Package.swift` that points at a local path or an untagged branch:
a release build resolves from a clean checkout and would fail, or worse,
silently resolve something else.

The kit's own conventions — conventional-commit subjects, Keep a Changelog,
bare `X.Y.Z` tags, and `RELEASING.md` — are that repository's, not this
one's. Use them when working there.

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
   skeleton under `.build/Vibe Bar.app/Contents`.
4. Copies the freshly built `VibeBar` executable into
   `Contents/MacOS/VibeBar`.
5. Copies SwiftPM's generated `VibeBar_VibeBarCore.bundle` into
   `Contents/Resources`; `PricingResolver` checks this installed-app
   location before falling back to `Bundle.module`.
6. Copies the versioned `Sparkle.framework` tree under
   `Contents/Frameworks`, preserving symlinks and executable permissions.
7. Copies `Resources/Info.plist` and `Resources/AppIcon.icns` into the
   bundle.
8. Writes `Contents/PkgInfo`.
9. Signs Sparkle's nested helpers in the documented order, then signs the
   outer app with `Resources/VibeBar.entitlements`.
10. Runs strict deep signature verification.

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
├── mini_window_geometry.json
└── mcp.sock          (socket, 0600, only while the app runs — see § 5.1)
```

If you are debugging odd behavior, that directory is the place to look.
Deleting it resets the app to first-run state.

Keychain stores one Vibe Bar credential Vault
(`com.astroqore.VibeBar.credential-vault` / `vault-v1`). Its versioned
JSON payload keeps OpenAI / Claude / Gemini / Grok Web cookies logically
split by source (`browser` vs `WebView`), plus the resolved Claude
organization ID and misc-provider secrets. The single-item design is
intentional: ad-hoc rebuilds change the app's Keychain ACL identity, so
Vibe Bar performs one non-interactive Vault lookup instead of one lookup per
secret. Do not add a password-assisted bulk-repair Settings page: it reopens
stale per-secret items and recreates the prompt storm this Vault replaces.
Inaccessible stale entries fail closed and are re-imported from the owning
provider's settings. Never put external CLI credentials or browser Safe
Storage keys in this Vault. Legacy plaintext cookie files under
`~/.vibebar/cookies/` may be read once for migration and must be deleted
immediately afterward. The app reads (never writes) Codex and Claude CLI
credential files and their session JSONL logs. Treat those as read-only
inputs.

There is exactly one exception, and it is whole-session deletion:
`SessionDeleter` (agent-session-kit) removes a session's
own log files, only when the user explicitly asks for that session to go
from the Workbench's Sessions page. It is fenced accordingly — every
target is canonicalized and must resolve strictly below one of the owning
adapter's provider roots, a target that is itself a symlink is refused,
and the session file is re-parsed immediately before removal so a stale
summary cannot delete a different session. Vibe Bar never edits the
*contents* of a session file, never deletes a credential file at all, and
no other code path may remove anything outside `~/.vibebar/`.

**Four providers are listed and readable but never deletable**, because
another app owns the store and removing from underneath it corrupts
rather than cleans:

| Provider        | Store                                              | Why it is refused                               |
| --------------- | -------------------------------------------------- | ----------------------------------------------- |
| `antigravity`   | `~/.gemini/antigravity{,-cli,-ide}/conversations`   | The CLI and IDE hold live WAL handles.          |
| `cursor`        | `~/.cursor/chats/**/store.db`                       | Cursor keeps the agent store open.              |
| `claudeCowork`  | `…/Application Support/Claude/local-agent-mode-sessions` | The files are inside Claude.app's own container. |
| `grokBot`       | `…/Application Support/Grok Bot/sand-client-persistence` | It is Grok Bot's own cache of conversations that live on xAI's servers. |

`SessionProvider.supportsDeletion` is the single source of truth: those
adapters throw `SessionDeleteError.providerIsReadOnly(provider)` — which
carries a per-provider message naming the app to delete from — and the
Sessions page asks the same property before offering the action, so the
gate and the adapters cannot drift. A new read-only provider adds a case
there and nowhere else. Read-only also means read-only in the small: these
adapters open the SQLite stores through the package's
`LiveSQLiteReader`, which only ever
opens the real file `SQLITE_OPEN_READONLY` and falls back to a private
temp-directory snapshot it deletes again.

### 5.1 The local MCP server

Vibe Bar exposes its own data to the user's coding agents over MCP. Code
lives in `Sources/VibeBarCore/MCP/` (data-source protocol, tool catalog,
DTOs) over agent-session-kit's transports, plus
`Sources/VibeBarApp/MCPController.swift` (the `MCPDataSource`
implementation over `AppEnvironment`) and
`Sources/VibeBarApp/Views/MCPSettingsSection.swift`.

**Transport.** A Unix domain socket at `~/.vibebar/mcp.sock`, mode 0600
inside the 0700 `~/.vibebar/`, speaking newline-delimited JSON-RPC 2.0
(protocol version `2025-06-18`). **No TCP port and no token file**: the
filesystem is the whole authentication story, so there is no secret to
leak and nothing reachable off this Mac. A stale socket is unlinked at
start; `AppDelegate.applicationShouldTerminate` removes the live one, so
the socket exists exactly while the app does.

**The bridge.** The same binary run as `VibeBar --mcp-stdio` is a plain
stdio MCP server that pumps bytes between stdin/stdout and that socket.
`AppDelegate.applicationDidFinishLaunching` handles the flag *before* any
UI exists — no status item, no `AppEnvironment`, no window — and the
process exits with the pump. Missing socket ⇒ exit 1 with
`Vibe Bar is not running (socket ~/.vibebar/mcp.sock not found). Launch
"Vibe Bar.app" first.` on stderr. `VIBEBAR_MCP_SOCKET` overrides the path;
it exists so tests (and a second build) can point at a temporary socket,
and it is documented rather than hidden for that reason.

**Tools.** `quota.get`, `quota.refresh`, `usage.summary`, `usage.trend`,
`usage.requests`, `cost.snapshot`, `cost.history`, `sessions.search`,
`sessions.list`, `status.get`, `pricing.effective`, `skills.install`, plus the
`vibebar://naming-spec` and `vibebar://tools` resources. The naming-spec
resource is **generated** from `ProviderHierarchyCatalog`, `ToolType` and
`HarnessCatalog` — never transcribe § 7.1 into it by hand, because a stale
spec teaches a model a label that no longer exists. `MCPResourceCatalogTests`
enforces that every harness, company and provider key appears.

**Privacy.** Everything is read-only except two tools. `quota.refresh`
is gated on `AppSettings.mcpServer.allowRefreshTools` and throttled to
one forced refresh per 20 s. `skills.install` is gated on
`AppSettings.mcpServer.allowSkillInstall` and is the only tool that
writes: it parses its `source` into a `SkillInstallSource` (a
`SkillRepoRef` or an absolute local directory — a github.com URL is
folded into the former, never fetched as an arbitrary file) and hands it
to the app-wide `SkillsService`, so the § 7 write allowlist holds for
agents exactly as it does for the Workbench. That service lives on
`AppEnvironment` and is shared with the Skills page: two instances would
each read-modify-write `~/.vibebar/skills.json`. Credentials, cookies and
organization ids are never projected; emails go through `EmailMasker`;
`cost.*` respects
`AppSettings.costData.privacyModeEnabled` the way `CostUsageService` does.
When adding a tool, add its projection to `MCPDTOs.swift` rather than
encoding a Core type directly — the DTO layer is where "what may an agent
see" is decided, and the wire shape is camelCase, pinned by
`MCPDTOEncodingTests`.

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

- **No Mac App Store distribution.** Vibe Bar is distributed through GitHub
  Releases and source builds, and was never on MAS, so this is a no-op.
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

`RealHomeDirectory` is the canonical entry point for any path under the
real user home — `~/.codex/`, `~/.claude/`, `~/.config/claude/`,
`~/.vibebar/`, `~/.gemini/`. Without the sandbox it is functionally
equivalent to `NSHomeDirectory()`, but keeping every call site routed
through one helper means re-enabling the sandbox later (or porting to a
sandboxed fork) does not require auditing every credential read again.

There are two of them, on purpose. agent-session-kit declares one and
`Sources/VibeBarCore/Utilities/RealHomeDirectory.swift` declares another
with the same name that **shadows** it: inside `VibeBarCore` the
module-local type wins, and `VibeBarApp` sees the `VibeBarCore` one
through the `@_exported import` in `Compat/AgentSessionKitReexport.swift`.
The shadow adds exactly one thing — a process-wide override that demo mode
(§ 6.5) sets once at launch — and otherwise returns the kit's answer byte
for byte. Two consequences:

- A file that imports `AgentSessionKit` directly *as well as*
  `VibeBarCore` sees both and must qualify (`VibeBarCore.RealHomeDirectory`);
  `Tests/VibeBarCoreTests/RealHomeDirectoryShadowTests.swift` is the
  example. Product code never needs the direct import.
- Kit APIs that default a `homeDirectory:` parameter to *the kit's*
  helper are not redirected by the override. Vibe Bar already passes
  `homeDirectory:` explicitly wherever it calls into the kit
  (`SessionProviderRegistry.standard(homeDirectory:)`,
  `SessionIndexService(homeDirectory:…)`, `SessionDeleter(homeDirectory:)`);
  keep doing that for any new kit call.

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

### 6.5 Demo mode and the README screenshots

Every image under `docs/screenshots/` is the real app launched in **demo
mode**: `VIBEBAR_DEMO_HOME=<dir>` (or `--demo-home <dir>`) redirects
`RealHomeDirectory` for the whole process to a synthetic home, and
`DemoMode.swift` (`Sources/VibeBarCore/Utilities/`) is the one switch every
gate reads. With it on:

- `AccountStore` takes its primary accounts from
  `<home>/.vibebar/demo_accounts.json` instead of probing credentials;
  misc instances still come from `settings.json`.
- `QuotaService.refresh` returns the cached snapshot and never calls an
  adapter; `CostUsageService.refreshAll` returns before scanning;
  `RemoteProbeService` reads `remote_core.json` and the ledger but builds
  no Relay client. `AppEnvironment` starts neither the quota scheduler,
  status polling, pricing loop, route-health probes nor any cookie import,
  and `AppUpdateController` leaves Sparkle unstarted. The MCP socket *is*
  created — inside the demo home.
- `KeychainStore` reports every item missing and swallows writes at its
  three primitives, so no surface can raise the login-keychain prompt.
- `DemoPresenter` (`Sources/VibeBarApp/Controllers/`) opens one surface
  (`VIBEBAR_DEMO_SURFACE=popover:<page>|mini:<mode>|workbench:<page>|settings:<section>`)
  on the sharpest display, behind it a flat full-screen backdrop, pinned to
  `VIBEBAR_DEMO_APPEARANCE=light|dark`, and prints the window frames on
  stdout for the capture script. The popover is anchored to the backdrop
  rather than the status item — the status item lives in the menu bar of
  whichever display the pointer last touched.

`DemoMode.bootstrap` refuses a demo home that resolves to the real home,
so the live store can never be put into a mode that stops refreshing it.

To regenerate the screenshots:

```sh
./Scripts/build_app.sh release
./Scripts/demo_home.py                 # ~ → /tmp/vibebar-demo-home, redacted
./Scripts/capture_demo_screenshots.sh  # → docs/screenshots/, both appearances
```

`demo_home.py` copies one maintainer's live quota, forecast, cost and ledger
state and rewrites every identifier (the Codex account id becomes
`demo-codex`, machine aliases and workspace ids are replaced); it copies no
credential, cookie, transcript or `/Users/<name>` path, and fabricates the
sessions and skills. The output path is short on purpose: the MCP socket
inside it is bound by the 104-byte `sun_path` limit. Review every new
capture against § 8 before committing it — a screenshot is source content.

## 7. Code Conventions

- **UI fluency is a requirement, not a nice-to-have.** Vibe Bar is a
  glanceable utility that sits in the user's peripheral vision all day;
  a stuttering popover, settings page, or chart is a bug on the same
  level as a wrong number. Every change to an interactive surface must
  keep interaction paths free of main-thread stalls: no file I/O,
  scanning, or O(n·m) recomputation inside a SwiftUI `body` or a
  binding getter; expensive derivations are computed once per data
  change (cached, or moved into Core and memoized), not once per
  render; charts downsample before drawing (`ChartSeriesPlanning`
  exists for this); `TimelineView` timers stay scoped to visible leaf
  surfaces; and a settings write fans out to every `$settings`
  subscriber, so hot paths (drags, hovers, keystrokes) must debounce or
  bypass `AppSettings` (see the mini-window geometry rule in § 11).
  Before merging UI work, exercise the surface it touches — scroll it,
  drag it, hover it — and treat any visible hitch as a blocker, not a
  follow-up.

  The budgets that make "fluent" testable:

  | Metric | Target | Blocker |
  |--------|--------|---------|
  | Hitch rate during interaction (Instruments "Animation Hitches", ms of hitch per second while scrolling/dragging/hovering the surface) | < 5 ms/s | ≥ 10 ms/s |
  | Longest synchronous main-thread stall on an interaction path | ≤ 16 ms | ≥ 100 ms |
  | Popover open, click → first frame from cached data | ≤ 100 ms | ≥ 250 ms |
  | Workbench page switch / Settings section switch | ≤ 150 ms | ≥ 300 ms |
  | Chart first paint at the largest retained dataset (30 d × hourly) | ≤ 100 ms | ≥ 250 ms |
  | Hover / crosshair update on any chart | 1 frame (≤ 8.3 ms @ 120 Hz) | > 2 frames |
  | Marks actually drawn per chart after downsampling | ≤ ~1 000 | unbounded raw series |
  | Idle CPU, popover closed / mini windows open | < 0.5 % / < 2 % | sustained ≥ 5 % |
  | Sustained settings-file write rate from any interaction | ≤ 1/s (debounced) | per-tick writes |

  How to measure: demo mode (§ 6.5) makes every surface reproducible;
  profile it with Instruments — *Animation Hitches* for the hitch rate,
  *Time Profiler* for stalls — or, minimally, `sample VibeBar` during
  the jank and Activity Monitor for idle CPU. When a budget cannot be
  met, the PR says which one and why rather than shipping the hitch
  silently.
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
- **The Skills manager is a narrow, documented exception to that write
  scope.** It writes to `~/.agents/skills/`, the allowlisted app skills
  directories, and only the native per-skill user-config fields below. The
  managed harnesses are Codex (`~/.codex/skills`), Claude Code
  (`~/.claude/skills`), Gemini CLI (`~/.gemini/skills`), AntiGravity
  (`~/.gemini/config/skills`), Grok Build (`~/.grok/skills`), and Cursor
  (`~/.cursor/skills`). Hermes and OpenCode roots remain in the allowlist only
  so old `skills.json` files can be decoded and safely cleaned up. ChatGPT
  Work, Claude Cowork, and Grok Bot do not expose an independent, stable local
  skill directory this feature can safely write, so no fake toggles are shown.
  Nothing else is touched, and never directly: every
  create, link, copy, and delete goes through `SkillSyncEngine` /
  `SkillsService`, which validate each directory name as a single safe
  path segment, refuse any resolved path outside those roots, require a
  `SKILL.md` before any sync, create missing ancestors one component at
  a time, never follow a symlink while deleting, and remove only
  symlinks that resolve back into the SSOT or copies whose recorded
  content hash still matches — so a folder the user authored or edited
  is left in place. Vibe Bar reads `~/.agents/.skill-lock.json` for
  provenance and never writes it, and pre-uninstall snapshots stay under
  `~/.vibebar/skill_backups/`.

  Projection is not activation. Codex, Gemini CLI, Grok Build, and Cursor all
  discover `~/.agents/skills` directly; AntiGravity also discovers the Gemini
  CLI root. The visible page therefore derives separate projection, native,
  and effective states. It re-reads projections and these native user settings
  while open: Codex `~/.codex/config.toml` `[[skills.config]]`, Claude
  `~/.claude/settings.json.skillOverrides`, Gemini
  `~/.gemini/settings.json.skills`, and Grok `~/.grok/config.toml [skills]`.
  Native config patches must be UTF-8/JSON/TOML-safe, preserve unknown fields,
  back up the original under `~/.vibebar/skill_backups/harness-config/`, and
  fail closed on parse errors. Cursor and standalone AntiGravity expose no
  stable full-off field: removing one projection while another discovery root
  still reaches the skill must show `coupled`, never disabled. New code that
  needs a skills path or harness setting goes through `SkillSyncEngine`,
  `SkillHarnessConfigManager`, or `SkillsService`; do not add another write
  path.
  That includes the MCP surface: `skills.install` (§ 5.1) resolves its
  `source` to a repository ref or a local directory and then calls
  `SkillsService.install(from:enableFor:method:)`, which reuses the same
  discovery, SSOT copy, and materialization the Workbench uses. An agent
  can therefore reach no path a user could not, and the gate on it is a
  settings toggle, not a second implementation.
- **Performance.** Avoid `TimelineView(.periodic(...))` in deep view
  trees that may be eagerly instantiated; prefer scoping to the visible
  surface. The mini window's screen position is persisted to its own
  JSON file (`mini_window_geometry.json`, one entry per window) — don't
  fold it back into `AppSettings`, because every settings write fans out
  to every Combine subscriber. The same reasoning gives the discovered
  quota buckets their own file: `quota_field_registry.json`, written by
  `QuotaService` when an adapter returns a bucket the static
  `MenuBarFieldCatalog` doesn't list.
- **JSONL parsing must be O(n).** Go through
  `CostUsageScanner.forEachJSONLLine`, which forwards to the package's
  `JSONLLineScanner.forEachLine`: a moving cursor, not `removeSubrange`.

### 7.1 Provider and harness naming

Vibe Bar names a provider along **two orthogonal axes**. A surface picks
one axis and stays on it; never mix levels of the two in one list.

**Quota axis** — what an account is billed against. L1 company → L2
SubProvider → L3 quota / model group. Source of truth:
`Sources/VibeBarCore/Models/ProviderHierarchy.swift` plus
`ToolType.hierarchy` / `ToolType.quotaSubProviderName`.

| L1 company | L2 SubProvider        | L3 quota / model groups                  |
| ---------- | --------------------- | ---------------------------------------- |
| OpenAI     | ChatGPT Agentic       | All Models, Codex Spark …                 |
| Anthropic  | Claude                | All Models, Sonnet, Opus, Fable …         |
| Google AI  | Gemini Web            | 5 Hours, Weekly                           |
| Google AI  | AntiGravity           | Gemini Models, Claude & GPT Models        |
| SpaceXAI   | Grok                  | Weekly Credits                            |
| SpaceXAI   | Cursor                | Cursor Models, Other Models               |
| SpaceXAI   | Grok Bot              | Weekly (cloud-only SubProvider)           |

**Usage / cost axis** — where the tokens were actually spent. The unit is
the local **harness**: the CLI or app that produced the sessions we
scanned. It is neither the company nor the quota SubProvider. Source of
truth: agent-session-kit's `Harness.swift` (`HarnessCatalog` holds the
display names). The mapping from a harness onto the quota axis —
`quotaTool`, `company`, the filter chips — is Vibe Bar's and lives in
`Sources/VibeBarCore/Models/Harness+Quota.swift`.

| Harness       | L1 company | Local evidence                                      |
| ------------- | ---------- | --------------------------------------------------- |
| Codex         | OpenAI     | `~/.codex/sessions`, every other `originator` (`Codex Desktop`, `codex-tui`, `codex_cli_rs`, `codex_exec`, `codex_vscode`) |
| ChatGPT Work  | OpenAI     | same tree, `originator` == "codex_work_desktop"      |
| Claude Code   | Anthropic  | `~/.claude/projects`, `~/.config/claude/projects`    |
| Claude Cowork | Anthropic  | `…/Application Support/Claude/local-agent-mode-sessions/**/.claude/projects` |
| Gemini CLI    | Google AI  | `~/.gemini/tmp/*/chats/session-*.jsonl`, telemetry log |
| AntiGravity   | Google AI  | `~/.gemini/antigravity{,-cli,-ide}/conversations`    |
| Grok Build    | SpaceXAI   | `~/.grok/sessions/**/updates.jsonl`                  |
| Cursor        | SpaceXAI   | `~/.cursor/chats/**/store.db` for sessions; dashboard events for cost |
| Grok Bot      | SpaceXAI   | `~/Library/Application Support/Grok Bot/sand-client-persistence` — sessions only; quota rides in on Cursor's `grok_bot_weekly` bucket |

Consequences worth stating out loud:

- Quota surfaces (Overview, mini window, menu bar, Settings) speak
  company / SubProvider / group. Usage and cost surfaces (Workbench
  Harness Mix, harness filter, cost cards) speak harnesses, grouped or
  filtered by company. **The Sessions page is a usage surface**: its rows
  are labelled with the harness, its Harness menu lists individual sources,
  and its separate Company menu is the only L1 batch control.
- "Gemini Web" is a quota SubProvider with **no** local usage; the
  deprecated CLI's historical tokens are always labelled "Gemini CLI".
- The ledger stores the harness per detail row *and* per daily rollup.
  Rows written before the dimension existed are backfilled from
  `Harness.defaultHarness(for:)`, so ChatGPT Desktop usage already folded
  into rollups stays attributed to "Codex"; only detail rows get
  corrected by a re-scan.

#### Coverage matrix

What Vibe Bar can say about each harness from purely local evidence.
"Sessions" means a listed, readable, searchable row in the Workbench's
Sessions page; "Delete" is § 5's read-only rule.

| Harness       | Model                              | Usage / cost              | Sessions                    | Delete |
| ------------- | ---------------------------------- | ------------------------- | --------------------------- | ------ |
| Codex         | ✅ `turn_context.model`            | ✅ local rollouts         | ✅ `CodexSessionAdapter`     | ✅ |
| ChatGPT Work  | ✅ same, `originator`-separated    | ✅ local rollouts         | ✅ same adapter, own harness | ✅ |
| Claude Code   | ✅ `message.model`                 | ✅ local JSONL            | ✅ `ClaudeSessionAdapter`    | ✅ |
| Claude Cowork | ✅ `message.model`                 | ✅ local JSONL            | ✅ `ClaudeCoworkSessionAdapter` | ❌ Claude.app's container |
| Gemini CLI    | ⚠️ newer vintages only             | ✅ telemetry + chat JSONL | ✅ `GeminiSessionAdapter`    | ✅ |
| AntiGravity   | ✅ `gen_metadata` turn             | ✅ conversation databases | ✅ `AntigravitySessionAdapter` | ❌ live WAL handles |
| Grok Build    | ✅ `current_model_id`              | ✅ local session state    | ✅ `GrokSessionAdapter`      | ✅ |
| Cursor        | ⚠️ when a turn recorded one        | ☁️ dashboard events only  | ✅ `CursorSessionAdapter`    | ❌ store stays open |
| Grok Bot      | ❌ never recorded locally          | ❌ cloud-only             | ✅ `GrokBotSessionAdapter`, read-only | ❌ the app's own cloud cache |

Where a ⚠️ appears the log genuinely does not carry the value — an aborted
Cursor conversation records no `modelName` at all, and old Gemini CLI
chats predate the per-turn `model` field. Leave those `nil`. Never infer a
model from the provider's "usual" one; a wrong model on a row is worse
than an empty chip, and it would also be wrong at pricing time.

Cursor's tokens stay remote on purpose. The nested field-5 accounting in
its blobs is context-window bookkeeping, not billable usage, so the
Sessions page lists Cursor conversations while the cost cards keep
sourcing Cursor from the dashboard — do not "fix" that by inventing local
counters.

Grok Bot is a **cloud cache**, and the coverage matrix means it
literally. The conversations run on xAI's servers; the directory is only
what the client happened to replicate, so history may be partial, may be
pruned, and may change underneath a scan. One `<base32>.blob` per key:
the `roster.last-roster` slice holds the bot names (its `title` field is
always empty and its `path` is a directory inside the *remote* sandbox),
and one `transcript.replicas.<uuid>` slice per bot is the session.
Entries carry no model, no token counts and no cost, so the provider
touches neither the ledger nor the cost scan — Grok Bot's contribution to
the quota axis stays exactly where it was, as Cursor's `grok_bot_weekly`
bucket. Roles are read from the transcript owner's point of view; the
mapping, including why an agent-to-agent turn stays `.user` / `.assistant`
rather than `.other`, is documented on `GrokBotSessionAdapter.message`
(agent-session-kit — see § 2.1).

**Model names.** Display always uses the canonical vendor id —
`gemini-3.5-flash-high`, not "Gemini 3.5 Flash (High)". Route every
user-visible model string through
`UsageModelNaming.canonicalDisplayName` (and keep the raw value as a
tooltip where the surface has one). The ledger and the pricing tables
keep whatever the provider wrote, because rates are matched on those
upstream labels — canonicalize the display, never the stored value.

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
  organization IDs in plaintext. Use the single Vibe Bar-owned credential
  Vault; keep logical service/account keys inside its payload and do not
  create a new physical Keychain item per secret;
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
  Use the **runtime agent's** trailer — detect from your harness, don't
  guess a model name from product branding or stale examples:

  | Agent | Trailer |
  | --- | --- |
  | Claude Code | `Co-Authored-By: Claude <runtime model name> <noreply@anthropic.com>` — e.g. `Claude Opus 4.8 <noreply@anthropic.com>` |
  | Codex | `Co-Authored-By: Codex <noreply@openai.com>` (read `commit_attribution` from `~/.codex/config.toml` if present) |
  | Grok Build (Cursor) | `Co-Authored-By: Grok Composer 2.5 Fast (xAI) <noreply@x.ai>` |

Example:

```text
Tint provider brand icons via SwiftUI color scheme

ProviderBrandIconView passed NSColor.labelColor without an NSAppearance,
so the dynamic color resolved against whatever appearance happened to
be current when the off-screen NSImage rendered. Forward the matching
.darkAqua / .aqua appearance so labelColor resolves correctly.

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>
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
- **The app runs but no menu-bar item ever appears** — on macOS 26 this
  is usually not our bug. Control Center keeps a per-bundle-id menu-bar
  allow-list in `trackedApplications` inside
  `~/Library/Group Containers/group.com.apple.controlcenter/Library/Preferences/group.com.apple.controlcenter.plist`.
  When an app the user hid from the menu bar keeps a stale reference to
  `com.astroqore.VibeBar` in its `menuItemLocations`, Control Center
  applies *that* app's `isAllowed = false` to us. Run
  `python3 Scripts/fix_menu_bar_allowlist.py` (dry run; `--apply` to
  fix) — it needs Full Disk Access for the terminal. The state survives
  reboots, our own toggle in System Settings > Menu Bar still reads as
  on, and flipping that toggle does nothing, so none of the obvious
  checks disprove it.

  Confirm before chasing our code: build a throwaway `.app` with a
  different `CFBundleIdentifier` and the same status-item code. If the
  copy appears and `com.astroqore.VibeBar` does not, the block is
  external. `MenuBarBlockWatchdog` keeps probing even when alert presentation
  was suppressed; Settings › Menu Bar Health exposes the live probe, the
  Control Center dry-run, alert toggle, and repair/re-registration path.
  `window.screen` is **not** the signal to key on (a blocked
  window still reports a screen) — the signature is a window left at
  `NSStatusBar.thickness` (22) while every screen's bar is taller,
  with occlusion missing `.visible`. It relapses whenever Control
  Center rebuilds those mappings.

## 11. Implementation Rules That Have Bitten

- **A quota cycle shorter than its stated window is usually real, not a
  bug.** Several buckets refill far more often than the window they
  report: two Codex weeklies have a *median* observed gap of 57 hours
  against a 168-hour window, and 62-71% of their cycles come in under
  half of it. Buckets that do follow their window (`claude_gpt_weekly`,
  `gemini_weekly`, `weekly_fable`) sit at 166-168 hours, so the two
  cases are easy to tell apart with data and impossible to tell apart by
  reading the code.

  This has already caused one wrong fix. `SubscriptionWindowSample`
  moves `windowStart` forward on every observation of a rolling window
  and stops when the cycle closes, which *looks* like it must leave a
  stale value behind, and reconstructing the start from
  `rawWindowSeconds` looks like the obvious repair. Measured against the
  interval between observed refills, the stored start is right for
  86-100% of cycles on every bucket; the reconstruction managed 14% on
  the worst. **Do not "fix" a short span without measuring first** —
  `QuotaPaceForecast.historicalRemainingUsage` derives each observation's
  progress from that span, so inflating it to the nominal window
  misplaces every comparison.

  The corollary worth building on: a cycle whose observed interval
  disagrees with the nominal window is an *event* — an off-schedule
  refill — and is worth recording and showing rather than smoothing
  away.
- **JSONL scanning must be O(n).** See
  `CostUsageScanner.forEachJSONLLine`. Use a moving cursor, not
  `removeSubrange`.
- **Avoid `TimelineView(.periodic(...))` in deep view trees** that may
  be eagerly instantiated. Scope live timers to the visible surface.
- **New persistent state** goes through `VibeBarLocalStore` and lives
  under `~/.vibebar/`. Do not write to `~/` directly from new code. The
  only exception is the skills write allow-list in § 7, and it is
  reached exclusively through `SkillSyncEngine`,
  `SkillHarnessConfigManager`, and `SkillsService`.
- **Every user-facing Settings control must round-trip through
  `AppSettings`.** Add its Codable key, a backward-compatible decode default,
  and a round-trip test. Migrations must be one-time and evidence-based; never
  rewrite a currently selectable value (such as a refresh interval) on every
  launch.
- **A URLSession request timeout is an idle timer, not a deadline.**
  `timeoutIntervalForRequest` fires only when *nothing* arrives for that
  long, so a slow trickle holds a download open forever. Anything a user
  waits on needs a wall-clock budget of its own
  (`timeoutIntervalForResource`, or a deadline recomputed across
  retries — see `SkillRepoFetcher.maxWallTime`) **and** a way out:
  `BoundedDownloader` fails with `CancellationError` when its task is
  cancelled. A long-running action in a view model should hold its
  `Task` so the button can become Cancel, and should say what it is
  doing while it runs.
- **Mini-window geometry stays in `mini_window_geometry.json`.** Do not
  fold it back into `AppSettings` — every settings write fans out to
  every Combine subscriber.
- **Keep the two naming axes intentionally separate.** Quota surfaces
  speak company / SubProvider / quota group; usage and cost surfaces speak
  the local harness that produced the sessions. The tables, the source-of-
  truth types, and the model-name rule are in § 7.1 — read it before
  adding a provider label to any list.
- **Keep the two pace systems intentionally separate.** The core-provider
  surfaces (ChatGPT/Codex, Claude, Gemini Web, AntiGravity, and Grok) may use
  `QuotaPaceForecast` and reset-cycle observations. Misc provider cards must
  retain the legacy elapsed-time `UsagePace` reserve/deficit calculation and
  `PaceMarkerCapsule`; do not route Misc through the personal forecast model
  unless AQ explicitly asks to change that product boundary.
- **Gemini Web quota requests are learned, not guessed.** Keep normal refresh
  on the lightweight URLSession replay path using the persisted, non-secret
  usage recipe. If Google rotates the private batchexecute rpcid or argument,
  the App-layer hidden usage WebView must observe the page's own request,
  verify the two-bucket payload against rendered percentages, persist only the
  recipe, and immediately return that quota. Do not substitute an unrelated
  Google rpcid from search results, persist response bodies/cookies, or route
  Gemini live quota through Gemini CLI credentials. Always normalize the
  resulting buckets to 5 Hours followed by Weekly.
- **Forecast overlays need one coherent visual vocabulary.** The current quota
  remains the primary summary-bar layer. The elapsed-time-only pace uses the
  substantial neutral inset tick established by `PaceMarkerCapsule`; the
  forecast-at-reset median is a verdict-colored vertical tick. The confidence
  interval always stays within the bar's original full height and follows four
  explicit geometries. Ordinary intervals use an opaque solid overlay. In Used
  mode, an interval separated from the actual endpoint stays opaque and uses a
  quiet centerline connector whose ends tuck beneath both rounded caps. An
  interval that starts exactly at the actual endpoint overlaps it by one
  rounded cap radius with no dark seam; when the actual endpoint falls
  strictly inside the interval, keep the interval's rounded lower cap laid over
  the complete actual fill and draw the curved background seam only at that
  actual endpoint. When Used-mode actual, interval, and median all crowd the
  lower axis, use a translucent full-height tint with a complete rounded
  outline and emphasized far edge. In Remaining mode, forecasts stay inside
  the current remaining fill; at 8% remaining or below, preserve that fill as
  the capsule silhouette and render the confidence interval as a narrow,
  borderless inset color core. Do not expose the track through the lower
  rounded cap, use gradients or square color cuts, or make the quota bar look
  thicker. Legends
  must use the same marker shapes as the bar — never show a solid sample for a
  dashed mark, reduce the wall-clock reference to a hairline, or turn the
  forecast into a dot. Used/Remaining projection must be performed through one
  shared coordinate transform; the visible median marker must stay inside its
  confidence band, and a band clipped by the 0% or 100% boundary must remain
  saturated at that boundary instead of fading as though it ended there.
  Keep forecast semantics in the labeled status row below the Overview bar;
  detailed utilization views may carry the explicit reference legend.
- **Forecast diagnostic tiles use one stable height per density.** Long labels
  may wrap within that shared height, but no individual tile may grow and leave
  a ragged two-column grid.
- **Subscription Utilization is the forecast explainability surface.** Keep
  the legacy wall-clock pace visible alongside the forecast at reset, then expose
  recent burn, reset-history comparison, weekday/hour activity weighting,
  recent activity trend, forecast interval, safety target, evidence counts,
  coverage, and confidence. The Overview may stay concise; this detail view
  must make the explanation available without dominating the page. Keep
  "How this forecast was calculated" collapsed by default and expand it per
  quota only when the user asks.
- **Core-provider use-up ETA comes from the personal forecast.** Under each
  core quota, preserve the scannable "runs out in" conclusion, but derive it
  from `QuotaPaceForecast.runOutAt`, not the legacy elapsed-time burn rate.
  When the model does not predict exhaustion before reset, say that the quota
  is projected to last until reset instead of extrapolating a meaningless time
  beyond the refill boundary. A `Watch` ETA is explicitly possible, not certain.
- **Reset history belongs to its quota.** Render each independently resettable
  bucket's cycle history immediately under that bucket in Subscription
  Utilization. Do not restore a shared selector at the bottom of the card;
  model-scoped limits such as Spark, Fable, Gemini Web, and AntiGravity must
  remain visible at the same time.
- **Provider detail pages share one asymmetric layout.** Preserve the existing
  column ratio with quota, Subscription Utilization, and service status in the
  narrow left column. Put cost, cost history, model ranking, past year, and
  when-you-use in the wide right column. ChatGPT, Claude, Gemini, and Grok must
  use the same framework. Overview and provider pages also share the popover
  shell's exact horizontal content inset; page-specific layouts must not add a
  second outer inset or shrink away from the scroll view's available width.
- **Dense status history is one drawing surface, not hundreds of views.** Use
  `Canvas` (or an equivalent batched renderer) for uptime strips and avoid one
  Swift Charts instance per quota. These detail pages can display many status
  components and quota dimensions simultaneously, so per-cell view trees make
  scrolling visibly stutter.
- **`Surplus` is a robust likely-waste verdict, not a synonym for high current
  remaining quota.** Keep `Learning` while confidence is low. Only surface
  `Surplus` with at least medium confidence, a materially large median surplus
  above the safety target, and a conservative forecast bound that still clears
  that target. Risk verdicts always take precedence.
- **Bundle ID is `com.astroqore.VibeBar`.** For a release, bump
  `CFBundleShortVersionString` and `CFBundleVersion` in
  `Resources/Info.plist`.

### 11.1 Adding a new Claude usage-limit model

Anthropic periodically adds a per-model dimension to the
`/api/oauth/usage` payload (a new `seven_day_<model>` key — this is how
Sonnet, Opus, and Fable each arrived). When you see one — in the API
response, in logs, or because AQ points it out — add it end-to-end
using this checklist. Do **not** stop at the parser; a half-added model
parses but never becomes selectable.

**2026-07 schema note.** The legacy `seven_day_<model>` keys now come
back `null`; per-model limits moved into a structured `limits` array
whose scoped entries carry the model's display name
(`{"kind": "weekly_scoped", "scope": {"model": {"display_name":
"Fable"}}}`). `ClaudeResponseParser.appendLimitsArrayBuckets` derives
the bucket id from that name (`Fable` → `weekly_fable`), so a
brand-new model **auto-surfaces in the popover with zero code
changes** — and, since the mini window's field picker merges the
runtime `QuotaFieldRegistry` (catalog-external buckets seen on this
Mac, persisted in `~/.vibebar/quota_field_registry.json`), it is
selectable in the mini window with zero code changes too. This
checklist is still required to make the model selectable in the menu
bar and to give it hand-tuned labels — but the "invisible until
someone edits the parser" failure mode is gone.

Use consistent ids for a model `<x>` (e.g. `fable`):

| Layer | Value |
|-------|-------|
| API payload key | `seven_day_<x>` |
| `QuotaBucket.id` | `weekly_<x>` |
| Mini-window group key | `claude.<x>` |
| Menu-bar field id | `claude.weekly_<x>` (built from the two above) |

**Required (correctness — without these the model is invisible):**

1. `Sources/VibeBarCore/Adapters/ClaudeResponseParser.swift` —
   add a `BucketSpec` to `knownBuckets`
   (`key: "seven_day_<x>", id: "weekly_<x>", …, groupTitle: "<X>"`) and
   the doc-comment line. Unknown payload keys are silently dropped, so
   this is the one edit that actually surfaces the data.
2. `Sources/VibeBarCore/Models/MenuBarSettings.swift` —
   add `option(.claude, "weekly_<x>", "<X> · Weekly", "<X> wk")` to
   `claudeFields` so the bucket is selectable in the menu bar / mini
   window. The `ClaudeModelBucketParityTests` suite **fails `swift test`**
   if you skip this, so it's the backstop for the required half of this
   list.

**Mini-window polish (degrades gracefully via `groupTitle` fallbacks,
but add for parity so the labels look hand-tuned):**

3. `Sources/VibeBarApp/Views/MiniWindowGroupLabelCatalog.swift` —
   add `.init(id: "claude.<x>", title: "CLAUDE · <X>", defaultLabel: "<X>")`.
4. `Sources/VibeBarApp/Views/MiniQuotaWindowView.swift` — four switches:
   `isBranchField`, `MiniBranchCell.defaultTitle` (use `"wk"`),
   `.groupKey` (→ `"claude.<x>"`), `.defaultGroupTitle` (→ `"<X>"`).
5. `Sources/VibeBarApp/MiniQuotaWindowController.swift` —
   `miniBranchGroupKey` (→ `"claude.<x>"`), keeps AppKit panel sizing in
   sync with the SwiftUI layout.

**Nice to have:**

6. `Sources/VibeBarCore/Services/MockDataProvider.swift` — add a sample
   `weekly_<x>` bucket to the `.claude` branch so mock mode is
   representative.
7. `Tests/VibeBarCoreTests/ClaudeParserTests.swift` — extend
   `testEachModelGetsItsOwnGroup` (present) and
   `testWebUsageBucketsIncludeDesignWhenPresent` (null) fixtures.

**Already automatic — do not add per-model code here:** the main popover
(`PopoverRoot`), the status item, `OverallFillRate`,
`SubscriptionUtilizationView`, and the Misc page all group Claude
buckets by `QuotaBucket.groupTitle`, so a new model appears there the
moment step 1 lands.

## 12. Releases

- Follow [RELEASING.md](RELEASING.md) for the complete tag, asset, signing,
  notarization, and draft-publishing flow.
- Bundle ID is `com.astroqore.VibeBar`. Bump
  `CFBundleShortVersionString` and `CFBundleVersion` in
  `Resources/Info.plist` for a new release.
- Confirm `Resources/VibeBar.entitlements` still matches the rule in
  **§ 4.5** — empty `<dict/>`, no `app-sandbox` key.
- Run **§ 4.3 – § 4.6** before tagging or announcing a release. The GitHub
  workflow repeats those checks on a macOS 26 runner.
- Main tags are exactly `v` plus `CFBundleShortVersionString`. Dev tags are
  `v<CFBundleShortVersionString>-dev.<CFBundleVersion>`. The workflow creates
  a draft GitHub Release so its assets can be inspected before publishing.
- Every published release must include the ZIP, checksum, and signed
  `appcast.xml`. The workflow requires the repository Actions secret
  `SPARKLE_ED_PRIVATE_KEY`, exposes it only to the release-asset build step,
  and passes it to Sparkle over standard input. The matching public key is
  `SUPublicEDKey` in `Resources/Info.plist`.
- Main is Sparkle's default channel; Dev adds the `dev` channel and still
  receives Main releases. Published release appcasts are promoted by
  `publish-update-feed.yml`, which regenerates against the latest feed before
  writing the machine-managed `updates` branch at
  `https://raw.githubusercontent.com/AstroQore/vibe-bar/updates/appcast.xml`.
  Never hand-edit that shared appcast.
- The license is AGPL-3.0-only; don't relicense without an explicit
  board decision.
- Releases remain ad-hoc signed when Apple credentials are absent. With the
  documented Developer ID secrets, the same workflow signs with hardened
  runtime, notarizes, and staples the unsandboxed app. There is no Homebrew
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
