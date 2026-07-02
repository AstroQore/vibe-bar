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

    /// Uptime the card should display: the incident-adjusted number when the
    /// provider's incident feed dented it, otherwise the official aggregate.
    public var displayUptimePercent: Double {
        guard let adjusted = incidentAdjustedUptimePercent else { return aggregateUptimePercent }
        return min(adjusted, aggregateUptimePercent)
    }

    /// Indicator with unresolved incidents folded in. Anthropic sometimes
    /// keeps `status.indicator == none` while an incident is still open, so
    /// the badge must not claim "All Systems Operational" in that state.
    public var effectiveIndicator: StatusIndicator {
        let unresolvedWorst = recentIncidents
            .filter { !$0.isResolved }
            .map { Self.indicator(for: $0.impact) }
            .max { $0.severity < $1.severity }
        guard let unresolvedWorst else { return indicator }
        return unresolvedWorst.severity > indicator.severity ? unresolvedWorst : indicator
    }

    /// Badge text override when `effectiveIndicator` outranks the page's own
    /// indicator (i.e. an open incident the page hasn't acknowledged).
    public var effectiveDescription: String {
        guard effectiveIndicator.severity > indicator.severity else { return description }
        switch effectiveIndicator {
        case .none:        return description
        case .maintenance: return "Under maintenance"
        case .minor:       return "Active incident"
        case .major:       return "Partial outage"
        case .critical:    return "Major outage"
        }
    }

    private static func indicator(for impact: IncidentImpact) -> StatusIndicator {
        switch impact {
        case .none:        return .none
        case .maintenance: return .maintenance
        case .minor:       return .minor
        case .major:       return .major
        case .critical:    return .critical
        }
    }

    public func components(in group: ServiceComponentGroup?) -> [ServiceComponentSummary] {
        if let group {
            return components.filter { $0.groupId == group.id }
        } else {
            return components.filter { $0.groupId == nil }
        }
    }
}
