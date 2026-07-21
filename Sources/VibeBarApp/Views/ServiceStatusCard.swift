import SwiftUI
import AppKit
import VibeBarCore

struct ServiceStatusCard: View {
    let tools: [ToolType]
    let density: Theme.Density

    @EnvironmentObject var environment: AppEnvironment
    @EnvironmentObject var serviceStatus: ServiceStatusController

    init(
        tools: [ToolType] = ToolType.allCases.filter(\.supportsStatusPage),
        density: Theme.Density
    ) {
        // Misc providers don't expose Atlassian-style status pages, so
        // they never belong in this card. Default to the providers
        // that actually publish a status feed; callers can still pass
        // an explicit subset (e.g. just `.codex` or `.claude`).
        self.tools = tools.filter(\.supportsStatusPage)
        self.density = density
    }

    var body: some View {
        VStack(alignment: .leading, spacing: density.statusGroupSpacing) {
            HStack(alignment: .firstTextBaseline) {
                Text("Service Status")
                    .font(.system(size: density.bucketTitleFontSize, weight: .semibold))
                Spacer()
                if let last = serviceStatus.lastFetched {
                    Text(timeAgo(last))
                        .font(.system(size: density.resetCountdownFontSize))
                        .foregroundStyle(.tertiary)
                }
                BorderlessIconButton(systemImage: "arrow.clockwise", help: "Refresh service status") {
                    serviceStatus.refreshAll()
                }
            }

            VStack(spacing: density.statusGroupSpacing + 4) {
                ForEach(tools, id: \.self) { tool in
                    ServiceStatusRow(tool: tool, density: density)
                }
            }
        }
        .padding(density.cardPadding)
        .background(
            RoundedRectangle(cornerRadius: density.cardCornerRadius, style: .continuous)
                .fill(.background.tertiary.opacity(0.6))
        )
        .overlay(
            RoundedRectangle(cornerRadius: density.cardCornerRadius, style: .continuous)
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
    let density: Theme.Density

    @EnvironmentObject var serviceStatus: ServiceStatusController

    var body: some View {
        let snapshot = serviceStatus.snapshotByTool[tool]
        let inFlight = serviceStatus.inFlight.contains(tool)
        let error = serviceStatus.errorByTool[tool]

        VStack(alignment: .leading, spacing: density.statusComponentSpacing + 2) {
            HStack(alignment: .center, spacing: 8) {
                ToolBrandBadge(
                    tool: tool,
                    iconSize: density.bucketTitleFontSize + 3,
                    containerSize: density.bucketTitleFontSize + 10
                )
                Text(displayName)
                    .font(.system(size: density.bucketTitleFontSize, weight: .semibold))
                StatusPill(
                    indicator: snapshot?.effectiveIndicator,
                    description: snapshot?.effectiveDescription,
                    density: density
                )
                Spacer(minLength: 6)
                if inFlight {
                    ProgressView().controlSize(.mini)
                }
                if let snapshot {
                    let agg = snapshot.displayUptimePercent
                    if agg > 0 {
                        Text(String(format: "%.2f%% uptime", agg))
                            .font(.system(size: density.resetCountdownFontSize, weight: .medium, design: .rounded).monospacedDigit())
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
                    .font(.system(size: density.resetCountdownFontSize))
                    .foregroundStyle(.orange)
                    .lineLimit(2)
            } else if let snapshot, let latest = snapshot.recentIncidents.first {
                IncidentRow(incident: latest, density: density)
            } else if snapshot != nil {
                Text("No incidents in the last 90 days")
                    .font(.system(size: density.resetCountdownFontSize))
                    .foregroundStyle(.tertiary)
            }
        }
    }

    @ViewBuilder
    private func groupedComponents(_ snapshot: ServiceStatusSnapshot) -> some View {
        // Default-expand most provider component groups so the
        // per-region rows are visible without an extra click. The one
        // carve-out is OpenAI: its status page has APIs / ChatGPT /
        // Codex / FedRAMP groups, and AQ only cares about Codex on
        // this app, so we open just that one and let the user click
        // through to APIs / ChatGPT / FedRAMP if they want. Claude /
        // Google / xAI keep the all-expanded behaviour.
        if snapshot.groups.isEmpty {
            ComponentGroupBlock(
                title: "Components",
                components: snapshot.components,
                density: density,
                defaultExpanded: defaultExpanded(forGroupName: "Components")
            )
        } else {
            VStack(alignment: .leading, spacing: density.statusGroupSpacing) {
                ForEach(snapshot.groups) { group in
                    let comps = snapshot.components(in: group)
                    if !comps.isEmpty {
                        ComponentGroupBlock(
                            title: group.name,
                            components: comps,
                            density: density,
                            defaultExpanded: defaultExpanded(forGroupName: group.name)
                        )
                    }
                }
                // Ungrouped components go last: they're usually brand-new
                // entries the provider hasn't filed yet (e.g. OpenAI's Ads
                // API / Ads Manager showed up ungrouped in 2026-07) and
                // shouldn't push the groups AQ actually watches below the
                // fold.
                let ungrouped = snapshot.components(in: nil)
                if !ungrouped.isEmpty {
                    ComponentGroupBlock(
                        title: "Other",
                        components: ungrouped,
                        density: density,
                        defaultExpanded: false
                    )
                }
            }
        }
    }

    /// Per-tool selective default-expand rule. Codex page opens only
    /// the "Codex" group; everything else opens every group.
    private func defaultExpanded(forGroupName name: String) -> Bool {
        if density.profile == .compact { return false }
        if density.profile == .spacious { return true }
        if tool == .codex {
            return name.localizedCaseInsensitiveContains("codex")
        }
        return true
    }

    /// Service Status rows now render at the L1 vendor level
    /// (`tool.statusProviderName`), so `.gemini` reads "Google" in
    /// line with the rest of the hierarchy. The old "Google AI"
    /// override predated the unified L1/L2/L3 catalog.
    private var displayName: String {
        tool.statusProviderName
    }
}

private struct ComponentGroupBlock: View {
    let title: String
    let components: [ServiceComponentSummary]
    let density: Theme.Density
    /// Provider-level incident overlay (see `ServiceStatusSnapshot.incidentDays`)
    /// — merged into the summary strip so incident-only providers
    /// (Anthropic) don't render an all-green wall next to their own
    /// incident footer.
    let incidentDays: [DayUptime]?
    let incidentAdjustedUptime: Double?
    @State private var expanded: Bool

    init(
        title: String,
        components: [ServiceComponentSummary],
        density: Theme.Density,
        defaultExpanded: Bool = false,
        incidentDays: [DayUptime]? = nil,
        incidentAdjustedUptime: Double? = nil
    ) {
        self.title = title
        self.components = components
        self.density = density
        self.incidentDays = incidentDays
        self.incidentAdjustedUptime = incidentAdjustedUptime
        self._expanded = State(initialValue: defaultExpanded)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: density.statusComponentSpacing) {
            BorderlessRowButton(action: {
                withAnimation(.easeInOut(duration: 0.18)) { expanded.toggle() }
            }) {
                HStack(spacing: 6) {
                    Image(systemName: statusIcon)
                        .font(.system(size: density.resetCountdownFontSize, weight: .semibold))
                        .foregroundStyle(componentColor(aggregateStatus))
                    Text(title)
                        .font(.system(size: density.subtitleFontSize, weight: .semibold))
                        .foregroundStyle(.primary)
                    Text("\(components.count) component\(components.count == 1 ? "" : "s")")
                        .font(.system(size: density.resetCountdownFontSize))
                        .foregroundStyle(.secondary)
                    Image(systemName: expanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 6)
                    if let uptime = aggregateUptime {
                        Text(String(format: "%.2f%% uptime", uptime))
                            .font(.system(size: density.resetCountdownFontSize, weight: .medium, design: .rounded).monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
            }

            if !summaryDays.isEmpty {
                UptimeStrip(days: summaryDays, currentImpact: impact(for: aggregateStatus))
                    .frame(height: density.statusStripHeight)
            } else {
                Capsule()
                    .fill(Color.primary.opacity(0.05))
                    .frame(height: 6)
            }

            if expanded {
                VStack(alignment: .leading, spacing: density.statusComponentSpacing) {
                    ForEach(components) { component in
                        ComponentBar(component: component, density: density)
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
        guard !values.isEmpty else { return incidentAdjustedUptime }
        let official = values.reduce(0, +) / Double(values.count)
        guard let adjusted = incidentAdjustedUptime else { return official }
        return min(official, adjusted)
    }

    private var summaryDays: [DayUptime] {
        var dates: Set<Date> = []
        var impactByDate: [Date: IncidentImpact] = [:]
        var mergeDay: (DayUptime) -> Void = { _ in }
        mergeDay = { day in
            dates.insert(day.date)
            guard let impact = day.worstImpact else { return }
            if let existing = impactByDate[day.date] {
                impactByDate[day.date] = worseImpact(existing, impact)
            } else {
                impactByDate[day.date] = impact
            }
        }
        for component in components {
            for day in component.recentDays {
                mergeDay(day)
            }
        }
        for day in incidentDays ?? [] {
            mergeDay(day)
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
    let density: Theme.Density

    var body: some View {
        VStack(alignment: .leading, spacing: max(3, density.statusComponentSpacing - 2)) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: statusIcon)
                    .font(.system(size: density.resetCountdownFontSize, weight: .semibold))
                    .foregroundStyle(componentColor(component.status))
                Text(component.name)
                    .font(.system(size: density.subtitleFontSize, weight: .medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 4)
                if component.status != .operational {
                    Text(componentLabel(component.status))
                        .font(.system(size: max(8, density.resetCountdownFontSize - 1), weight: .semibold))
                        .foregroundStyle(componentColor(component.status))
                }
                if let uptime = component.uptimePercent {
                    Text(String(format: "%.2f%% uptime", uptime))
                        .font(.system(size: max(8, density.resetCountdownFontSize - 1), weight: .medium, design: .rounded).monospacedDigit())
                        .foregroundStyle(.tertiary)
                }
            }
            if !component.recentDays.isEmpty {
                UptimeStrip(days: component.recentDays, currentImpact: currentImpact)
                    .frame(height: density.statusStripHeight)
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
    let density: Theme.Density

    var body: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(color)
                .frame(width: 6, height: 6)
            Text(text)
                .font(.system(size: density.resetCountdownFontSize, weight: .medium))
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
        Canvas { context, size in
            guard !days.isEmpty else { return }
            let gap: CGFloat = 1
            let count = days.count
            let totalGap = CGFloat(count - 1) * gap
            let cellWidth = max((size.width - totalGap) / CGFloat(count), 1)

            for (index, day) in days.enumerated() {
                let isToday = index == count - 1
                let impact = isToday ? (currentImpact ?? day.worstImpact) : day.worstImpact
                let rect = CGRect(
                    x: CGFloat(index) * (cellWidth + gap),
                    y: 0,
                    width: cellWidth,
                    height: size.height
                )
                context.fill(
                    Path(roundedRect: rect, cornerRadius: 1.2),
                    with: .color(uptimeColor(for: impact))
                )
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Service uptime over the last \(days.count) days")
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
    let density: Theme.Density

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: incident.isResolved ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .font(.system(size: density.resetCountdownFontSize, weight: .semibold))
                .foregroundStyle(incident.isResolved ? .secondary : impactColor(incident.impact))
            Text(incident.name)
                .font(.system(size: density.resetCountdownFontSize))
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
