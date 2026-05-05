import SwiftUI
import VibeBarCore

struct MiniQuotaWindowView: View {
    let onClose: () -> Void
    let onToggleDisplayMode: () -> Void

    @EnvironmentObject var environment: AppEnvironment
    @EnvironmentObject var settingsStore: SettingsStore

    var body: some View {
        let contentByTool = miniContentByTool
        let visibleTools = ToolType.allCases.filter { tool in
            contentByTool[tool]?.isEmpty == false
        }
        let displayMode = settingsStore.settings.miniWindow.displayMode

        ZStack(alignment: .topTrailing) {
            MiniWindowProviderLayout(
                displayMode: displayMode,
                visibleTools: visibleTools,
                contentByTool: contentByTool
            )
            .padding(.horizontal, displayMode == .compact ? 8 : 14)
            .padding(.top, displayMode == .compact ? 16 : 22)
            .padding(.bottom, displayMode == .compact ? 9 : 14)
            .frame(maxWidth: .infinity, alignment: .center)
            .contentShape(Rectangle())
            .onTapGesture(count: 2, perform: onToggleDisplayMode)

            Button(action: onClose) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .padding(.top, 6)
            .padding(.trailing, 8)
        }
        .fixedSize(horizontal: true, vertical: true)
        .glassEffect(.clear, in: .rect(cornerRadius: Theme.miniCornerRadius))
    }

    private var miniContentByTool: [ToolType: MiniToolContent] {
        let mini = settingsStore.settings.miniWindow
        let selected = mini.fieldIds(for: mini.displayMode)
        let selectedFieldIds = Set(selected)
        var contentByTool: [ToolType: MiniToolContent] = [:]
        for tool in ToolType.allCases {
            var cells: [MiniCell] = []
            for fieldId in selected {
                guard
                    let field = MenuBarFieldCatalog.field(id: fieldId),
                    field.tool == tool
                else { continue }
                let liveBucket = environment.quota(for: tool)?.bucket(id: field.bucketId)
                if liveBucket?.groupTitle != nil || isBranchField(field) {
                    continue
                }
                cells.append(
                    MiniCell(
                        tool: tool,
                        field: field,
                        bucket: liveBucket,
                        customLabel: settingsStore.settings.miniWindow.customLabels[field.id]
                    )
                )
            }
            let selectedBucketIds = Set(cells.map { $0.field.bucketId })
            let branchCells = branchCells(
                for: tool,
                selectedFieldIds: selectedFieldIds,
                excluding: selectedBucketIds
            )
            let content = MiniToolContent(primaryCells: cells, branchCells: branchCells)
            if !content.isEmpty { contentByTool[tool] = content }
        }
        return contentByTool
    }

    private func isBranchField(_ field: MenuBarFieldOption) -> Bool {
        switch field.bucketId {
        case "gpt_5_3_codex_spark_five_hour",
             "gpt_5_3_codex_spark_weekly",
             "weekly_sonnet",
             "weekly_design",
             "daily_routines",
             "weekly_opus",
             "weekly_oauth_apps":
            return true
        default:
            return false
        }
    }

    private func branchCells(
        for tool: ToolType,
        selectedFieldIds: Set<String>,
        excluding selectedBucketIds: Set<String>
    ) -> [MiniBranchCell] {
        guard let quota = environment.quota(for: tool) else { return [] }
        return quota.buckets.compactMap { bucket in
            let fieldId = MenuBarFieldCatalog.fieldId(tool: tool, bucketId: bucket.id)
            guard
                selectedFieldIds.contains(fieldId),
                let field = MenuBarFieldCatalog.field(id: fieldId),
                !selectedBucketIds.contains(bucket.id),
                let rawGroup = bucket.groupTitle?.trimmingCharacters(in: .whitespacesAndNewlines),
                !rawGroup.isEmpty
            else { return nil }
            return MiniBranchCell(
                tool: tool,
                field: field,
                bucket: bucket,
                customLabel: settingsStore.settings.miniWindow.customLabels[field.id]
            )
        }
    }
}

private struct MiniWindowProviderLayout: View {
    let displayMode: MiniWindowDisplayMode
    let visibleTools: [ToolType]
    let contentByTool: [ToolType: MiniToolContent]

