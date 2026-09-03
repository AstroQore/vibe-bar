import Foundation

/// A quota bucket an adapter actually returned that the static
/// `MenuBarFieldCatalog` does not list — e.g. a limit the provider shipped
/// after this build (ChatGPT's `GPT-reserve` weekly pool). Recording it makes
/// the bucket selectable in the mini-window field picker without a release,
/// and remembering it keeps the row visible (dimmed) when the account stops
/// returning it, so a selection survives a provider hiccup.
public struct DiscoveredQuotaField: Codable, Equatable, Sendable, Identifiable {
    public let tool: ToolType
    public let bucketId: String
    /// The bucket's own window title ("Weekly", "5 Hours").
    public var title: String
    /// The L3 quota-group name the adapter attached ("GPT-reserve"), if any.
    public var groupTitle: String?
    public var shortLabel: String
    public var firstSeen: Date
    public var lastSeen: Date

    public var id: String { MenuBarFieldCatalog.fieldId(tool: tool, bucketId: bucketId) }

    public init(
        tool: ToolType,
        bucketId: String,
        title: String,
        groupTitle: String?,
        shortLabel: String,
        firstSeen: Date,
        lastSeen: Date
    ) {
        self.tool = tool
        self.bucketId = bucketId
        self.title = title
        self.groupTitle = groupTitle
        self.shortLabel = shortLabel
        self.firstSeen = firstSeen
        self.lastSeen = lastSeen
    }
}

/// Every catalog-external quota bucket this Mac has ever seen, persisted under
/// `~/.vibebar/`. The mini-window catalog is the merge of the static table and
/// this registry: static entries own their ids, labels and ordering; the
/// registry adds whatever the adapters discovered at runtime.
public struct QuotaFieldRegistry: Codable, Equatable, Sendable {
    public var fields: [DiscoveredQuotaField]

    /// Hard cap so a misbehaving adapter that invents a new bucket id per
    /// refresh cannot grow the file forever. Oldest-seen entries fall off.
    public static let maximumFields = 128

    public init(fields: [DiscoveredQuotaField] = []) {
        self.fields = fields
    }

    private enum CodingKeys: String, CodingKey {
        case fields
    }

