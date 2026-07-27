import Foundation

/// Identifies one page of the popover for layout purposes: the Overview, or a
/// provider detail page.
///
/// String-backed and open for the same reason as `PageLayoutModuleID` — a page
/// this build does not recognize (a provider added later, or one removed from
/// `ToolType`) must survive a round trip through `layout.json` instead of
/// dropping the user's arrangement for it.
public struct PageLayoutPageID: RawRepresentable, Hashable, Sendable {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public init(_ rawValue: String) {
        self.init(rawValue: rawValue)
    }

    public enum Family {
        public static let overview = "overview"
        public static let detail = "detail"
    }

    /// The Overview page.
    public static let overview = PageLayoutPageID(rawValue: Family.overview)

    /// A provider detail page, e.g. `detail:claude`.
    public static func detail(_ tool: ToolType) -> PageLayoutPageID {
        PageLayoutPageID(rawValue: "\(Family.detail):\(tool.rawValue)")
    }

    public var isOverview: Bool { rawValue == Family.overview }

    /// The provider this page belongs to, or `nil` for the Overview and for
    /// detail pages naming a tool this build does not know.
    public var detailTool: ToolType? {
        let parts = rawValue.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2, parts[0] == Family.detail else { return nil }
        return ToolType(rawValue: String(parts[1]))
    }
}

extension PageLayoutPageID: Codable {
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        self.init(rawValue: try container.decode(String.self))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

/// Makes `[PageLayoutPageID: PageLayoutConfig]` encode as a JSON object keyed
/// by the page identifier.
extension PageLayoutPageID: CodingKeyRepresentable {
    public var codingKey: CodingKey {
        PageLayoutStringCodingKey(rawValue)
    }

    public init?<T: CodingKey>(codingKey: T) {
        self.init(rawValue: codingKey.stringValue)
    }
}

extension PageLayoutPageID: CustomStringConvertible {
    public var description: String { rawValue }
}