    var body: some View {
        HStack(alignment: .top, spacing: displayMode == .compact ? 8 : 14) {
            ForEach(Array(visibleTools.enumerated()), id: \.element) { index, tool in
                if let content = contentByTool[tool], !content.isEmpty {
                    if index > 0 {
                        MiniProviderDivider(height: displayMode == .compact ? 82 : 116)
                            .padding(.top, 2)
                    }
                    switch displayMode {
                    case .regular:
                        MiniProviderColumn(
                            tool: tool,
                            primaryCells: content.primaryCells,
                            branchCells: content.branchCells
                        )
                    case .compact:
                        MiniCompactProviderColumn(
                            tool: tool,
                            primaryCells: content.primaryCells,
                            branchCells: content.branchCells
                        )
                    }
                }
            }
        }
    }
}

private struct MiniToolContent {
    let primaryCells: [MiniCell]
    let branchCells: [MiniBranchCell]

    var isEmpty: Bool {
        primaryCells.isEmpty && branchCells.isEmpty
    }
}

private struct MiniCell: Identifiable {
    let tool: ToolType
    let field: MenuBarFieldOption
    let bucket: QuotaBucket?
    let customLabel: String?

    var id: String { "\(tool.rawValue).\(field.id)" }

    var resolvedLabel: String {
        if let trimmed = customLabel?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty {
            return trimmed
        }
        if let bucket, field.defaultLabel != bucket.shortLabel {
            return bucket.shortLabel
        }
        return field.defaultLabel
    }
}

private struct MiniBranchCell: Identifiable {
    let tool: ToolType
    let field: MenuBarFieldOption
    let bucket: QuotaBucket
    let customLabel: String?

    var id: String { "\(tool.rawValue).branch.\(bucket.id)" }

    var title: String {
        if let trimmed = customLabel?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty {
            return trimmed
        }
        return defaultTitle
    }

    private var defaultTitle: String {
        switch bucket.id {
        case "gpt_5_3_codex_spark_five_hour": return "5h"
        case "gpt_5_3_codex_spark_weekly": return "wk"
        case "weekly_sonnet": return "wk"
        case "weekly_design": return "wk"
        case "daily_routines": return "Daily"
        case "weekly_opus": return "Opus"
        case "weekly_oauth_apps": return "OAuth"
        default:
            let group = bucket.groupTitle ?? bucket.shortLabel
            return group
                .replacingOccurrences(of: "GPT-5.3 Codex Spark", with: "Spark")
                .replacingOccurrences(of: "Daily Routines", with: "Routine")
        }
    }

    var groupKey: String {
        switch bucket.id {
        case "gpt_5_3_codex_spark_five_hour", "gpt_5_3_codex_spark_weekly":
            return "codex.spark"
        case "weekly_sonnet":
            return "claude.sonnet"
        case "weekly_design":
            return "claude.design"
        case "daily_routines":
            return "claude.routine"
        case "weekly_opus":
            return "claude.opus"
        case "weekly_oauth_apps":
            return "claude.oauth"
        default:
            return "\(tool.rawValue).\(field.bucketId)"
        }
    }

    var defaultGroupTitle: String {
        if let label = MiniWindowGroupLabelCatalog.defaultLabel(for: groupKey) {
            return label
        }
        switch bucket.id {
        case "gpt_5_3_codex_spark_five_hour", "gpt_5_3_codex_spark_weekly":
            return "Spark"
        case "weekly_sonnet":
            return "Sonnet"
        case "weekly_design":
            return "Design"
        case "daily_routines":
            return "Routine"
        case "weekly_opus":
            return "Opus"
        case "weekly_oauth_apps":
            return "OAuth"
        default:
            return (bucket.groupTitle ?? bucket.shortLabel)
                .replacingOccurrences(of: "GPT-5.3 Codex Spark", with: "Spark")
                .replacingOccurrences(of: "Daily Routines", with: "Routine")
        }
    }
}

private func providerAccent(for tool: ToolType) -> Color {
    switch tool {
    case .codex:  return Color(red: 0.30, green: 0.78, blue: 0.74)  // teal
    case .claude: return Color(red: 0.93, green: 0.40, blue: 0.40)  // coral
    }
}

private func providerTitle(for tool: ToolType) -> String {
    switch tool {
    case .codex:  return "CODEX"
    case .claude: return "CLAUDE"
    }
}

private struct MiniProviderDivider: View {
    var height: CGFloat

    var body: some View {
        Rectangle()
            .fill(Color.primary.opacity(0.055))
            .frame(width: 0.75, height: height)
    }
}