    /// Lossy per entry.
    ///
    /// The synthesized decoder threw on the first entry it could not read — a
    /// `ToolType` a newer build added, most likely — and `QuotaService` loads
    /// this with `try? … ?? .empty`, so one unreadable row discarded *every*
    /// remembered field. The next refresh then rewrote the file without them,
    /// which is a silent, permanent loss of exactly the rows the keep set
    /// exists to protect: buckets the user selected that the provider is not
    /// returning right now.
    ///
    /// Dropping a single unreadable entry is right, and is the one place in
    /// this model where it is: the registry is a record of what adapters
    /// returned, not something the user authored, and an entry for a provider
    /// this build has no `ToolType` for cannot be fetched or drawn. The next
    /// build that understands it rediscovers it from a live response.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let stored = try container.decodeIfPresent(
            [LossyDiscoveredQuotaField].self, forKey: .fields
        ) ?? []
        self.fields = stored.compactMap(\.value)
    }

    public static let empty = QuotaFieldRegistry()

    public func field(id: String) -> DiscoveredQuotaField? {
        fields.first { $0.id == id }
    }

    public func fields(for tool: ToolType) -> [DiscoveredQuotaField] {
        fields.filter { $0.tool == tool }
    }

    /// Fold one refresh result in. Returns true when anything changed enough
    /// to persist — a new bucket, or metadata (title/group) that moved.
    /// `lastSeen` alone is throttled to daily granularity so a 60-second
    /// refresh loop doesn't rewrite the file every tick.
    @discardableResult
    public mutating func record(tool: ToolType, buckets: [QuotaBucket], now: Date = Date()) -> Bool {
        var changed = false
        for bucket in buckets {
            let fieldId = MenuBarFieldCatalog.fieldId(tool: tool, bucketId: bucket.id)
            guard MenuBarFieldCatalog.field(id: fieldId) == nil else { continue }
            let trimmedGroup = bucket.groupTitle?.trimmingCharacters(in: .whitespacesAndNewlines)
            let group = (trimmedGroup?.isEmpty ?? true) ? nil : trimmedGroup
            if let index = fields.firstIndex(where: { $0.id == fieldId }) {
                var existing = fields[index]
                if existing.title != bucket.title
                    || existing.groupTitle != group
                    || existing.shortLabel != bucket.shortLabel {
                    existing.title = bucket.title
                    existing.groupTitle = group
                    existing.shortLabel = bucket.shortLabel
                    changed = true
                }
                if now.timeIntervalSince(existing.lastSeen) > 86_400 {
                    existing.lastSeen = now
                    changed = true
                }
                fields[index] = existing
            } else {
                fields.append(
                    DiscoveredQuotaField(
                        tool: tool,
                        bucketId: bucket.id,
                        title: bucket.title,
                        groupTitle: group,
                        shortLabel: bucket.shortLabel,
                        firstSeen: now,
                        lastSeen: now
                    )
                )
                changed = true
            }
        }
        if fields.count > Self.maximumFields {
            fields.sort { $0.lastSeen > $1.lastSeen }
            fields.removeLast(fields.count - Self.maximumFields)
            changed = true
        }
        return changed
    }

    /// Whether the live quota cache still returns this field's bucket.
    public func isLive(_ field: DiscoveredQuotaField, in quotas: [ToolType: AccountQuota]) -> Bool {
        quotas[field.tool]?.bucket(id: field.bucketId) != nil
    }

    /// Forget `tool`'s entries the provider stopped returning that nothing
    /// references — not selected in any mini window and never given a name,
    /// where "a name" includes a custom label on the field itself *or* on
    /// its quota group (a discovered group's label key is
    /// `<tool>.<bucket-id stem>`). A referenced entry stays (dimmed in the
    /// picker) so a selection survives a provider hiccup; an unreferenced
    /// one was never the user's and does not need remembering. Returns true
    /// when anything dropped.
    @discardableResult
    public mutating func prune(
        tool: ToolType,
        liveBucketIds: Set<String>,
        keeping keep: QuotaFieldKeepSet
    ) -> Bool {
        let before = fields.count
        fields.removeAll { field in
            guard field.tool == tool,
                  !liveBucketIds.contains(field.bucketId),
                  !keep.fieldIds.contains(field.id)
            else { return false }
            let groupKey = "\(field.tool.rawValue).\(MenuBarFieldCatalog.bucketGroupStem(field.bucketId))"
            return !keep.groupKeys.contains(groupKey)
        }
        return fields.count != before
    }

    /// Drop one entry outright — the picker's explicit "forget" control.
    @discardableResult
    public mutating func forget(id: String) -> Bool {
        let before = fields.count
        fields.removeAll { $0.id == id }
        return fields.count != before
    }
}

/// What the registry must not forget: field ids a mini window selects or the
/// user labelled, plus group-label keys — naming a discovered bucket's group
/// is as much a claim on it as naming the bucket itself.
public struct QuotaFieldKeepSet: Sendable {
    public var fieldIds: Set<String>
    public var groupKeys: Set<String>

    public init(fieldIds: Set<String> = [], groupKeys: Set<String> = []) {
        self.fieldIds = fieldIds
        self.groupKeys = groupKeys
    }
}

public extension MenuBarFieldCatalog {
    /// The static catalog plus everything the registry has discovered, with
    /// static entries winning id collisions. This is the catalog every
    /// mini-window surface (picker, layouts, panel sizing) resolves against.
    static func mergedFields(registry: QuotaFieldRegistry) -> [MenuBarFieldOption] {
        var ids = Set(allFields.map(\.id))
        var merged = allFields
        for discovered in registry.fields where ids.insert(discovered.id).inserted {
            merged.append(option(for: discovered))
        }
        return merged
    }

