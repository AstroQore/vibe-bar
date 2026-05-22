# Merge Usage Charts Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Collapse `UsageHeatmapView` + `UsageRateView` into a single `UsageActivityView` where the hourly bar chart sits as a marginal histogram above the 7×24 heatmap, sharing one X axis, peak label, and refresh button.

**Architecture:**
- Pure-data helpers (hour totals, peak hour, peak cell, hour-label formatter) land as a `UsageHeatmap` extension in `VibeBarCore` so they get XCTest coverage.
- SwiftUI-bound helpers (`HeatmapGridMetrics`, `intensityColor`, the `HeatmapGridWidthPreferenceKey`) live in a new `UsageHeatmapShared.swift` in the app target so the new view and any future card share them.
- `UsageActivityView` lays out 24 hand-positioned `RoundedRectangle` bars on top of the existing weekday × hour cell grid, sharing one `HeatmapGridMetrics` so bars and cells align column-for-column.
- Four PopoverRoot call sites swap in one go; `UsageHeatmapView.swift` and `UsageRateView.swift` are then deleted.

**Tech Stack:** Swift 6.2, SwiftUI, AppKit, XCTest. SwiftPM single-package layout. macOS 26+.

**Spec:** [docs/superpowers/specs/2026-05-23-merge-usage-charts-design.md](../specs/2026-05-23-merge-usage-charts-design.md).

**Worktree:** `/Users/aq/Coding/Gits/vibe-bar/.claude/worktrees/feat+merge-usage-charts` on branch `feat/merge-usage-charts`. All commands assume this is the working directory.

---

## Task 1: Add `UsageHeatmap` activity extensions in Core (with tests)

Add pure-data helpers that the new view will use. These live in Core so we can unit-test them.

**Files:**
- Create: `Sources/VibeBarCore/Models/UsageHeatmap+Activity.swift`
- Create: `Tests/VibeBarCoreTests/UsageHeatmapActivityTests.swift`

---

- [ ] **Step 1: Write the failing tests**

Create `Tests/VibeBarCoreTests/UsageHeatmapActivityTests.swift`:

```swift
import XCTest
@testable import VibeBarCore

final class UsageHeatmapActivityTests: XCTestCase {
    // MARK: - formatHourLabel

    func testFormatHourLabelMidnight() {
        XCTAssertEqual(UsageHeatmap.formatHourLabel(0), "12am")
    }

    func testFormatHourLabelNoon() {
        XCTAssertEqual(UsageHeatmap.formatHourLabel(12), "12pm")
    }

    func testFormatHourLabelMorning() {
        XCTAssertEqual(UsageHeatmap.formatHourLabel(3), "3am")
        XCTAssertEqual(UsageHeatmap.formatHourLabel(11), "11am")
    }

    func testFormatHourLabelAfternoon() {
        XCTAssertEqual(UsageHeatmap.formatHourLabel(15), "3pm")
        XCTAssertEqual(UsageHeatmap.formatHourLabel(23), "11pm")
    }

    // MARK: - hourTotals

    func testHourTotalsSumsColumns() {
        var cells = Array(repeating: Array(repeating: 0, count: 24), count: 7)
        cells[0][3] = 10
        cells[1][3] = 20
        cells[2][3] = 30
        cells[0][15] = 1
        let heatmap = UsageHeatmap(tool: .codex, cells: cells, totalTokens: 61)
        let totals = heatmap.hourTotals
        XCTAssertEqual(totals.count, 24)
        XCTAssertEqual(totals[3], 60)
        XCTAssertEqual(totals[15], 1)
        XCTAssertEqual(totals[0], 0)
    }

    // MARK: - peakHour

    func testPeakHourOfEmptyHeatmapIsNil() {
        let heatmap = UsageHeatmap.empty(tool: .claude)
        XCTAssertNil(heatmap.peakHour)
    }

    func testPeakHourReturnsHourOfHighestColumnTotal() {
        var cells = Array(repeating: Array(repeating: 0, count: 24), count: 7)
        cells[0][9] = 5
        cells[1][9] = 5
        cells[0][15] = 11
        let heatmap = UsageHeatmap(tool: .codex, cells: cells, totalTokens: 21)
        XCTAssertEqual(heatmap.peakHour, 15)
    }

    func testPeakHourTieReturnsEarliestHour() {
        var cells = Array(repeating: Array(repeating: 0, count: 24), count: 7)
        cells[0][7] = 10
        cells[0][20] = 10
        let heatmap = UsageHeatmap(tool: .codex, cells: cells, totalTokens: 20)
        XCTAssertEqual(heatmap.peakHour, 7)
    }

    // MARK: - peakCell

    func testPeakCellOfEmptyHeatmapIsNil() {
        let heatmap = UsageHeatmap.empty(tool: .claude)
        XCTAssertNil(heatmap.peakCell)
    }

    func testPeakCellReturnsWeekdayAndHourOfMaxCell() {
        var cells = Array(repeating: Array(repeating: 0, count: 24), count: 7)
        cells[0][9] = 30
        cells[4][15] = 90 // Thu 3pm — biggest single cell
        cells[5][3] = 50
        let heatmap = UsageHeatmap(tool: .codex, cells: cells, totalTokens: 170)
        let peak = heatmap.peakCell
        XCTAssertEqual(peak?.weekday, 4)
        XCTAssertEqual(peak?.hour, 15)
    }

    func testPeakCellTieReturnsFirstScannedCell() {
        var cells = Array(repeating: Array(repeating: 0, count: 24), count: 7)
        cells[2][10] = 50
        cells[5][3] = 50
        let heatmap = UsageHeatmap(tool: .codex, cells: cells, totalTokens: 100)
        let peak = heatmap.peakCell
        // Scanning order is weekday 0..7, hour 0..24 → (2, 10) wins over (5, 3).
        XCTAssertEqual(peak?.weekday, 2)
        XCTAssertEqual(peak?.hour, 10)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter UsageHeatmapActivityTests`