private enum MiniRingMetrics {
    static let cellWidth: CGFloat = 62
    static let ringSize: CGFloat = 48
    static let ringLineWidth: CGFloat = 5
    static let ringSpacing: CGFloat = 8
    static let labelHeight: CGFloat = 12
    static let paceHeight: CGFloat = 10
    static let resetHeight: CGFloat = 10
}

private struct MiniBranchGroup: Identifiable {
    let id: String
    let title: String
    var cells: [MiniBranchCell]
}

private func miniBranchGroups(
    from branchCells: [MiniBranchCell],
    settings: MiniWindowSettings
) -> [MiniBranchGroup] {
    var groups: [MiniBranchGroup] = []
    var indexByKey: [String: Int] = [:]
    for cell in branchCells {
        let key = cell.groupKey
        let title = miniGroupTitle(for: cell, settings: settings).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { continue }
        if let index = indexByKey[key] {
            groups[index].cells.append(cell)
        } else {
            indexByKey[key] = groups.count
            groups.append(MiniBranchGroup(id: key, title: title, cells: [cell]))
        }
    }
    return groups
}

private func miniGroupTitle(for cell: MiniBranchCell, settings: MiniWindowSettings) -> String {
    let custom = settings.groupLabels[cell.groupKey]?.trimmingCharacters(in: .whitespacesAndNewlines)
    if let custom, !custom.isEmpty {
        return custom
    }
    return cell.defaultGroupTitle
}

private struct MiniProviderColumn: View {
    let tool: ToolType
    let primaryCells: [MiniCell]
    let branchCells: [MiniBranchCell]

    @EnvironmentObject var settingsStore: SettingsStore

    var body: some View {
        VStack(alignment: .center, spacing: 7) {
            HStack(spacing: 4) {
                Circle()
                    .fill(providerAccent(for: tool))
                    .frame(width: 5, height: 5)
                Text(providerTitle(for: tool))
                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                    .foregroundStyle(.primary.opacity(0.86))
                    .tracking(0.2)
            }
            .frame(width: contentWidth, alignment: .center)

            HStack(alignment: .top, spacing: 8) {
                if !primaryCells.isEmpty {
                    MiniPrimaryRingGroup(cells: primaryCells)
                }
                ForEach(branchGroups) { group in
                    MiniGroupDivider()
                        .padding(.top, 15)
                    MiniBranchRingGroup(group: group)
                }
            }
        }
    }

    private var contentWidth: CGFloat {
        var width: CGFloat = 0
        var groupCount = 0
        if !primaryCells.isEmpty {
            width += CGFloat(primaryCells.count) * MiniRingMetrics.cellWidth
                + CGFloat(max(0, primaryCells.count - 1)) * MiniRingMetrics.ringSpacing
            groupCount += 1
        }
        for group in branchGroups {
            width += CGFloat(group.cells.count) * MiniRingMetrics.cellWidth
                + CGFloat(max(0, group.cells.count - 1)) * MiniRingMetrics.ringSpacing
            groupCount += 1
        }
        if groupCount > 1 {
            width += CGFloat(groupCount - 1) * 16.5
        }
        return width
    }

    private var branchGroups: [MiniBranchGroup] {
        miniBranchGroups(from: branchCells, settings: settingsStore.settings.miniWindow)
    }
}

private struct MiniPrimaryRingGroup: View {
    let cells: [MiniCell]

    var body: some View {
        MiniRingGroupShell(title: nil, width: groupWidth) {
            HStack(alignment: .top, spacing: MiniRingMetrics.ringSpacing) {
                ForEach(cells) { cell in
                    MiniRingCell(cell: cell)
                }
            }
        }
    }

    private var groupWidth: CGFloat {
        CGFloat(cells.count) * MiniRingMetrics.cellWidth
            + CGFloat(max(0, cells.count - 1)) * MiniRingMetrics.ringSpacing
    }
}

private struct MiniBranchRingGroup: View {
    let group: MiniBranchGroup

    var body: some View {
        MiniRingGroupShell(title: group.title, width: groupWidth) {
            HStack(alignment: .top, spacing: MiniRingMetrics.ringSpacing) {
                ForEach(group.cells) { cell in
                    MiniBranchRingCell(cell: cell)
                }
            }
        }
    }

    private var groupWidth: CGFloat {
        CGFloat(group.cells.count) * MiniRingMetrics.cellWidth
            + CGFloat(max(0, group.cells.count - 1)) * MiniRingMetrics.ringSpacing
    }
}

