import Foundation

/// Adapts the real ledger onto the assembler's three-call protocol.
///
/// A shim rather than a conformance on `UsageEventLedger` itself, because the
/// ledger's `trend(_:bucket:)` takes an *optional* bucket (it picks one from
/// the range when none is given) and Swift will not let an optional parameter
/// witness a non-optional requirement. Spelling the bridge out here also keeps
/// the assembler's surface the narrow three calls it actually uses, which is
/// what makes it testable with a plain value type.
public struct EInkLedgerUsageSource: EInkUsageQuerying {
    private let ledger: UsageEventLedger

    public init(ledger: UsageEventLedger) {
        self.ledger = ledger
    }

    public func summary(_ filter: UsageQueryFilter) async throws -> UsageSummaryMetrics {
        try await ledger.summary(filter)
    }

    public func harnessStats(_ filter: UsageQueryFilter) async throws -> [UsageHarnessStat] {
        try await ledger.harnessStats(filter)
    }

    public func trend(_ filter: UsageQueryFilter, bucket: UsageTrendBucket) async throws -> UsageTrendSeries {
        try await ledger.trend(filter, bucket: bucket)
    }
}

/// Stands in when the ledger could not be opened at all.
///
/// It **refuses** rather than answering zero. A quota-only device never asks
/// it anything, so nothing is lost there; a usage slide, on the other hand,
/// would print "TODAY $0 · 0 tokens" from a successful empty answer, and
/// someone reading that across a desk has no way to tell it from a quiet day.
/// Refusing routes it through the same `usageUnavailable` path an opened-but-
/// failing ledger takes, which skips the slide and says why.
public struct EInkEmptyUsageSource: EInkUsageQuerying {
    public struct LedgerUnavailable: Error, Equatable, Sendable {
        public init() {}
    }

    public init() {}

    public func summary(_ filter: UsageQueryFilter) async throws -> UsageSummaryMetrics {
        throw LedgerUnavailable()
    }

    public func harnessStats(_ filter: UsageQueryFilter) async throws -> [UsageHarnessStat] {
        throw LedgerUnavailable()
    }

    public func trend(_ filter: UsageQueryFilter, bucket: UsageTrendBucket) async throws -> UsageTrendSeries {
        throw LedgerUnavailable()
    }
}