Expected: build fails with "type 'UsageHeatmap' has no member 'formatHourLabel'" / "no member 'hourTotals'" / "no member 'peakHour'" / "no member 'peakCell'".

- [ ] **Step 3: Write the extension to make tests pass**

Create `Sources/VibeBarCore/Models/UsageHeatmap+Activity.swift`:

```swift
import Foundation

public extension UsageHeatmap {
    /// Token totals collapsed across the 7 weekdays, indexed by hour 0..23.
    var hourTotals: [Int] {
        (0..<24).map { hour in
            cells.reduce(0) { $0 + $1[hour] }
        }
    }

    /// Hour of day with the highest aggregate token count across all weekdays,
    /// or nil if the heatmap is empty. Earliest hour wins on tie.
    var peakHour: Int? {
        let totals = hourTotals
        guard let max = totals.max(), max > 0 else { return nil }
        return totals.firstIndex(of: max)
    }

    /// The single (weekday, hour) cell with the highest token count, or nil
    /// if the heatmap is empty. Scan order is weekday 0..7 then hour 0..24,
    /// so the first-seen maximum wins on tie.
    var peakCell: (weekday: Int, hour: Int)? {
        var best: (value: Int, weekday: Int, hour: Int) = (0, 0, 0)
        for (d, row) in cells.enumerated() {
            for (h, v) in row.enumerated() where v > best.value {
                best = (v, d, h)
            }
        }
        return best.value > 0 ? (best.weekday, best.hour) : nil
    }

    /// 12-hour formatter for a 0..23 hour index — "12am", "3am", "12pm", "3pm".
    /// Used in peak labels, axis ticks, and cell tooltips so the merged
    /// activity card never mixes 12h and 24h styles.
    static func formatHourLabel(_ hour: Int) -> String {
        switch hour {
        case 0:  return "12am"
        case 12: return "12pm"
        default: return hour < 12 ? "\(hour)am" : "\(hour - 12)pm"
        }
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter UsageHeatmapActivityTests`
Expected: PASS, 8 tests.

- [ ] **Step 5: Commit**

