import Foundation

/// Where an account's reset-credit record is listed and how much of it.
///
/// The Overview shows no credits at all: a credit belongs to one SubProvider,
/// so its inventory lives on that provider's page and its record on the
/// Workbench Resets page and in the reset journal. The ledger passed in is
/// already newest first (`ResetCreditLedgerEntry.ledger`), so nothing here
/// sorts — every function is a slice or a count.
public enum ResetCreditLedgerDisplay {
    /// Provider-page quota card: the latest few lines under the inventory.
    public static let previewLimit = 4
    /// Workbench record: lines listed before the rest fold behind
    /// "Show earlier records".
    public static let collapsedLimit = 30

    /// Whether a surface has anything to draw: a credit to spend or a line
    /// of record.
    public static func shows(credits: ResetCredits?, ledger: [ResetCreditLedgerEntry]?) -> Bool {
        (credits?.hasAvailable ?? false) || !(ledger ?? []).isEmpty
    }

    /// The Workbench record's limit: everything once expanded, otherwise
    /// `collapsedLimit`.
    public static func recordLimit(expanded: Bool) -> Int? {
        expanded ? nil : collapsedLimit
    }

    /// The lines to list, newest first. A nil `limit` lists everything.
    public static func visibleEntries(
        _ ledger: [ResetCreditLedgerEntry],
        limit: Int?
    ) -> ArraySlice<ResetCreditLedgerEntry> {
        guard let limit else { return ledger[...] }
        return ledger.prefix(max(0, limit))
    }

    /// Whether the record is long enough to fold at all — the toggle is
    /// drawn only then, in both states.
    public static func isCollapsible(_ ledger: [ResetCreditLedgerEntry]) -> Bool {
        ledger.count > collapsedLimit
    }
}

/// The counts heading an account's credit record, built once per store
/// change alongside the ledger so no view counts while rendering.
public struct ResetCreditLedgerSummary: Hashable, Sendable {
    public var used: Int
    public var granted: Int
    /// Of `used`, the ones inferred from a falling count rather than read
    /// from a receipt.
    public var inferredUsed: Int

    public init(used: Int = 0, granted: Int = 0, inferredUsed: Int = 0) {
        self.used = used
        self.granted = granted
        self.inferredUsed = inferredUsed
    }

    public init(_ ledger: [ResetCreditLedgerEntry]) {
        self.init()
        for entry in ledger {
            switch entry.kind {
            case .used:
                used += 1
                if entry.event.isInferred { inferredUsed += 1 }
            case .granted:
                granted += 1
            }
        }
    }

    public static func summaries(
        _ ledger: [String: [ResetCreditLedgerEntry]]
    ) -> [String: ResetCreditLedgerSummary] {
        ledger.mapValues(ResetCreditLedgerSummary.init)
    }
}

// MARK: - Reset journal

/// A credit line the reset journal lists on its own: a credit received, or a
/// credit spent that no recorded refill was matched to. A spent credit that
/// *was* matched is already the refill's own "Reset credit used" row.
public struct ResetJournalCreditEntry: Hashable, Sendable, Identifiable {
    public var accountId: String
    public var tool: ToolType
    public var entry: ResetCreditLedgerEntry
    public var id: String { accountId + ":" + entry.id }

    public init(accountId: String, tool: ToolType, entry: ResetCreditLedgerEntry) {
        self.accountId = accountId
        self.tool = tool
        self.entry = entry
    }
}

/// One row of the reset journal's single timeline.
public enum ResetJournalItem: Hashable, Sendable, Identifiable {
    case cycle(SubscriptionWindowSample)
    case credit(ResetJournalCreditEntry)

    /// When it happened: a refill's completion, a credit's own timestamp.
    public var date: Date {
        switch self {
        case let .cycle(sample): sample.completedAt ?? .distantPast
        case let .credit(credit): credit.entry.event.occurredAt
        }
    }

