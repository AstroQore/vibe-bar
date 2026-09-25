import SwiftUI
import VibeBarCore

/// Workbench · Resets: the limit reset credits record. One column per
/// account that has a credit to spend or a line of record — the credits
/// available now with their expiries, how many the record holds as used and
/// received, and every line newest first. A long record folds after
/// `ResetCreditLedgerDisplay.collapsedLimit` lines.
///
/// Nothing here sorts or counts: the ledger arrives newest first and the
/// counts come precomputed from `QuotaService`, both per store change.
struct ResetCreditsRecordCard: View {
    let density: Theme.Density

    @EnvironmentObject private var environment: AppEnvironment
    @EnvironmentObject private var quotaService: QuotaService
    /// Accounts whose record is unfolded. View state only, never a setting.
    @State private var expandedAccountIDs: Set<String> = []

    private struct Record: Identifiable {
        let tool: ToolType
        let accountId: String
        let accountLabel: String?
        let credits: ResetCredits?
        let buckets: [QuotaBucket]
        let ledger: [ResetCreditLedgerEntry]
        let summary: ResetCreditLedgerSummary
        var id: String { accountId }
    }

    /// A lookup per account, no derivation: the providers that can hold
    /// credits are a handful of accounts.
    private var records: [Record] {
        var out: [Record] = []
        // The ledger is keyed by account; one column per account id.
        var seen: Set<String> = []
        for tool in ToolType.dedicatedCardProviders {
            let accounts = environment.accountStore.accounts(for: tool)
            for account in accounts where seen.insert(account.id).inserted {
                let quota = quotaService.cachedQuota(for: account.id)
                let ledger = quotaService.resetCreditLedger[account.id] ?? []
                guard ResetCreditLedgerDisplay.shows(credits: quota?.resetCredits, ledger: ledger) else { continue }
                out.append(Record(
                    tool: tool,
                    accountId: account.id,
                    accountLabel: accounts.count > 1 ? account.displayLabel : nil,
                    credits: quota?.resetCredits,
                    buckets: quota?.buckets ?? [],
                    ledger: ledger,
                    summary: quotaService.resetCreditSummary[account.id] ?? ResetCreditLedgerSummary()
                ))
            }
        }
        // A record outlives its login: after a sign-out or an account switch
        // the identity leaves the store, but its history is still loaded.
        // The redemption and grant records name the tool, so the column
        // keeps its brand.
        for (accountId, ledger) in quotaService.resetCreditLedger where !ledger.isEmpty && seen.insert(accountId).inserted {
            let record = quotaService.resetRedemptions.first { $0.accountId == accountId }
                ?? quotaService.resetCreditGrants.first { $0.accountId == accountId }
            out.append(Record(
                tool: record?.resolvedTool ?? .codex,
                accountId: accountId,
                accountLabel: nil,
                credits: nil,
                buckets: [],
                ledger: ledger,
                summary: quotaService.resetCreditSummary[accountId] ?? ResetCreditLedgerSummary()
            ))
        }
        return out
    }

    var body: some View {
        let records = records
        if !records.isEmpty {
            CardShell(density: density, spacing: 8) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(L10n.Quota.ResetCredits.title)
                        .font(.system(size: 12, weight: .semibold))
                    Spacer(minLength: 6)
                    Text(L10n.Workbench.Resets.Credits.detail)
                        .font(.system(size: 9.5))
                        .foregroundStyle(.tertiary)
                }
                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 270), spacing: 12, alignment: .top)],
                    alignment: .leading,
                    spacing: 12
                ) {
                    ForEach(records) { record in
                        column(record)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func column(_ record: Record) -> some View {
        let count = record.credits?.availableCount ?? 0
        let expanded = expandedAccountIDs.contains(record.accountId)
        return VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Circle()
                    .fill(Theme.providerAccent(for: record.tool))
                    .frame(width: 6, height: 6)
                Text(record.tool.quotaSubProviderName().uppercased())
                    .font(.system(size: 10, weight: .bold))
                    .tracking(0.4)
                Spacer(minLength: 6)
                if let accountLabel = record.accountLabel {
                    Text(accountLabel)
                        .font(.system(size: 8.5, weight: .medium))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                }
            }
            .padding(.bottom, 2)
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                Image(systemName: "clock.arrow.circlepath")
                    .font(.system(size: density.resetCountdownFontSize))
                    .foregroundStyle(.secondary)
                Text(L10n.Quota.ResetCredits.available(count: count))
                    .font(.system(size: density.bucketTitleFontSize, weight: .semibold))
                    .foregroundStyle(count > 0 ? Color.primary : Color.secondary)
            }
            ResetCreditsInventory(credits: record.credits, buckets: record.buckets, density: density)
            Text(L10n.Workbench.Resets.Credits.summary(used: record.summary.used, received: record.summary.granted))
                .font(.system(size: density.resetCountdownFontSize))
                .foregroundStyle(.tertiary)
                .padding(.top, 6)
            if record.ledger.isEmpty {
                Text(L10n.Workbench.Resets.Credits.empty)
                    .font(.system(size: density.resetCountdownFontSize))
                    .foregroundStyle(.tertiary)
                    .padding(.top, 4)
            }
            ForEach(ResetCreditLedgerDisplay.visibleEntries(
                record.ledger,
                limit: ResetCreditLedgerDisplay.recordLimit(expanded: expanded)
            )) { entry in
                ResetCreditLedgerLine(entry: entry, density: density)
            }
            if ResetCreditLedgerDisplay.isCollapsible(record.ledger) {
                Button(expanded ? L10n.Workbench.Sessions.Message.showLess : L10n.ResetJournal.more) {
                    if expanded {
                        expandedAccountIDs.remove(record.accountId)
                    } else {
                        expandedAccountIDs.insert(record.accountId)
                    }
                }
                .buttonStyle(.borderless)
                .font(.caption)
                .padding(.top, 4)
            }
        }
    }
}