```bash
git add Sources/VibeBarCore/Models/UsageHeatmap+Activity.swift \
       Tests/VibeBarCoreTests/UsageHeatmapActivityTests.swift
git commit -m "$(cat <<'EOF'
Add UsageHeatmap activity helpers for merged usage card

Extension on UsageHeatmap exposing hourTotals, peakHour, peakCell, and
a canonical 12-hour formatHourLabel. These move the pure-data shape of
UsageRateView.hourTotals and UsageHeatmapView.peakLabel into Core so
they are testable and the upcoming merged UsageActivityView shares one
source of truth instead of duplicating the logic again.
EOF
)"
```

---

## Task 2: Add SwiftUI shared helpers (`HeatmapGridMetrics`, `intensityColor`)

Extract the layout-metric struct and gradient helper so the new view and the existing one can briefly coexist without duplicating logic. The existing `UsageHeatmapView` keeps its `private struct HeatmapGridMetrics` and `private func intensityColor` until Task 5 deletes the whole file — there is no symbol collision because both old declarations are file-private.

**Files:**
- Create: `Sources/VibeBarApp/Views/UsageHeatmapShared.swift`

---

- [ ] **Step 1: Create the shared helpers file**

Create `Sources/VibeBarApp/Views/UsageHeatmapShared.swift`:

```swift
import SwiftUI

/// Layout metrics shared by `UsageActivityView`'s bar row and heatmap grid so
/// they line up column-for-column at every popover width.
struct HeatmapGridMetrics {
    let labelWidth: CGFloat
    let cellSide: CGFloat
    let cellSpacing: CGFloat

    /// Pixel width of a 6-hour block at the current cell size, used for the
    /// `0 / 6am / 12pm / 6pm` axis labels.
    var hourBlockWidth: CGFloat {
        cellSide * 6 + cellSpacing * 5
    }

    var cellCornerRadius: CGFloat {
        min(2.5, max(1.5, cellSide * 0.16))
    }

    /// Compute the metrics that fit `availableWidth`. A measured width of 0
    /// (first layout pass before GeometryReader has a real width) falls back
    /// to a conservative 520 pt so a nested popover cannot inflate itself
    /// and then keep measuring the inflated width.
    static func compute(forWidth availableWidth: CGFloat) -> HeatmapGridMetrics {
        let labelWidth: CGFloat = 28
        let cellSpacing: CGFloat = 2
        let fallbackWidth: CGFloat = 520
        let resolvedWidth = availableWidth > 1 ? availableWidth : fallbackWidth
        let usableWidth = max(0, resolvedWidth - labelWidth - cellSpacing * 24)
        let rawSide = usableWidth / 24
        let cellSide = min(max(rawSide, 9), 30)
        return HeatmapGridMetrics(
            labelWidth: labelWidth,
            cellSide: cellSide,
            cellSpacing: cellSpacing
        )
    }
}

/// PreferenceKey used by `UsageActivityView` to read the GeometryReader width
/// without triggering a layout loop.
struct HeatmapGridWidthPreferenceKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

/// Continuous faint-blue → warm-orange gradient. `intensity` is clamped to 0…1.
/// Opacity also rises with intensity so 0-value cells stay almost invisible.
func intensityColor(intensity: Double) -> Color {
    let clamped = min(max(intensity, 0), 1)
    let r = 0.42 + (0.97 - 0.42) * clamped
    let g = 0.60 - (0.60 - 0.55) * clamped
    let b = 0.97 - (0.97 - 0.20) * clamped
    return Color(red: r, green: g, blue: b).opacity(0.35 + 0.65 * clamped)
}
```

- [ ] **Step 2: Build to verify no symbol collision**

Run: `swift build`
Expected: build succeeds. The existing `UsageHeatmapView.swift` keeps its file-private `HeatmapGridMetrics`/`intensityColor`; both definitions coexist because of file-private scope.

- [ ] **Step 3: Commit**

