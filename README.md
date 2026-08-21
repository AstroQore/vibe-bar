<p align="center">
  <img src="Resources/AppIcon.png" alt="Vibe Bar" width="128">
</p>

<h1 align="center">Vibe Bar</h1>

<p align="center">
  <strong>Will this AI subscription last until it resets — and how much of it are you leaving unused?</strong>
</p>

<p align="center">
  <a href="https://github.com/AstroQore/vibe-bar/actions/workflows/ci.yml"><img src="https://github.com/AstroQore/vibe-bar/actions/workflows/ci.yml/badge.svg" alt="CI"></a>
  <a href="https://github.com/AstroQore/vibe-bar/releases/latest"><img src="https://img.shields.io/github/v/release/AstroQore/vibe-bar?display_name=tag&sort=semver" alt="Latest release"></a>
  <img src="https://img.shields.io/badge/macOS-26%2B-000000?logo=apple" alt="macOS 26+">
  <img src="https://img.shields.io/badge/Swift-6.2-F05138?logo=swift&logoColor=white" alt="Swift 6.2">
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-AGPL--3.0--only-blue" alt="AGPL-3.0-only"></a>
</p>

<p align="center">
  <a href="https://github.com/AstroQore/vibe-bar/releases/latest"><strong>Download</strong></a>
  · <a href="#build-from-source">Build from source</a>
  · <a href="#agents-mcp">Agents (MCP)</a>
  · <a href="#acknowledgements">Acknowledgements</a>
  · <a href="README.zh-CN.md">中文</a>
</p>

Vibe Bar is a native macOS menu-bar app for people who run coding agents
all day on subscription plans. It puts ChatGPT/Codex, Claude Code, Gemini,
AntiGravity, Grok, Cursor and a dozen coding-plan providers on one quiet
surface, and answers the two questions a raw percentage does not:

- **Will this quota last until its next reset?** A personal forecast built
  from wall-clock pace, recent burn, the history of previous reset cycles and
  your working-hour patterns — with a confidence band, not a single number.
- **Am I paying for quota I never use?** Reset-cycle history shows what was
  still left every time a window closed, so pre-reset waste is visible before
  the window disappears.

Under the menu bar sits a Workbench: a per-request usage ledger across every
harness, a searchable index of every local agent session with one-click
resume, and a skills manager that keeps one library in sync across five
agent CLIs. All of it is read from files already on your Mac, and an MCP
server lets your agents ask the same questions.

![The Overview: cost and status at the top, one quota card per provider below, each bar carrying its forecast](docs/screenshots/popover-overview.png)

<details>
<summary>The same Overview in the light appearance</summary>

![The Overview in the light appearance](docs/screenshots/popover-overview-light.png)

</details>

## Forecasts, not percentages

Every quota bar carries a verdict — `Learning`, `Enough`, `Watch`,
`At risk` or `Surplus` — plus a projected run-out time and the forecast's
confidence. The provider pages show how it was reached: the reset history
as one bar per cycle, the fill curve against a time-only pace line, and the
local cost, model ranking, yearly activity and working-hour pattern on the
right, in the same layout for every core provider.

<table>
  <tr>
    <td width="50%"><img src="docs/screenshots/popover-openai.png" alt="The OpenAI page: ChatGPT Agentic and Codex Spark quotas with reset history and fill curves beside cost, models and activity"><br><sub><strong>OpenAI</strong> — ChatGPT Agentic and GPT-5.3 Codex Spark windows, reset history, quota history, cost, model ranking, and a year of activity.</sub></td>
    <td width="50%"><img src="docs/screenshots/popover-anthropic.png" alt="The Anthropic page: 5 Hours, Weekly and Fable windows with their forecasts"><br><sub><strong>Anthropic</strong> — 5 Hours, Weekly and per-model weekly windows, each with its own forecast and cycle history.</sub></td>
  </tr>
  <tr>
    <td width="50%"><img src="docs/screenshots/popover-google.png" alt="The Google AI page: Gemini Web and AntiGravity quotas"><br><sub><strong>Google AI</strong> — Gemini Web quotas and the AntiGravity language-server quotas for Gemini and Claude/GPT models, side by side.</sub></td>
    <td width="50%"><img src="docs/screenshots/popover-spacexai.png" alt="The SpaceXAI page: Grok, Cursor and Grok Bot quotas"><br><sub><strong>SpaceXAI</strong> — Grok Build, Cursor and Grok Bot quotas, with Cursor's account usage folded into the cost side.</sub></td>
  </tr>
