---
name: vibe-bar
description: >-
  Answer questions about this Mac's AI subscription quota, token usage, spend,
  provider status and local agent sessions through Vibe Bar's MCP server. Use
  when the user asks about "my AI quota", "how much Codex / Claude / Gemini /
  Grok / Cursor do I have left", "when does my 5-hour window reset", "am I
  going to run out", "refresh my usage", "what did I spend this month", "who
  used the most tokens", "why is this costing so much", or "is Anthropic
  down". Also the local session manager for agent work on this Mac: find any
  CLI session by keyword, project or time and read its transcript — "find the
  session about …", "what was Codex doing in this repo", "what did that other
  agent already try", "show me that conversation". Also installs agent skills
  through Vibe Bar's Skills manager ("install this skill", "set me up with the
  Vibe Bar skill"). Requires the Vibe Bar app to be running with its MCP
  server enabled.
---

# Vibe Bar

Vibe Bar is a macOS menu-bar app that watches this Mac's AI subscriptions. Its
MCP server (`vibebar`) exposes what it knows. Everything it reports comes from
the running app's own caches — answers are fast, and they are as fresh as the
app made them, which is why every payload carries `generatedAt`. Every tool is
read-only except `skills.install`, which writes only inside the skills
directories Vibe Bar manages.

If the `vibebar` tools are not available, the app is not running or the server
is switched off in Settings → MCP Server. Say so; do not guess numbers.

## Two naming axes — get this right first

This is the single most common way to answer wrongly.

- **Quota axis** — what an account is *billed against*. L1 company → L2
  SubProvider → L3 bucket. Anthropic → Claude → "5 Hours" / "Weekly" /
  per-model groups. `quota.*` and `status.*` speak this.
- **Usage / cost axis** — where the tokens were *actually spent*. The unit is
  the local **harness**: the CLI or app that produced the sessions. `usage.*`
  and `sessions.*` speak this.

They are not the same list and must never be mixed in one answer. Claude Code
and Claude Cowork are two harnesses spending one Claude quota. "Gemini Web" is
a quota SubProvider with no local usage at all — historical Gemini tokens are
always labelled "Gemini CLI". Read the `vibebar://naming-spec` resource for
the current tables; it is generated from the app's own catalogs, so it is
never stale.

Model names are always the raw vendor id (`claude-opus-4-7`,
`gemini-3.5-flash-high`). Filter on those; never invent a friendly name, and
never infer a model that a log recorded as absent.

## Which tool answers what

| Question | Tool |
| --- | --- |
| "how much X do I have left?" / "when does it reset?" | `quota.get` |
| "am I going to run out before the reset?" | `quota.get` with `includeForecast: true` |
| "refresh my usage" | `quota.refresh`, then `quota.get` |
| "what did I spend today / this week / this month?" | `cost.snapshot` |
| "how has my spend moved day by day?" | `cost.history` |
| "who used the most tokens?" | `usage.summary` with `groupBy: "harness"` |
| "which model costs me the most?" | `usage.summary` with `groupBy: "model"` |
| "show my usage over time" | `usage.trend` |
| "what were my last N requests?" | `usage.requests` |
| "find the session about X" / "which session was that in?" | `sessions.search` |
| "what ran in this repo lately?" / "what have I been working on?" | `sessions.list` |
| "what did that agent actually do?" / "show me the match in context" | `sessions.transcript` |
| "is <provider> down?" | `status.get` |
| "why is this model so expensive?" | `pricing.effective` |
| "install this skill" / "set me up with the Vibe Bar skill" | `skills.install` |

`vibebar://tools` carries the same routing table plus the rules below, if you
would rather read it than trust this copy.

## Rules

- **Cite `generatedAt`,** and for quota also `lastUpdated`. These are cached
  numbers. "As of 3 minutes ago, you have 57% of your 5-hour window left" is
  a correct answer; "you have 57% left" implies a live read you did not do.
- **Refresh sparingly.** `quota.refresh` without `force` only touches accounts
  that are genuinely stale — that is the right default and it is nearly free.
  Do not force-refresh more than once every few minutes; forced refreshes are
  rate-limited to one every 20 seconds and the user can disable them entirely.
  A `triggered: false` answer is normal, not an error: read the message.
- **Prefer `cost.snapshot` over `usage.summary`** for "what have I spent" —
  it is pre-aggregated. Reach for `usage.summary` when the user wants a custom
  window or a breakdown.
- **Money comes in two fields.** `costMicros` is exact micro-USD; `costUSD` is
  rounded for display. Add up micros, print dollars.
- **`unpricedRequests > 0` means the cost total is a floor.** Some model in
  the window has no rate card. Say so, and check `pricing.effective`.
- **Privacy mode empties the cost surfaces.** When `cost.snapshot` reports
  `privacyModeEnabled: true`, the user turned cost tracking off — report that,
  never "you spent nothing".
- **Request-level history is about 30 days deep.** Older usage survives only as
  daily totals: `usage.summary` and `usage.trend` still see it, `usage.requests`
  does not.
- **Cursor has no local token counters.** Its sessions are listed locally, but
  its cost comes from the dashboard. A Cursor session with real messages and no
  tokens is expected, not a bug.
- **Never open `sourcePath` yourself.** Read sessions through
  `sessions.transcript`. See the section below for why.
- **Empty filter lists mean "nothing"**, not "everything". Omit a filter to
  mean everything.
- **`skills.install` is the only tool that writes.** It installs into
  `~/.agents/skills/` and projects into the agent CLIs named in `apps` —
  nowhere else, and never over a folder a different skill already holds. Pass
  `apps` or the skill is on the machine switched on for nobody. It can be
  turned off in Settings → MCP Server, in which case it says so.

## Sessions: the local session manager

