import SwiftUI
import VibeBarCore

/// One quota bucket refilling inside the visible horizon: when, how much
/// comes back, and how tight the bucket is right now.
struct UpcomingResetEvent: Identifiable {
    let tool: ToolType
    let accountId: String
    /// Set only when the tool has several accounts, so a single-account
    /// setup keeps its short labels.
    let accountLabel: String?
    let subProviderName: String
    let groupTitle: String?
    let bucketId: String
    let bucketTitle: String
    let remainingPercent: Double
    /// What the reset gives back — the used share of the window.
    let gainPercent: Double
    let resetAt: Date
    /// The personal forecast's remaining % at the moment of this reset, when
    /// one exists — shown in the lane's hover card.
    var forecastRemainingAtResetPercent: Double? = nil

    var id: String { "\(accountId).\(bucketId)" }

    /// "Claude · Fable · Weekly" — canonical quota-axis names, full words.
    var label: String {
        var base: String
        if let groupTitle {
            base = "\(subProviderName) · \(groupTitle) · \(bucketTitle)"
        } else {
            base = "\(subProviderName) · \(bucketTitle)"
        }
        if let accountLabel {
            base += " · \(accountLabel)"
        }
        return base
    }
}

enum UpcomingResets {
    /// Every dedicated-provider bucket whose reset lands within `horizonDays`
    /// and gives anything back, soonest first. Reads only the cached quotas.
    @MainActor
    static func events(
        environment: AppEnvironment,
        now: Date,
        horizonDays: Double = 7
    ) -> [UpcomingResetEvent] {
        let horizon = now.addingTimeInterval(horizonDays * 86_400)
        var out: [UpcomingResetEvent] = []
        let settings = environment.settingsStore.settings
        // Forecasts run on the page's shared 5-minute clock so the memo in
        // QuotaService actually hits — a fresh `now` per minute tick would
        // recompute every bucket's blend for nothing.
        let forecastNow = Date(
            timeIntervalSinceReferenceDate: (now.timeIntervalSinceReferenceDate / 300).rounded(.down) * 300
        )
        for tool in ToolType.dedicatedCardProviders where settings.isCoreProviderVisible(tool) {
            // Every account, not the first one — multi-account providers
            // (Gemini, say) refill per account.
            let accounts = environment.accountStore.accounts(for: tool)
            for account in accounts {
                guard let quota = environment.quotaService.cachedQuota(for: account.id) else { continue }
                let accountLabel = accounts.count > 1 ? account.displayLabel : nil
                for bucket in quota.buckets {
                    guard let resetAt = bucket.resetAt,
                          resetAt > now, resetAt <= horizon,
                          bucket.usedPercent >= 1
                    else { continue }
                    let subProvider = tool.quotaSubProviderName(bucketID: bucket.id)
                    let group = bucket.groupTitle?.trimmingCharacters(in: .whitespacesAndNewlines)
                    let snapshot = environment.costService.snapshot(for: tool)
                    let forecast = environment.quotaService.paceForecast(
                        accountId: account.id,
                        bucket: bucket,
                        activityHeatmap: snapshot?.heatmap,
                        dailyActivity: snapshot?.dailyHistory ?? [],
                        now: forecastNow,
                        allowsPostResetGrace: true
                    )
                    out.append(UpcomingResetEvent(
                        tool: tool,
                        accountId: account.id,
                        accountLabel: accountLabel,
                        subProviderName: subProvider,
                        groupTitle: (group?.isEmpty ?? true) || group?.caseInsensitiveCompare(subProvider) == .orderedSame
                            ? nil : group,
                        bucketId: bucket.id,
                        bucketTitle: bucket.title,
                        remainingPercent: max(0, 100 - bucket.usedPercent),
                        gainPercent: bucket.usedPercent,
                        resetAt: resetAt,
                        forecastRemainingAtResetPercent: forecast.map {
                            max(0, min(100, 100 - $0.projectedUsedPercent))
                        }
                    ))
                }
            }
        }
        return out.sorted { $0.resetAt < $1.resetAt }
    }
}

/// The horizon as a lane: each refill is a slim column standing on a time
/// axis — height says how much comes back, colour says how tight the bucket
/// is right now, the leading hairline is *now*. Deliberately no rings.
struct ResetLaneView: View {
    let events: [UpcomingResetEvent]
    let now: Date
    var horizonDays: Double = 7
    var laneHeight: CGFloat = 64

    @State private var hoveredEventID: String?

