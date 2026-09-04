import Foundation

public enum StatusIndicator: String, Codable, Sendable {
    case none
    case minor
    case major
    case critical
    case maintenance

    public var severity: Int {
        switch self {
        case .none:        return 0
        case .maintenance: return 1
        case .minor:       return 2
        case .major:       return 3
        case .critical:    return 4
        }
    }

    /// Badge text for a page-level indicator, in **our** words rather than
    /// the provider's. A status feed that publishes a blurb of its own —
    /// "All Systems Operational", "Users in the APAC region may see
    /// elevated latency" — wrote that text itself, and it stays exactly as
    /// sent (see `ServiceStatusSnapshot.description`). This is what we say
    /// when the feed carries only an indicator, so it is copy and it is
    /// translated.
    ///
    /// Computed, never stored: a localized string written into the cached
    /// snapshot would keep whatever language was current when it was
    /// written. `effectiveDescription` speaks for an *unacknowledged*
    /// incident and deliberately words `.minor` differently; everything
    /// reporting a provider's own indicator uses this.
    public var summaryDescription: String {
        switch self {
        case .none:        return L10n.Status.summaryAllOperational
        case .maintenance: return L10n.Status.summaryUnderMaintenance
        case .minor:       return L10n.Status.summaryServiceIssue
        case .major:       return L10n.Status.summaryPartialOutage
        case .critical:    return L10n.Status.summaryMajorOutage
        }
    }
}

public enum ComponentStatusLevel: String, Codable, Sendable {
    case operational
    case degradedPerformance = "degraded_performance"
    case partialOutage       = "partial_outage"
    case majorOutage         = "major_outage"
    case underMaintenance    = "under_maintenance"

    public var severity: Int {
        switch self {
        case .operational:         return 0
        case .underMaintenance:    return 1
        case .degradedPerformance: return 2
        case .partialOutage:       return 3
        case .majorOutage:         return 4
        }
    }
}

public enum IncidentImpact: String, Codable, Sendable {
    case none
    case maintenance
    case minor
    case major
    case critical

    public var severity: Int {
        switch self {
        case .none:        return 0
        case .maintenance: return 1
        case .minor:       return 2
        case .major:       return 3
        case .critical:    return 4
        }
    }

    /// The two ladders are deliberately one-to-one: an incident's impact is
    /// the page indicator it would justify on its own.
    public var indicator: StatusIndicator {
        switch self {
        case .none:        return .none
        case .maintenance: return .maintenance
        case .minor:       return .minor
        case .major:       return .major
        case .critical:    return .critical
        }
    }

    public var componentStatus: ComponentStatusLevel {
        switch self {
        case .none:        return .operational
        case .maintenance: return .underMaintenance
        case .minor:       return .degradedPerformance
        case .major:       return .partialOutage
        case .critical:    return .majorOutage
        }
    }
}

public struct ServiceComponentSummary: Codable, Sendable, Hashable, Identifiable {
    public let id: String
    public let name: String
    public let status: ComponentStatusLevel
    public let groupId: String?
    public let uptimePercent: Double?
    public let recentDays: [DayUptime]

    public init(
        id: String,
        name: String,
        status: ComponentStatusLevel,
        groupId: String? = nil,
        uptimePercent: Double? = nil,
        recentDays: [DayUptime] = []
    ) {
        self.id = id
        self.name = name
        self.status = status
        self.groupId = groupId
        self.uptimePercent = uptimePercent
        self.recentDays = recentDays
    }
}

public struct ServiceComponentGroup: Codable, Sendable, Hashable, Identifiable {
    public let id: String
    public let name: String

    public init(id: String, name: String) {
        self.id = id
        self.name = name
    }
}

public struct IncidentSummary: Codable, Sendable, Hashable, Identifiable {
    public let id: String
    public let name: String
    public let impact: IncidentImpact
    public let createdAt: Date
    public let resolvedAt: Date?
    public let url: URL?

    public init(
        id: String,
        name: String,
        impact: IncidentImpact,
        createdAt: Date,
        resolvedAt: Date?,
        url: URL?
    ) {
        self.id = id
        self.name = name
        self.impact = impact
        self.createdAt = createdAt
        self.resolvedAt = resolvedAt
        self.url = url
    }

    public var isResolved: Bool { resolvedAt != nil }
}

public struct DayUptime: Codable, Sendable, Hashable, Identifiable {
    public let date: Date
    public let worstImpact: IncidentImpact?

    public init(date: Date, worstImpact: IncidentImpact?) {
        self.date = date
        self.worstImpact = worstImpact
    }

    public var id: Date { date }
}