private struct MiniRingGroupShell<Content: View>: View {
    let title: String?
    let width: CGFloat
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(spacing: 5) {
            Group {
                if let title {
                    Text(title.uppercased())
                        .font(.system(size: 8.5, weight: .semibold, design: .rounded))
                        .foregroundStyle(.primary.opacity(0.58))
                        .tracking(2.2)
                        .lineLimit(1)
                        .minimumScaleFactor(0.65)
                } else {
                    Text(" ")
                        .font(.system(size: 8.5, weight: .semibold, design: .rounded))
                        .hidden()
                }
            }
            .frame(width: width, height: 10, alignment: .center)
            content()
        }
    }
}

private struct MiniBranchRingCell: View {
    let cell: MiniBranchCell

    @EnvironmentObject var settingsStore: SettingsStore

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            content(now: context.date)
        }
        .frame(width: MiniRingMetrics.cellWidth)
    }

    @ViewBuilder
    private func content(now: Date) -> some View {
        let pace = UsagePace.compute(bucket: cell.bucket, now: now)
        let percent = cell.bucket.displayPercent(settingsStore.displayMode)
        let color = Theme.barColor(percent: percent, mode: settingsStore.displayMode)
        VStack(spacing: 3) {
            let expected: Double? = pace.map { p in
                switch settingsStore.displayMode {
                case .used:      return p.expectedUsedPercent
                case .remaining: return 100 - p.expectedUsedPercent
                }
            }
            RingGauge(
                percent: percent,
                expected: expected,
                color: color,
                markerColor: paceColor(pace: pace),
                size: MiniRingMetrics.ringSize,
                lineWidth: MiniRingMetrics.ringLineWidth
            ) {
                Text(centerText(percent: percent))
                    .font(.system(size: 11, weight: .bold, design: .rounded).monospacedDigit())
                    .foregroundStyle(color)
                    .minimumScaleFactor(0.55)
                    .lineLimit(1)
            }
            Text(cell.title)
                .font(.system(size: 9, weight: .medium, design: .rounded))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .frame(height: MiniRingMetrics.labelHeight, alignment: .center)
            Text(paceLine(pace: pace, now: now))
                .font(.system(size: 8, weight: .medium, design: .rounded).monospacedDigit())
                .foregroundStyle(paceColor(pace: pace))
                .lineLimit(1)
                .minimumScaleFactor(0.62)
                .frame(height: MiniRingMetrics.paceHeight, alignment: .center)
            Text(resetText(now: now))
                .font(.system(size: 8, design: .rounded).monospacedDigit())
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .frame(height: MiniRingMetrics.resetHeight, alignment: .center)
        }
        .frame(width: MiniRingMetrics.cellWidth)
        .help("\(providerTitle(for: cell.tool)) · \(cell.bucket.groupTitle ?? cell.bucket.shortLabel) · \(cell.bucket.title)")
    }

    private func centerText(percent: Double) -> String {
        if cell.bucket.id == "daily_routines" {
            let label = cell.bucket.shortLabel.trimmingCharacters(in: .whitespacesAndNewlines)
            if label.contains("/") { return label }
            if cell.bucket.title.contains("--") { return "--" }
        }
        return "\(Int(percent.rounded()))%"
    }

    private func resetText(now: Date) -> String {
        ResetCountdownFormatter.string(from: cell.bucket.resetAt, now: now) ?? "—"
    }

    private func paceLine(pace: UsagePace?, now: Date) -> String {
        guard let pace else { return "" }
        switch pace.stage {
        case .onTrack:
            return ""
        case .slightlyBehind, .behind, .farBehind:
            return pace.stageSummary
        case .slightlyAhead, .ahead, .farAhead:
            if pace.willLastToReset { return pace.stageSummary }
            guard let etaSeconds = pace.etaSeconds, etaSeconds > 0 else { return "" }
            let target = now.addingTimeInterval(etaSeconds)
            return ResetCountdownFormatter.string(from: target, now: now).map { "out \($0)" } ?? ""
        }
    }

    private func paceColor(pace: UsagePace?) -> Color {
        guard let pace else { return Color.secondary.opacity(0.5) }
        switch pace.stage {
        case .onTrack:           return .secondary
        case .slightlyBehind:    return Color(red: 0.40, green: 0.78, blue: 0.50)
        case .behind:            return Color(red: 0.25, green: 0.72, blue: 0.45)
        case .farBehind:         return Color(red: 0.18, green: 0.62, blue: 0.40)
        case .slightlyAhead:     return Color(red: 0.96, green: 0.78, blue: 0.30)
        case .ahead:             return Color(red: 0.97, green: 0.55, blue: 0.20)
        case .farAhead:          return Color(red: 0.95, green: 0.32, blue: 0.32)
        }
    }
}