</table>

The verdict is only as good as its history, so a freshly added provider says
`Learning` until enough reset cycles have been observed to trust a
projection; the forecast never claims a confidence it does not have.

## Mini window

Every active quota as a gauge that stays above your work — on a second
display, beside a full-screen terminal, wherever you put it. Two densities
of the same model, switched from the window itself; the surface is Liquid
Glass and follows whatever is behind it.

![The regular mini window: one gauge per quota window, grouped by provider](docs/screenshots/mini-regular.png)

![The compact mini window: the same quotas as slim vertical bars](docs/screenshots/mini-compact.png)

<details>
<summary>The regular mini window in the light appearance</summary>

![The regular mini window in the light appearance](docs/screenshots/mini-regular-light.png)

</details>

## More coding plans

The Misc page keeps provider-specific quota semantics simple and scannable.
Supported integrations include Copilot, OpenCode Go, Ollama Cloud, OpenRouter,
Kilo, Kiro, Zhipu GLM, Xiaomi MiMo, Kimi, MiniMax, iFlytek Spark, Alibaba
Bailian, Volcengine Coding and Agent Plans, Tencent Hunyuan, Baidu Qianfan and
Warp. Sign in through the app's own WebView, import a browser cookie, or paste
a key — whatever the provider's console offers.

![The Misc page: OpenCode Go, Ollama, Zhipu GLM and MiniMax plan windows](docs/screenshots/popover-misc.png)

## The Workbench

The popover is for a glance. The Workbench is a window you leave open.

### Usage Stats

A per-request ledger across every harness on the Mac — Claude Code, Claude
Cowork, Codex, ChatGPT Work, Cursor, Grok Build, AntiGravity, Gemini CLI —
with real token counts split into input, output, cache write and cache read,
priced from the same catalog the popover uses. Filter by harness, model and
range; drag the navigator to focus the chart while the tables keep the full
window.

![Usage Stats: 30 days of tokens by day, the harness mix, and the period table below](docs/screenshots/workbench-usage.png)

<details>
<summary>Usage Stats in the light appearance</summary>

![Usage Stats in the light appearance](docs/screenshots/workbench-usage-light.png)

</details>

### Sessions

Every local agent session, indexed with full-text search over prompts,
replies and tool calls, grouped by project, filtered by company, harness or
time. Open one and the transcript is beside it, with a find bar and page
controls that stay fast on transcripts with tens of thousands of lines;
**Open** hands the session back to its own CLI (`claude --resume`,
`codex resume`, `grok --resume`, `agy --conversation`).

![Sessions: the session list on the left, an open transcript with tool calls on the right](docs/screenshots/workbench-sessions.png)

<details>
<summary>Sessions in the light appearance</summary>

![Sessions in the light appearance](docs/screenshots/workbench-sessions-light.png)

</details>

