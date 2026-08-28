import SwiftUI
import VibeBarCore

/// Workbench · Resets & Subscriptions: every quota cycle on this Mac in one
/// place — the refill horizon, each SubProvider's cycle with its fill curve
/// and forecast, a fourteen-day reset calendar, and the run-out ranking.
struct ResetsPage: View {
    let density: Theme.Density

    @EnvironmentObject private var environment: AppEnvironment
    @EnvironmentObject private var settingsStore: SettingsStore
    @EnvironmentObject private var quotaService: QuotaService

    var body: some View {
        // One leaf timer for the whole page: countdown text drifts by the
        // minute; data re-renders arrive with quota refreshes on their own.
        TimelineView(.periodic(from: .now, by: 60)) { context in
            content(now: context.date)
        }
    }

    @ViewBuilder
    private func content(now: Date) -> some View {
        let events = UpcomingResets.events(environment: environment, now: now, horizonDays: 14)
        // Forecasts run on a 5-minute clock: the pace blend over the full
        // observation history is the expensive part, and QuotaService memoizes
        // it on exact inputs — a fresh `now` every 60 s tick would defeat
        // that for every bucket on the page. Countdown strings keep the
        // minute clock.
        let cycles = subProviderCycles(now: Date(
            timeIntervalSinceReferenceDate: (now.timeIntervalSinceReferenceDate / 300).rounded(.down) * 300
        ))
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 14) {
                box {
                    boxHeader("Refill Horizon", detail: "next 7 days · column height = how much comes back")
                    ResetLaneView(
                        events: events.filter { $0.resetAt.timeIntervalSince(now) <= 7 * 86_400 },
                        now: now,
                        laneHeight: 96
                    )
                }
                cycleGrid(cycles, now: now)
                HStack(alignment: .top, spacing: 14) {
                    box {
                        boxHeader("Reset Calendar", detail: "14 days")
                        calendar(events, now: now)
                    }
                    .frame(maxWidth: .infinity)
                    box {
                        boxHeader("Run-out Risk", detail: "ranked by the personal forecast")
                        riskList(cycles, now: now)
                    }
                    .frame(width: 320)
                }
            }
            .padding(16)
        }
    }

    // MARK: - Cycle model

    /// One L2 SubProvider's live cycle: its buckets, the headline (longest
    /// window — the cycle a subscription is priced on), and the forecast.
    private struct SubProviderCycle: Identifiable {
        let tool: ToolType
        let accountId: String
        let accountLabel: String?
        let name: String
        let plan: String?
        let buckets: [QuotaBucket]
        let headline: QuotaBucket
        let forecast: QuotaPaceForecast?
        var id: String { "\(accountId)/\(name)" }
    }

    private func subProviderCycles(now: Date) -> [SubProviderCycle] {
        var out: [SubProviderCycle] = []
        for tool in ToolType.dedicatedCardProviders {
            let accounts = environment.accountStore.accounts(for: tool)
            for account in accounts {
                guard let quota = environment.quotaService.cachedQuota(for: account.id),
                      !quota.buckets.isEmpty
                else { continue }
                let accountLabel = accounts.count > 1 ? account.displayLabel : nil
                var bySub: [String: [QuotaBucket]] = [:]
                var order: [String] = []
                for bucket in quota.buckets {
                    let sub = tool.quotaSubProviderName(bucketID: bucket.id)
                    if bySub[sub] == nil { order.append(sub) }
                    bySub[sub, default: []].append(bucket)
                }
                for sub in order {
                    guard let buckets = bySub[sub],
                          let headline = buckets.max(by: {
                              ($0.rawWindowSeconds ?? 0) < ($1.rawWindowSeconds ?? 0)
                          })
                    else { continue }
                    out.append(SubProviderCycle(
                        tool: tool,
                        accountId: account.id,
                        accountLabel: accountLabel,
                        name: sub,
                        plan: quota.plan,
                        buckets: buckets,
                        headline: headline,
                        forecast: forecast(accountId: account.id, tool: tool, bucket: headline, now: now)
                    ))
                }
            }
        }
        return out
    }

    /// Per-account forecast — `miniQuotaForecast` resolves the tool's first
    /// account, which is wrong the moment a provider has two.
    private func forecast(
        accountId: String,
        tool: ToolType,
        bucket: QuotaBucket,
        now: Date
    ) -> QuotaPaceForecast? {
        let snapshot = environment.costService.snapshot(for: tool)
        return quotaService.paceForecast(
            accountId: accountId,
            bucket: bucket,
            activityHeatmap: snapshot?.heatmap,
            dailyActivity: snapshot?.dailyHistory ?? [],
            now: now,
            allowsPostResetGrace: true
        )
    }

    // MARK: - Cycle cards

    private func cycleGrid(_ cycles: [SubProviderCycle], now: Date) -> some View {
        LazyVGrid(
            columns: [GridItem(.adaptive(minimum: 270), spacing: 12, alignment: .top)],
            alignment: .leading,
            spacing: 12
        ) {
            ForEach(cycles) { cycle in
                cycleCard(cycle, now: now)
            }
        }
    }

    private func cycleCard(_ cycle: SubProviderCycle, now: Date) -> some View {
        let remaining = max(0, 100 - cycle.headline.usedPercent)
        let color = Theme.barColor(percent: remaining, mode: .remaining)
        return box {
            HStack(spacing: 6) {
                Circle()
                    .fill(Theme.providerAccent(for: cycle.tool))
                    .frame(width: 6, height: 6)
                Text(cycle.name.uppercased())
                    .font(.system(size: 10, weight: .bold))
                    .tracking(0.4)
                Spacer(minLength: 6)
                if let accountLabel = cycle.accountLabel {
                    Text(accountLabel)
                        .font(.system(size: 8.5, weight: .medium))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                }
                if let plan = cycle.plan {
                    Text(plan)
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.tertiary)
                }
            }
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("\(Int(remaining.rounded()))%")
                    .font(.system(size: 24, weight: .bold, design: .rounded).monospacedDigit())
                    .foregroundStyle(color)
                Text("\(cycle.headline.title) · resets \(ResetCountdownFormatter.string(from: cycle.headline.resetAt, now: now) ?? "—")")
                    .font(.system(size: 10, design: .rounded).monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.primary.opacity(0.08))
                    Capsule()
                        .fill(color)
                        .frame(width: max(2, proxy.size.width * remaining / 100))
                }
            }
            .frame(height: 5)
            bucketLines(cycle, now: now)
            if let forecast = cycle.forecast {
                Text(miniForecastLine(forecast, now: now))
                    .font(.system(size: 10, weight: .semibold, design: .rounded).monospacedDigit())
                    .foregroundStyle(miniForecastColor(forecast))
            }
            fillCurve(cycle)
        }
    }

    private func bucketLines(_ cycle: SubProviderCycle, now: Date) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(cycle.buckets.filter { $0.id != cycle.headline.id }, id: \.id) { bucket in
                let remaining = max(0, 100 - bucket.usedPercent)
                HStack(spacing: 5) {
                    Text(bucket.groupTitle.map { "\($0) · \(bucket.title)" } ?? bucket.title)
                        .font(.system(size: 9.5))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                    Spacer(minLength: 4)
                    Text("\(Int(remaining.rounded()))%")
                        .font(.system(size: 9.5, weight: .bold, design: .rounded).monospacedDigit())
                        .foregroundStyle(Theme.barColor(percent: remaining, mode: .remaining))
                    Text(ResetCountdownFormatter.string(from: bucket.resetAt, now: now) ?? "—")
                        .font(.system(size: 8.5, design: .rounded).monospacedDigit())
                        .foregroundStyle(.tertiary)
                }
            }
        }
    }

    /// The headline bucket's remaining-percent curve across its current
    /// cycle, from the fill-timeline observations the forecast already keeps.
    @ViewBuilder
    private func fillCurve(_ cycle: SubProviderCycle) -> some View {
        let points = cyclePoints(cycle)
        if points.count >= 2 {
            GeometryReader { proxy in
                let w = proxy.size.width
                let h = proxy.size.height
                Path { path in
                    for (index, point) in points.enumerated() {
                        let x = w * CGFloat(point.fraction)
                        let y = h - h * CGFloat(point.remaining) / 100
                        if index == 0 { path.move(to: CGPoint(x: x, y: y)) }
                        else { path.addLine(to: CGPoint(x: x, y: y)) }
                    }
                }
                .stroke(
                    Theme.providerAccent(for: cycle.tool).opacity(0.75),
                    style: StrokeStyle(lineWidth: 1.5, lineJoin: .round)
                )
            }
            .frame(height: 30)
            .help("Remaining % across the current \(cycle.headline.title) cycle")
        }
    }

    private struct CyclePoint {
        /// Position across the cycle window, 0…1 — samples sit where their
        /// timestamps put them, so a gap (app closed, refreshes off) reads
        /// as a gap instead of compressing the curve.
        let fraction: Double
        let remaining: Double
    }

    private func cyclePoints(_ cycle: SubProviderCycle) -> [CyclePoint] {
        guard let resetAt = cycle.headline.resetAt,
              let window = cycle.headline.rawWindowSeconds, window > 0
        else { return [] }
        let key = SubscriptionHistoryKey(accountId: cycle.accountId, bucketId: cycle.headline.id)
        let cycleStart = resetAt.addingTimeInterval(-Double(window))
        let samples = (quotaService.observationsByAccountBucket[key] ?? [])
            .filter { $0.slotStart >= cycleStart }
            .map { sample in
                CyclePoint(
                    fraction: min(1, max(0, sample.slotStart.timeIntervalSince(cycleStart) / Double(window))),
                    remaining: max(0, 100 - sample.usedPercent)
                )
            }
        guard samples.count > 2 else { return samples }
        // Bounded draw: the chart is 30 pt tall, forty-eight segments is
        // already denser than it can show.
        let stride = max(1, samples.count / 48)
        var thinned = Swift.stride(from: 0, to: samples.count, by: stride).map { samples[$0] }
        if let last = samples.last, thinned.last?.fraction != last.fraction {
            thinned.append(last)
        }
        return thinned
    }

    // MARK: - Calendar

    private func calendar(_ events: [UpcomingResetEvent], now: Date) -> some View {
        let columns = [GridItem(.adaptive(minimum: 96), spacing: 6, alignment: .top)]
        let calendar = Calendar.current
        let todayStart = calendar.startOfDay(for: now)
        return LazyVGrid(columns: columns, alignment: .leading, spacing: 6) {
            ForEach(0..<14, id: \.self) { offset in
                // Calendar arithmetic, not fixed 86 400 s — a DST transition
                // would otherwise shift every later cell off local midnight.
                let dayStart = calendar.date(byAdding: .day, value: offset, to: todayStart) ?? todayStart
                let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart) ?? dayStart.addingTimeInterval(86_400)
                let hits = events.filter { $0.resetAt >= max(dayStart, now) && $0.resetAt < dayEnd }
                VStack(alignment: .leading, spacing: 3) {
                    Text(offset == 0 ? "Today" : dayStart.formatted(.dateTime.weekday(.abbreviated).day()))
                        .font(.system(size: 8.5, weight: .semibold))
                        .foregroundStyle(.tertiary)
                    ForEach(hits) { event in
                        HStack(spacing: 3) {
                            Circle()
                                .fill(Theme.providerAccent(for: event.tool))
                                .frame(width: 4, height: 4)
                            Text("\(event.subProviderName) +\(Int(event.gainPercent.rounded()))%")
                                .font(.system(size: 8, weight: .semibold, design: .rounded).monospacedDigit())
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .minimumScaleFactor(0.7)
                        }
                        .help(event.label)
                    }
                    if hits.isEmpty {
                        Text("—")
                            .font(.system(size: 8))
                            .foregroundStyle(.quaternary)
                    }
                }
                .padding(6)
                .frame(maxWidth: .infinity, minHeight: 52, alignment: .topLeading)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(Color.primary.opacity(hits.isEmpty ? 0.025 : 0.05))
                )
            }
        }
    }

    // MARK: - Risk

    private func riskList(_ cycles: [SubProviderCycle], now: Date) -> some View {
        // Every bucket whose forecast is uneasy, or that is simply low now.
        var rows: [(cycle: SubProviderCycle, bucket: QuotaBucket, forecast: QuotaPaceForecast?)] = []
        for cycle in cycles {
            for bucket in cycle.buckets {
                let bucketForecast = bucket.id == cycle.headline.id
                    ? cycle.forecast
                    : forecast(accountId: cycle.accountId, tool: cycle.tool, bucket: bucket, now: now)
                let remaining = max(0, 100 - bucket.usedPercent)
                let uneasy = bucketForecast.map { $0.verdict == .watch || $0.verdict == .atRisk } ?? false
                if uneasy || remaining <= 15 {
                    rows.append((cycle, bucket, bucketForecast))
                }
            }
        }
        // The forecast's projected run-out ranks first; buckets it is calm
        // about sort by what is left.
        rows.sort { lhs, rhs in
            let lhsOut = lhs.forecast?.runOutAt ?? Date.distantFuture
            let rhsOut = rhs.forecast?.runOutAt ?? Date.distantFuture
            if lhsOut != rhsOut { return lhsOut < rhsOut }
            return (100 - lhs.bucket.usedPercent) < (100 - rhs.bucket.usedPercent)
        }
        return VStack(alignment: .leading, spacing: 0) {
            if rows.isEmpty {
                Text("Every bucket is projected to last its cycle.")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.tertiary)
                    .padding(.vertical, 8)
            }
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                let remaining = max(0, 100 - row.bucket.usedPercent)
                HStack(spacing: 7) {
                    // The badge is the forecast's verdict, not a raw
                    // threshold: an at-risk bucket with 20% left is the one
                    // to worry about, and a low-but-stable one is not "out".
                    Text(riskBadge(remaining: remaining, forecast: row.forecast))
                        .font(.system(size: 8, weight: .heavy, design: .rounded))
                        .foregroundStyle(Color.black.opacity(0.8))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1.5)
                        .background(
                            Capsule().fill(Theme.barColor(percent: remaining, mode: .remaining))
                        )
                    Text("\(row.cycle.name)\(row.cycle.accountLabel.map { " · \($0)" } ?? "") · \(row.bucket.groupTitle.map { "\($0) · " } ?? "")\(row.bucket.title)")
                        .font(.system(size: 10))
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                    Spacer(minLength: 4)
                    Text("\(Int(remaining.rounded()))% · refills \(ResetCountdownFormatter.string(from: row.bucket.resetAt, now: now) ?? "—")")
                        .font(.system(size: 9, design: .rounded).monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 4)
            }
        }
    }

    private func riskBadge(remaining: Double, forecast: QuotaPaceForecast?) -> String {
        // OUT means exhausted, full stop; a calm or still-learning bucket
        // that happens to be low is LOW, and only the forecast may escalate.
        if remaining <= 1 { return "OUT" }
        switch forecast?.verdict {
        case .atRisk: return "RISK"
        case .watch: return "WATCH"
        default: return "LOW"
        }
    }

    // MARK: - Chrome

    /// The shared card surface — same shell as every other Workbench card,
    /// so the porcelain floors apply here too.
    private func box(@ViewBuilder _ content: @escaping () -> some View) -> some View {
        CardShell(density: density, spacing: 8, content: content)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func boxHeader(_ title: String, detail: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
            Spacer(minLength: 6)
            Text(detail)
                .font(.system(size: 9.5))
                .foregroundStyle(.tertiary)
        }
    }
}