private struct MiniGroupDivider: View {
    var height: CGFloat = 92

    var body: some View {
        Rectangle()
            .fill(Color.primary.opacity(0.055))
            .frame(width: 0.75, height: height)
    }
}

private struct MiniRingCell: View {
    let cell: MiniCell

    @EnvironmentObject var settingsStore: SettingsStore

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            content(now: context.date)
        }
        .frame(width: MiniRingMetrics.cellWidth)
    }

    @ViewBuilder
    private func content(now: Date) -> some View {
        let pace = cell.bucket.flatMap { UsagePace.compute(bucket: $0, now: now) }
        VStack(spacing: 3) {
            ringGauge(pace: pace, now: now)
            Text(cell.resolvedLabel)
                .font(.system(size: 9, weight: .medium, design: .rounded))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .frame(height: MiniRingMetrics.labelHeight, alignment: .center)
            Text(paceLine(pace: pace, now: now))
                .font(.system(size: 8, weight: .medium, design: .rounded).monospacedDigit())
                .foregroundStyle(paceColor(pace: pace))
                .lineLimit(1)
                .minimumScaleFactor(0.65)
                .frame(height: MiniRingMetrics.paceHeight, alignment: .center)
            Text(resetText(now: now))
                .font(.system(size: 8, design: .rounded).monospacedDigit())
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .frame(height: MiniRingMetrics.resetHeight, alignment: .center)
        }
        .frame(width: MiniRingMetrics.cellWidth)
    }

    private func resetText(now: Date) -> String {
        guard let bucket = cell.bucket else { return "—" }
        if let s = ResetCountdownFormatter.string(from: bucket.resetAt, now: now) {
            return s
        }
        return "—"
    }

    /// Pace caption shown beneath the ring:
    ///   - "X% in reserve"  → behind linear pace (good news, room to spare)
    ///   - "X% in deficit"  → ahead of linear pace, but will still last
    ///   - "out 5h 30m"     → projected to run out before reset
    ///   - empty string     → on pace, or no data yet (avoid noise)
    private func paceLine(pace: UsagePace?, now: Date) -> String {
        guard let pace else { return "" }
        switch pace.stage {
        case .onTrack:
            return ""
        case .slightlyBehind, .behind, .farBehind:
            // User has reserve. Always preferred over the "out X" projection
            // because behind-the-line means we'd never run out anyway.
            return pace.stageSummary
        case .slightlyAhead, .ahead, .farAhead:
            if pace.willLastToReset {
                // Burning faster than linear but will still survive the window.
                return pace.stageSummary
            }
            guard let etaSeconds = pace.etaSeconds, etaSeconds > 0 else { return "" }
            let target = now.addingTimeInterval(etaSeconds)
            return ResetCountdownFormatter.string(from: target, now: now).map { "out \($0)" } ?? ""
        }
    }

    /// Mini ring caption color. Same logic as the popover row: in reserve is
    /// green (good), in deficit is amber → red (bad), on-pace stays neutral.
    private func paceColor(pace: UsagePace?) -> Color {
        guard let pace else { return Color.secondary.opacity(0.5) }
        switch pace.stage {
        case .onTrack:           return .secondary
        case .slightlyBehind:    return Color(red: 0.40, green: 0.78, blue: 0.50)
        case .behind:            return Color(red: 0.25, green: 0.72, blue: 0.45)
        case .farBehind:         return Color(red: 0.18, green: 0.62, blue: 0.40)
        case .slightlyAhead:     return Color(red: 0.96, green: 0.78, blue: 0.30)
        case .ahead:             return Color(red: 0.97, green: 0.55, blue: 0.20)
        case .farAhead:          return Color(red: 0.95, green: 0.32, blue: 0.32)
        }
    }

    @ViewBuilder
    private func ringGauge(pace: UsagePace?, now: Date) -> some View {
        if let bucket = cell.bucket {
            let percent = bucket.displayPercent(settingsStore.displayMode)
            let expected: Double? = pace.map { p in
                switch settingsStore.displayMode {
                case .used:      return p.expectedUsedPercent
                case .remaining: return 100 - p.expectedUsedPercent
                }
            }
            let color = Theme.barColor(percent: percent, mode: settingsStore.displayMode)
            RingGauge(
                percent: percent,
                expected: expected,
                color: color,
                markerColor: paceColor(pace: pace),
                size: MiniRingMetrics.ringSize,
                lineWidth: MiniRingMetrics.ringLineWidth
            ) {
                Text("\(Int(percent.rounded()))%")
                    .font(.system(size: 12, weight: .bold, design: .rounded).monospacedDigit())
                    .foregroundStyle(color)
                    .minimumScaleFactor(0.7)
                    .lineLimit(1)
            }
        } else {
            RingGauge(
                percent: 0,
                expected: nil,
                color: .secondary.opacity(0.4),
                size: MiniRingMetrics.ringSize,
                lineWidth: MiniRingMetrics.ringLineWidth
            ) {
                Text("--")
                    .font(.system(size: 12, weight: .bold, design: .rounded).monospacedDigit())
                    .foregroundStyle(.tertiary)
            }
        }
    }
}

