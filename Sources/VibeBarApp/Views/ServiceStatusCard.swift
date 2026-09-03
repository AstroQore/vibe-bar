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
        var filtered = tools.filter(\.supportsStatusPage)
        if filtered.contains(.grok) {
            // Cursor is a SubProvider group inside SpaceXAI, not a duplicate
            // top-level company row.
            filtered.removeAll { $0 == .cursor }
        }
        self.tools = filtered
        self.density = density
    }

    var body: some View {
        VStack(alignment: .leading, spacing: density.statusGroupSpacing) {
            HStack(alignment: .firstTextBaseline) {
                Text(L10n.Status.cardTitle)
                    .font(.system(size: density.bucketTitleFontSize, weight: .semibold))
                Spacer()
                if let last = serviceStatus.lastFetched {
                    Text(timeAgo(last))
                        .font(.system(size: density.resetCountdownFontSize))
                        .foregroundStyle(.tertiary)
                }
                BorderlessIconButton(systemImage: "arrow.clockwise", help: L10n.Status.cardRefresh) {
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
        if seconds < 60 { return L10n.Status.cardUpdatedJustNow }
        if seconds < 3600 { return L10n.Status.cardUpdatedMinutesAgo(minutes: seconds / 60) }
        return L10n.Status.cardUpdatedHoursAgo(hours: seconds / 3600)
    }
}

private struct ServiceStatusRow: View {
    let tool: ToolType
    let density: Theme.Density

    @EnvironmentObject var serviceStatus: ServiceStatusController

    var body: some View {
        let projection = serviceStatus.projection(for: tool)
        let snapshot = projection.snapshot
        let inFlight = projection.isRefreshing
        let error = projection.error

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
                        Text(L10n.Status.cardUptime(percent: String(format: "%.2f%%", agg)))
                            .font(.system(size: density.resetCountdownFontSize, weight: .medium, design: .rounded).monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
                BorderlessIconButton(systemImage: "arrow.up.right.square", help: L10n.Status.cardOpenStatusPage(
                    host: tool.statusPageURL.host ?? L10n.Status.cardStatusPageFallback
                )) {
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
                Text(L10n.Status.cardNoIncidents)
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
        // Google AI / SpaceXAI keep the all-expanded behaviour.
        if snapshot.groups.isEmpty {
            ComponentGroupBlock(
                title: L10n.Status.cardComponents,
                components: snapshot.components,
                density: density,
                // The group *name* stays English: `defaultExpanded` matches on
                // what the provider's status page calls the group, which is
                // data, not copy.
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
                        title: L10n.Status.componentOther,
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

    /// Service Status rows render at the L1 company/brand level.
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
        // `aggregateStatus` walks every component and `summaryDays` merges
        // ~90 days per component through a set and a dictionary; the header,
        // the icon and the strip each used to ask for them again. One
        // derivation each per pass, reused below.
        let status = aggregateStatus
        let days = summaryDays
        VStack(alignment: .leading, spacing: density.statusComponentSpacing) {
            BorderlessRowButton(action: {
                withAnimation(.easeInOut(duration: 0.18)) { expanded.toggle() }
            }) {
                HStack(spacing: 6) {
                    Image(systemName: Self.statusIcon(for: status))
                        .font(.system(size: density.resetCountdownFontSize, weight: .semibold))
                        .foregroundStyle(componentColor(status))
                    Text(title)
                        .font(.system(size: density.subtitleFontSize, weight: .semibold))
                        .foregroundStyle(.primary)
                    Text(L10n.Status.cardComponentCount(count: components.count))
                        .font(.system(size: density.resetCountdownFontSize))
                        .foregroundStyle(.secondary)
                    Image(systemName: expanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 6)
                    if let uptime = aggregateUptime {
                        Text(L10n.Status.cardUptime(percent: String(format: "%.2f%%", uptime)))
                            .font(.system(size: density.resetCountdownFontSize, weight: .medium, design: .rounded).monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
            }

            if !days.isEmpty {
                UptimeStrip(days: days, currentImpact: impact(for: status))
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

    /// Takes the already-derived status so `body` doesn't recompute the
    /// aggregate just to pick a glyph.
    private static func statusIcon(for status: ComponentStatusLevel) -> String {
        switch status {
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
                    Text(L10n.Status.cardUptime(percent: String(format: "%.2f%%", uptime)))
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
    case .operational:         return L10n.Status.componentOperational
    case .underMaintenance:    return L10n.Status.componentMaintenance
    case .degradedPerformance: return L10n.Status.componentDegraded
    case .partialOutage:       return L10n.Status.componentPartialOutage
    case .majorOutage:         return L10n.Status.componentMajorOutage
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
        case .none?, nil:    return L10n.Status.indicatorLoading
        case .maintenance?:  return L10n.Status.indicatorMaintenance
        case .minor?:        return L10n.Status.indicatorMinor
        case .major?:        return L10n.Status.indicatorMajor
        case .critical?:     return L10n.Status.indicatorCritical
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
        .accessibilityLabel(L10n.Status.cardUptimeStrip(days: days.count))
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
                BorderlessIconButton(systemImage: "arrow.up.right", help: L10n.Status.cardOpenIncident, size: 9) {
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
