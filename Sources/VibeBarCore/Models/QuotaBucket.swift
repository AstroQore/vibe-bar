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
        self.shortLabel = Self.expandedWindowLabel(
            VisibleSecretRedactor.redact(shortLabel) ?? "",
            bucketId: id
        )
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

    private enum CodingKeys: String, CodingKey {
        case id
        case title
        case shortLabel
        case usedPercent
        case resetAt
        case rawWindowSeconds
        case groupTitle
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            id: try container.decode(String.self, forKey: .id),
            title: try container.decode(String.self, forKey: .title),
            shortLabel: try container.decode(String.self, forKey: .shortLabel),
            usedPercent: try container.decode(Double.self, forKey: .usedPercent),
            resetAt: try container.decodeIfPresent(Date.self, forKey: .resetAt),
            rawWindowSeconds: try container.decodeIfPresent(Int.self, forKey: .rawWindowSeconds),
            groupTitle: try container.decodeIfPresent(String.self, forKey: .groupTitle)
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(title, forKey: .title)
        try container.encode(shortLabel, forKey: .shortLabel)
        try container.encode(usedPercent, forKey: .usedPercent)
        try container.encodeIfPresent(resetAt, forKey: .resetAt)
        try container.encodeIfPresent(rawWindowSeconds, forKey: .rawWindowSeconds)
        try container.encodeIfPresent(groupTitle, forKey: .groupTitle)
    }

    /// Quota-window names are ordinary UI copy, not telemetry codes. Keep
    /// provider/parser compatibility inside the adapters while guaranteeing
    /// that every newly parsed or cache-restored bucket exposes full words to
    /// the app surfaces.
    private static func expandedWindowLabel(_ label: String, bucketId: String) -> String {
        if bucketId == "five_hour" { return "5 Hours" }
        if bucketId == "weekly" { return "Weekly" }
        return label
            .split(separator: " ", omittingEmptySubsequences: false)
            .map { component in
                switch component.lowercased() {
                case "5h": return "5 Hours"
                case "wk": return "Weekly"
                default: return String(component)
                }
            }
            .joined(separator: " ")
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