private enum MiniCompactMetrics {
    static let cellWidth: CGFloat = 40
    static let barHeight: CGFloat = 36
    static let barWidth: CGFloat = 7
    static let ringSpacing: CGFloat = 4
    static let labelHeight: CGFloat = 9
    static let percentHeight: CGFloat = 12
    static let paceHeight: CGFloat = 8
    static let resetHeight: CGFloat = 8
}

private struct MiniCompactProviderColumn: View {
    let tool: ToolType
    let primaryCells: [MiniCell]
    let branchCells: [MiniBranchCell]

    @EnvironmentObject var settingsStore: SettingsStore

    var body: some View {
        VStack(alignment: .center, spacing: 5) {
            HStack(spacing: 4) {
                Circle()
                    .fill(providerAccent(for: tool))
                    .frame(width: 5, height: 5)
                Text(providerTitle(for: tool))
                    .font(.system(size: 9.5, weight: .semibold, design: .rounded))
                    .foregroundStyle(.primary.opacity(0.86))
                    .tracking(0.2)
            }
            .frame(width: contentWidth, alignment: .center)

            HStack(alignment: .top, spacing: 5) {
                if !primaryCells.isEmpty {
                    MiniCompactPrimaryGroup(cells: primaryCells)
                }
                ForEach(branchGroups) { group in
                    MiniGroupDivider(height: 66)
                        .padding(.top, 12)
                    MiniCompactBranchGroup(group: group)
                }
            }
        }
    }

    private var contentWidth: CGFloat {
        var width: CGFloat = 0
        var groupCount = 0
        if !primaryCells.isEmpty {
            width += CGFloat(primaryCells.count) * MiniCompactMetrics.cellWidth
                + CGFloat(max(0, primaryCells.count - 1)) * MiniCompactMetrics.ringSpacing
            groupCount += 1
        }
        for group in branchGroups {
            width += CGFloat(group.cells.count) * MiniCompactMetrics.cellWidth
                + CGFloat(max(0, group.cells.count - 1)) * MiniCompactMetrics.ringSpacing
            groupCount += 1
        }
        if groupCount > 1 {
            width += CGFloat(groupCount - 1) * 10
        }
        return width
    }

    private var branchGroups: [MiniBranchGroup] {
        miniBranchGroups(from: branchCells, settings: settingsStore.settings.miniWindow)
    }
}

private struct MiniCompactPrimaryGroup: View {
    let cells: [MiniCell]

    var body: some View {
        MiniCompactGroupShell(title: nil, width: groupWidth) {
            HStack(alignment: .top, spacing: MiniCompactMetrics.ringSpacing) {
                ForEach(cells) { cell in
                    MiniCompactBarCell(
                        data: MiniCompactCellData(
                            id: cell.id,
                            tool: cell.tool,
                            title: cell.resolvedLabel,
                            bucket: cell.bucket,
                            help: "\(providerTitle(for: cell.tool)) · \(cell.resolvedLabel)"
                        )
                    )
                }
            }
        }
    }

    private var groupWidth: CGFloat {
        CGFloat(cells.count) * MiniCompactMetrics.cellWidth
            + CGFloat(max(0, cells.count - 1)) * MiniCompactMetrics.ringSpacing
    }
}

private struct MiniCompactBranchGroup: View {
    let group: MiniBranchGroup

