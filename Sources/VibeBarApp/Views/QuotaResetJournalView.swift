import SwiftUI
import VibeBarCore

enum ResetJournalKind: String, CaseIterable, Identifiable {
    case normal, earlyRestarted, earlyUnchanged, credit, unknown
    var id: String { rawValue }
    init(_ sample: SubscriptionWindowSample) {
        self.init(resetKind: sample.resetKind, creditRedeemedAt: sample.resetDetails?.creditRedeemedAt)
    }
    init(resetKind: SubscriptionWindowSample.ResetKind?, creditRedeemedAt: Date?) {
        if creditRedeemedAt != nil { self = .credit; return }
        switch resetKind {
        case .onSchedule: self = .normal
        case .earlyClockRestarted: self = .earlyRestarted
        case .earlyClockUnchanged: self = .earlyUnchanged
        default: self = .unknown
        }
    }
    var title: String {
        switch self {
        case .normal: L10n.ResetJournal.normal
        case .earlyRestarted: L10n.ResetJournal.earlyRestarted
        case .earlyUnchanged: L10n.ResetJournal.earlyUnchanged
        case .credit: L10n.ResetJournal.credit
        case .unknown: L10n.ResetJournal.unknown
        }
    }
    var symbol: String {
        switch self {
        case .normal: "clock"
        case .earlyRestarted: "arrow.clockwise"
        case .earlyUnchanged: "plus.circle"
        case .credit: "ticket"
        case .unknown: "questionmark"
        }
    }
    var color: Color {
        switch self {
        case .normal, .unknown: .secondary
        case .earlyRestarted: .teal
        case .earlyUnchanged: .orange
        case .credit: .blue
        }
    }
    func drawMarker(_ context: inout GraphicsContext, in bounds: CGRect) {
        guard self != .normal else { return }
        let glyph = Text(Image(systemName: symbol))
            .font(.system(size: max(8, bounds.height * 0.8), weight: .medium)).foregroundColor(color)
        context.draw(context.resolve(glyph), at: CGPoint(x: bounds.midX, y: bounds.midY), anchor: .center)
    }

}

/// One shared entry point. A bucket strip scopes it to that bucket; the
/// comparison card opens the same complete retained history for its providers.
struct ResetJournalButton: View {
    var tools: [ToolType]?
    var accountId: String?
    var bucketId: String?
    @State private var presented = false
    var body: some View {
        Button { presented = true } label: {
            Label(L10n.ResetJournal.open, systemImage: "list.bullet.rectangle")
        }
        .buttonStyle(.borderless)
        .popover(isPresented: $presented, arrowEdge: .trailing) {
            QuotaResetJournalView(tools: tools, accountId: accountId, bucketId: bucketId)
                .vibeBarNoInitialFocus()
        }
    }
}

struct QuotaResetJournalView: View {
    var tools: [ToolType]?
    var accountId: String?
    var bucketId: String?
    @EnvironmentObject private var quotaService: QuotaService
    @EnvironmentObject private var environment: AppEnvironment
    @Environment(\.dismiss) private var dismiss
    @State private var selection: ResetJournalKind?
    @State private var visibleLimit = 100

    private var samples: [SubscriptionWindowSample] {
        let featureRecords = quotaService.featureResetHistory
        let featureIDs = Set(featureRecords.map(\.journalID))
        let cycles = quotaService.historyByAccountBucket.values.flatMap { $0 }
            .filter { !featureIDs.contains($0.journalID) }
        return (cycles + featureRecords).filter { sample in
            sample.isCompleted && (tools == nil || tools!.contains(sample.tool))
                && (accountId == nil || accountId == sample.accountId)
                && (bucketId == nil || bucketId == sample.bucketId)
        }.sorted { ($0.completedAt ?? .distantPast) > ($1.completedAt ?? .distantPast) }
    }
    private var unmatchedReceipts: [QuotaResetRedemption] {
        guard bucketId == nil, tools == nil || tools!.contains(.codex) else { return [] }
        let all = samples
        return quotaService.resetRedemptions.filter { receipt in
            (accountId == nil || accountId == receipt.accountId) && !all.contains {
                $0.accountId == receipt.accountId && $0.resetDetails?.creditRedeemedAt == receipt.credit.redeemedAt
            }
        }.sorted { $0.credit.redeemedAt > $1.credit.redeemedAt }
    }

    @EnvironmentObject private var settingsStore: SettingsStore
    @State private var expandedID: String?

