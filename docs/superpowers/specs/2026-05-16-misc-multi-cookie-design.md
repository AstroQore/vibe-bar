# Multi-Cookie Misc Providers — Design

## Motivation

Cookie-based misc providers (Kimi, Cursor, Alibaba console, MiMo,
iFlytek, Tencent Hunyuan, Volcengine, OpenCode Go, Ollama) currently
hold a single cookie per tool. Power users have multiple accounts
with the same provider — one team account, one personal account, a
trial account — and want the Vibe Bar card to reflect the combined
plan capacity across all of them.

## User story

1. **Additive import.** Importing a cookie never clobbers a previously
   imported one. Each click of "Import from browser" or each manual
   paste appends a new slot.
2. **Managed list.** Settings shows the list of imported cookies for
   the provider in insertion order, with the import time and source
   label, and a delete button per row.
3. **Aggregated query.** On refresh, every slot is queried in
   parallel. For each bucket, `usedPercent` is averaged across
   successful queries (0% + 100% → 50%; 20% + 80% → 50%). Failed
   queries are excluded; if every slot fails, the surfaced error
   matches the first failure.

This applies to every cookie-based misc provider listed above. Misc
providers that use API keys / OAuth / local probes are unchanged.

## Architecture

### Storage — `MiscCookieSlotStore`

New core module `Sources/VibeBarCore/Credentials/MiscCookieSlotStore.swift`.

```swift
public struct MiscCookieSlot: Codable, Equatable, Sendable {
    public let id: UUID
    public var cookieHeader: String
    public var sourceLabel: String   // "Manual paste", "Chrome (Default)", "Auto-refresh"
    public var importedAt: Date
    public var origin: Origin        // .manual | .browserImport | .autoRefresh

    public enum Origin: String, Codable, Sendable {
        case manual
        case browserImport
        case autoRefresh
    }
}

public enum MiscCookieSlotStore {
    public static func slots(for tool: ToolType) -> [MiscCookieSlot]
    @discardableResult public static func append(_ slot: MiscCookieSlot, for tool: ToolType) -> Bool
    @discardableResult public static func updateHeader(slotID: UUID, for tool: ToolType, header: String, sourceLabel: String? = nil) -> Bool
    @discardableResult public static func delete(slotID: UUID, for tool: ToolType) -> Bool
    @discardableResult public static func deleteAll(for tool: ToolType) -> Bool
    public static func hasAnySlot(for tool: ToolType) -> Bool
}
```

- Single Keychain entry per tool, service
  `com.astroqore.VibeBar.misc-secrets`, account
  `<tool.rawValue>.cookieSlots`. Value is a JSON-encoded
  `[MiscCookieSlot]`.
- Append is O(n) (decode → push → re-encode), which is fine: a
  realistic upper bound is < 10 slots per tool.
- Treats an empty list as "delete the keychain entry."

### Migration — `MiscCookieSlotStore.migrateLegacyIfNeeded(_:)`

On every slot read, lazily migrate single-cookie state into slots:

1. If the slot list is empty:
   - If `MiscCredentialStore.manualCookieHeader` exists →
     append a `.manual` slot with `sourceLabel = "Manual paste"`,
     `importedAt = now` (the original timestamp is unknown), then
     delete `manualCookieHeader`.
   - If `CookieHeaderCache.load(for:)` returns an entry whose label
     is not `"Manual paste"` → append a `.browserImport` slot using
     that entry's `sourceLabel` + `storedAt`, then clear the cache.
2. The legacy `importedCookieHeader` Keychain kind is removed (it
   was never populated by current code; verified by grep).

After migration, single-cookie reads via `manualCookieHeader` and
`CookieHeaderCache` are no longer authoritative. They are deleted
during migration; any future writes to those locations are dead
code that we also remove.

### Resolution — `MiscCookieResolver`

`MiscCookieResolver` gains `resolveAll(for:) -> [Resolution]`:

