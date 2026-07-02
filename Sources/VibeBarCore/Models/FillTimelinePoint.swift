import Foundation

/// One point-in-time usage sample for a quota bucket, bucketed to an hour
/// slot. Powers the CodexBar-style fill timeline chart: unlike
/// `SubscriptionWindowSample` (one aggregate per reset window), this is a
/// short-horizon time series — "at 16:00 on Jul 2 the weekly bucket was 24%
/// used" — so it can include the 5-hour rolling windows the window-peak
/// store deliberately excludes.
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

    public init(
        accountId: String,
        tool: ToolType,
        bucketId: String,
        slotStart: Date,
        usedPercent: Double,
        sampledAt: Date
    ) {
        self.accountId = accountId
        self.tool = tool
        self.bucketId = bucketId
        self.slotStart = slotStart
        self.usedPercent = usedPercent
        self.sampledAt = sampledAt
    }
}
