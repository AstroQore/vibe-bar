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
        self.title = VisibleSecretRedactor.redact(title) ?? ""
        self.shortLabel = VisibleSecretRedactor.redact(shortLabel) ?? ""
        // Swift's `min/max` on Double pass NaN through unchanged in
        // one ordering and trap it in the other, so a non-finite
        // value here would silently end up as 100% — a much louder
        // bug than treating it as zero (the parser shouldn't have
        // produced a non-finite percent in the first place).
        self.usedPercent = usedPercent.isFinite ? max(0.0, min(100.0, usedPercent)) : 0
        self.resetAt = resetAt
        self.rawWindowSeconds = rawWindowSeconds
        self.groupTitle = VisibleSecretRedactor.redact(groupTitle)
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