    public var id: String {
        switch self {
        case let .cycle(sample): "cycle:" + sample.journalID
        case let .credit(credit): "credit:" + credit.id
        }
    }
}

public extension SubscriptionWindowSample {
    /// Stable identity of a closed cycle in the reset journal.
    var journalID: String {
        accountId + ":" + bucketId + ":" + String((completedAt ?? windowEnd).timeIntervalSince1970)
    }
}

/// Builds the reset journal: recorded refills and credit lines in one
/// newest-first timeline, so a credit received sits between the refills it
/// happened between instead of trailing the list.
public enum ResetJournalTimeline {
    public static func items(
        cycles: [SubscriptionWindowSample],
        featureResets: [SubscriptionWindowSample],
        redemptions: [QuotaResetRedemption],
        grants: [QuotaResetRedemption],
        tools: [ToolType]? = nil,
        accountId: String? = nil,
        bucketId: String? = nil
    ) -> [ResetJournalItem] {
        let featureIDs = Set(featureResets.map(\.journalID))
        let samples = (cycles.filter { !featureIDs.contains($0.journalID) } + featureResets)
            .filter { sample in
                sample.isCompleted
                    && (tools == nil || tools!.contains(sample.tool))
                    && (accountId == nil || accountId == sample.accountId)
                    && (bucketId == nil || bucketId == sample.bucketId)
            }
            .sorted { ($0.completedAt ?? .distantPast) > ($1.completedAt ?? .distantPast) }
        let credits = creditEntries(samples: samples, redemptions: redemptions, grants: grants,
                                    tools: tools, accountId: accountId, bucketId: bucketId)
        // Both inputs are newest first; one linear merge keeps them so.
        var out: [ResetJournalItem] = []
        out.reserveCapacity(samples.count + credits.count)
        var s = 0
        var c = 0
        while s < samples.count || c < credits.count {
            let takeCycle: Bool
            if s == samples.count { takeCycle = false }
            else if c == credits.count { takeCycle = true }
            else {
                takeCycle = (samples[s].completedAt ?? .distantPast) >= credits[c].entry.event.occurredAt
            }
            if takeCycle { out.append(.cycle(samples[s])); s += 1 }
            else { out.append(.credit(credits[c])); c += 1 }
        }
        return out
    }

    /// Credit lines for the journal, newest first. A bucket-scoped journal
    /// (one quota strip) lists none: a credit belongs to the account, and a
    /// spent one already shows on the refill it paid for.
    static func creditEntries(
        samples: [SubscriptionWindowSample],
        redemptions: [QuotaResetRedemption],
        grants: [QuotaResetRedemption],
        tools: [ToolType]?,
        accountId: String?,
        bucketId: String?
    ) -> [ResetJournalCreditEntry] {
        guard bucketId == nil else { return [] }
        func inScope(_ record: QuotaResetRedemption) -> Bool {
            (accountId == nil || accountId == record.accountId)
                && (tools == nil || tools!.contains(record.resolvedTool))
        }
        let matched = Set(samples.compactMap { sample in
            sample.creditRedemptionDate.map { matchKey(accountId: sample.accountId, date: $0) }
        })
        var out: [ResetJournalCreditEntry] = []
        for record in redemptions where inScope(record)
            && !matched.contains(matchKey(accountId: record.accountId, date: record.credit.occurredAt)) {
            out.append(.init(accountId: record.accountId, tool: record.resolvedTool,
                             entry: .init(kind: .used, event: record.credit)))
        }
        for record in grants where inScope(record) {
            out.append(.init(accountId: record.accountId, tool: record.resolvedTool,
                             entry: .init(kind: .granted, event: record.credit)))
        }
        return out.sorted { $0.entry.event.occurredAt > $1.entry.event.occurredAt }
    }

    private static func matchKey(accountId: String, date: Date) -> String {
        accountId + "@" + String(date.timeIntervalSince1970)
    }
}
