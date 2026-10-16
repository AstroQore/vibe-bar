import Foundation

public enum OverviewQuotaGranularity: String, Codable, CaseIterable, Sendable {
    case company, subProvider, model
}

/// Stable card identities and bucket filters; quota values remain in the
/// original snapshots. Window variants of one model stay in the same card.
public struct OverviewQuotaPartition: Hashable, Sendable {
    public let tool: ToolType
    public let subProvider: String
    public let groupTitle: String?
    public let bucketIDs: [String]
    public let granularity: OverviewQuotaGranularity
    public let showsSharedMetadata: Bool
    /// The X Subscription's one pool: Grok's Weekly card, still Grok's on the
    /// quota axis (L2 stays the SubProvider, so the card's identity and layout
    /// slot are the ones the Grok card always had), presented under the
    /// bundle's name with Cursor and Grok Bot's shares beneath it.
    public let isSharedPool: Bool

    public init(
        tool: ToolType,
        subProvider: String,
        groupTitle: String?,
        bucketIDs: [String],
        granularity: OverviewQuotaGranularity,
        showsSharedMetadata: Bool,
        isSharedPool: Bool = false
    ) {
        self.tool = tool
        self.subProvider = subProvider
        self.groupTitle = groupTitle
        self.bucketIDs = bucketIDs
        self.granularity = granularity
        self.showsSharedMetadata = showsSharedMetadata
        self.isSharedPool = isSharedPool
    }

    /// The one card The X Subscription's pool gets on the Overview, at every
    /// granularity.
    public static func sharedPool(granularity: OverviewQuotaGranularity) -> Self {
        Self(tool: .grok, subProvider: ToolType.grok.quotaSubProviderName(), groupTitle: nil,
             bucketIDs: ["weekly"], granularity: granularity, showsSharedMetadata: true, isSharedPool: true)
    }

    /// What the SubProvider row reads: the plan's name on the pool card, the
    /// SubProvider's everywhere else.
    public var displayTitle: String {
        isSharedPool ? SharedPoolSummary.subProviderName : subProvider
    }

    public var id: String {
        let scope = Data((subProvider + "\u{0}" + (groupTitle ?? "")).utf8).base64EncodedString()
        return "overview-quota:\(tool.rawValue):\(granularity.rawValue.lowercased()):\(scope)"
    }

    public var suppressGroupTitles: Bool {
        tool == .cursor && subProvider == tool.quotaSubProviderName(bucketID: "grok_bot_weekly")
    }

    public static func partitions(
        tool: ToolType,
        buckets: [QuotaBucket],
        granularity: OverviewQuotaGranularity
    ) -> [Self] {
        guard !buckets.isEmpty else {
            return [Self(tool: tool, subProvider: tool.quotaSubProviderName(), groupTitle: nil,
                         bucketIDs: [], granularity: granularity, showsSharedMetadata: true)]
        }
        struct Key: Hashable { let subProvider: String; let group: String? }
        var order: [Key] = []
        var ids: [Key: [String]] = [:]
        for bucket in buckets {
            let name = granularity == .company ? tool.quotaSubProviderName() : tool.quotaSubProviderName(bucketID: bucket.id)
            let trimmed = bucket.groupTitle?.trimmingCharacters(in: .whitespacesAndNewlines)
            let group = trimmed?.isEmpty == false ? trimmed : nil
            let title = granularity == .model && group?.caseInsensitiveCompare(name) != .orderedSame
                ? group : nil
            let key = Key(subProvider: name, group: title)
            if ids[key] == nil { order.append(key); ids[key] = [] }
            if ids[key]?.contains(bucket.id) == false { ids[key]?.append(bucket.id) }
        }
        var shownSubProviders = Set<String>()
        return order.map { key in
            Self(tool: tool, subProvider: key.subProvider, groupTitle: key.group,
                 bucketIDs: ids[key] ?? [], granularity: granularity,
                 showsSharedMetadata: shownSubProviders.insert(key.subProvider).inserted)
        }
    }
}