```bash
git add Sources/VibeBarApp/Views/UsageHeatmapShared.swift
git commit -m "$(cat <<'EOF'
Extract HeatmapGridMetrics and intensityColor into a shared file

Pulls the layout-metric struct, GeometryReader preference key, and the
faint-blue-to-warm-orange gradient out of UsageHeatmapView and into a
new UsageHeatmapShared.swift so the upcoming UsageActivityView can
reuse them. The existing UsageHeatmapView keeps its file-private
copies until the merge lands; no symbol collision.
EOF
)"
```

---

## Task 3: Create `UsageActivityView`

The merged view: header row → bar row + Y-axis ticks → shared hour-axis labels → 7-row weekday heatmap → legend. All sharing one `HeatmapGridMetrics` instance so columns align.

**Files:**
- Create: `Sources/VibeBarApp/Views/UsageActivityView.swift`

---

- [ ] **Step 1: Create the view file with the full implementation**

Create `Sources/VibeBarApp/Views/UsageActivityView.swift`:

```swift
import SwiftUI
import VibeBarCore

/// Merged "When you use X" card. The top half is the hourly burn-rate
/// histogram (formerly `UsageRateView`); the bottom half is the weekday ×
/// hour heatmap (formerly `UsageHeatmapView`). Both share one X axis, one
/// `HeatmapGridMetrics` instance, one peak label, and one refresh button.
struct UsageActivityView: View {
    let heatmap: UsageHeatmap
    let density: Theme.Density
    /// Optional title override. The Overview's "all providers" version of
    /// this card uses `"When you use everything"` instead of the default
    /// derived from `heatmap.tool`.
    var titleOverride: String? = nil

    private let weekdayLabels = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]
    private let barRowHeight: CGFloat = 64

    @State private var measuredGridWidth: CGFloat = 0
    @EnvironmentObject var environment: AppEnvironment

    var body: some View {
        VStack(alignment: .leading, spacing: density.cardSpacing) {
            header
            content
            legend
        }
        .padding(density.cardPadding)
        .background(
            RoundedRectangle(cornerRadius: density.cardCornerRadius, style: .continuous)
                .fill(.background.tertiary.opacity(0.6))
        )
        .overlay(
            RoundedRectangle(cornerRadius: density.cardCornerRadius, style: .continuous)
                .stroke(.separator.opacity(0.4), lineWidth: 0.5)
        )
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(titleOverride ?? "When you use \(toolName)")
                .font(.system(size: density.bucketTitleFontSize, weight: .semibold))
            Spacer()
            if heatmap.totalTokens > 0 {
                Text(peakLabel)
                    .font(.system(size: density.subtitleFontSize))
                    .foregroundStyle(.secondary)
            }
            SectionRefreshButton(isRefreshing: false) {
                environment.refreshCostUsage()
            }
            .padding(.leading, 4)
        }
    }

    private var toolName: String {
        switch heatmap.tool {
        case .codex:  return "Codex"
        case .claude: return "Claude"
        case .alibaba, .alibabaTokenPlan, .gemini, .antigravity, .grok, .copilot, .zai, .minimax, .kimi, .cursor, .mimo, .iflytek, .tencentHunyuan, .tencentTokenPlan, .volcengine, .baiduQianfan, .openCodeGo, .kilo, .kiro, .ollama, .openRouter, .warp:
            return heatmap.tool.menuTitle
        }
    }

    private var peakLabel: String {
        guard let peakH = heatmap.peakHour, let cell = heatmap.peakCell else { return "" }
        let hourStr = UsageHeatmap.formatHourLabel(peakH)
        let cellHourStr = UsageHeatmap.formatHourLabel(cell.hour)
        let dayStr = weekdayLabels[cell.weekday]
        if peakH == cell.hour {
            return "Peak \(hourStr) · \(dayStr)"
        }
        return "Peak \(hourStr) · \(dayStr) \(cellHourStr)"
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        if heatmap.totalTokens == 0 {
            Text("No data yet")
                .font(.system(size: density.subtitleFontSize))
                .foregroundStyle(.tertiary)
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.vertical, 24)
        } else {
            let metrics = HeatmapGridMetrics.compute(forWidth: measuredGridWidth)
            GeometryReader { proxy in
                let liveMetrics = HeatmapGridMetrics.compute(forWidth: proxy.size.width)
                VStack(alignment: .leading, spacing: liveMetrics.cellSpacing) {
                    barRow(metrics: liveMetrics)
                    hourAxis(metrics: liveMetrics)
                    heatmapGrid(metrics: liveMetrics)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .preference(key: HeatmapGridWidthPreferenceKey.self, value: proxy.size.width)
            }
            .frame(height: contentHeight(for: metrics))
            .onPreferenceChange(HeatmapGridWidthPreferenceKey.self) { width in
                if abs(width - measuredGridWidth) > 0.5 {
                    measuredGridWidth = width
                }
            }
        }
    }

    private func contentHeight(for metrics: HeatmapGridMetrics) -> CGFloat {
        // bar row + spacing + hour axis (8pt) + spacing + 7 cell rows
        barRowHeight
            + metrics.cellSpacing
            + 8
            + metrics.cellSpacing
            + 7 * metrics.cellSide
            + 6 * metrics.cellSpacing
    }

    // MARK: - Bar row

    private func barRow(metrics: HeatmapGridMetrics) -> some View {
        let totals = heatmap.hourTotals
        let maxTotal = totals.max() ?? 0
        return HStack(alignment: .bottom, spacing: metrics.cellSpacing) {
            yAxisTickColumn(maxTotal: maxTotal, metrics: metrics)
            ForEach(0..<24, id: \.self) { hour in
                ZStack(alignment: .bottom) {
                    Color.clear
                    RoundedRectangle(cornerRadius: metrics.cellCornerRadius, style: .continuous)
                        .fill(intensityColor(intensity: barIntensity(value: totals[hour], max: maxTotal)))
                        .frame(width: metrics.cellSide, height: barHeight(value: totals[hour], max: maxTotal))
                }
                .frame(width: metrics.cellSide, height: barRowHeight)
            }
            Spacer(minLength: 0)
        }
        .frame(height: barRowHeight)
    }

    private func yAxisTickColumn(maxTotal: Int, metrics: HeatmapGridMetrics) -> some View {
        // Three ticks: max, ~50%, 0. Right-aligned in the 28pt label gutter.
        let ticks = [maxTotal, maxTotal / 2, 0]
        return VStack(alignment: .trailing, spacing: 0) {
            ForEach(Array(ticks.enumerated()), id: \.offset) { idx, tick in
                Text(formatTokens(tick))
                    .font(.system(size: 9, design: .rounded).monospacedDigit())
                    .foregroundStyle(.tertiary)
                if idx < ticks.count - 1 {
                    Spacer(minLength: 0)
                }
            }
        }
        .frame(width: metrics.labelWidth, height: barRowHeight, alignment: .trailing)
    }

    /// Log-scaled normalized intensity (0…1) so small columns still color.
    private func barIntensity(value: Int, max: Int) -> Double {
        guard value > 0, max > 0 else { return 0 }
        return log1p(Double(value)) / log1p(Double(max))
    }

    /// Pixel height of a single bar. Mirrors `barIntensity` (log-scaled) and
    /// floors any non-zero value at 2 pt so near-zero columns stay visible.
    private func barHeight(value: Int, max: Int) -> CGFloat {
        guard value > 0, max > 0 else { return 0 }
        let normalized = log1p(Double(value)) / log1p(Double(max))
        return CGFloat(max(2.0, normalized * Double(barRowHeight)))
    }

    private func formatTokens(_ tokens: Int) -> String {
        if tokens < 1_000 { return "\(tokens)" }
        if tokens < 1_000_000 { return String(format: "%.1fk", Double(tokens) / 1_000) }
        return String(format: "%.1fM", Double(tokens) / 1_000_000)
    }

    // MARK: - Hour axis row

    private func hourAxis(metrics: HeatmapGridMetrics) -> some View {
        HStack(spacing: metrics.cellSpacing) {
            Text("")
                .font(.system(size: 8))
                .frame(width: metrics.labelWidth, alignment: .trailing)
            ForEach([0, 6, 12, 18], id: \.self) { hour in
                Text(UsageHeatmap.formatHourLabel(hour))
                    .font(.system(size: 8, design: .rounded).monospacedDigit())
                    .foregroundStyle(.tertiary)
                    .frame(width: metrics.hourBlockWidth, alignment: .leading)
            }
            Spacer(minLength: 0)
        }
        .frame(height: 8)
    }

    // MARK: - Heatmap grid

    private func heatmapGrid(metrics: HeatmapGridMetrics) -> some View {
        let maxCell = heatmap.cells.flatMap { $0 }.max() ?? 0
        return VStack(alignment: .leading, spacing: metrics.cellSpacing) {
            ForEach(0..<7, id: \.self) { weekday in
                HStack(spacing: metrics.cellSpacing) {
                    Text(weekdayLabels[weekday])
                        .font(.system(size: 9, design: .rounded))
                        .foregroundStyle(.secondary)
                        .frame(width: metrics.labelWidth, alignment: .trailing)
                    ForEach(0..<24, id: \.self) { hour in
                        RoundedRectangle(cornerRadius: metrics.cellCornerRadius, style: .continuous)
                            .fill(cellColor(weekday: weekday, hour: hour, max: maxCell))
                            .frame(width: metrics.cellSide, height: metrics.cellSide)
                            .help(cellTooltip(weekday: weekday, hour: hour))
                    }
                    Spacer(minLength: 0)
                }
            }
        }
    }

    private func cellColor(weekday: Int, hour: Int, max: Int) -> Color {
        let value = heatmap.cells[weekday][hour]
        guard value > 0, max > 0 else { return Color.primary.opacity(0.05) }
        let normalized = log1p(Double(value)) / log1p(Double(max))
        return intensityColor(intensity: normalized)
    }

    private func cellTooltip(weekday: Int, hour: Int) -> String {
        let value = heatmap.cells[weekday][hour]
        let day = weekdayLabels[weekday]
        let hourStr = UsageHeatmap.formatHourLabel(hour)
        let label: String
        if value < 1_000 { label = "\(value) tok" }
        else if value < 1_000_000 { label = String(format: "%.1fk tok", Double(value) / 1_000) }
        else { label = String(format: "%.2fM tok", Double(value) / 1_000_000) }
        return "\(day) \(hourStr) · \(label)"
    }

    // MARK: - Legend

    private var legend: some View {
        HStack(spacing: 6) {
            Text("Quiet")
                .font(.system(size: density.resetCountdownFontSize))
                .foregroundStyle(.tertiary)
            ForEach(0..<6, id: \.self) { step in
                RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                    .fill(intensityColor(intensity: Double(step) / 5.0))
                    .frame(width: 16, height: 8)
            }
            Text("Heavy")
                .font(.system(size: density.resetCountdownFontSize))
                .foregroundStyle(.tertiary)
            Spacer()
        }
    }
}
```

