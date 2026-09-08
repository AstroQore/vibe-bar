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
