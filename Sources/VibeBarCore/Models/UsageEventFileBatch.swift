import Foundation

/// One scanned event plus the price the cost pipeline put on it.
///
/// `costMicros` is `nil` when the event could not be priced at all — an
/// unknown model, a provider with no rate table, or a `totals`-only record.
/// A `nil` is deliberately *not* collapsed to `0`: the ledger counts those
/// rows separately so a usage UI can say "spend excludes N unpriced
/// requests" instead of quietly under-reporting.
public struct PricedUsageEvent: Sendable, Equatable {
    public let event: CostUsageScanCache.ParsedEvent
    public let costMicros: Int64?

    public init(event: CostUsageScanCache.ParsedEvent, costMicros: Int64?) {
        self.event = event
        self.costMicros = costMicros
    }

    /// The single place a `Double` cost becomes money. Everything
    /// downstream — storage, sums, averages — is `Int64` micro-USD.
    public init(event: CostUsageScanCache.ParsedEvent, costUSD: Double?) {
        self.init(event: event, costMicros: costUSD.flatMap(Self.micros(fromUSD:)))
    }

    static func micros(fromUSD usd: Double) -> Int64? {
        let scaled = (usd * 1_000_000).rounded()
        guard scaled.isFinite,
              scaled >= Double(Int64.min),
              scaled <= Double(Int64.max)
        else { return nil }
        return Int64(scaled)
    }

    public static func == (lhs: PricedUsageEvent, rhs: PricedUsageEvent) -> Bool {
        lhs.costMicros == rhs.costMicros
            && lhs.event.date == rhs.event.date
            && lhs.event.model == rhs.event.model
            && lhs.event.input == rhs.event.input
            && lhs.event.output == rhs.event.output
            && lhs.event.cache == rhs.event.cache
            && lhs.event.cacheCreation == rhs.event.cacheCreation
            && lhs.event.messageId == rhs.event.messageId
            && lhs.event.requestId == rhs.event.requestId
    }
}

/// Everything `CostUsageScanner` finished with for one source file.
///
/// `mtime` / `size` are the same fingerprint `CostUsageScanCache` uses, so
/// a sink can skip a file it has already ingested without re-reading it.
public struct UsageEventFileBatch: Sendable {
    public let tool: ToolType
    public let filePath: String
    public let mtime: Date
    public let size: Int64
    public let events: [PricedUsageEvent]

    /// Sentinel `size` for a batch whose events came from a stale cache
    /// fallback rather than from the file on disk (the AntiGravity `.pb`
    /// path when the language server is not reachable). A real fingerprint
    /// can never be negative, so recording this value keeps repeated stale
    /// emissions idempotent while still letting the first *real* batch for
    /// the same file re-ingest.
    public static let staleFallbackSize: Int64 = -1

    public init(
        tool: ToolType,
        filePath: String,
        mtime: Date,
        size: Int64,
        events: [PricedUsageEvent]
    ) {
        self.tool = tool
        self.filePath = filePath
        self.mtime = mtime
        self.size = size
        self.events = events
    }
}

/// Receiver for per-file scan output.
///
/// `CostUsageScanner` calls this once per source file, for freshly parsed
/// *and* cache-reused files, so a sink attached to an empty store still
/// backfills from a warm scan cache on the very first pass.
public protocol CostUsageEventSink: Sendable {
    func consume(_ batch: UsageEventFileBatch) async
}