- [ ] **Step 2: Build to verify the new view compiles**

Run: `swift build`
Expected: build succeeds. The view is unreferenced for now; the compiler will not complain.

- [ ] **Step 3: Commit**

```bash
git add Sources/VibeBarApp/Views/UsageActivityView.swift
git commit -m "$(cat <<'EOF'
Add UsageActivityView merging heatmap and burn-rate cards

New view that draws the 24-hour bar chart as a marginal histogram
above the existing weekday-by-hour heatmap, sharing one X axis,
one HeatmapGridMetrics, one peak label, and one refresh button.
Bars use log-scaled height on the same gradient as the cells so a
peak-hour column reads continuously from bar magnitude into the
heaviest day below it. Call-site swap and old-view deletion follow.
EOF
)"
```

---

## Task 4: Swap the four PopoverRoot call sites

Replace each of the four adjacent `UsageHeatmapView` + `UsageRateView` pairs with a single `UsageActivityView`. Line numbers below are from the spec's snapshot; if `git diff` shows them shifted by a few lines, follow the surrounding identifiers (`combinedHeatmap`, `snapshot.heatmap`, `snap.heatmap`) — they are unique enough to locate without numbers.

**Files:**
- Modify: `Sources/VibeBarApp/Views/PopoverRoot.swift` (four spots)