    var body: some View {
        let filtered = samples.filter { selection == nil || ResetJournalKind($0) == selection }
        let receipts = selection == nil || selection == .credit ? unmatchedReceipts : []
        let density = Theme.overviewDensity(for: settingsStore.settings.popoverDensity)
        DetailPopoverShell(title: L10n.ResetJournal.title, density: density,
                           detail: AppLocale.number(filtered.count + receipts.count),
                           height: CGFloat(min(640, max(280, 110 + min(filtered.count + receipts.count, 10) * 54 + (expandedID == nil ? 0 : 180))))) {
            HStack {
                Picker(L10n.ResetJournal.title, selection: $selection) {
                    Text(L10n.Common.all).tag(Optional<ResetJournalKind>.none)
                    ForEach(ResetJournalKind.allCases) { kind in
                        Text(kind.title).tag(Optional(kind))
                    }
                }.labelsHidden().controlSize(.small).fixedSize()
                Spacer()
                Image(systemName: "info.circle").foregroundStyle(.tertiary)
                    .help(L10n.ResetJournal.explanation)
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if filtered.isEmpty && receipts.isEmpty {
                        Text(L10n.ResetJournal.empty).font(.callout).foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .center).padding(.vertical, 40)
                    }
                    ForEach(Array(filtered.prefix(visibleLimit)), id: \.journalID) { sample in
                        eventRow(sample)
                        Divider().padding(.leading, 24)
                    }
                    if filtered.count > visibleLimit {
                        Button(L10n.ResetJournal.more) { visibleLimit += 100 }.padding(.vertical, 10)
                    }
                    ForEach(receipts) { receipt in
                        HStack(alignment: .top, spacing: 8) {
                            Image(systemName: "ticket").foregroundStyle(.blue).frame(width: 16)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(L10n.ResetJournal.credit).font(.system(size: 12, weight: .medium))
                                Text(L10n.ResetJournal.creditOnly).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text(shortDate(receipt.credit.redeemedAt)).font(.caption).foregroundStyle(.secondary).monospacedDigit()
                        }.padding(.vertical, 10)
                        Divider()
                    }
                }
            }
        }
    }

    private func eventRow(_ sample: SubscriptionWindowSample) -> some View {
        let kind = ResetJournalKind(sample)
        let expanded = expandedID == sample.journalID
        return VStack(alignment: .leading, spacing: 0) {
            Button { expandedID = expanded ? nil : sample.journalID } label: {
                HStack(alignment: .top, spacing: 8) {
                    Group {
                        if kind == .normal { Color.clear }
                        else { Image(systemName: kind.symbol).foregroundStyle(kind.color) }
                    }.frame(width: 16, height: 16)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(kind.title).font(.system(size: 12, weight: .medium)).foregroundStyle(.primary)
                        Text(lane(sample)).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer(minLength: 12)
                    VStack(alignment: .trailing, spacing: 4) {
                        Text(shortDate(sample.completedAt)).font(.system(size: 10)).foregroundStyle(.secondary)
                        if let details = sample.resetDetails {
                            Text(change(details)).font(.system(size: 11, weight: .medium)).foregroundStyle(.primary)
                        }
                    }.monospacedDigit()
                    Image(systemName: expanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 8, weight: .semibold)).foregroundStyle(.tertiary).frame(width: 8)
                }
                .padding(.vertical, 11).contentShape(Rectangle())
            }.buttonStyle(.plain)
            if expanded {
                VStack(alignment: .leading, spacing: 7) {
                    if let details = sample.resetDetails {
                        field(L10n.ResetJournal.beforeReset, date(details.previousResetAt))
                        field(L10n.ResetJournal.afterReset, date(details.nextResetAt))
                        field(L10n.ResetJournal.observationRange, date(details.observedAfter) + " → " + date(details.observedBefore))
                        if let redeemed = details.creditRedeemedAt {
                            field(L10n.ResetJournal.redeemedAt, date(redeemed))
                            Text(L10n.ResetJournal.creditConfirmed).font(.caption).foregroundStyle(.secondary)
                        } else if sample.refilledEarly {
                            Text(L10n.ResetJournal.sourceUnknown).font(.caption).foregroundStyle(.secondary)
                        }
                        if let plan = ProviderPlanDisplay.displayName(for: sample.tool, rawPlan: details.plan) {
                            Text(plan).font(.caption).foregroundStyle(.tertiary)
                        }
                    } else {
                        Text(L10n.ResetJournal.missingDetails).font(.caption).foregroundStyle(.secondary)
                    }
                }.font(.system(size: 10)).padding(.leading, 24).padding(.bottom, 12)
            }
        }
    }

    private func change(_ details: QuotaResetDetails) -> String {
        if let before = details.previousRemaining, let after = details.nextRemaining {
            return AppLocale.number(before) + " → " + AppLocale.number(after)
        }
        return AppLocale.percent((100 - details.previousUsedPercent) / 100, fractionDigits: 1)
            + " → " + AppLocale.percent((100 - details.nextUsedPercent) / 100, fractionDigits: 1)
    }

    private func shortDate(_ value: Date?) -> String {
        guard let value else { return "—" }
        return AppLocale.dateFormatter(template: "yyMMMdHHmm", timeZone: .current).string(from: value)
    }

    private func field(_ title: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title).foregroundStyle(.secondary)
            Spacer(minLength: 14)
            Text(value).monospacedDigit().multilineTextAlignment(.trailing).textSelection(.enabled)
        }
    }
    private func lane(_ sample: SubscriptionWindowSample) -> String {
        let bucket = quotaService.cachedQuota(for: sample.accountId)?.bucket(id: sample.bucketId)
        let title = bucket?.title ?? ResetHistoryLanes.retiredBucketTitle(
            tool: sample.tool, bucketId: sample.bucketId, registry: quotaService.fieldRegistry)
        return sample.tool.vendorName + " · " + sample.tool.quotaSubProviderName(bucketID: sample.bucketId)
            + " · " + QuotaGroupLabelLocalizer.displayComposed(title)
    }
    private func date(_ value: Date?) -> String {
        guard let value else { return "—" }
        return AppLocale.dateFormatter(template: "yyyyMMMdEEEHHmmssz", timeZone: .current).string(from: value)
    }
}

private extension SubscriptionWindowSample {
    var journalID: String { accountId + ":" + bucketId + ":" + String((completedAt ?? windowEnd).timeIntervalSince1970) }
}
