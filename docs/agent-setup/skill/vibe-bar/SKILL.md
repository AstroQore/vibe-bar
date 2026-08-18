---
name: vibe-bar
description: >-
  Answer questions about this Mac's AI subscription quota, token usage, spend,
  provider status and local agent sessions through Vibe Bar's MCP server. Use
  when the user asks about "my AI quota", "how much Codex / Claude / Gemini /
  Grok / Cursor do I have left", "when does my 5-hour window reset", "am I
  going to run out", "refresh my usage", "what did I spend this month", "who
  used the most tokens", "why is this costing so much", "is Anthropic down", or
  "find my session about …". Requires the Vibe Bar app to be running with its
  MCP server enabled.
---

# Vibe Bar

Vibe Bar is a macOS menu-bar app that watches this Mac's AI subscriptions. Its
MCP server (`vibebar`) exposes what it knows, read-only. Everything comes from
the running app's own caches — answers are fast, and they are as fresh as the
app made them, which is why every payload carries `generatedAt`.

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
| "find my session about X" | `sessions.search` |
| "what have I been working on?" | `sessions.list` |
| "is <provider> down?" | `status.get` |
| "why is this model so expensive?" | `pricing.effective` |

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
- **Empty filter lists mean "nothing"**, not "everything". Omit a filter to
  mean everything.

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

**"Find that session where I fixed the socket server."**
`sessions.search` with the user's own words as `query`. Show the title,
project directory, harness and last-active time, and offer the `sourcePath` so
they can open the transcript. The `<b>` markers in `snippet` mark the match —
render them as emphasis or strip them, do not print them raw.

**"Refresh and tell me where I stand."**
`quota.refresh` (no `force`), wait a couple of seconds, then `quota.get`. If
`triggered` was false because nothing was stale, say the numbers were already
current rather than pretending to have refreshed.