---

- [ ] **Step 1: Locate the four call-site pairs**

Run: `grep -n "UsageHeatmapView\|UsageRateView" Sources/VibeBarApp/Views/PopoverRoot.swift`
Expected: eight lines — four `UsageHeatmapView(...)` and four `UsageRateView(...)`, each pair adjacent.

- [ ] **Step 2: Replace the `OverviewWaterfall` pair**

Current (around line 450):

```swift
                    UsageHeatmapView(
                        heatmap: combinedHeatmap,
                        density: density,
                        titleOverride: "When you use everything"
                    )
                    UsageRateView(heatmap: combinedHeatmap, density: density)
```

Replace with:

```swift
                    UsageActivityView(
                        heatmap: combinedHeatmap,
                        density: density,
                        titleOverride: "When you use everything"
                    )
```

- [ ] **Step 3: Replace the `ProviderCostStack` pair**

Current (around line 595):

```swift
            UsageHeatmapView(heatmap: snapshot.heatmap, density: density, titleOverride: heatmapTitleOverride)
            UsageRateView(heatmap: snapshot.heatmap, density: density)
```

Replace with:

```swift
            UsageActivityView(heatmap: snapshot.heatmap, density: density, titleOverride: heatmapTitleOverride)
```

- [ ] **Step 4: Replace the `CostDetailPopoverContent` pair**