    static func field(id: String, registry: QuotaFieldRegistry) -> MenuBarFieldOption? {
        if let statically = field(id: id) { return statically }
        guard let discovered = registry.field(id: id) else { return nil }
        return option(for: discovered)
    }

    static func option(for discovered: DiscoveredQuotaField) -> MenuBarFieldOption {
        let title: String
        if let group = discovered.groupTitle {
            title = "\(group) · \(discovered.title)"
        } else {
            title = discovered.title
        }
        return MenuBarFieldOption(
            id: discovered.id,
            tool: discovered.tool,
            bucketId: discovered.bucketId,
            title: title,
            defaultLabel: discovered.shortLabel,
            dynamicGroupTitle: discovered.groupTitle,
            isDynamic: true
        )
    }

    /// The company → SubProvider skeleton for one mini window, honoring the
    /// user's field order. Fields group into SubProviders in order of first
    /// appearance; consecutive SubProviders sharing a vendor fold into one
    /// company column, exactly as `subProviderGroups(for:selectedFieldIds:)`
    /// folds them in catalog order.
    static func orderedSubProviderGroups(
        fieldIds: [String],
        registry: QuotaFieldRegistry
    ) -> [MenuBarCompanyFieldGroup] {
        var groups: [MenuBarCompanyFieldGroup] = []
        var subProviderIndex: [String: (company: Int, sub: Int)] = [:]
        for fieldId in fieldIds {
            guard let field = field(id: fieldId, registry: registry) else { continue }
            let name = field.tool.quotaSubProviderName(bucketID: field.bucketId)
            let key = "\(field.tool.rawValue)/\(name)"
            if let position = subProviderIndex[key] {
                groups[position.company].subProviders[position.sub].fields.append(field)
                continue
            }
            let subProvider = MenuBarSubProviderGroup(tool: field.tool, name: name, fields: [field])
            if let last = groups.indices.last, groups[last].company == field.tool.vendorName {
                groups[last].subProviders.append(subProvider)
                subProviderIndex[key] = (last, groups[last].subProviders.count - 1)
            } else {
                groups.append(
                    MenuBarCompanyFieldGroup(
                        company: field.tool.vendorName,
                        accentTool: field.tool,
                        subProviders: [subProvider]
                    )
                )
                subProviderIndex[key] = (groups.count - 1, 0)
            }
        }
        return groups
    }

    /// The stem of a bucket id with its window suffix removed, so the two
    /// windows of one discovered quota group ("gpt_reserve_five_hour" /
    /// "gpt_reserve_weekly") land in one labelled group instead of two.
    static func bucketGroupStem(_ bucketId: String) -> String {
        var stem = bucketId
        for suffix in ["_five_hour", "_weekly", "_monthly", "_daily", "_primary", "_secondary"] {
            if stem.hasSuffix(suffix) {
                stem = String(stem.dropLast(suffix.count))
                break
            }
        }
        // "…_30d_window" / "…_12h_window" from CodexResponseParser's generic
        // window naming.
        if stem.hasSuffix("_window") {
            let trimmed = String(stem.dropLast("_window".count))
            if let underscore = trimmed.lastIndex(of: "_") {
                let tail = trimmed[trimmed.index(after: underscore)...]
                if tail.count > 1, tail.dropLast().allSatisfy(\.isNumber),
                   tail.last == "d" || tail.last == "h" {
                    stem = String(trimmed[..<underscore])
                }
            }
        }
        return stem.isEmpty ? bucketId : stem
    }
}


/// Tolerant wrapper: one entry this build cannot read must not cost the rest.
private struct LossyDiscoveredQuotaField: Decodable {
    let value: DiscoveredQuotaField?

    init(from decoder: Decoder) throws {
        self.value = try? DiscoveredQuotaField(from: decoder)
    }
}
