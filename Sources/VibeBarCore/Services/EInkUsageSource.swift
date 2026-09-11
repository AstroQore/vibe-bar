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

/// Stands in when the ledger could not be opened.
///
/// A broken SQLite file costs the usage half of a slide, not the app: the
/// quota rows still draw, and a panel with zeros on its usage line is a
/// readable answer where a thrown error would be a blank screen.
public struct EInkEmptyUsageSource: EInkUsageQuerying {
    public init() {}

    public func summary(_ filter: UsageQueryFilter) async throws -> UsageSummaryMetrics {
        UsageSummaryMetrics.empty
    }

    public func harnessStats(_ filter: UsageQueryFilter) async throws -> [UsageHarnessStat] { [] }

    public func trend(_ filter: UsageQueryFilter, bucket: UsageTrendBucket) async throws -> UsageTrendSeries {
        UsageTrendSeries(bucket: bucket, points: [])
    }
}