Current (around line 1107):

```swift
                    UsageHeatmapView(heatmap: snap.heatmap, density: density, titleOverride: heatmapTitleOverride)
                    UsageRateView(heatmap: snap.heatmap, density: density)
```

Replace with:

```swift
                    UsageActivityView(heatmap: snap.heatmap, density: density, titleOverride: heatmapTitleOverride)
```

- [ ] **Step 5: Replace the `ProviderDetailView` pair**

Current (around line 1177):

```swift
                    UsageHeatmapView(heatmap: snapshot.heatmap, density: density)
                    UsageRateView(heatmap: snapshot.heatmap, density: density)
```

Replace with:

```swift
                    UsageActivityView(heatmap: snapshot.heatmap, density: density)
```

- [ ] **Step 6: Confirm no stale references remain**

Run: `grep -n "UsageHeatmapView\|UsageRateView" Sources/VibeBarApp/Views/PopoverRoot.swift`
Expected: zero matches.

- [ ] **Step 7: Build**

Run: `swift build`
Expected: success. Old `UsageHeatmapView.swift` / `UsageRateView.swift` are now dead code (still compiling, no callers).

- [ ] **Step 8: Commit**

```bash
git add Sources/VibeBarApp/Views/PopoverRoot.swift
git commit -m "$(cat <<'EOF'
Swap PopoverRoot call sites to merged UsageActivityView

Four sites — Overview, ProviderCostStack, CostDetailPopoverContent,
ProviderDetailView — used to render UsageHeatmapView and UsageRateView
adjacently. They now render one UsageActivityView each. The two old
views are still compiled but unreferenced; the next commit removes
them.
EOF
)"
```

---

## Task 5: Delete the old views

With every call site swapped, `UsageHeatmapView.swift` and `UsageRateView.swift` are unreferenced. Remove them in one commit.

**Files:**
- Delete: `Sources/VibeBarApp/Views/UsageHeatmapView.swift`
- Delete: `Sources/VibeBarApp/Views/UsageRateView.swift`

---

- [ ] **Step 1: Confirm both files have no remaining references in the source tree**

Run: `grep -rn "UsageHeatmapView\|UsageRateView" Sources Tests`
Expected: matches only inside `Sources/VibeBarApp/Views/UsageHeatmapView.swift` and `Sources/VibeBarApp/Views/UsageRateView.swift` themselves. If there are any matches in other files, stop and fix them first.

- [ ] **Step 2: Delete both files**

Run:
```bash
rm Sources/VibeBarApp/Views/UsageHeatmapView.swift
rm Sources/VibeBarApp/Views/UsageRateView.swift
```

- [ ] **Step 3: Build**

Run: `swift build`
Expected: success.

