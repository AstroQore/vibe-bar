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

    /// Which month the calendar shows, as an offset from the current one.
    /// Negative pages into recorded history, positive into the forecastable
    /// future.
    @State private var calendarMonthOffset = 0

    var body: some View {
        // One timer for the whole page: countdown text drifts by the minute;
        // data re-renders arrive with quota refreshes on their own. The clock
        // shares the app-wide phase anchor, so the instant this page asks the
        // forecast about is the same one every other surface asks about — a
        // `.now` anchor re-phased on every body pass and defeated the memo.
        // Ungated: the Workbench window is visible whenever it exists.
        StableClock(interval: 60) { tickDate in
            content(now: tickDate)
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
                // Draws its own card, so it is inserted bare rather than
                // wrapped in `box` — a second surface under a card is the one
                // thing `docs/DESIGN.md` forbids outright.
                ResetHistoryCompareCard(density: density)
                cycleGrid(cycles, now: now)
                HStack(alignment: .top, spacing: 14) {
                    box {
                        calendarHeader(now: now)
                        subDailyLane(now: now)
                        monthCalendar(now: now)
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

    /// One quota group's live cycle — the popover's own granularity: a
    /// SubProvider's primary buckets are one card ("Chatgpt Agentic"), and
    /// every model-scoped group (Spark, Reserve, Fable…) is its own card,
    /// with the headline being that group's longest window.
    private struct SubProviderCycle: Identifiable {
        let tool: ToolType
        let accountId: String
        let accountLabel: String?
        /// The SubProvider ("Claude"), always shown.
        let subProviderName: String
        /// The quota group inside it ("Fable"), nil for the primary buckets.
        let groupTitle: String?
        let plan: String?
        let buckets: [QuotaBucket]
        let headline: QuotaBucket
        let forecast: QuotaPaceForecast?
        var id: String { "\(accountId)/\(subProviderName)/\(groupTitle ?? "")" }
        var name: String { groupTitle.map { "\(subProviderName) · \($0)" } ?? subProviderName }
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
                var byGroup: [String: [QuotaBucket]] = [:]
                var meta: [String: (sub: String, group: String?)] = [:]
                var order: [String] = []
                for bucket in quota.buckets {
                    let sub = tool.quotaSubProviderName(bucketID: bucket.id)
                    let trimmed = bucket.groupTitle?.trimmingCharacters(in: .whitespacesAndNewlines)
                    // A group titled after its own SubProvider is the primary
                    // lane (Grok Bot), not a model group.
                    let group = (trimmed?.isEmpty ?? true)
                        || trimmed?.caseInsensitiveCompare(sub) == .orderedSame
                        ? nil : trimmed
                    let key = "\(sub)/\(group ?? "")"
                    if byGroup[key] == nil {
                        order.append(key)
                        meta[key] = (sub, group)
                    }
                    byGroup[key, default: []].append(bucket)
                }
                for key in order {
                    guard let buckets = byGroup[key], let info = meta[key],
                          let headline = buckets.max(by: {
                              ($0.rawWindowSeconds ?? 0) < ($1.rawWindowSeconds ?? 0)
                          })
                    else { continue }
                    out.append(SubProviderCycle(
                        tool: tool,
                        accountId: account.id,
                        accountLabel: accountLabel,
                        subProviderName: info.sub,
                        groupTitle: info.group,
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
                    Text(bucket.title)
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

    /// One thing happening on one day: a future reset (from the cached
    /// quotas) or a recorded one (from the subscription history), with how
    /// much it gives/gave back.
    private struct CalendarEntry: Identifiable {
        let id: String
        let tool: ToolType
        let label: String
        let shortLabel: String
        let gainPercent: Double
        let at: Date
        let isPast: Bool
    }

    // Built per language rather than once per process: a formatter
    // parked in a `static let` keeps the language it was created in.
    private static var monthTitleFormatter: DateFormatter {
        AppLocale.dateFormatter(template: "MMMMyyyy")
    }

    // Built per language rather than once per process: a formatter
    // parked in a `static let` keeps the language it was created in.
    private static var entryTimeFormatter: DateFormatter {
        AppLocale.dateFormatter(template: "MMMdHHmm")
    }

    private func displayedMonthStart(now: Date) -> Date {
        let calendar = Calendar.current
        let thisMonth = calendar.dateInterval(of: .month, for: now)?.start ?? now
        return calendar.date(byAdding: .month, value: calendarMonthOffset, to: thisMonth) ?? thisMonth
    }

    /// Quotas that cycle inside a day (the five-hour lanes) would reset
    /// several times per calendar cell; they get their own next-24-hours
    /// timeline instead, with the same hover cards as the horizon.
    @ViewBuilder
    private func subDailyLane(now: Date) -> some View {
        let events = UpcomingResets.events(environment: environment, now: now, horizonDays: 1)
            .filter { event in
                guard let bucket = environment.quotaService.cachedQuota(for: event.accountId)?
                    .bucket(id: event.bucketId) else { return false }
                return (bucket.rawWindowSeconds ?? 86_400) < 86_400
            }
        if !events.isEmpty {
            VStack(alignment: .leading, spacing: 2) {
                Text("NEXT 24 HOURS · SUB-DAILY QUOTAS")
                    .font(.system(size: 8.5, weight: .semibold, design: .rounded))
                    .foregroundStyle(.tertiary)
                    .tracking(1.2)
                ResetLaneView(events: events, now: now, horizonDays: 1, laneHeight: 52)
            }
            .padding(.bottom, 2)
        }
    }

    private func calendarHeader(now: Date) -> some View {
        let monthStart = displayedMonthStart(now: now)
        return HStack(spacing: 8) {
            Text("Reset Calendar")
                .font(.system(size: 12, weight: .semibold))
            Spacer(minLength: 6)
            Button {
                calendarMonthOffset -= 1
            } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 9, weight: .semibold))
                    .frame(width: 20, height: 20)
            }
            .buttonStyle(.vibeBar)
            .help("Previous month")
            Text(Self.monthTitleFormatter.string(from: monthStart))
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .frame(minWidth: 110)
            Button {
                calendarMonthOffset += 1
            } label: {
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .frame(width: 20, height: 20)
            }
            .buttonStyle(.vibeBar)
            .help("Next month")
            if calendarMonthOffset != 0 {
                Button("Today") {
                    calendarMonthOffset = 0
                }
                .font(.system(size: 10, weight: .semibold))
                .buttonStyle(.vibeBar)
            }
        }
    }

    /// Everything that lands in the displayed month: recorded cycle ends from
    /// the subscription history (the past pages) and scheduled resets from
    /// the cached quotas (the future ones — as far ahead as the providers
    /// declare their next reset).
    private func calendarEntries(monthStart: Date, monthEnd: Date, now: Date) -> [CalendarEntry] {
        var out: [CalendarEntry] = []
        // Past: completed cycles. Bucket titles come from the account's
        // current quota when it still carries the bucket; a lane that no
        // longer exists keeps just its SubProvider name rather than leaking
        // a raw bucket id into copy.
        for (key, samples) in quotaService.historyByAccountBucket {
            let quota = environment.quotaService.cachedQuota(for: key.accountId)
            for sample in samples {
                let at = sample.completedAt ?? sample.windowEnd
                guard at >= monthStart, at < monthEnd, at <= now,
                      (sample.rawWindowSeconds ?? 86_400) >= 86_400
                else { continue }
                let sub = sample.tool.quotaSubProviderName(bucketID: sample.bucketId)
                let title = quota?.bucket(id: sample.bucketId)?.title
                let name = title.map { "\(sub) · \($0)" } ?? sub
                out.append(CalendarEntry(
                    id: "past.\(key.accountId).\(sample.bucketId).\(at.timeIntervalSinceReferenceDate)",
                    tool: sample.tool,
                    label: "\(name) — reset \(Self.entryTimeFormatter.string(from: at)) at \(Int(sample.lastUsedPercent.rounded()))% used",
                    shortLabel: sub,
                    gainPercent: sample.lastUsedPercent,
                    at: at,
                    isPast: true
                ))
            }
        }
        // Future: scheduled resets from the live quotas. Sub-daily windows
        // (the five-hour lanes) reset several times per cell — they live on
        // the 24-hour timeline above the grid, not in day cells.
        for tool in ToolType.dedicatedCardProviders {
            for account in environment.accountStore.accounts(for: tool) {
                guard let quota = environment.quotaService.cachedQuota(for: account.id) else { continue }
                for bucket in quota.buckets {
                    guard let resetAt = bucket.resetAt,
                          resetAt >= max(monthStart, now), resetAt < monthEnd,
                          (bucket.rawWindowSeconds ?? 86_400) >= 86_400
                    else { continue }
                    let sub = tool.quotaSubProviderName(bucketID: bucket.id)
                    out.append(CalendarEntry(
                        id: "next.\(account.id).\(bucket.id)",
                        tool: tool,
                        label: "\(sub) · \(bucket.title) — resets \(Self.entryTimeFormatter.string(from: resetAt)), +\(Int(bucket.usedPercent.rounded()))% back",
                        shortLabel: sub,
                        gainPercent: bucket.usedPercent,
                        at: resetAt,
                        isPast: false
                    ))
                }
            }
        }
        return out.sorted { $0.at < $1.at }
    }

    private func monthCalendar(now: Date) -> some View {
        let calendar = Calendar.current
        let monthStart = displayedMonthStart(now: now)
        let monthEnd = calendar.date(byAdding: .month, value: 1, to: monthStart) ?? monthStart
        let entries = calendarEntries(monthStart: monthStart, monthEnd: monthEnd, now: now)
        var byDay: [Date: [CalendarEntry]] = [:]
        for entry in entries {
            byDay[calendar.startOfDay(for: entry.at), default: []].append(entry)
        }
        let today = calendar.startOfDay(for: now)
        // Natural weeks: pad to the calendar's own first weekday.
        let firstWeekdayOffset = (calendar.component(.weekday, from: monthStart)
            - calendar.firstWeekday + 7) % 7
        let dayCount = calendar.range(of: .day, in: .month, for: monthStart)?.count ?? 30
        let weekdaySymbols = orderedWeekdaySymbols(calendar)
        let columns = Array(repeating: GridItem(.flexible(), spacing: 4, alignment: .top), count: 7)
        return VStack(alignment: .leading, spacing: 4) {
            LazyVGrid(columns: columns, spacing: 4) {
                ForEach(weekdaySymbols, id: \.self) { symbol in
                    Text(symbol.uppercased())
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.tertiary)
                        .frame(maxWidth: .infinity)
                }
                ForEach(0..<firstWeekdayOffset, id: \.self) { blank in
                    Color.clear
                        .frame(height: 8)
                        .id("blank-\(blank)")
                }
                ForEach(1...dayCount, id: \.self) { day in
                    let dayStart = calendar.date(byAdding: .day, value: day - 1, to: monthStart) ?? monthStart
                    dayCell(
                        day: day,
                        dayStart: dayStart,
                        isToday: dayStart == today,
                        isPast: dayStart < today,
                        entries: byDay[dayStart] ?? []
                    )
                }
            }
        }
    }

    private func orderedWeekdaySymbols(_ calendar: Calendar) -> [String] {
        let symbols = calendar.veryShortStandaloneWeekdaySymbols
        let first = calendar.firstWeekday - 1
        return Array(symbols[first...] + symbols[..<first])
    }

    private func dayCell(
        day: Int,
        dayStart: Date,
        isToday: Bool,
        isPast: Bool,
        entries: [CalendarEntry]
    ) -> some View {
        VStack(alignment: .leading, spacing: 2.5) {
            Text("\(day)")
                .font(.system(size: 10.5, weight: isToday ? .bold : .semibold, design: .rounded).monospacedDigit())
                .foregroundStyle(isToday ? Color.accentColor : (isPast ? Color.secondary : Color.primary))
            ForEach(entries.prefix(3)) { entry in
                HStack(spacing: 3) {
                    Circle()
                        .fill(Theme.providerAccent(for: entry.tool))
                        .frame(width: 4.5, height: 4.5)
                    Text("\(entry.shortLabel) +\(Int(entry.gainPercent.rounded()))%")
                        .font(.system(size: 9, weight: .semibold, design: .rounded).monospacedDigit())
                        .foregroundStyle(entry.isPast ? .tertiary : .secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                }
                .help(entry.label)
            }
            if entries.count > 3 {
                Text("+\(entries.count - 3) more")
                    .font(.system(size: 8.5, weight: .medium))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(5)
        .frame(maxWidth: .infinity, minHeight: 64, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(
                    isToday
                        ? Color.accentColor.opacity(0.10)
                        : Color.primary.opacity(entries.isEmpty ? 0.025 : 0.05)
                )
        )
        .overlay(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .stroke(isToday ? Color.accentColor.opacity(0.35) : Color.clear, lineWidth: 0.8)
        )
        .opacity(isPast ? 0.75 : 1)
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
