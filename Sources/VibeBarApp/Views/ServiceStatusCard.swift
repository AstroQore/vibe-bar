import SwiftUI
import AppKit
import VibeBarCore

struct ServiceStatusCard: View {
    let tools: [ToolType]

    @EnvironmentObject var environment: AppEnvironment
    @EnvironmentObject var serviceStatus: ServiceStatusController

    init(tools: [ToolType] = ToolType.allCases.filter(\.supportsStatusPage)) {
        // Misc providers don't expose Atlassian-style status pages, so
        // they never belong in this card. Default to the providers
        // that actually publish a status feed; callers can still pass
        // an explicit subset (e.g. just `.codex` or `.claude`).
        self.tools = tools.filter(\.supportsStatusPage)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text("Service Status")
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                if let last = serviceStatus.lastFetched {
                    Text(timeAgo(last))
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                }
                BorderlessIconButton(systemImage: "arrow.clockwise", help: "Refresh service status") {
                    serviceStatus.refreshAll()
                }
            }

            VStack(spacing: 16) {
                ForEach(tools, id: \.self) { tool in
                    ServiceStatusRow(tool: tool)
                }
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: Theme.sectionCornerRadius, style: .continuous)
                .fill(.background.tertiary.opacity(0.6))
        )
        .overlay(
            RoundedRectangle(cornerRadius: Theme.sectionCornerRadius, style: .continuous)
                .stroke(.separator.opacity(0.5), lineWidth: 0.5)
        )
    }

    private func timeAgo(_ date: Date) -> String {
        let seconds = Int(Date().timeIntervalSince(date))
        if seconds < 60 { return "updated just now" }
        if seconds < 3600 { return "updated \(seconds / 60)m ago" }
        return "updated \(seconds / 3600)h ago"
    }
}

private struct ServiceStatusRow: View {
    let tool: ToolType

    @EnvironmentObject var serviceStatus: ServiceStatusController

    var body: some View {
        let snapshot = serviceStatus.snapshotByTool[tool]
        let inFlight = serviceStatus.inFlight.contains(tool)
        let error = serviceStatus.errorByTool[tool]

        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 8) {
                ToolBrandBadge(tool: tool, iconSize: 17, containerSize: 24)
                Text(tool.statusProviderName)
                    .font(.system(size: 13, weight: .semibold))
                StatusPill(indicator: snapshot?.indicator, description: snapshot?.description)
                Spacer(minLength: 6)
                if inFlight {
                    ProgressView().controlSize(.mini)
                }
                if let snapshot {
                    let agg = snapshot.aggregateUptimePercent
                    if agg > 0 {
                        Text(String(format: "%.2f%% uptime", agg))
                            .font(.system(size: 10, weight: .medium, design: .rounded).monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
                BorderlessIconButton(systemImage: "arrow.up.right.square", help: "Open \(tool.statusPageURL.host ?? "status page")") {
                    NSWorkspace.shared.open(tool.statusPageURL)
                }
            }

            if let snapshot {
                groupedComponents(snapshot)
            } else if error != nil {
                Capsule()
                    .fill(Color.primary.opacity(0.06))
                    .frame(height: 6)
            }

            if let error {
                Text(error)
                    .font(.system(size: 10))
                    .foregroundStyle(.orange)
                    .lineLimit(2)
            } else if let snapshot, let latest = snapshot.recentIncidents.first {
                IncidentRow(incident: latest)
            } else if snapshot != nil {
                Text("No incidents in the last 90 days")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }
        }
    }

    @ViewBuilder
    private func groupedComponents(_ snapshot: ServiceStatusSnapshot) -> some View {
        if snapshot.groups.isEmpty {
            ComponentGroupBlock(
                title: "Components",
                components: snapshot.components,
                defaultExpanded: shouldExpandFlatComponents
            )
        } else {
            VStack(alignment: .leading, spacing: 12) {
                let ungrouped = snapshot.components(in: nil)
                if !ungrouped.isEmpty {
                    ComponentGroupBlock(title: "Other", components: ungrouped, defaultExpanded: false)
                }
                ForEach(snapshot.groups) { group in
                    let comps = snapshot.components(in: group)
                    if !comps.isEmpty {
                        ComponentGroupBlock(
                            title: group.name,
                            components: comps,
                            defaultExpanded: shouldExpand(group)
                        )
                    }
                }
            }
        }
    }

    private var shouldExpandFlatComponents: Bool {
        tool == .claude
    }

    private func shouldExpand(_ group: ServiceComponentGroup) -> Bool {
        tool == .codex && group.name.localizedCaseInsensitiveContains("codex")
    }
}

private struct ComponentGroupBlock: View {
    let title: String
    let components: [ServiceComponentSummary]
    @State private var expanded: Bool