    var body: some View {
        MiniCompactGroupShell(title: group.title, width: groupWidth) {
            HStack(alignment: .top, spacing: MiniCompactMetrics.ringSpacing) {
                ForEach(group.cells) { cell in
                    MiniCompactBarCell(
                        data: MiniCompactCellData(
                            id: cell.id,
                            tool: cell.tool,
                            title: cell.title,
                            bucket: cell.bucket,
                            help: "\(providerTitle(for: cell.tool)) · \(cell.bucket.groupTitle ?? cell.bucket.shortLabel) · \(cell.bucket.title)"
                        )
                    )
                }
            }
        }
    }

    private var groupWidth: CGFloat {
        CGFloat(group.cells.count) * MiniCompactMetrics.cellWidth
            + CGFloat(max(0, group.cells.count - 1)) * MiniCompactMetrics.ringSpacing
    }
}

private struct MiniCompactGroupShell<Content: View>: View {
    let title: String?
    let width: CGFloat
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(spacing: 4) {
            Group {
                if let title {
                    Text(title.uppercased())
                        .font(.system(size: 7.5, weight: .semibold, design: .rounded))
                        .foregroundStyle(.primary.opacity(0.56))
                        .tracking(1.7)
                        .lineLimit(1)
                        .minimumScaleFactor(0.62)
                } else {
                    Text(" ")
                        .font(.system(size: 7.5, weight: .semibold, design: .rounded))
                        .hidden()
                }
            }
            .frame(width: width, height: 9, alignment: .center)
            content()
        }
    }
}

private struct MiniCompactCellData: Identifiable {
    let id: String
    let tool: ToolType
    let title: String
    let bucket: QuotaBucket?
    let help: String
}

private struct MiniCompactBarCell: View {
    let data: MiniCompactCellData

    @EnvironmentObject var settingsStore: SettingsStore

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            content(now: context.date)
        }
        .frame(width: MiniCompactMetrics.cellWidth)
    }

    @ViewBuilder
    private func content(now: Date) -> some View {
        let pace = data.bucket.flatMap { UsagePace.compute(bucket: $0, now: now) }
        let percent = data.bucket?.displayPercent(settingsStore.displayMode) ?? 0
        let expected: Double? = pace.map { p in
            switch settingsStore.displayMode {
            case .used:      return p.expectedUsedPercent
            case .remaining: return 100 - p.expectedUsedPercent
            }
        }
        let color = data.bucket.map { Theme.barColor(percent: $0.displayPercent(settingsStore.displayMode), mode: settingsStore.displayMode) }
            ?? .secondary.opacity(0.45)

        VStack(spacing: 1.5) {
            Text(data.title)
                .font(.system(size: 7.5, weight: .medium, design: .rounded))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.62)
                .frame(height: MiniCompactMetrics.labelHeight, alignment: .center)
            MiniVerticalQuotaBar(
                percent: percent,
                expected: expected,
                color: color,
                markerColor: compactPaceColor(pace)
            )
            Text(centerText(percent: percent))
                .font(.system(size: 10.5, weight: .bold, design: .rounded).monospacedDigit())
                .foregroundStyle(color)
                .lineLimit(1)
                .minimumScaleFactor(0.68)
                .frame(height: MiniCompactMetrics.percentHeight, alignment: .center)
            Text(compactPaceLine(pace: pace, now: now))
                .font(.system(size: 6.8, weight: .medium, design: .rounded).monospacedDigit())
                .foregroundStyle(compactPaceColor(pace))
                .lineLimit(1)
                .minimumScaleFactor(0.48)
                .frame(height: MiniCompactMetrics.paceHeight, alignment: .center)
            Text(resetText(now: now))
                .font(.system(size: 6.8, design: .rounded).monospacedDigit())
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                .frame(height: MiniCompactMetrics.resetHeight, alignment: .center)
        }
        .frame(width: MiniCompactMetrics.cellWidth)
        .help(data.help)
    }

    private func centerText(percent: Double) -> String {
        guard let bucket = data.bucket else { return "--" }
        if bucket.id == "daily_routines" {
            let label = bucket.shortLabel.trimmingCharacters(in: .whitespacesAndNewlines)
            if label.contains("/") { return label }
            if bucket.title.contains("--") { return "--" }
        }
        return "\(Int(percent.rounded()))%"
    }

    private func resetText(now: Date) -> String {
        guard let bucket = data.bucket else { return "—" }
        return ResetCountdownFormatter.string(from: bucket.resetAt, now: now) ?? "—"
    }

    private func compactPaceLine(pace: UsagePace?, now: Date) -> String {
        guard let pace else { return "" }
        switch pace.stage {
        case .onTrack:
            return "On pace"
        case .slightlyBehind, .behind, .farBehind:
            return pace.stageSummary
                .replacingOccurrences(of: " in reserve", with: " reserve")
        case .slightlyAhead, .ahead, .farAhead:
            if pace.willLastToReset {
                return pace.stageSummary
                    .replacingOccurrences(of: " in deficit", with: " deficit")
            }
            guard let etaSeconds = pace.etaSeconds, etaSeconds > 0 else { return "" }
            let target = now.addingTimeInterval(etaSeconds)
            return ResetCountdownFormatter.string(from: target, now: now).map { "out \($0)" } ?? ""
        }
    }

    private func compactPaceColor(_ pace: UsagePace?) -> Color {
        guard let pace else { return Color.secondary.opacity(0.5) }
        switch pace.stage {
        case .onTrack:           return .secondary
        case .slightlyBehind:    return Color(red: 0.40, green: 0.78, blue: 0.50)
        case .behind:            return Color(red: 0.25, green: 0.72, blue: 0.45)
        case .farBehind:         return Color(red: 0.18, green: 0.62, blue: 0.40)
        case .slightlyAhead:     return Color(red: 0.96, green: 0.78, blue: 0.30)
        case .ahead:             return Color(red: 0.97, green: 0.55, blue: 0.20)
        case .farAhead:          return Color(red: 0.95, green: 0.32, blue: 0.32)
        }
    }
}

