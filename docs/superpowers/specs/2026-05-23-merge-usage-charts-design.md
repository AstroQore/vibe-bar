# Merge Usage Heatmap and Hourly Burn Rate — Design

## Motivation

The Overview, the cost-detail popover, the per-provider stack, and the
per-provider detail view each render two adjacent cards:

- `UsageHeatmapView` — 7 × 24 weekday × hour heatmap.
- `UsageRateView` — 24-hour aggregate bar chart of token totals.

The bar chart is exactly the column sum of the heatmap (see
`UsageRateView.hourTotals`, which sums `heatmap.cells` along the
weekday axis). The two cards therefore tell the same story twice — at
different resolutions — and together consume ~360 pt of vertical space
per render site. AQ flagged this as redundant.

## User-facing change

Replace the two cards with a single card that mounts the bar chart as
a **marginal histogram on top of the heatmap**, sharing one X axis.
The bar chart keeps its full height-encoded magnitude (this is the
"intuitiveness" AQ asked to preserve); the heatmap below it answers
"which days drive each hour's column."

```
┌─ When you use Claude        Peak 3am · Fri 3pm  ⟳ ─┐
│                                                     │
│  ▁ ▁ ▂ █ ▆ ▃ ▁ ▁  ▁ ▂ ▃ ▂  ▂ ▃ ▄ ▃ ▂ ▁  ▂ ▂ ▂ ▂ ▂ ▁│   bar row
│  12am   3am   6am    12pm    6pm                    │   ~80 pt
│  ───────────────────────────────────────────────    │
│  Sun ░ ░ ▒ █ ▓ ▒ ░ ░  ░ ▒ ▒ ▒  ▒ ▓ ▒ ▒ ░ ░  ░ ░ ░ ░│
│  Mon ░ ░ ░ ▒ ▒ ░ ░ ░  ░ ▒ ▓ ▒  ▒ ▒ ▒ ▒ ▒ ░  ░ ░ ░ ░│
│  Tue ░ ░ ░ ▒ ▒ ░ ░ ░  ░ ▒ ▒ ▓  ▒ ▓ █ ▓ ▒ ░  ░ ░ ░ ░│
│  Wed ░ ░ ░ ▒ ░ ░ ░ ░  ░ ░ ▒ ▒  ▒ ▒ ▒ ▒ ░ ░  ░ ░ ░ ░│   heatmap
│  Thu ░ ▒ ▒ █ █ ▓ ░ ░  ░ ▒ ▒ ▒  ▒ ▓ ▒ ▒ ░ ░  ▒ ░ ░ ░│   ~140 pt
│  Fri ░ ░ ▒ ▓ ▓ ▒ ░ ░  ░ ▒ ▓ ▓  ▓ ▓ ▓ █ ▓ ░  ▒ ░ ░ ░│
│  Sat ░ ░ ░ ▒ ▒ ░ ░ ░  ░ ▒ ▒ ▒  ▒ ▒ ▒ ▒ ▒ ░  ▒ ░ ░ ░│
│                                                     │
│  Quiet ▫▫▫▪■  Heavy                                 │
└─────────────────────────────────────────────────────┘
```

Net effect: ~360 pt → ~260 pt per render site (~100 pt saved, four
sites), one title, one refresh button, one peak label.

## Design

### New view — `UsageActivityView`

A new view in `Sources/VibeBarApp/Views/`, replacing the call sites of
both `UsageHeatmapView` and `UsageRateView`. Same input as today:

```swift
struct UsageActivityView: View {
    let heatmap: UsageHeatmap
    let density: Theme.Density
    var titleOverride: String? = nil
}
```

Internals:

1. **Cell-width source of truth.** Compute `HeatmapGridMetrics` exactly
   as `UsageHeatmapView.gridMetrics(for:)` does today (label gutter +
   24 cells + 23 inter-cell gaps). Both the bar row and the heatmap
   row share this metric so bars and cells line up column-for-column.
