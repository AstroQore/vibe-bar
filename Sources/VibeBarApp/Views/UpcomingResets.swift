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
                        resetAt: resetAt
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
                ForEach(1...Int(horizonDays), id: \.self) { day in
                    let x = width * CGFloat(day) / horizonDays
                    Rectangle()
                        .fill(Color.primary.opacity(0.18))
                        .frame(width: 1, height: 5)
                        .offset(x: x, y: laneHeight - 18)
                    Text("+\(day)d")
                        .font(.system(size: 7.5, design: .rounded).monospacedDigit())
                        .foregroundStyle(.tertiary)
                        .frame(width: 30)
                        .offset(x: x - 15, y: laneHeight - 11)
                }
                let fanned = fannedOffsets(width: width)
                ForEach(events) { event in
                    marker(event, width: width, fanOffset: fanned[event.id] ?? 0)
                }
            }
        }
        .frame(height: laneHeight)
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
        .offset(x: x - 3.5, y: laneHeight - 14 - height)
        .help("\(event.label) — \(Int(event.remainingPercent.rounded()))% now, +\(Int(event.gainPercent.rounded()))% \(ResetCountdownFormatter.string(from: event.resetAt, now: now) ?? "")")
    }
}

/// Overview card: the 7-day lane plus the next three refills as rows.
struct UpcomingResetsCard: View {
    let density: Theme.Density

    @EnvironmentObject private var environment: AppEnvironment
    @EnvironmentObject private var quotaService: QuotaService

    var body: some View {
        // A leaf timer, one minute: the lane's countdowns drift slowly, and
        // quota refreshes re-render the card on their own.
        TimelineView(.periodic(from: .now, by: 60)) { context in
            content(now: context.date)
        }
    }

    @ViewBuilder
    private func content(now: Date) -> some View {
        let events = UpcomingResets.events(environment: environment, now: now)
        CardShell(density: density, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("Upcoming Resets")
                    .font(.system(size: density.bucketTitleFontSize, weight: .semibold))
                Spacer(minLength: 6)
                Text("next 7 days")
                    .font(.system(size: density.resetCountdownFontSize))
                    .foregroundStyle(.tertiary)
            }
            if events.isEmpty {
                Text("Nothing refills in the next seven days.")
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
            Text("+\(Int(event.gainPercent.rounded()))%")
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