    init(
        title: String,
        components: [ServiceComponentSummary],
        defaultExpanded: Bool = false
    ) {
        self.title = title
        self.components = components
        self._expanded = State(initialValue: defaultExpanded)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            BorderlessRowButton(action: {
                withAnimation(.easeInOut(duration: 0.18)) { expanded.toggle() }
            }) {
                HStack(spacing: 6) {
                    Image(systemName: statusIcon)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(componentColor(aggregateStatus))
                    Text(title)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.primary)
                    Text("\(components.count) component\(components.count == 1 ? "" : "s")")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                    Image(systemName: expanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 6)
                    if let uptime = aggregateUptime {
                        Text(String(format: "%.2f%% uptime", uptime))
                            .font(.system(size: 10, weight: .medium, design: .rounded).monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
            }

            if !summaryDays.isEmpty {
                UptimeStrip(days: summaryDays, currentImpact: impact(for: aggregateStatus))
                    .frame(height: 12)
            } else {
                Capsule()
                    .fill(Color.primary.opacity(0.05))
                    .frame(height: 6)
            }

            if expanded {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(components) { component in
                        ComponentBar(component: component)
                    }
                }
                .padding(.leading, 4)
            }
        }
    }

    private var aggregateStatus: ComponentStatusLevel {
        components.max(by: { $0.status.severity < $1.status.severity })?.status ?? .operational
    }

    private var aggregateUptime: Double? {
        let values = components.compactMap(\.uptimePercent)
        guard !values.isEmpty else { return nil }
        return values.reduce(0, +) / Double(values.count)
    }

    private var summaryDays: [DayUptime] {
        var dates: Set<Date> = []
        var impactByDate: [Date: IncidentImpact] = [:]
        for component in components {
            for day in component.recentDays {
                dates.insert(day.date)
                guard let impact = day.worstImpact else { continue }
                if let existing = impactByDate[day.date] {
                    impactByDate[day.date] = worseImpact(existing, impact)
                } else {
                    impactByDate[day.date] = impact
                }
            }
        }
        return dates.sorted().map { date in
            DayUptime(date: date, worstImpact: impactByDate[date])
        }
    }

    private var statusIcon: String {
        switch aggregateStatus {
        case .operational:         return "checkmark.circle.fill"
        case .underMaintenance:    return "wrench.and.screwdriver.fill"
        case .degradedPerformance: return "exclamationmark.circle.fill"
        case .partialOutage:       return "exclamationmark.triangle.fill"
        case .majorOutage:         return "xmark.octagon.fill"
        }
    }
}

private struct ComponentBar: View {
    let component: ServiceComponentSummary

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: statusIcon)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(componentColor(component.status))
                Text(component.name)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 4)
                if component.status != .operational {
                    Text(componentLabel(component.status))
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(componentColor(component.status))
                }
                if let uptime = component.uptimePercent {
                    Text(String(format: "%.2f%% uptime", uptime))
                        .font(.system(size: 9, weight: .medium, design: .rounded).monospacedDigit())
                        .foregroundStyle(.tertiary)
                }
            }
            if !component.recentDays.isEmpty {
                UptimeStrip(days: component.recentDays, currentImpact: currentImpact)
                    .frame(height: 12)
            } else {
                Capsule()
                    .fill(Color.primary.opacity(0.05))
                    .frame(height: 6)
            }
        }
    }

    private var statusIcon: String {
        switch component.status {
        case .operational:         return "checkmark.circle.fill"
        case .underMaintenance:    return "wrench.and.screwdriver.fill"
        case .degradedPerformance: return "exclamationmark.circle.fill"
        case .partialOutage:       return "exclamationmark.triangle.fill"
        case .majorOutage:         return "xmark.octagon.fill"
        }
    }

    private var currentImpact: IncidentImpact? {
        impact(for: component.status)
    }
}

