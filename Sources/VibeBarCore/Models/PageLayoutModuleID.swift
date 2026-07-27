import Foundation

/// Stable identifier for one card ("module") on a popover page.
///
/// Deliberately a thin string wrapper instead of an enum. `layout.json` is user
/// data that outlives any single build, so a module this build does not know
/// about — one added by a newer version, or one whose provider is temporarily
/// disabled — must survive a decode/encode round trip byte-for-byte rather than
/// being silently dropped from the user's arrangement.
///
/// Convention: `<family>` or `<family>:<qualifier>[:<qualifier>…]`, lowercase
/// kebab-case. The helpers below spell out the families that exist today; they
/// are the naming convention, not an exhaustive list.
public struct PageLayoutModuleID: RawRepresentable, Hashable, Sendable {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public init(_ rawValue: String) {
        self.init(rawValue: rawValue)
    }

    // MARK: - Families

    /// Family prefixes. Kept as constants so parsing and construction cannot
    /// drift apart.
    public enum Family {
        public static let quotaGroup = "quota-group"
        public static let cost = "cost"
        public static let costAll = "cost-all"
        public static let quotaHistoryAll = "quota-history-all"
        public static let status = "status"
        public static let modelBreakdown = "model-breakdown"
    }

    /// One quota group card — a provider's bucket family (`five_hour`,
    /// `weekly`, …) as rendered on Overview and on that provider's page.
    public static func quotaGroup(tool: ToolType, groupKey: String) -> PageLayoutModuleID {
        PageLayoutModuleID(rawValue: "\(Family.quotaGroup):\(tool.rawValue):\(groupKey)")
    }

    /// Per-provider local token-cost card.
    public static func cost(tool: ToolType) -> PageLayoutModuleID {
        PageLayoutModuleID(rawValue: "\(Family.cost):\(tool.rawValue)")
    }

    /// Combined all-providers cost card.
    public static let costAll = PageLayoutModuleID(rawValue: Family.costAll)

    /// Combined all-providers quota history card.
    public static let quotaHistoryAll = PageLayoutModuleID(rawValue: Family.quotaHistoryAll)

    /// Service-status card.
    public static let status = PageLayoutModuleID(rawValue: Family.status)

    /// Per-provider model breakdown / ranking card.
    public static func modelBreakdown(tool: ToolType) -> PageLayoutModuleID {
        PageLayoutModuleID(rawValue: "\(Family.modelBreakdown):\(tool.rawValue)")
    }

    /// Escape hatch for identifiers that do not (yet) have a helper. Round
    /// trips losslessly like every other value.
    public static func custom(_ rawValue: String) -> PageLayoutModuleID {
        PageLayoutModuleID(rawValue: rawValue)
    }

    // MARK: - Parsing

    /// The leading `<family>` segment. Returns the whole identifier when there
    /// is no qualifier.
    public var family: String {
        guard let separator = rawValue.firstIndex(of: ":") else { return rawValue }
        return String(rawValue[rawValue.startIndex..<separator])
    }

    /// The tool the identifier is scoped to, when the first qualifier names
    /// one. Covers `quota-group:<tool>:…`, `cost:<tool>`,
    /// `model-breakdown:<tool>`, and any future `<family>:<tool>` identifier.
    /// `nil` for global cards and for identifiers this build cannot parse.
    public var tool: ToolType? {
        let parts = rawValue.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count >= 2 else { return nil }
        return ToolType(rawValue: String(parts[1]))
    }
}

extension PageLayoutModuleID: Codable {
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        self.init(rawValue: try container.decode(String.self))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

/// Makes `[PageLayoutModuleID: Double]` encode as a plain JSON object keyed by
/// the raw identifier rather than the stdlib's alternating key/value array.
extension PageLayoutModuleID: CodingKeyRepresentable {
    public var codingKey: CodingKey {
        PageLayoutStringCodingKey(rawValue)
    }

    public init?<T: CodingKey>(codingKey: T) {
        self.init(rawValue: codingKey.stringValue)
    }
}

extension PageLayoutModuleID: CustomStringConvertible {
    public var description: String { rawValue }
}

/// Dynamic string coding key shared by the page-layout types.
struct PageLayoutStringCodingKey: CodingKey {
    let stringValue: String
    var intValue: Int? { nil }

    init(_ stringValue: String) {
        self.stringValue = stringValue
    }

    init?(stringValue: String) {
        self.init(stringValue)
    }

    init?(intValue: Int) {
        self.init(String(intValue))
    }
}