```swift
public struct Resolution {
    public let slotID: UUID
    public let header: String
    public let sourceLabel: String
}

public static func resolveAll(for spec: Spec) -> [Resolution]
```

Behaviour:

- Reads `MiscCookieSlotStore.slots(for: spec.tool)`.
- Filters slots by the current `MiscProviderSettings.sourceMode`:
  - `auto` → all slots
  - `browserOnly` → only `.browserImport` / `.autoRefresh` slots
  - `manualOnly` → only `.manual` slots
  - `apiOnly` / `off` → empty
- Filters out slots whose `cookieHeader` no longer has the
  spec's required credential cookies (same gate as today).
- Returns Resolutions in slot insertion order.

`resolve(for:)` keeps its existing signature but is now a thin
shim: `resolveAll(for:).first`. Adapters migrate off it.

`forceBrowserImport(for:)` becomes `appendBrowserImport(for:)` —
it always appends a new slot (or returns `nil` if no browser
session is found). The button label in Settings changes to "Import
from browser" to match.

### Aggregation — `MiscQuotaAggregator`

New module `Sources/VibeBarCore/Services/MiscQuotaAggregator.swift`:

```swift
public enum MiscQuotaAggregator {
    public struct SlotResult {
        public let slotID: UUID
        public let outcome: Result<AccountQuota, QuotaError>
    }

    public static func aggregate(
        tool: ToolType,
        account: AccountIdentity,
        results: [SlotResult],
        queriedAt: Date
    ) -> AccountQuota
}
```

Semantics:

- For each bucket id observed in any successful result:
  - `usedPercent` = arithmetic mean across results that contained
    that id (rounded to one decimal).
  - `resetAt` = earliest non-nil `resetAt` (most pessimistic).
  - `title`, `shortLabel`, `rawWindowSeconds`, `groupTitle` =
    copied from the first result that contained the bucket.
- `plan` = first non-nil plan among successful results.
- `email` = first non-nil email.
- `error` = nil if any result succeeded; otherwise the first
  failure (so the card surfaces "Needs login" or "Network error"
  exactly as it does today for a single failing cookie).
- `queriedAt` = the caller's clock (single timestamp for the card,
  not per slot).

The aggregator is pure (no Keychain, no networking) — easy to test
with hand-rolled `SlotResult`s.

### Adapters

Every cookie-based adapter currently follows this pattern:

```swift
guard let resolution = MiscCookieResolver.resolve(for: spec) else { ... }
let data = try await fetch(using: resolution.header)
let buckets = parse(data)
return AccountQuota(... buckets ...)
```

The new pattern, applied uniformly to all 9 cookie adapters:

```swift
let resolutions = MiscCookieResolver.resolveAll(for: spec)
guard !resolutions.isEmpty else { throw QuotaError.noCredential }

let results = await withTaskGroup(of: MiscQuotaAggregator.SlotResult.self) { group in
    for r in resolutions {
        group.addTask { await fetchOneSlot(r) }
    }
    return await group.collect()
}

return MiscQuotaAggregator.aggregate(
    tool: .volcengine,
    account: account,
    results: results,
    queriedAt: now()
)
```

`fetchOneSlot(_:)` wraps the existing per-cookie request in a
`do/catch`, returning `.success(AccountQuota)` or `.failure(QuotaError)`.

Per-slot stale-cookie handling: when a slot's fetch raises
`.needsLogin`, we **mark** the slot as suspect (we don't delete it
silently — the user must see it in Settings and decide). A
follow-up improvement could carry a `lastError` field on the slot
for UI display; the initial cut just logs a `SafeLog.warn` and lets
the user re-import.

### Auto-refresh — `HiddenCookieRefresher`

`HiddenCookieRefresher` currently writes to
`CookieHeaderCache`. After migration that path is gone. The new
contract:

- For each tool the refresher supports, iterate over its slots
  in order.