private func impact(for status: ComponentStatusLevel) -> IncidentImpact? {
    switch status {
    case .operational:         return nil
    case .underMaintenance:    return .maintenance
    case .degradedPerformance: return .minor
    case .partialOutage:       return .major
    case .majorOutage:         return .critical
    }
}

private func worseImpact(_ lhs: IncidentImpact, _ rhs: IncidentImpact) -> IncidentImpact {
    lhs.severity >= rhs.severity ? lhs : rhs
}

private func componentColor(_ status: ComponentStatusLevel) -> Color {
    switch status {
    case .operational:         return .green
    case .underMaintenance:    return .blue
    case .degradedPerformance: return .yellow
    case .partialOutage:       return .orange
    case .majorOutage:         return .red
    }
}

private func componentLabel(_ status: ComponentStatusLevel) -> String {
    switch status {
    case .operational:         return "Operational"
    case .underMaintenance:    return "Maintenance"
    case .degradedPerformance: return "Degraded"
    case .partialOutage:       return "Partial Outage"
    case .majorOutage:         return "Major Outage"
    }
}

private struct StatusPill: View {
    let indicator: StatusIndicator?
    let description: String?

    var body: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(color)
                .frame(width: 6, height: 6)
            Text(text)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 2)
        .background(
            Capsule().fill(color.opacity(0.15))
        )
    }

    private var color: Color {
        switch indicator {
        case .none?, nil:    return .green
        case .maintenance?:  return .blue
        case .minor?:        return .yellow
        case .major?:        return .orange
        case .critical?:     return .red
        }
    }

    private var text: String {
        if let description, !description.isEmpty { return description }
        switch indicator {
        case .none?, nil:    return "Loading"
        case .maintenance?:  return "Maintenance"
        case .minor?:        return "Minor"
        case .major?:        return "Major"
        case .critical?:     return "Critical"
        }
    }
}

private struct UptimeStrip: View {
    let days: [DayUptime]
    let currentImpact: IncidentImpact?

    var body: some View {
        GeometryReader { proxy in
            let count = max(days.count, 1)
            let totalGap = CGFloat(count - 1) * 1
            let cellWidth = max((proxy.size.width - totalGap) / CGFloat(count), 1)
            HStack(spacing: 1) {
                ForEach(Array(days.enumerated()), id: \.element.id) { index, day in
                    let isToday = index == count - 1
                    let impact = isToday ? (currentImpact ?? day.worstImpact) : day.worstImpact
                    RoundedRectangle(cornerRadius: 1.2, style: .continuous)
                        .fill(uptimeColor(for: impact))
                        .frame(width: cellWidth)
                }
            }
        }
    }
}

private func uptimeColor(for impact: IncidentImpact?) -> Color {
    switch impact {
    case nil:                return Color.green.opacity(0.85)
    case .none?:             return Color.green.opacity(0.85)
    case .maintenance?:      return Color.blue.opacity(0.65)
    case .minor?:            return Color.yellow
    case .major?:            return Color.orange
    case .critical?:         return Color.red
    }
}

private struct IncidentRow: View {
    let incident: IncidentSummary

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: incident.isResolved ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(incident.isResolved ? .secondary : impactColor(incident.impact))
            Text(incident.name)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .lineLimit(2)
            Spacer(minLength: 4)
            if let url = incident.url {
                BorderlessIconButton(systemImage: "arrow.up.right", help: "Open incident", size: 9) {
                    NSWorkspace.shared.open(url)
                }
            }
        }
    }
}

private func impactColor(_ impact: IncidentImpact) -> Color {
    switch impact {
    case .none, .maintenance: return .blue
    case .minor:              return .yellow
    case .major:              return .orange
    case .critical:           return .red
    }
}
