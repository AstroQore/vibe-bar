import SwiftUI
import VibeBarCore

/// "Limit reset credits" on a provider page — usage-limit resets the user can
/// spend (Codex, Claude, Grok): how many are left, when each expires, which
/// windows they clear when the provider says, and the latest credits used or
/// received. Rendered when there is a reset to spend or a record to show.
///
/// The Overview draws none of this; the full record is the Workbench Resets
/// page's `ResetCreditsRecordCard` and the reset journal.
struct ResetCreditsRow: View {
    let credits: ResetCredits?
    /// Newest first, from `QuotaService.resetCreditLedger`.
    let ledger: [ResetCreditLedgerEntry]
    let buckets: [QuotaBucket]
    let density: Theme.Density

    static func shows(credits: ResetCredits?, ledger: [ResetCreditLedgerEntry]?) -> Bool {
        ResetCreditLedgerDisplay.shows(credits: credits, ledger: ledger)
    }

    var body: some View {
        let count = credits?.availableCount ?? 0
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                Image(systemName: "clock.arrow.circlepath")
                    .font(.system(size: density.resetCountdownFontSize))
                    .foregroundStyle(.secondary)
                Text(L10n.Quota.ResetCredits.title)
                    .font(.system(size: density.bucketTitleFontSize, weight: .semibold))
                Spacer(minLength: 6)
                Text(AppLocale.number(count))
                    .font(.system(size: density.bucketPercentFontSize, weight: .semibold, design: .rounded).monospacedDigit())
                    .foregroundStyle(count > 0 ? Color.green : Color.secondary)
            }
            ResetCreditsInventory(credits: credits, buckets: buckets, density: density)
            ForEach(ResetCreditLedgerDisplay.visibleEntries(ledger, limit: ResetCreditLedgerDisplay.previewLimit)) { entry in
                ResetCreditLedgerLine(entry: entry, density: density)
            }
        }
    }
}

/// The available credits' detail: the windows they clear and one line per
/// credit with its expiry. Draws nothing when no credit is left.
/// The Overview's view of a SubProvider's reset credits: the title row with
/// the count, then the inventory — cleared windows and each credit's expiry.
/// No record lines; those are the provider page's and the Resets page's.
struct ResetCreditsInventoryRow: View {
    let credits: ResetCredits?
    let buckets: [QuotaBucket]
    let density: Theme.Density

    var body: some View {
        let count = credits?.availableCount ?? 0
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                Image(systemName: "clock.arrow.circlepath")
                    .font(.system(size: density.resetCountdownFontSize))
                    .foregroundStyle(.secondary)
                Text(L10n.Quota.ResetCredits.title)
                    .font(.system(size: density.bucketTitleFontSize, weight: .semibold))
                Spacer(minLength: 6)
                Text(AppLocale.number(count))
                    .font(.system(size: density.bucketPercentFontSize, weight: .semibold, design: .rounded).monospacedDigit())
                    .foregroundStyle(count > 0 ? Color.green : Color.secondary)
            }
            ResetCreditsInventory(credits: credits, buckets: buckets, density: density)
        }
    }
}

struct ResetCreditsInventory: View {
    let credits: ResetCredits?
    let buckets: [QuotaBucket]
    let density: Theme.Density

    var body: some View {
        let count = credits?.availableCount ?? 0
        if count > 0 {
            if let cleared = clearedWindows {
                Text(cleared)
                    .font(.system(size: density.resetCountdownFontSize))
                    .foregroundStyle(.tertiary)
                    .lineLimit(2)
            }
            let dates = credits?.availableExpirations ?? credits?.nextExpiresAt.map { [$0] } ?? []
            ForEach(Array(dates.enumerated()), id: \.offset) { index, expiry in
                HStack(alignment: .firstTextBaseline) {
                    Text(L10n.Quota.ResetCredits.item(number: index + 1))
                    Spacer(minLength: 6)
                    Text(L10n.Quota.ResetCredits.expiresAt(when: expiryText(expiry)))
                        .monospacedDigit()
                }
                .font(.system(size: density.resetCountdownFontSize))
                .foregroundStyle(.secondary)
                .padding(.top, 4)
            }
            if dates.count < count {
                Text(L10n.Quota.ResetCredits.missingExpiries(count: count - dates.count))
                    .font(.system(size: density.resetCountdownFontSize)).foregroundStyle(.tertiary)
            }
        }
    }

    /// "5 Hours · Weekly · Fable · Weekly", in the card's own bucket words.
    private var clearedWindows: String? {
        let ids = credits?.clearedBucketIDs ?? []
        let titles = ids.compactMap { id -> String? in
            guard let bucket = buckets.first(where: { $0.id == id }) else { return nil }
            let label = [bucket.groupTitle, bucket.title].compactMap { $0 }.joined(separator: " · ")
            return QuotaGroupLabelLocalizer.displayComposed(label)
        }
        return titles.isEmpty ? nil : titles.joined(separator: " · ")
    }

    private func expiryText(_ date: Date) -> String {
        AppLocale.dateFormatter(template: "MMMdEEEHHmmz", timeZone: .current).string(from: date)
    }
}

/// One line of a credit record: a credit spent (−1) or received (+1), when,
/// and "≈" when the use was inferred from a falling count rather than read
/// from a receipt.
struct ResetCreditLedgerLine: View {
    let entry: ResetCreditLedgerEntry
    let density: Theme.Density

    var body: some View {
        let used = entry.kind == .used
        let line = HStack(alignment: .firstTextBaseline, spacing: 5) {
            Image(systemName: used ? "ticket" : "plus.circle")
                .foregroundStyle(used ? Color.blue : Color.green)
            Text(used ? L10n.ResetJournal.credit : L10n.ResetJournal.creditGranted)
                .lineLimit(1)
            Text(used ? "−1" : "+1").monospacedDigit()
            Spacer(minLength: 6)
            Text((entry.event.isInferred ? "≈ " : "") + ledgerDate(entry.event.occurredAt))
                .monospacedDigit()
        }
        .font(.system(size: density.resetCountdownFontSize))
        .foregroundStyle(.secondary)
        .padding(.top, 4)
        if entry.event.isInferred {
            line.help(L10n.ResetJournal.creditInferred)
        } else {
            line
        }
    }

    private func ledgerDate(_ date: Date) -> String {
        AppLocale.dateFormatter(template: "MMMdHHmm", timeZone: .current).string(from: date)
    }
}
