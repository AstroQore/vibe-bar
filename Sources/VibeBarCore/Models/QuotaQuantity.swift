import Foundation

/// Absolute allowance values. Missing totals must never become a fabricated percentage.
public struct QuotaQuantity: Codable, Hashable, Sendable {
    public var used: Int?
    public var remaining: Int?
    public var limit: Int?
    public var isEstimated: Bool
    public var coverageComplete: Bool

    public init(used: Int? = nil, remaining: Int? = nil, limit: Int? = nil,
                isEstimated: Bool = false, coverageComplete: Bool = true) {
        self.used = used.flatMap { $0 >= 0 ? $0 : nil }
        self.remaining = remaining.flatMap { $0 >= 0 ? $0 : nil }
        self.limit = limit.flatMap { $0 > 0 ? $0 : nil }
        self.isEstimated = isEstimated
        self.coverageComplete = coverageComplete
    }

    public var usedPercent: Double? {
        guard coverageComplete, let limit else { return nil }
        if let used { return min(100, 100 * Double(used) / Double(limit)) }
        if let remaining { return max(0, 100 - 100 * Double(remaining) / Double(limit)) }
        return nil
    }

    public func value(_ mode: DisplayMode) -> Int? {
        switch mode {
        case .used: return used
        case .remaining: return remaining
        }
    }
}