Every coding agent on this Mac leaves a session log behind — Codex rollouts,
Claude Code projects, Gemini chats, Grok updates, Cursor stores. Vibe Bar
indexes all of them, which makes these three tools the way one agent finds and
reads what another agent did. That is the point of them: you are usually not
answering "find *my* session about X" for a human, you are picking up work
someone else started.

### Locate

`sessions.search` when you know what was said — it matches titles, project
paths and message bodies, substring, so partial words and CJK both work.
`sessions.list` when you know *where* or *when* instead. Both narrow the same
way, with the same argument names `usage.*` uses:

| Argument | Means |
| --- | --- |
| `harnesses` | the CLI or app that produced it (`codex`, `claudeCode`, …) |
| `providers` | the on-disk store — prefer `harnesses` unless you want a specific store |
| `projectDir` | case-insensitive **substring** of the working directory |
| `from` / `to` | ISO-8601 bounds on last activity, `from` inclusive, `to` exclusive |
| `models` | raw vendor model ids, exact and case-insensitive |

`projectDir` being a substring is deliberate and useful: pass a repo name to
match every checkout of it, or a full absolute path for an exact one.
`sessions.list` also still accepts `since` as an alias for `from`.

### What comes back, and what to use it for

| Field | Use it for |
| --- | --- |
| `sessionId` | resuming with that CLI — the id its own `--resume` wants |
| `projectDir` | where the work happened; `cd` there before continuing it |
| `harness` / `harnessName` | which agent produced it (the usage axis, not a quota name) |
| `title` / `summary` | naming the session to the user |
| `lastActiveAt` | how stale the work is |
| `matchedSeq` (search) | the message index of the hit — feed straight to `sessions.transcript` |
| `snippet` (search) | the excerpt, `<b>` around the match — render as emphasis or strip, never print raw |
| `sourcePath` | telling two sessions apart, or a command the *user* runs. **Not** for you to open |
| `id` | naming the session to `sessions.transcript` |

`sourcePath` is a last resort. On a busy Mac these logs reach hundreds of
megabytes; reading one yourself burns your context and can stall the tool
call. `sessions.transcript` exists so you never have to.

### Read

`sessions.transcript` takes `id`, or `sessionId` plus `provider`. Two window
shapes:

- **`around: <seq>`** with `radius` (default 20) — a match in context. Pass a
  search hit's `matchedSeq` directly; it always resolves.
- **`from` / `limit`** — paging. Feed the response's `nextFrom` back as `from`
  until `hasMore` is false.

`roles` thins a window (`["user"]` for just the prompts). It does *not* search
past the window, so "the 20 messages around seq 400, user turns only" stays
inside 380–420.

Responses are capped three ways — message count, a total byte budget, and per
message — so one 40 KB tool dump cannot swallow the answer. When a cap bites,
`truncated` is true, `truncationReasons` names which (`messageLimit`,
`byteBudget`, `messageText`, `readCeiling`), and `notice` is a sentence you can
relay. Relay it: silently reporting a clipped transcript as the whole one is
the failure mode here.

### The honest limits

- **The index is as fresh as the last sweep.** A session being written right
  now is searchable up to that sweep, not up to its newest message. If a
  colleague's agent just started, wait or ask them.
- **Body search needs body indexing on.** With it off (Vibe Bar → Settings),
  titles and project paths still match, but the words inside messages do not —
  so an empty result means "not indexed", not "never happened".
- **`totalMessageCount` is usually absent.** The reader stops as soon as it has
  your window, so it genuinely does not know how long the log is. Use
  `hasMore` / `nextFrom`, not arithmetic on a total.
- **A window past the readable region comes back empty** with `readCeiling`
  and no cursor. Retrying the identical call will not help; that part of the
  log is past what a bounded read reaches.
- **Sessions are read-only here.** There is no edit, no delete, no resume.
  Hand the user a resume command; do not try to drive another agent's session.

## Worked patterns

**"How am I doing on Claude?"**
Call `quota.get` with `tools: ["claude"]` and `includeForecast: true`. Report
the bucket titles as the app names them ("5 Hours", "Weekly"), remaining
percent, reset time, and the forecast verdict if the confidence is not
`learning`. Name the company/SubProvider, not a harness.

**"Who's been burning my tokens this month?"**
`usage.summary` with `days: 30` and `groupBy: "harness"`. Rank by
`totalTokens`, quote `costUSD` alongside. Answer in harness names ("Claude
Code", "Codex"), and only mention companies if the user asked at that level.

**"Another agent was working on the socket server here — what did it try?"**
`sessions.search` with `query: "socket server"` and `projectDir` set to the
repo you are in. Take the newest hit, then `sessions.transcript` with its `id`
and `around: <matchedSeq>` to read the match in context. Widen with `radius`,
or page from `nextFrom`, before concluding anything — one message is rarely
the whole attempt. Report the harness and `lastActiveAt` so the user knows
whose work it was and how old.

**"What has Codex been doing in this repo this week?"**
`sessions.list` with `harnesses: ["codex"]`, `projectDir` set to the repo, and
`from` seven days back. Summarize by title and last-active time. Open the
interesting ones with `sessions.transcript` and `roles: ["user"]` — the
prompts are the outline of what was attempted.

**"Refresh and tell me where I stand."**
`quota.refresh` (no `force`), wait a couple of seconds, then `quota.get`. If
`triggered` was false because nothing was stale, say the numbers were already
current rather than pretending to have refreshed.

**"Install the Vibe Bar skill for me."**
`skills.install` with `source: "AstroQore/vibe-bar"` and `apps` set to the
agent CLIs the user wants it in — yours at minimum. Report the `path` it came
back with. Do not copy files by hand while this tool is available: the app
keeps one copy and the projections in step, and a hand-made folder is one it
will refuse to manage later.
