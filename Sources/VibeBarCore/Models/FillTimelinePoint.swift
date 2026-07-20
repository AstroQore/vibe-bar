import Foundation

/// One point-in-time usage sample for a quota bucket. Slots are adaptive:
/// five-hour windows use five-minute slots, weekly windows use hourly slots,
/// and monthly windows use six-hour slots. The exact sample timestamp and the
/// provider's reset forecast are retained so the forecasting engine can
/// distinguish real burn from refills and reset-time drift.
public struct FillTimelinePoint: Codable, Sendable, Hashable {
    public let accountId: String
    public let tool: ToolType
    public let bucketId: String
    /// Start of the hour slot this sample is filed under (UTC-floored).
    public var slotStart: Date
    /// Used percent at `sampledAt` (0–100). Last sample in the hour wins.
    public var usedPercent: Double
    /// Exact refresh timestamp of the winning sample — shown in the
    /// hover caption ("Jul 2 at 16:23: 24% used").
    public var sampledAt: Date
    /// Provider-reported reset forecast at the time of this observation.
    /// Optional for schema-v1 points migrated from older builds.
    public var resetAt: Date?
    /// Window length at the time of this observation. Optional for legacy
    /// points whose original payload did not retain this field.
    public var rawWindowSeconds: Int?

    public init(
        accountId: String,
        tool: ToolType,
        bucketId: String,
        slotStart: Date,
        usedPercent: Double,
        sampledAt: Date,
        resetAt: Date? = nil,
        rawWindowSeconds: Int? = nil
    ) {
        self.accountId = accountId
        self.tool = tool
        self.bucketId = bucketId
        self.slotStart = slotStart
        self.usedPercent = usedPercent
        self.sampledAt = sampledAt
        self.resetAt = resetAt
        self.rawWindowSeconds = rawWindowSeconds
    }
}