private struct MiniVerticalQuotaBar: View {
    let percent: Double
    let expected: Double?
    let color: Color
    let markerColor: Color

    var body: some View {
        GeometryReader { proxy in
            let height = proxy.size.height
            let clamped = max(0, min(100, percent)) / 100
            let fillHeight = max(2, height * CGFloat(clamped))
            let markerY = expected.map { height * (1 - CGFloat(max(0, min(100, $0)) / 100)) }
            ZStack {
                RoundedRectangle(cornerRadius: MiniCompactMetrics.barWidth / 2, style: .continuous)
                    .fill(Theme.barTrack)
                    .frame(width: MiniCompactMetrics.barWidth, height: height)
                    .position(x: proxy.size.width / 2, y: height / 2)
                RoundedRectangle(cornerRadius: MiniCompactMetrics.barWidth / 2, style: .continuous)
                    .fill(color)
                    .frame(width: MiniCompactMetrics.barWidth, height: fillHeight)
                    .position(x: proxy.size.width / 2, y: height - fillHeight / 2)
                if let markerY {
                    Capsule()
                        .fill(markerColor.opacity(0.76))
                        .frame(width: 14, height: 1.1)
                        .position(x: proxy.size.width / 2, y: markerY)
                }
            }
        }
        .frame(width: 16, height: MiniCompactMetrics.barHeight)
    }
}

private struct RingGauge<CenterLabel: View>: View {
    let percent: Double
    let expected: Double?
    let color: Color
    var markerColor: Color = .secondary
    var size: CGFloat = 50
    var lineWidth: CGFloat = 5
    @ViewBuilder var center: () -> CenterLabel

    private let arcFraction: Double = 0.78

    var body: some View {
        let clamped = max(0, min(100, percent)) / 100
        let rotation: Angle = .degrees(90 + (1 - arcFraction) * 180)
        ZStack {
            Circle()
                .trim(from: 0, to: arcFraction)
                .stroke(Theme.barTrack, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(rotation)
            Circle()
                .trim(from: 0, to: arcFraction * clamped)
                .stroke(color, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(rotation)
            if let expected, expected > 0 && expected < 100 {
                let expectedFraction = max(0, min(100, expected)) / 100
                let markerCenter = arcFraction * expectedFraction
                let markerSpan = 0.012
                Circle()
                    .trim(
                        from: max(0, markerCenter - markerSpan),
                        to: min(arcFraction, markerCenter + markerSpan)
                    )
                    .stroke(markerColor.opacity(0.20), style: StrokeStyle(lineWidth: lineWidth + 5, lineCap: .round))
                    .rotationEffect(rotation)
                Circle()
                    .trim(
                        from: max(0, markerCenter - markerSpan),
                        to: min(arcFraction, markerCenter + markerSpan)
                    )
                    .stroke(markerColor, style: StrokeStyle(lineWidth: lineWidth + 1, lineCap: .round))
                    .rotationEffect(rotation)
            }
            center()
        }
        .frame(width: size, height: size)
    }
}