public struct ServiceStatusSnapshot: Sendable, Hashable, Codable {
    public let tool: ToolType
    public let indicator: StatusIndicator
    /// The provider's own words for its current state, verbatim — "All
    /// Systems Operational", "Users in APAC may see elevated latency".
    ///
    /// This is **data, not copy**: it arrives over the wire in whatever the
    /// provider wrote and is persisted to `service_status.json`, so it is
    /// never translated, and nothing from the catalog is ever written into
    /// it — a localized string stored here would be frozen in the language
    /// that was current when the cache was written.
    ///
    /// Empty when the feed publishes no blurb at all: xAI's HTML page and
    /// Google's incident feed carry an indicator and nothing else. Our own
    /// (translated) words for that state come from `effectiveDescription`,
    /// derived per read. Read that rather than this on any surface.
    public let description: String
    public let updatedAt: Date
    public let groups: [ServiceComponentGroup]
    public let components: [ServiceComponentSummary]
    public let recentIncidents: [IncidentSummary]
    /// Provider-level per-day incident overlay. Some status pages (Anthropic)
    /// post incidents without ever flipping a component to degraded, so the
    /// component-derived day strips stay green; this overlay lets the card
    /// mark those days anyway. Optional so cached pre-schema snapshots decode.
    public let incidentDays: [DayUptime]?
    /// Aggregate uptime with incident downtime folded in — see `incidentDays`.
    public let incidentAdjustedUptimePercent: Double?

    public init(
        tool: ToolType,
        indicator: StatusIndicator,
        description: String,
        updatedAt: Date,
        groups: [ServiceComponentGroup],
        components: [ServiceComponentSummary],
        recentIncidents: [IncidentSummary],
        incidentDays: [DayUptime]? = nil,
        incidentAdjustedUptimePercent: Double? = nil
    ) {
        self.tool = tool
        self.indicator = indicator
        self.description = description
        self.updatedAt = updatedAt
        self.groups = groups
        self.components = components
        self.recentIncidents = recentIncidents
        self.incidentDays = incidentDays
        self.incidentAdjustedUptimePercent = incidentAdjustedUptimePercent
    }

    /// Average per-component uptime over the recent window.
    public var aggregateUptimePercent: Double {
        let values = components.compactMap { $0.uptimePercent }
        guard !values.isEmpty else { return 0 }
        return values.reduce(0, +) / Double(values.count)
    }

    /// Uptime shown by the card comes only from the provider's published
    /// component uptime. Incident tickets are not continuous downtime
    /// intervals: some stay open across intermittent degradation for days.
    public var displayUptimePercent: Double {
        aggregateUptimePercent
    }

    /// Indicator with unresolved incidents folded in. Anthropic sometimes
    /// keeps `status.indicator == none` while an incident is still open, so
    /// the badge must not claim "All Systems Operational" in that state.
    public var effectiveIndicator: StatusIndicator {
        let unresolvedWorst = recentIncidents
            .filter { !$0.isResolved }
            .map(\.impact.indicator)
            .max { $0.severity < $1.severity }
        guard let unresolvedWorst else { return indicator }
        return unresolvedWorst.severity > indicator.severity ? unresolvedWorst : indicator
    }

    /// The badge text a surface should draw, resolved in three steps:
    ///
    /// 1. an open incident the page has not acknowledged
    ///    (`effectiveIndicator` outranks `indicator`) — we say what the page
    ///    will not, so these are **our** words and they are translated;
    /// 2. otherwise the provider's own blurb, verbatim, because it wrote it;
    /// 3. otherwise — the feed published only an indicator — our own
    ///    `summaryDescription` for it, also translated.
    ///
    /// Every branch is derived on read. Nothing here may be written back
    /// into `description`, which is cached to disk in the language it was
    /// fetched in.
    public var effectiveDescription: String {
        guard effectiveIndicator.severity > indicator.severity else { return statedDescription }
        switch effectiveIndicator {
        case .none:        return statedDescription
        case .maintenance: return L10n.Status.summaryUnderMaintenance
        case .minor:       return L10n.Status.summaryActiveIncident
        case .major:       return L10n.Status.summaryPartialOutage
        case .critical:    return L10n.Status.summaryMajorOutage
        }
    }

    /// The provider's blurb when it published one, our own words for its
    /// indicator when it did not. Steps 2 and 3 of `effectiveDescription`.
    private var statedDescription: String {
        description.isEmpty ? indicator.summaryDescription : description
    }

    public func components(in group: ServiceComponentGroup?) -> [ServiceComponentSummary] {
        if let group {
            return components.filter { $0.groupId == group.id }
        } else {
            return components.filter { $0.groupId == nil }
        }
    }

    /// A sub-provider whose components are published on another provider's
    /// status page but which this app treats as its own row. SpaceXAI's
    /// "Grok Bot" ships on Cursor's status page, so without a breakout it
    /// would read as a Cursor feature instead of a sibling of Grok / Cursor.
    public struct SubProviderBreakout: Sendable, Hashable {
        public let id: String
        public let name: String
        /// Component names (as published by the host status page) to peel off.
        public let componentNames: Set<String>

        public init(id: String, name: String, componentNames: Set<String>) {
            self.id = id
            self.name = name
            self.componentNames = componentNames
        }
    }