    var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            ZStack(alignment: .topLeading) {
                Rectangle()
                    .fill(Color.primary.opacity(0.13))
                    .frame(width: width, height: 1)
                    .offset(y: laneHeight - 14)
                Rectangle()
                    .fill(Color.primary.opacity(0.35))
                    .frame(width: 2, height: laneHeight - 20)
                    .offset(y: 4)
                // Day ticks for multi-day horizons; hour ticks when the
                // lane covers a single day (the sub-daily timeline).
                let ticks: [(fraction: Double, label: String)] = horizonDays <= 1
                    ? [0.25, 0.5, 0.75, 1].map {
                        ($0, L10n.Quota.upcomingAxisHours(hours: Int($0 * horizonDays * 24)))
                    }
                    : (1...Int(horizonDays)).map {
                        (Double($0) / horizonDays, L10n.Quota.upcomingAxisDays(days: $0))
                    }
                ForEach(Array(ticks.enumerated()), id: \.offset) { _, tick in
                    let x = width * CGFloat(tick.fraction)
                    Rectangle()
                        .fill(Color.primary.opacity(0.18))
                        .frame(width: 1, height: 5)
                        .offset(x: x, y: laneHeight - 18)
                    Text(tick.label)
                        .font(.system(size: 7.5, design: .rounded).monospacedDigit())
                        .foregroundStyle(.tertiary)
                        .frame(width: 30)
                        .offset(x: x - 15, y: laneHeight - 11)
                }
                let fanned = fannedOffsets(width: width)
                ForEach(events) { event in
                    marker(event, width: width, fanOffset: fanned[event.id] ?? 0)
                }
                if let hovered = events.first(where: { $0.id == hoveredEventID }) {
                    hoverCard(hovered, width: width, fanOffset: fanned[hovered.id] ?? 0)
                }
            }
        }
        .frame(height: laneHeight)
    }

    /// The hover legend AQ asked for: what the column is, exactly when it
    /// resets, how much is left now, how much comes back, and what the
    /// forecast expects at that moment.
    private func hoverCard(_ event: UpcomingResetEvent, width: CGFloat, fanOffset: CGFloat) -> some View {
        let fraction = min(1, event.resetAt.timeIntervalSince(now) / (horizonDays * 86_400))
        let x = max(4, min(width - 4, width * fraction + fanOffset))
        let cardWidth: CGFloat = 236
        let cardX = max(0, min(width - cardWidth, x - cardWidth / 2))
        return VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 5) {
                Circle()
                    .fill(Theme.providerAccent(for: event.tool))
                    .frame(width: 5, height: 5)
                Text(event.label)
                    .font(.system(size: 9.5, weight: .semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
            Text(L10n.Quota.upcomingResetsAt(
                countdown: ResetCountdownFormatter.string(from: event.resetAt, now: now) ?? "—",
                // Same renderer as every other absolute reset time in the app,
                // so the date reads as a date in whichever language is on.
                absolute: ResetCountdownFormatter.absoluteTime(for: event.resetAt, now: now) ?? "—"
            ))
                .font(.system(size: 9, design: .rounded).monospacedDigit())
                .foregroundStyle(.secondary)
            Text(L10n.Quota.upcomingLeftAndGain(
                remaining: Int(event.remainingPercent.rounded()),
                gain: Int(event.gainPercent.rounded())
            ))
                .font(.system(size: 9, design: .rounded).monospacedDigit())
                .foregroundStyle(Theme.barColor(percent: event.remainingPercent, mode: .remaining))
            if let projected = event.forecastRemainingAtResetPercent {
                Text(L10n.Quota.upcomingForecastAtReset(percent: Int(projected.rounded())))
                    .font(.system(size: 9, design: .rounded).monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .frame(width: cardWidth, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(.thickMaterial)
                .overlay(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .stroke(Color.primary.opacity(0.12), lineWidth: 0.7)
                )
        )
        .offset(x: cardX, y: -2)
        .zIndex(2)
        .allowsHitTesting(false)
        .transition(.opacity)
    }

    /// Buckets that reset together (Claude's overall and model-scoped
    /// weeklies, say) would stack into one indistinguishable column; fan a
    /// cluster out by a column width per member.
    private func fannedOffsets(width: CGFloat) -> [String: CGFloat] {
        var byX: [Int: [String]] = [:]
        for event in events {
            let fraction = min(1, event.resetAt.timeIntervalSince(now) / (horizonDays * 86_400))
            let slot = Int((width * fraction / 9).rounded())
            byX[slot, default: []].append(event.id)
        }
        var offsets: [String: CGFloat] = [:]
        for ids in byX.values where ids.count > 1 {
            let span = CGFloat(ids.count - 1) * 9
            for (index, id) in ids.enumerated() {
                offsets[id] = CGFloat(index) * 9 - span / 2
            }
        }
        return offsets
    }

    private func marker(_ event: UpcomingResetEvent, width: CGFloat, fanOffset: CGFloat) -> some View {
        let fraction = min(1, event.resetAt.timeIntervalSince(now) / (horizonDays * 86_400))
        let x = max(4, min(width - 4, width * fraction + fanOffset))
        let height = 6 + (laneHeight - 30) * event.gainPercent / 100
        return UnevenRoundedRectangle(
            topLeadingRadius: 3.5, bottomLeadingRadius: 1,
            bottomTrailingRadius: 1, topTrailingRadius: 3.5,
            style: .continuous
        )
        .fill(Theme.barColor(percent: event.remainingPercent, mode: .remaining))
        .frame(width: 7, height: height)
        .overlay(
            UnevenRoundedRectangle(
                topLeadingRadius: 3.5, bottomLeadingRadius: 1,
                bottomTrailingRadius: 1, topTrailingRadius: 3.5,
                style: .continuous
            )
            .stroke(Color.primary.opacity(hoveredEventID == event.id ? 0.55 : 0), lineWidth: 1)
        )
        .offset(x: x - 3.5, y: laneHeight - 14 - height)
        .contentShape(Rectangle().inset(by: -4))
        .onHover { inside in
            if inside {
                hoveredEventID = event.id
            } else if hoveredEventID == event.id {
                hoveredEventID = nil
            }
        }
        .help(L10n.Quota.upcomingMarkerHelp(
            label: event.label,
            remaining: Int(event.remainingPercent.rounded()),
            gain: Int(event.gainPercent.rounded()),
            countdown: ResetCountdownFormatter.string(from: event.resetAt, now: now) ?? ""
        ))
    }
}

/// Overview card: the 7-day lane plus the next three refills as rows.
struct UpcomingResetsCard: View {
    let density: Theme.Density

    @EnvironmentObject private var environment: AppEnvironment
    @EnvironmentObject private var quotaService: QuotaService

    var body: some View {
        // One clock for the card, one minute: the lane's countdowns drift
        // slowly, and quota refreshes re-render the card on their own. It is a
        // `PageClock` rather than a raw `TimelineView(.periodic(from: .now,
        // ...))` for two reasons — the phase has to survive a body pass so the
        // date matches what the quota cards ask for, and the Overview stays
        // hosted after the popover closes, where this must not keep firing.
        PageClock(interval: 60) { tickDate in
            content(now: tickDate)
        }
    }

    @ViewBuilder
    private func content(now: Date) -> some View {
        let events = UpcomingResets.events(environment: environment, now: now)
        CardShell(density: density, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(L10n.Quota.upcomingTitle)
                    .font(.system(size: density.bucketTitleFontSize, weight: .semibold))
                Spacer(minLength: 6)
                Text(L10n.Quota.upcomingHorizon)
                    .font(.system(size: density.resetCountdownFontSize))
                    .foregroundStyle(.tertiary)
            }
            if events.isEmpty {
                Text(L10n.Quota.upcomingEmpty)
                    .font(.system(size: density.subtitleFontSize))
                    .foregroundStyle(.tertiary)
                    .padding(.vertical, 12)
                    .frame(maxWidth: .infinity)
            } else {
                ResetLaneView(events: events, now: now)
                VStack(spacing: 0) {
                    ForEach(Array(events.prefix(3))) { event in
                        row(event, now: now)
                    }
                }
            }
        }
    }

    private func row(_ event: UpcomingResetEvent, now: Date) -> some View {
        HStack(spacing: 8) {
            Circle()
                .fill(Theme.providerAccent(for: event.tool))
                .frame(width: 6, height: 6)
            Text(event.label)
                .font(.system(size: density.subtitleFontSize))
                .foregroundStyle(.primary.opacity(0.88))
                .lineLimit(1)
                .minimumScaleFactor(0.75)
            Spacer(minLength: 6)
            Text(L10n.Quota.upcomingGain(gain: Int(event.gainPercent.rounded())))
                .font(.system(size: density.subtitleFontSize, weight: .semibold, design: .rounded).monospacedDigit())
                .foregroundStyle(Theme.barColor(percent: event.remainingPercent, mode: .remaining))
            Text(ResetCountdownFormatter.string(from: event.resetAt, now: now) ?? "—")
                .font(.system(size: density.resetCountdownFontSize, design: .rounded).monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 3)
        .help(event.label)
    }
}
