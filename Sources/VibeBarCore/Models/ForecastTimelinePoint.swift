import Foundation

/// One recorded pace-forecast snapshot for a quota bucket.
///
/// `QuotaPaceForecast` is recomputed from scratch every time a view renders, so
/// nothing on screen remembers what the forecast said an hour ago. The history
/// chart needs exactly that: the projection line has to be drawn from what was
/// actually predicted at the time, not from a projection recomputed with
/// hindsight. Points are filed into the same adaptive slots as
/// `FillTimelinePoint` (see `UsageTimelineSlotPolicy`) and the last sample in a
/// slot wins.
public struct ForecastTimelinePoint: Codable, Sendable, Hashable {
    public let accountId: String
    public let tool: ToolType
    public let bucketId: String
    /// Start of the slot this sample is filed under (UTC-floored).
    public var slotStart: Date
    /// Exact timestamp of the winning sample in this slot.
    public var sampledAt: Date
    /// Median projected demand at reset. May exceed 100 — the forecast keeps
    /// shortage severity even though the visible quota caps at 100%.
    public var projectedUsedPercent: Double
    /// Optimistic bound of the projection (least demand).
    public var projectedUsedLowerPercent: Double
    /// Pessimistic bound of the projection (most demand).
    public var projectedUsedUpperPercent: Double
    /// Reset forecast this projection was made against. The history chart
    /// segments its lines whenever this changes.
    public var resetAt: Date?
    /// Window length at the time of this observation. Drives slot width and
    /// retention, exactly as on `FillTimelinePoint`.
    public var rawWindowSeconds: Int?

    public init(
        accountId: String,
        tool: ToolType,
        bucketId: String,
        slotStart: Date,
        sampledAt: Date,
        projectedUsedPercent: Double,
        projectedUsedLowerPercent: Double,
        projectedUsedUpperPercent: Double,
        resetAt: Date? = nil,
        rawWindowSeconds: Int? = nil
    ) {
        self.accountId = accountId
        self.tool = tool
        self.bucketId = bucketId
        self.slotStart = slotStart
        self.sampledAt = sampledAt
        self.projectedUsedPercent = projectedUsedPercent
        self.projectedUsedLowerPercent = projectedUsedLowerPercent
        self.projectedUsedUpperPercent = projectedUsedUpperPercent
        self.resetAt = resetAt
        self.rawWindowSeconds = rawWindowSeconds
    }
}

/// One bucket's forecast, flattened for the recording hook.
///
/// Keeps `UsageForecastTimelineStore` independent of `QuotaPaceForecast`'s full
/// diagnostics payload: only the three projection percentages and the window
/// metadata are ever persisted.
public struct BucketForecastObservation: Sendable, Equatable {
    public let bucketId: String
    public let resetAt: Date?
    public let rawWindowSeconds: Int?
    public let projectedUsedPercent: Double
    public let projectedUsedLowerPercent: Double
    public let projectedUsedUpperPercent: Double

    public init(
        bucketId: String,
        resetAt: Date?,
        rawWindowSeconds: Int?,
        projectedUsedPercent: Double,
        projectedUsedLowerPercent: Double,
        projectedUsedUpperPercent: Double
    ) {
        self.bucketId = bucketId
        self.resetAt = resetAt
        self.rawWindowSeconds = rawWindowSeconds
        self.projectedUsedPercent = projectedUsedPercent
        self.projectedUsedLowerPercent = projectedUsedLowerPercent
        self.projectedUsedUpperPercent = projectedUsedUpperPercent
    }

    public init(bucket: QuotaBucket, forecast: QuotaPaceForecast) {
        self.init(
            bucketId: bucket.id,
            resetAt: bucket.resetAt,
            rawWindowSeconds: bucket.rawWindowSeconds,
            projectedUsedPercent: forecast.projectedUsedPercent,
            projectedUsedLowerPercent: forecast.projectedUsedLowerPercent,
            projectedUsedUpperPercent: forecast.projectedUsedUpperPercent
        )
    }
}