    /// Adds a linked provider as one component group while preserving this
    /// snapshot's L1 company identity. Used by the SpaceXAI card to include
    /// Cursor Status without implying a second top-level company row.
    /// Any `breakouts` claim their named components into their own trailing
    /// groups, which render with the same styling as the primary group.
    ///
    /// The result is a **display-time projection**, rebuilt whenever a row
    /// is drawn and never cached, which is why its `description` may hold
    /// already-resolved (and so possibly translated) text where a fetched
    /// snapshot's may not.
    public func mergingSubProvider(
        _ child: ServiceStatusSnapshot,
        groupID: String,
        groupName: String,
        breakouts: [SubProviderBreakout] = []
    ) -> ServiceStatusSnapshot {
        let childComponents = child.components.map { component -> ServiceComponentSummary in
            let owner = breakouts.first { $0.componentNames.contains(component.name) }?.id ?? groupID
            return ServiceComponentSummary(
                id: "\(owner):\(component.id)",
                name: component.name,
                status: component.status,
                groupId: owner,
                uptimePercent: component.uptimePercent,
                recentDays: component.recentDays
            )
        }
        let claimed = Set(childComponents.compactMap(\.groupId))
        var childGroups = [ServiceComponentGroup(id: groupID, name: groupName)]
        for breakout in breakouts where claimed.contains(breakout.id) {
            childGroups.append(ServiceComponentGroup(id: breakout.id, name: breakout.name))
        }
        let childIsWorse = child.effectiveIndicator.severity > effectiveIndicator.severity
        let incidents = (recentIncidents + child.recentIncidents)
            .sorted { $0.createdAt > $1.createdAt }
        return ServiceStatusSnapshot(
            tool: tool,
            indicator: childIsWorse ? child.effectiveIndicator : effectiveIndicator,
            description: childIsWorse ? "\(groupName) · \(child.effectiveDescription)" : effectiveDescription,
            updatedAt: max(updatedAt, child.updatedAt),
            groups: groups + childGroups,
            components: components + childComponents,
            recentIncidents: Array(incidents.prefix(4)),
            incidentDays: incidentDays,
            incidentAdjustedUptimePercent: incidentAdjustedUptimePercent
        )
    }

    /// One canonical SpaceXAI status projection shared by the Workbench card
    /// and the menu-bar context menu.
    public static func mergedSpaceXAI(
        grok: ServiceStatusSnapshot?,
        cursor: ServiceStatusSnapshot?
    ) -> ServiceStatusSnapshot? {
        guard let cursor else { return grok }
        // No Grok feed: stand in with an empty description rather than words
        // of our own. Empty means "the provider said nothing", and
        // `effectiveDescription` answers that with the localized summary of
        // whatever indicator the merge settles on — which, once Cursor is
        // folded in below, is the state the row is actually reporting.
        var base = grok ?? ServiceStatusSnapshot(
            tool: .grok,
            indicator: .none,
            description: "",
            updatedAt: cursor.updatedAt,
            groups: [],
            components: [],
            recentIncidents: []
        )
        if grok != nil {
            let groupID = "subprovider:grok"
            base = ServiceStatusSnapshot(
                tool: base.tool,
                indicator: base.indicator,
                description: base.description,
                updatedAt: base.updatedAt,
                groups: [ServiceComponentGroup(id: groupID, name: "Grok")],
                components: base.components.map { component in
                    ServiceComponentSummary(
                        id: component.id,
                        name: component.name,
                        status: component.status,
                        groupId: groupID,
                        uptimePercent: component.uptimePercent,
                        recentDays: component.recentDays
                    )
                },
                recentIncidents: base.recentIncidents,
                incidentDays: base.incidentDays,
                incidentAdjustedUptimePercent: base.incidentAdjustedUptimePercent
            )
        }
        // Ordering is Grok, Cursor, Grok Bot: the two sub-providers with their
        // own status page first, then the one that only happens to be
        // published on Cursor's.
        return base.mergingSubProvider(
            cursor,
            groupID: "subprovider:cursor",
            groupName: "Cursor",
            breakouts: [
                SubProviderBreakout(
                    id: "subprovider:grok-bot",
                    name: "Grok Bot",
                    componentNames: ["Grok Bot"]
                )
            ]
        )
    }

    /// Gemini Web and AntiGravity poll the same Google AI feed. Prefer the
    /// worse effective state (including open incidents), then the newer cache.
    public static func preferredGoogleAI(
        gemini: ServiceStatusSnapshot?,
        antigravity: ServiceStatusSnapshot?
    ) -> ServiceStatusSnapshot? {
        guard let gemini else { return antigravity }
        guard let antigravity else { return gemini }
        if gemini.effectiveIndicator.severity != antigravity.effectiveIndicator.severity {
            return gemini.effectiveIndicator.severity > antigravity.effectiveIndicator.severity
                ? gemini
                : antigravity
        }
        return gemini.updatedAt >= antigravity.updatedAt ? gemini : antigravity
    }
}