2. **Bar row.** A custom 24-wide HStack of `RoundedRectangle` bars,
   not SwiftUI `Charts` — the existing `Charts`-driven `BarMark` lays
   out its own bandscale and won't align pixel-exactly to a hand-laid
   grid. Each bar:
   - Width = `cellSide` (same as heatmap cell).
   - Max height = ~64 pt (so the row is ~80 pt with axis labels).
   - Height = `hourTotal / maxHourTotal` × maxHeight, clamped so that
     a non-zero column always renders at least 2 pt (the heatmap uses
     `log1p` for the same reason; we'll reuse `log1p`-scaled height).
   - Fill = `intensityColor(intensity:)` shared with the heatmap, so
     bar color and cell color come from one continuous gradient
     instead of `UsageRateView`'s three discrete buckets.
3. **Y-axis tick column.** A 28 pt left gutter matching the heatmap's
   weekday-label gutter. Three ticks (`0`, mid, max) formatted via the
   same `formatTokens` helper currently in `UsageRateView`. This keeps
   the bar row's absolute magnitude readable instead of relative-only.
4. **Shared hour-label row.** The existing `0 / 6am / 12pm / 6pm`
   labels move out of `UsageHeatmapView`'s grid and become a single
   shared row sitting *between* the bars and the heatmap. The label
   for each tick is centered on the column of the corresponding cell.
5. **Header.**
   - Title: same as today (`titleOverride` or `"When you use \(tool)"`).
   - Peak label: combined string `Peak <hour> · <day> <hour>`, e.g.
     `Peak 3am · Fri 3pm` (hourly-aggregate peak first, day × hour
     peak second). Hour peak comes from `hourTotals`; day × hour peak
     comes from the existing `peakLabel` logic. Both hours are
     formatted through the unified `formatHourLabel`. If the two
     peak hours coincide (e.g. both happen at hour 15), collapse to
     `Peak 3pm · Fri`.
   - Refresh button: one only, calls `environment.refreshCostUsage()`.
6. **Footer.** Drop the `"Aggregated across all weekdays"` line — the
   heatmap right below already shows the per-day decomposition, which
   makes the label redundant. Keep the existing Quiet → Heavy legend
   row.

### Helper extraction

Three small symbols move from one or both existing views into a
private helper file `Sources/VibeBarApp/Views/UsageHeatmapShared.swift`
so the new view and any future consumers share them instead of having
two copies:

- `intensityColor(intensity:) -> Color`
- `formatHourLabel(_ hour: Int) -> String` — single canonical formatter
  using the 12-hour style (`12am`, `3am`, `12pm`, `3pm`). Today the
  two views disagree: `UsageHeatmapView.hourLabel(15)` returns `"15"`
  (24-hour) while `UsageRateView.formatHour(15)` returns `"3pm"`. The
  rate-view style wins because the peak label / tooltip read more
  naturally to a US/EN reader (the existing `Peak Fri 15` is the
  outlier). All cell tooltips, peak labels, and axis ticks route
  through this one function.
- `HeatmapGridMetrics` (currently file-private in the heatmap view).

No public API change — these are app-internal.

### Deletion

`UsageHeatmapView` and `UsageRateView` are deleted in the same commit
that lands `UsageActivityView`, because every caller is updated in
one go. Their tests (none today; they're View-only) need nothing.

## Affected callsites

All in `Sources/VibeBarApp/Views/PopoverRoot.swift`:

- `OverviewWaterfall` (lines ~450–458) — replace the two adjacent
  cards in the masonry column with one `UsageActivityView`. Use
  `titleOverride: "When you use everything"` to preserve the existing
  Overview label.
- `CostDetailPopoverContent` (lines ~1107–1108).
- `ProviderCostStack` (lines ~595–596).
- `ProviderDetailView` (lines ~1177–1178) — right column.

In each case the replacement is a one-for-two swap; no surrounding
layout change required because the masonry / VStack just receives one
child instead of two.

## Out of scope

- No change to `UsageHeatmap` model, `CostSnapshot.heatmap`, or
  `CostSnapshotAggregator.combinedHeatmap`.
- No interactivity beyond the existing `.help(...)` tooltip on cells
  (no hover-to-highlight column, no click-to-filter).
- No mini-window changes — `UsageActivityView` is only used inside the
  popover/detail surfaces.
- No localization or text changes beyond the peak label and the
  removed footer.

## Verification

Per `AGENTS.md` § 4, before claiming the change works:

```sh
swift build
swift test
./Scripts/build_app.sh release
codesign -d --entitlements - ".build/Vibe Bar.app"
```

Manual smoke (only the new visuals matter — the data path is
unchanged):

1. `open ".build/Vibe Bar.app"`, click the menubar item.
2. Overview tab: one merged "When you use everything" card. Confirm
   bars and cells line up column-for-column at the three width
   breakpoints (narrow / default / wide popover).
3. Click into a provider detail → same merged card in the right
   column.
4. Pick a provider with sparse data and confirm bars still render a
   2 pt minimum height (no invisible bars on near-zero hours).
5. Pick a provider with no data — both subviews should collapse to
   the existing `"No data yet"` placeholder without leaving an empty
   bar row.