- For each slot, inject the slot's cookies into the
  `WKWebsiteDataStore`, load `Config.refreshURL`, wait
  `postLoadWait`, capture the resulting cookie header.
- If the captured header differs from the slot's stored header,
  call `MiscCookieSlotStore.updateHeader(slotID:for:header:sourceLabel:)`
  with `sourceLabel = "Auto-refresh"`. Slot ID and `importedAt`
  are preserved.
- Between slots, clear the WebView cookie store so slots can't
  leak into each other. Cheapest path: tear down the
  `WKWebsiteDataStore` per slot. We accept slower refresh in
  exchange for correctness.

Manual slots (`origin == .manual`) are skipped — auto-refresh
only revives sessions the user originally captured via the
in-app web login or browser auto-import. The user's pasted
session is their problem to maintain.

### Settings UI — `CookieSourceControls`

The current row exposes "Import now" + a single manual paste field.
Replaces with:

```
┌──────────────────────────────────────────────────────────┐
│ [trash] Chrome (Default)   imported 2026-05-16 10:14    │
│ [trash] Manual paste       imported 2026-05-16 11:02    │
│ [trash] Auto-refresh       refreshed 2026-05-16 11:30    │
├──────────────────────────────────────────────────────────┤
│ [ Import from browser ]                                  │
│ [ Paste new cookie...        ] [Save]                    │
└──────────────────────────────────────────────────────────┘
```

- Slot list shows `sourceLabel` + relative or absolute
  `importedAt`. Each row has a trash button that calls
  `MiscCookieSlotStore.delete(slotID:for:)` and triggers a
  refresh.
- "Import from browser" runs `MiscCookieResolver.appendBrowserImport(for:)`
  off the main thread.
- "Paste new cookie" saves into a new `.manual` slot on the same
  store, then clears the textfield.

Empty list shows the existing tertiary help text.

The list uses a `@State`-tracked snapshot that's reloaded after every
mutation, plus subscribes to a new `Notification.Name.miscCookieSlotsChanged`
posted by the store on writes, so the UI updates when
`HiddenCookieRefresher` mutates slots in the background.

### Tests (`Tests/VibeBarCoreTests`)

New files / cases:

- `MiscCookieSlotStoreTests.swift`
  - Append → list grows in order.
  - Delete by id → list shrinks; deleting last clears the keychain entry.
  - Update header preserves id + importedAt.
  - Migration: pre-existing `manualCookieHeader` + cache entry produce
    expected slots and clear legacy entries (mock the keychain via
    a test-only protocol or by namespacing the service to the test bundle).
- `MiscQuotaAggregatorTests.swift`
  - Two successes (0% + 100%) → 50%.
  - Two successes with non-overlapping bucket ids → both buckets
    appear with their original percent.
  - One success + one `needsLogin` → success bucket only, no error.
  - All failures → carries the first failure as `error`.
  - Earliest `resetAt` wins.
- `MiscCookieResolverTests.swift` (extend)
  - `resolveAll` filters by sourceMode.
  - Slots missing required credentials are dropped.

No existing tests need to change once the adapters are migrated;
parser tests stay green because parsing is per-slot.

## Migration safety

- The migration is one-way (single → list). A user downgrading
  the app loses multi-slot state; the first slot survives because
  the legacy migration runs only when the list is empty.
- All slot data is in Keychain, never in `~/.vibebar/settings.json`.
- `MiscProviderSettings.sensitiveKeyMarkers` already rejects
  `manualcookie` / `cookieheader`; no settings JSON change.

## Out of scope (for this PR)

- Per-slot `lastError` indicator on the Settings row.
- Aggregation across **different** providers (still per-tool).
- "Pause/disable" toggle for an individual slot — the user can
  just delete and re-import.
- Aggregating MiniMax / Z.ai API keys or Copilot device tokens
  (this PR only touches cookie-based misc providers).
