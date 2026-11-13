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
        if isSharedPool { return SharedPoolSummary.subProviderName }
        return tool.isChatGPTQuotaSource ? ToolType.chatGPTQuotaTitle : subProvider
    }

    public var isCombinedChatGPT: Bool { tool == .codex && granularity == .subProvider }

    // The combined card owns its visibility settings. Reusing a source's
    // ID would turn a previous "hide Codex" setting into "hide ChatGPT".
    public static let combinedChatGPTModuleID = PageLayoutModuleID("overview-quota:codex:subprovider:chatgpt")
    static let legacyCodexModuleID = legacySubProviderModuleID(tool: .codex, name: "ChatGPT Agentic")
    static let legacyChatModuleID = legacySubProviderModuleID(tool: .chatgptChat, name: "ChatGPT Chat")

    private static func legacySubProviderModuleID(tool: ToolType, name: String) -> PageLayoutModuleID {
        PageLayoutModuleID(partitionID(tool: tool, granularity: .subProvider, name: name, groupTitle: nil))
    }

    /// Keep the new position when present, then the former Codex position,
    /// then the former Chat position. Drop the other positions for the card.
    static func combiningChatGPT(in groups: [[PageLayoutModuleID]]) -> [[PageLayoutModuleID]] {
        let combined = combinedChatGPTModuleID
        let positions = [combined, legacyCodexModuleID, legacyChatModuleID]
        let ids = Set(groups.joined())
        guard let preferred = positions.first(where: ids.contains) else { return groups }

        var placed = false
        return groups.map { group in
            group.compactMap { id in
                guard positions.contains(id) else { return id }
                guard id == preferred, !placed else { return nil }
                placed = true
                return combined
            }
        }
    }

    static func combiningChatGPT(in layout: StoredPageLayout) -> StoredPageLayout {
        let chat = legacyChatModuleID
        let codex = legacyCodexModuleID
        let combined = combinedChatGPTModuleID
        let saved = Set(layout.columns.joined()).union(layout.segments.joined()).union(layout.hidden)
        guard saved.contains(chat) || saved.contains(codex) else { return layout }

        var hidden = layout.hidden.filter { $0 != codex && $0 != chat }
        // When upgrading old settings, hiding one source still leaves the
        // other visible. If the combined card already has a saved setting,
        // use that setting.
        if !saved.contains(combined), layout.hidden.contains(codex), layout.hidden.contains(chat) {
            hidden.append(combined)
        }
        return StoredPageLayout(mode: layout.mode, ratio: layout.ratio,
                                columns: combiningChatGPT(in: layout.columns),
                                segments: combiningChatGPT(in: layout.segments),
                                hidden: hidden)
    }

    public var id: String {
        if isCombinedChatGPT { return Self.combinedChatGPTModuleID.rawValue }
        return Self.partitionID(tool: tool, granularity: granularity, name: subProvider, groupTitle: groupTitle)
    }

    private static func partitionID(
        tool: ToolType, granularity: OverviewQuotaGranularity, name: String, groupTitle: String?
    ) -> String {
        let scope = Data((name + "\u{0}" + (groupTitle ?? "")).utf8).base64EncodedString()
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
        // The Codex partition owns the common card even before either
        // source returns data. At model granularity each source keeps its
        // own set of partitions, including stable IDs for saved layouts.
        if tool == .chatgptChat, granularity == .subProvider { return [] }
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