Deleting a session from here is the one change Vibe Bar ever makes to a
harness's session files, and only at your explicit request — see
[Privacy and local data](#privacy-and-local-data).

### Skills

One shared library at `~/.agents/skills/`, projected into the skills
directories of Codex, Claude Code, AntiGravity, Grok Build and Cursor. Each
row is a skill; each dot is a harness, on or off. Install from a ZIP, adopt
skills a CLI already has, discover more from a repository, and back up before
anything is replaced.

![Skills: one row per skill, a toggle per harness, and the install, import and discover actions](docs/screenshots/workbench-skills.png)

<details>
<summary>Skills in the light appearance</summary>

![Skills in the light appearance](docs/screenshots/workbench-skills-light.png)

</details>

## Settings that stay out of the way

Everything is one two-column window. Three panes are worth a picture:

**Layout** arranges the cards of every popover page — which cards, which
column, which order — with presets and a live preview, so the Overview can
be the four quotas you watch and nothing else.

![The Layout editor: three segments of cards for the Overview page with a preview on the right](docs/screenshots/settings-layout.png)

<details>
<summary>The Layout editor in the light appearance</summary>

![The Layout editor in the light appearance](docs/screenshots/settings-layout-light.png)

</details>

**Menu Bar** chooses what the menu bar item itself says — icon only, one
line, two rows or compact — which quota windows it shows, and whether the
colour follows the forecast or the raw percentage.

![Menu Bar settings: layout and density pickers, and a checklist of quota windows per provider](docs/screenshots/settings-menubar.png)

**MCP Server** is the agent side of the app, covered next.

## Agents (MCP)

Vibe Bar can answer your coding agent's questions about your own usage. While
the app runs it exposes a read-only MCP server on a Unix domain socket in your
home directory — no network port, no API key — so Claude Code, Codex CLI,
Cursor or any stdio MCP client can ask "how much Claude do I have left?",
"who burned the most tokens this month?" or "find my session about the
parser".

Set it up by pasting this into any agent that can fetch a URL:

```
Fetch and execute the appropriate instructions to set me up for Vibe Bar from https://raw.githubusercontent.com/AstroQore/vibe-bar/main/docs/agent-setup/prompt.md
```

Or configure it by hand — every client runs the same command:

```sh
claude mcp add --scope user vibebar -- "/Applications/Vibe Bar.app/Contents/MacOS/VibeBar" --mcp-stdio
```

![MCP Server settings: the switch, socket path and connected clients, then a copyable snippet per client](docs/screenshots/settings-mcp.png)

Everything agents can reach is read-only except an opt-in "refresh my quota"
tool and an opt-in skill installer; credentials are never exposed and emails
are masked. The socket is created `0600` inside the `0700` `~/.vibebar/`,
is never bound to a network interface, and is removed when Vibe Bar quits.

## Remote machines

The separate [VibeBar Probe](https://github.com/AstroQore/vibebar-probe)
watches supported CLI logs on a systemd Linux machine without opening an
inbound port. Facts are buffered locally, encrypted to this Mac's Core, and
routed through an opaque Relay that never sees plaintext. Each machine stays
out of your totals until you switch **Include in totals** on; then its usage
joins this Mac's in the Overview and the cost pages.

![The Machines page: two probes with today's, 7-day and 30-day tokens and cost, and an Include in totals switch](docs/screenshots/popover-machines.png)

![Remote Probes settings: the workspace, relay and sync state, provisioning, and per-machine cost aggregation](docs/screenshots/settings-remote.png)

See the [Remote Probe guide](https://vibebar.aqor.io/docs/guide/remote-probes)
for installation, enrollment, updates, rollback and the end-to-end encryption
model.

## What Vibe Bar reads

| Surface | Quota and status | Cost and activity |
| --- | --- | --- |
| ChatGPT / Codex | Codex subscription windows, Spark, OpenAI status | `~/.codex/sessions/**/*.jsonl` |
| Claude Code / Cowork | 5 Hours, Weekly, per-model weekly, Anthropic status | `~/.claude/projects/**/*.jsonl`, Claude.app's Cowork transcripts |
| Gemini + AntiGravity | Gemini Web quotas, local AntiGravity language-server quotas | Local Gemini / AntiGravity usage records |
| Grok + Cursor | Grok quota, Cursor Models and Other Models, Grok Bot weekly, SpaceXAI + Cursor status | Local Grok records, Cursor account usage events; Grok Bot is quota-only |
| Misc providers | Each provider's own coding- or token-plan endpoint | Quota-only unless an adapter exposes local usage |

Provider contracts change without notice. Vibe Bar keeps refresh errors
visible, keeps the last known good snapshot, and never presents stale data as
a successful update.

## About the screenshots

Every picture on this page is the real app, launched in its **demo mode**:
the same binary, pointed at a home directory built by
[`Scripts/demo_home.py`](Scripts/demo_home.py). The quota, forecast, cost and
ledger numbers are one maintainer's real usage, copied; everything that would
identify a person — account ids, machine names, paths, sessions, cookies,
Keychain items — is replaced or fabricated, and every refresh that would
leave that directory is switched off. The agent sessions and skills are
written for the occasion. [`Scripts/capture_demo_screenshots.sh`](Scripts/capture_demo_screenshots.sh)
opens each surface in both appearances and captures it over a flat backdrop;
`DemoMode.swift` is the switch.

## Architecture

Vibe Bar is one app built from two SwiftPM targets plus one package of its
own that lives in a separate repository.

| Piece | What it is | Where it lives |
| --- | --- | --- |
| `VibeBarApp` | The menu-bar item, the popover, the Mini Window, the Workbench, Settings. AppKit + SwiftUI. | This repository |
| `VibeBarCore` | Quota, usage, cost, pricing, forecasting, provider adapters, remote sync — everything testable without a window. | This repository |
| [`agent-session-kit`](https://github.com/AstroQore/agent-session-kit) | Reading what the coding agents left on disk: session discovery and parsing per harness, the full-text session index, deletion planning, harness naming, and the local MCP Unix-socket / stdio transport. | Separate public repository |

The kit was extracted from this repository so that the "what did my agents
actually do" half is usable — and auditable — on its own. It knows nothing
about quotas, plans or prices; that vocabulary stays in `VibeBarCore`. It has
no third-party dependencies and is AGPL-3.0-only, same as Vibe Bar.

**How a kit release reaches you.** `Package.swift` pins the kit to an exact
tag and SwiftPM links it statically — it is compiled into the executable, not
shipped as a framework you could swap. A new kit release changes nothing on
your Mac until Vibe Bar bumps that pin and ships a build. **Settings › System
› Components** shows the kit version compiled into the build you are running,
with a *Check for kit updates* button; nothing checks at launch or on a
timer.

## Privacy and local data

Vibe Bar has no telemetry pipeline and no hosted plaintext analytics backend.
Local and remote-Probe usage analysis stays on this Mac. The optional hosted
account/control service stores workspace, enrollment, Relay directory and
audit metadata only. Derived state stays under:

```text
~/.vibebar/
├── settings.json
├── quotas/
├── cost_snapshots/
├── scan_cache/
├── pricing_sources/
├── pricing_cache.json
├── service_status.json
├── usage_events.sqlite3
├── session_index.sqlite3
├── remote_core.json
├── remote_usage.sqlite3
├── cost_history.json
└── mcp.sock            (only while the app runs, mode 0600)
```

- CLI credential and session files are read-only inputs. The one exception
  is whole-session deletion from the Workbench's Sessions page, performed
  only at your explicit request and never editing a session file's contents.
- The Skills manager writes to `~/.agents/skills/` and the managed skills
  directories of the five harnesses it projects into, and nowhere else.
- Vibe Bar-owned cookies and provider secrets live inside one versioned
  Keychain Vault, not one prompt-generating item per secret.
- Privacy Mode clears derived cost data and keeps cost history off disk while
  enabled. Retention is configurable, and Cost Data can be cleared manually.

Vibe Bar intentionally runs **without the App Sandbox**: browser-cookie
import and the local AntiGravity language-server probe require capabilities
the sandbox blocks. The app is open source, reads only the provider inputs it
needs, and writes application state only under `~/.vibebar/` and its
Keychain Vault. See
[AGENTS.md](AGENTS.md#6-home-directory-and-why-we-no-longer-sandbox) for the
full trade-off.

## Install

### Download a release

1. Download the Apple-silicon ZIP from
   [GitHub Releases](https://github.com/AstroQore/vibe-bar/releases/latest).
2. Move `Vibe Bar.app` to `/Applications`.
3. Launch it from Applications or Spotlight.

Release builds are ad-hoc signed and not notarized. If Gatekeeper blocks the
first launch, right-click the app and choose **Open**. No Apple Developer
account is required to build or run Vibe Bar locally.

Installed builds check the signed update feed once a day and always ask
before installing. **Settings › System** chooses between the stable **Main**
channel and the preview **Dev** channel; Dev also receives every Main
release. **Check for Updates…** is in the menu-bar item's context menu and in
Settings.

### Build from source

Requirements: macOS 26+, Xcode 26, Swift 6.2+.

```bash
git clone https://github.com/AstroQore/vibe-bar.git
cd vibe-bar
swift test
./Scripts/build_app.sh release
open ".build/Vibe Bar.app"
```

The package contains the `VibeBar` executable and the testable `VibeBarCore`
library. The packaging script assembles `.build/Vibe Bar.app`, copies its
resources and the Sparkle framework, and ad-hoc signs the bundle.

## Contributing

- [CONTRIBUTING.md](CONTRIBUTING.md) — concise human contributor guide.
- [AGENTS.md](AGENTS.md) — complete repository rules for coding agents.
- [AGENT-PR.md](AGENT-PR.md) — branch, verify, push, and open a PR.
- [AGENT-DEPLOY.md](AGENT-DEPLOY.md) — build, package, verify, and optionally
  install on a Mac.
- [SECURITY.md](SECURITY.md) — report vulnerabilities without exposing secrets.

Provider APIs and quota contracts move quickly; focused adapters, fixtures
and UI refinements are welcome.

## Acknowledgements

Vibe Bar is an independent project, but it stands on work shared by the wider
coding-agent community:

- [CodexBar](https://github.com/steipete/CodexBar) is the primary technical
  reference for the macOS menu-bar quota experience. Several browser-cookie
  and Keychain utilities, selected provider behaviors, and the AntiGravity
  local-probe flow were adapted from or reimplemented with reference to it.
- [CC Switch](https://github.com/farion1231/cc-switch) informed the unified
  Skills workflow and remains an interoperability reference for existing
  cross-agent skill layouts.
- [CLIProxyAPI](https://github.com/router-for-me/CLIProxyAPI) and its ecosystem
  informed our understanding of multi-provider CLI account and quota
  workflows. Vibe Bar does not embed, launch, or require CLIProxyAPI.
- [ccusage](https://github.com/ccusage/ccusage) informed local session-cost
  parsing and pricing semantics.
- [LiteLLM](https://github.com/BerriAI/litellm),
  [models.dev](https://github.com/anomalyco/models.dev), and
  [Portkey Models](https://github.com/Portkey-AI/models) maintain the public
  model-pricing catalogs Vibe Bar refreshes and merges for cost attribution.
  [AstroQore VibeBar Model Pricing](https://github.com/AstroQore/vibebar-model-pricing)
  carries the small Vibe Bar-specific supplement layer.

Vibe Bar also directly uses
[SweetCookieKit](https://github.com/steipete/SweetCookieKit) for local browser
cookie access and [Sparkle](https://github.com/sparkle-project/Sparkle) for
signed app updates. See [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md) for
the relationship and license details; complete applicable license texts live
under [Resources/ThirdPartyLicenses](Resources/ThirdPartyLicenses) and are
included in packaged app bundles. These projects are independent from Vibe
Bar; acknowledgement does not imply affiliation or endorsement.

## License

Vibe Bar is licensed under the
[GNU Affero General Public License v3.0 only](LICENSE).

## Star History

<p align="center">
  <a href="https://star-history.com/#AstroQore/vibe-bar&Date">
    <img src="https://api.star-history.com/svg?repos=AstroQore/vibe-bar&type=Date" alt="Star History Chart">
  </a>
</p>