- [ ] **Step 4: Run tests**

Run: `swift test`
Expected: success, including the 8 `UsageHeatmapActivityTests` cases from Task 1.

- [ ] **Step 5: Commit**

```bash
git add -A Sources/VibeBarApp/Views/
git commit -m "$(cat <<'EOF'
Delete UsageHeatmapView and UsageRateView

Their behavior is now in UsageActivityView; every PopoverRoot caller
already points there. The shared HeatmapGridMetrics, intensityColor,
and HeatmapGridWidthPreferenceKey moved into UsageHeatmapShared.swift
two commits ago, so nothing here is left to migrate.
EOF
)"
```

---

## Task 6: Full verification chain and manual smoke test

No code change. Run the four-step verification chain from `AGENTS.md` § 4 plus the manual checks from the spec.

**Files:** none modified.

---

- [ ] **Step 1: Run `swift build`**

Run: `swift build`
Expected: success, no warnings about `UsageHeatmapView` / `UsageRateView`.

- [ ] **Step 2: Run `swift test`**

Run: `swift test`
Expected: success. Confirm `UsageHeatmapActivityTests` reports 8 tests passed.

- [ ] **Step 3: Build the signed app bundle**

Run: `./Scripts/build_app.sh release`
Expected: completes without errors, produces `.build/Vibe Bar.app`.

- [ ] **Step 4: Inspect the entitlements**

Run: `codesign -d --entitlements - ".build/Vibe Bar.app"`
Expected: output is an empty `<dict/>` plist with no `com.apple.security.app-sandbox` key. If `app-sandbox` appears, stop — `Resources/VibeBar.entitlements` or `Scripts/build_app.sh` regressed and the change must not be pushed.

- [ ] **Step 5: Verify signature**

Run: `codesign --verify --deep --strict ".build/Vibe Bar.app"`
Expected: exits 0 with no output.

- [ ] **Step 6: Manual smoke (per spec § Verification)**

Run: `open ".build/Vibe Bar.app"`

Then walk through:

1. Click the menubar item to open the popover. Overview tab should show one merged "When you use everything" card (no separate "Hourly Burn Rate" card directly below).
2. Confirm the bars and cells line up: pick a column where the bar is tall, and the heatmap cell directly below it for the busiest weekday should be the heaviest colored cell in that column.
3. Resize the popover narrow / default / wide and confirm alignment holds at each width breakpoint.
4. Click into one provider's detail (e.g. Codex or Claude) — the right column of the detail view should also render one merged card.
5. Pick a provider whose data is sparse (some hours zero) — confirm those hour columns show no bar (height 0) and that non-zero but tiny hours still render a ≥2 pt bar.
6. Pick a provider with zero data — confirm the card shows the `"No data yet"` placeholder without leaving an empty bar row above an empty grid.
7. Confirm only one refresh button appears per card, and clicking it triggers a refresh as before.
8. Confirm the peak label reads e.g. `Peak 3am · Fri 3pm` (two hours) or `Peak 3pm · Fri` (collapsed when hours coincide), with no `Fri 15`-style 24-hour leakage.

- [ ] **Step 7: No commit; report verification result back to the user**

After all steps pass, the branch is ready for `git push` and a PR. Do not push automatically — wait for AQ's go-ahead.

---

## Done state

- New file: `Sources/VibeBarCore/Models/UsageHeatmap+Activity.swift`
- New file: `Tests/VibeBarCoreTests/UsageHeatmapActivityTests.swift`
- New file: `Sources/VibeBarApp/Views/UsageHeatmapShared.swift`
- New file: `Sources/VibeBarApp/Views/UsageActivityView.swift`
- Modified: `Sources/VibeBarApp/Views/PopoverRoot.swift` (four call-site swaps)
- Deleted: `Sources/VibeBarApp/Views/UsageHeatmapView.swift`
- Deleted: `Sources/VibeBarApp/Views/UsageRateView.swift`
- Five commits on `feat/merge-usage-charts`, all green through `swift build` / `swift test` / `./Scripts/build_app.sh release` / `codesign -d --entitlements -`.
