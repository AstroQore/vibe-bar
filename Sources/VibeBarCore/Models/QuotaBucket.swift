import Foundation

public struct QuotaBucket: Codable, Identifiable, Hashable, Sendable {
    public var id: String
    public var title: String
    public var shortLabel: String
    public var usedPercent: Double
    public var resetAt: Date?
    public var rawWindowSeconds: Int?
    public var groupTitle: String?

    public init(
        id: String,
        title: String,
        shortLabel: String,
        usedPercent: Double,
        resetAt: Date? = nil,
        rawWindowSeconds: Int? = nil,
        groupTitle: String? = nil
    ) {
        self.id = id
        self.title = title
        self.shortLabel = shortLabel
        self.usedPercent = max(0.0, min(100.0, usedPercent))
        self.resetAt = resetAt
        self.rawWindowSeconds = rawWindowSeconds
        self.groupTitle = groupTitle
    }

    public var remainingPercent: Double {
        max(0.0, min(100.0, 100.0 - usedPercent))
    }

    public func displayPercent(_ mode: DisplayMode) -> Double {
        switch mode {
        case .remaining: return remainingPercent
        case .used: return usedPercent
        }
    }
}
