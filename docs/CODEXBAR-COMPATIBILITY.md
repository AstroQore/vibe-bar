# CodexBar compatibility and migration notes

Research baseline: [`steipete/CodexBar@fa50cf2`](https://github.com/steipete/CodexBar/commit/fa50cf2dcdb67796dfc200c422d7b7c4f325a294),
version 0.55.0 (129), inspected on 2026-08-24.

## What the screenshot shows

CodexBar's cost menu combines a Token/Cost daily chart with the selected
day's model split, 30-day estimated cost, Codex project ranking, and recent
sessions. The implementation is
[`CostHistoryChartMenuView.swift`](https://github.com/steipete/CodexBar/blob/fa50cf2dcdb67796dfc200c422d7b7c4f325a294/Sources/CodexBar/CostHistoryChartMenuView.swift).
It does not currently use pie or donut charts.

Vibe Bar already has a broader per-request ledger than that view: Codex,
ChatGPT Work, Claude Code/Cowork, Gemini CLI, AntiGravity, Grok Build, and
Cursor. The Overview therefore adds its own 30-day `Usage Mix` card rather
than porting CodexBar's scanner or view. It switches between Project,
Harness, Model, and Token Flow donut charts. Project attribution comes from
the cwd in Codex and Claude request logs; agent worktrees collapse into their
owning repository.

## Provider boundary

The current CodexBar manifest registers 69 provider ids. Its provider guide
is slightly stale: the summary table omits `qoder`, `poe`, `longcat`, and
`sub2api`, so the source manifest is the authority.

Already native to Vibe Bar (keep Vibe Bar's adapter and hierarchy):

`codex`, `claude`, `cursor`, `opencodego`, `alibaba`, `alibabatokenplan`,
`gemini`, `antigravity`, `copilot`, `zai`, `minimax`, `kimi`, `kilo`, `kiro`,
`ollama`, `openrouter`, `mimo`, `warp`, `grok`.

Good native-port candidates whose request/parser logic is relatively
self-contained:

`openai`, `clinepass`, `fireworks`, `manus`, `moonshot`, `t3chat`,
`synthetic`, `elevenlabs`, `perplexity`, `deepinfra`, `crof`, `venice`,
`qoder`, `llmproxy`, `litellm`, `deepgram`, `poe`, `chutes`, `neuralwatt`,
`clawrouter`, `sub2api`, `zenmux`, `aiand`, `xai`, and the newer `ibmbob`.

Providers that need browser-cookie, CSRF, localStorage, workspace, or
multi-step adaptation:

`opencode`, `qwencloud`, `factory`, `sakana`, `abacus`, `mistral`,
`commandcode`, `groq`, `longcat`, `zoommate`, `notion`.

Providers that need local files, subprocesses, OAuth brokers, cloud signing,
or another platform runtime:

`devin`, `vertexai`, `augment`, `amp`, `windsurf`, `zed`, `doubao`,
`deepseek`, `codebuff`, `stepfun`, `bedrock`.

Do not present these as quota integrations without more product evidence:

- `azureopenai` currently verifies a deployment with a minimal completion;
- `jetbrains` depends on IDE XML state;
- `wayfinder` is a multi-endpoint local router integration.

Vibe Bar also has providers CodexBar does not: iFlyTek, Tencent Hunyuan
Coding/Token Plans, Volcengine Coding/Agent Plans, and Baidu Qianfan. A
CodexBar migration must never delete or flatten them. `grok` and `xai`,
`codex` and `openai`, `kimi` and `moonshot`, and the Alibaba surfaces are
different billing products and remain separate.

### Why provider source files are not copied wholesale

CodexBar is MIT and Vibe Bar already ships its license notice, so the license
permits a port. The files do not compile in Vibe Bar unchanged: they depend on
CodexBar's `ProviderDescriptor`, `ProviderFetchContext`, `UsageSnapshot`,
credential registry, plugin host, QuickJS/Sucrase runtime, and Swift 6 strict
concurrency contracts. Vibe Bar has its own `ToolType`, `QuotaAdapter`,
`AccountQuota`, Keychain Vault, and company/SubProvider/harness axes.

The initial compatibility layer is therefore the read-only **CodexBar
Bridge** on the Misc page. When an installed CodexBar CLI is present, Vibe Bar
reads its stable `dashboard-v1` JSON and displays only provider windows that
Vibe Bar does not already own. Credentials remain in CodexBar; overlapping
providers remain on Vibe Bar's native pipeline. The bridge always requests
redacted identity, so full account emails never enter its stdout. Small high-value adapters can
then move from the candidate lists above into Vibe Bar one by one.

## What the CodexBar CLI does

It is not the OpenAI Codex coding CLI. It exposes CodexBar's provider fetchers,
cost scanner, configuration, and automation surfaces to shells, CI, and local
dashboards. See upstream [`docs/cli.md`](https://github.com/steipete/CodexBar/blob/fa50cf2dcdb67796dfc200c422d7b7c4f325a294/docs/cli.md).

- `usage`: quota for enabled providers as text, JSON, or TOON.
- `cards`: terminal card grid.
- `cost`: local token/cost; Codex can group by project or session.
- `sessions list|focus`: local session discovery and window focus.
- `dashboard`: one stable dashboard-v1 JSON snapshot, then exit.
- `serve`: foreground HTTP server and web UI.
- `guard`: script-friendly exit codes based on remaining session/weekly quota.
- `config validate|dump|providers|enable|disable|set-api-key`.
- `hooks list|enable|disable|test|watch`.
- `cache clear`, `cookie refresh`, `diagnose`, and plugin management.

The app can install its bundled CLI into `/usr/local/bin` and
`/opt/homebrew/bin`; standalone release archives, Linuxbrew/AUR packages, and
`swift build -c release --product CodexBarCLI` are also supported upstream.

Vibe Bar already exposes quota, usage, cost, sessions, status, pricing, and
skills over its local Unix-socket MCP server. If Vibe Bar gains a public CLI,
it should be a thin client over that socket, with `guard` as the most useful
first automation command. A duplicate local HTTP server and a second secret
store are not needed.
