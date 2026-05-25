# Subscription Fill History — Design

## Motivation

`SubscriptionUtilizationView` shows the **current** state of each quota
bucket (used % + linear "expected" reference + ETA). It does not retain
anything once a window resets. AQ wants to see, per bucket, how the
last several windows ended — "did I burn through my weekly plan, or
leave headroom?" — so a 30-day trend is visible at a glance.

## Scope

### In scope

- Four primary providers only: `codex`, `claude`, `gemini`, `grok`.
  Misc providers (`MiscQuotaAggregator` and everything routed through
  it) are excluded entirely from both write and display paths.
- Bucket scope inside those four: **only buckets whose window is
  fixed-clock and monotonic within the window.** Concretely, a bucket
  is recorded iff `rawWindowSeconds == nil || rawWindowSeconds >= 86_400`.
  Hits:
  - Claude — `weekly` (and sub-buckets `weekly_sonnet`, `weekly_opus`,
    `weekly_design`, `weekly_oauth_apps`), `daily_routines`.
  - Codex — `weekly`.
  - Grok — `monthly` (`rawWindowSeconds = nil`; the monthly reset
    timestamp from xAI's billing endpoint anchors the window).
  - Gemini Web — per-model daily buckets (one bucket per model id;
    `rawWindowSeconds = nil`, anchored on the per-model `resetAt`).

### Out of scope

- **`five_hour` buckets** (Claude + Codex). These are on-demand rolling
  windows: the 5h clock doesn't tick when idle. Recording per-window
  peaks across many such windows produces a series in which "I used
  more" can look like "the bar went down" — exactly the failure mode
  AQ flagged. The 5-hour view remains in the existing live bar + pace
  ETA; we just do not historize it.
- Cost/tokens history. That's `CostHistoryStore`'s job; this store
  only deals with quota fill %.
- Cross-bucket aggregation ("show me Claude's combined Sonnet+Opus
  weekly utilization"). Possible later; data will be there.

## User-facing change

Inside each row of `SubscriptionUtilizationView`, below the existing
`pace` legend line, add a 16–20 pt sparkline strip showing past
windows for that bucket. Each tick:

- **Bar height** encodes the fill metric for that window
  (`peakUsedPercent`, transformed by current `DisplayMode`).
- **Bar color** reuses `Theme.barColor(percent:mode:)`.
- **Rightmost bar** is the **in-progress** window (current `resetAt`),
  rendered at 0.5 opacity to read as "this week, so far".
- **Bars to its left** are completed windows, newest-right to
  oldest-left, capped to whatever fits the row width (~8 bars in the
  narrow popover, ~20 in the wide mini-window layout).

Hover/tooltip on a bar shows:

```
peak  87%       (or "13% left" in remaining mode)
last  85%
window  05-19 12:00 → 05-26 12:00     (omits left side if windowStart is nil)
observed 312×
```

Bars older than `AppSettings.costData.retentionDays` (default 30) are
pruned from disk and never reach the view.

## Architecture

### New model — `SubscriptionWindowSample`

In `Sources/VibeBarCore/Models/`:

```swift
public struct SubscriptionWindowSample: Codable, Hashable, Sendable {
    public var accountId: String        // matches QuotaCacheStore key
    public var tool: ToolType
    public var bucketId: String         // "weekly" / "daily_routines" / "monthly" / model id
    public var windowEnd: Date          // == resetAt at the time of observation
    public var windowStart: Date?       // resetAt - rawWindowSeconds when available
    public var rawWindowSeconds: Int?   // mirror of QuotaBucket.rawWindowSeconds
    public var peakUsedPercent: Double  // max(usedPercent) observed in this window
    public var lastUsedPercent: Double  // latest observation's usedPercent
    public var observationCount: Int
    public var firstSeenAt: Date
    public var lastSeenAt: Date
}
```

Identity for max-merge is `(accountId, bucketId, windowEnd)`. A window
is uniquely identified by its `resetAt`; if the API later reports a
different `resetAt` for the same bucket, that's a new window (new
sample).

**Stability assumption.** All four primary providers report `resetAt`
as an absolute server-side timestamp (Claude/Codex/Gemini: ISO8601 or
epoch from the API payload; Grok: the billing endpoint's monthly
`resetsAt`). The value is therefore deterministic across refreshes
within one window, and exact equality is a safe merge key. If a future
provider drifts (e.g., reports "seconds remaining" that we'd convert
to `now + Δ`), the fix is a `±5 min` tolerance match inside `observe`
— intentionally deferred until we see such a case.

### New service — `SubscriptionHistoryStore`

In `Sources/VibeBarCore/Services/SubscriptionHistoryStore.swift`,
following `CostHistoryStore` 1-for-1:

- Swift `actor`.
- Backing file `~/.vibebar/subscription_history.json`, mode 0600,
  schema-versioned.
- In-memory cached storage, throttled write (~30 s coalesce window).
- `flushPendingWrites()` for shutdown / tests.
- Retention pruning by `AppSettings.costData.retentionDays` — a
  sample is dropped when `windowEnd < now - retentionDays` (consistent
  with how cost history treats `date < cutoff`).
- Defensive 16 MB file-size guard mirrors cost history.

Public API:

```swift
public actor SubscriptionHistoryStore {
    public static let shared = SubscriptionHistoryStore()

    /// Fold one `AccountQuota` into the store. No-op for any tool
    /// not in the primary-four allow-list, and for any bucket where
    /// `resetAt == nil`, `usedPercent` is NaN, or
    /// `rawWindowSeconds != nil && rawWindowSeconds < 86_400`.
    public func observe(_ quota: AccountQuota, now: Date = Date())

    /// All samples for one (accountId, bucketId), newest windowEnd
    /// first. `includeCurrent` controls whether the in-progress window
    /// (resetAt in the future) is included.
    public func samples(
        accountId: String,
        bucketId: String,
        now: Date = Date(),
        includeCurrent: Bool = true,
        limit: Int? = nil
    ) -> [SubscriptionWindowSample]

    public func prune(retentionDays: Int)
    public func eraseAll()
    public func flushPendingWrites() async
}
```

Merge rule inside `observe`:

```
key = (accountId, bucketId, windowEnd = bucket.resetAt)
if existing for key:
    existing.peakUsedPercent  = max(existing.peakUsedPercent, fresh)
    existing.lastUsedPercent  = fresh                 // overwrite by time
    existing.observationCount += 1
    existing.lastSeenAt       = max(existing.lastSeenAt, now)
else:
    create with peak = last = fresh, count = 1,
                firstSeenAt = lastSeenAt = now
prune by retention
schedule throttled save
```

### Write path

```
QuotaService.refresh
  → adapter.fetch
  → store(success: AccountQuota)          (existing)
        ├─ QuotaCacheStore.save           (existing, current snapshot)
        └─ Task { SubscriptionHistoryStore.shared.observe(quota) }   (new)
```

The hook lives in `QuotaService.store(success:)`. It dispatches into
the actor with a detached `Task` so the synchronous refresh path
doesn't await disk I/O. The provider gating
(`quota.tool ∈ {codex,claude,gemini,grok}`) is enforced inside
`observe` rather than at the call site, so the call site stays one
line and future provider additions only touch one file.

### Read path / View integration

- `QuotaService` gains a `@Published var historyByAccountBucket:
  [HistoryKey: [SubscriptionWindowSample]]` (struct key
  `{accountId, bucketId}`). Populated on launch from
  `SubscriptionHistoryStore.shared` and refreshed after each
  `observe(_)` call.
- `SubscriptionUtilizationView.row(for:)` reads the samples for the
  current `(account.id, bucket.id)` from `quotaService` (already in
  `@EnvironmentObject`), passes them into a new
  `SubscriptionWindowSparkline` view.
- New `Sources/VibeBarApp/Views/SubscriptionWindowSparkline.swift`:

```swift
struct SubscriptionWindowSparkline: View {
    let samples: [SubscriptionWindowSample]   // newest first
    let mode: DisplayMode
    let density: Theme.Density
    let bucketResetAt: Date?                  // current in-progress windowEnd

    // Renders an HStack of fixed-width rounded bars; the bar whose
    // windowEnd == bucketResetAt is treated as in-progress.
}
```

**Empty-history case.** When `samples` is empty and the bucket has a
`resetAt`, the sparkline renders a single faded "current" bar at the
current `usedPercent` (read from the bucket itself, not the store).
When `samples` is empty and the bucket has no `resetAt` either, the
sparkline renders nothing (no row underneath the main bar). This keeps
the row visually stable as the first window starts filling.

Hover handled with a `.popover(isPresented:)` driven by a per-bar
`HoverableBar` wrapper — same pattern the existing tooltip code uses
for the heatmap legend.

### Configuration / settings surface

No new user settings. Retention follows the existing
`AppSettings.costData.retentionDays` slider in the Settings view's
"Cost Data" section.

Because the slider lives under "Cost Data" but now affects both
stores, this work adds a one-line caption under the existing
"Keep history" Picker:

> Applies to cost history and subscription fill history.

No new section, no new toggle. If subscription history later needs
its own independent retention, splitting this into a second slider
is a self-contained follow-up.

## Data scale

Worst-case 30-day retention, one account per primary tool, all
buckets covered:

| Bucket                       | Samples / 30 d |
|------------------------------|----------------|
| Claude weekly + 4 sub-buckets| ~5 × 5 = 25    |
| Claude daily_routines        | 30             |
| Codex weekly                 | 5              |
| Grok monthly                 | 1–2            |
| Gemini per-model daily × ~6  | ~180           |
| **Total**                    | **~240**       |

~240 samples × ~250 bytes JSON each ≈ 60 KB. Well under the 16 MB
guard.

## Privacy

- `accountId` is already a privacy-preserving hash
  (`PrivacyPreservingHash`); we don't store anything beyond what
  `QuotaCacheStore` already keeps.
- No email, plan label, cookies, or tokens leave `QuotaService`.
- File mode 0600, same as the other `.vibebar` artifacts.

## Migration / versioning

- `Storage.schemaVersion = 1` from day one.
- No legacy file to migrate.
- If a future schema bump is incompatible with the on-disk version,
  the store falls back to empty (cost-history's pattern) — losing
  history is acceptable because it's purely observational.

## Testing

`Tests/VibeBarCoreTests/SubscriptionHistoryStoreTests.swift`:

1. **Empty store, then observe one quota** → one sample per eligible
   bucket; ineligible buckets (`five_hour`, misc tools) are skipped.
2. **Two observations in same window** → one sample, peak = max,
   last = latest, count = 2.
3. **Observation with smaller `usedPercent` than the stored peak**
   → peak retained, last updated.
4. **`resetAt` advances** (new window) → new sample appears, previous
   sample untouched.
5. **Retention prune** at 7 days drops samples whose `windowEnd <
   now - 7 days`.
6. **Restart round-trip** — write, instantiate a new store on the
   same file URL, samples match.
7. **Provider gating** — observing a `codex` quota writes; observing a
   misc-provider quota is a no-op.
8. **Window-gating** — `five_hour` bucket is a no-op; `weekly` and
   `daily_routines` write.

For the UI, a SwiftUI preview in `SubscriptionWindowSparkline.swift`
that exercises:

- One full bar at 100%, one at 80%, one at 5%, current at 20%.
- Empty history (current-only).
- Remaining-mode rendering.

## Verification checklist (before claiming done)

Same four commands `CLAUDE.md` requires:

```sh
swift build
swift test
./Scripts/build_app.sh release
codesign -d --entitlements - ".build/Vibe Bar.app"
```

Then `open ".build/Vibe Bar.app"` and confirm:

- A sparkline strip renders under each eligible bucket row.
- The 5-hour row has **no** sparkline (only the live bar + pace).
- Hovering a bar pops the tooltip with peak/last/window/count.
- Killing and relaunching the app preserves the strip (samples reload
  from disk).
- Toggling `DisplayMode` flips the bars between used / remaining
  encoding without re-querying.

## Open questions

None at this stage — proceed to writing-plans.
