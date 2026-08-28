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
    @Environment(\.colorScheme) private var colorScheme

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
        let cycles = subProviderCycles(now: now)
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
        let name: String
        let plan: String?
        let buckets: [QuotaBucket]
        let headline: QuotaBucket
        let forecast: QuotaPaceForecast?
        var id: String { "\(tool.rawValue)/\(name)" }
    }

    private func subProviderCycles(now: Date) -> [SubProviderCycle] {
        var out: [SubProviderCycle] = []
        for tool in ToolType.dedicatedCardProviders {
            guard let quota = environment.quota(for: tool), !quota.buckets.isEmpty else { continue }
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
                    name: sub,
                    plan: quota.plan,
                    buckets: buckets,
                    headline: headline,
                    forecast: miniQuotaForecast(
                        tool: tool,
                        bucket: headline,
                        environment: environment,
                        quotaService: quotaService,
                        now: now
                    )
                ))
            }
        }
        return out
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
                    for (index, value) in points.enumerated() {
                        let x = w * CGFloat(index) / CGFloat(points.count - 1)
                        let y = h - h * CGFloat(value) / 100
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

    private func cyclePoints(_ cycle: SubProviderCycle) -> [Double] {
        guard let accountId = environment.account(for: cycle.tool)?.id,
              let resetAt = cycle.headline.resetAt,
              let window = cycle.headline.rawWindowSeconds
        else { return [] }
        let key = SubscriptionHistoryKey(accountId: accountId, bucketId: cycle.headline.id)
        let cycleStart = resetAt.addingTimeInterval(-Double(window))
        let samples = (quotaService.observationsByAccountBucket[key] ?? [])
            .filter { $0.slotStart >= cycleStart }
            .map { max(0, 100 - $0.usedPercent) }
        guard samples.count > 2 else { return samples }
        // Bounded draw: the chart is 30 pt tall, forty-eight segments is
        // already denser than it can show.
        let stride = max(1, samples.count / 48)
        var thinned = Swift.stride(from: 0, to: samples.count, by: stride).map { samples[$0] }
        if let last = samples.last, thinned.last != last { thinned.append(last) }
        return thinned
    }

    // MARK: - Calendar

    private func calendar(_ events: [UpcomingResetEvent], now: Date) -> some View {
        let columns = [GridItem(.adaptive(minimum: 96), spacing: 6, alignment: .top)]
        let calendar = Calendar.current
        return LazyVGrid(columns: columns, alignment: .leading, spacing: 6) {
            ForEach(0..<14, id: \.self) { offset in
                let dayStart = calendar.startOfDay(for: now).addingTimeInterval(Double(offset) * 86_400)
                let dayEnd = dayStart.addingTimeInterval(86_400)
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
                let forecast = bucket.id == cycle.headline.id
                    ? cycle.forecast
                    : miniQuotaForecast(
                        tool: cycle.tool, bucket: bucket,
                        environment: environment, quotaService: quotaService, now: now
                    )
                let remaining = max(0, 100 - bucket.usedPercent)
                let uneasy = forecast.map { $0.verdict == .watch || $0.verdict == .atRisk } ?? false
                if uneasy || remaining <= 15 {
                    rows.append((cycle, bucket, forecast))
                }
            }
        }
        rows.sort {
            (100 - $0.bucket.usedPercent) < (100 - $1.bucket.usedPercent)
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
                    Text(remaining <= 5 ? "OUT" : "WATCH")
                        .font(.system(size: 8, weight: .heavy, design: .rounded))
                        .foregroundStyle(Color.black.opacity(0.8))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1.5)
                        .background(
                            Capsule().fill(Theme.barColor(percent: remaining, mode: .remaining))
                        )
                    Text("\(row.cycle.name) · \(row.bucket.groupTitle.map { "\($0) · " } ?? "")\(row.bucket.title)")
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

    // MARK: - Chrome

    private func box(@ViewBuilder _ content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            content()
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(WorkbenchPorcelain.overlayFill(for: colorScheme))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(WorkbenchPorcelain.hairline(for: colorScheme), lineWidth: 1)
        )
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
