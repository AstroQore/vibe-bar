import SwiftUI
import VibeBarCore

/// Skills ranked by uses: name, uses, sessions, when last used, the share
/// each harness had, and the projects they ran in.
struct UsageSkillsCard: View, Equatable {
    let density: Theme.Density
    let skills: [UsageDashboardSnapshot.SkillRow]

    var body: some View {
        CardShell(density: density, spacing: 10) {
            UsageCardHeader(
                density: density,
                title: L10n.Workbench.Page.Skills.title,
                subtitle: L10n.Workbench.Usage.Skills.subtitle
            )
            if skills.isEmpty {
                UsageEmptyMessage(density: density, text: L10n.Workbench.Usage.Skills.empty, systemImage: "puzzlepiece.extension")
            } else {
                let maximum = max(1, skills.map(\.invocations).max() ?? 1)
                VStack(spacing: 9) {
                    ForEach(skills) { skill in
                        row(skill, maximum: maximum)
                    }
                }
            }
            // Greedy tail: beside a taller card the surface stretches to the
            // row's height instead of stopping short of its neighbour.
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func row(_ skill: UsageDashboardSnapshot.SkillRow, maximum: Int) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Image(systemName: "puzzlepiece.extension")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.orange)
                    .frame(width: 14)
                Text(skill.name)
                    .font(.system(size: 12.5, weight: .medium, design: .monospaced))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 8)
                Text(L10n.Workbench.Usage.Count.uses(count: skill.invocations))
                    .font(.system(size: 11.5, weight: .semibold, design: .rounded).monospacedDigit())
                Text(L10n.Workbench.Usage.Count.sessions(count: skill.sessions))
                    .font(.system(size: 10.5, design: .rounded).monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(minWidth: 62, alignment: .trailing)
            }
            HStack(spacing: 8) {
                Color.clear.frame(width: 14, height: 1)
                harnessShare(skill, maximum: maximum)
                    .frame(maxWidth: 160)
                if let last = skill.lastUsedAt {
                    Text(L10n.Workbench.Usage.Skills.lastUsed(when: UsageDashboardFormat.relative(last)))
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
                Spacer(minLength: 4)
                if !skill.projects.isEmpty {
                    Text(L10n.Workbench.Usage.Skills.projects(projects: projectList(skill)))
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
        }
        .accessibilityElement(children: .combine)
    }

    /// One bar as long as the skill's share of the top skill's uses, split
    /// by harness in each harness's colour.
    private func harnessShare(_ skill: UsageDashboardSnapshot.SkillRow, maximum: Int) -> some View {
        UsageSegmentedBar(
            parts: skill.harnesses.map { UsageSegmentedBar.Part(value: Double($0.count), tint: $0.harness.usageTint) },
            scale: Double(maximum),
            height: 5
        )
        .help(skill.harnesses
            .map { L10n.Workbench.Usage.Skills.harnessUses(harness: $0.harness.displayName, count: $0.count) }
            .joined(separator: "\n"))
    }

    private func projectList(_ skill: UsageDashboardSnapshot.SkillRow) -> String {
        let names = skill.projects.joined(separator: ", ")
        let more = skill.projectCount - skill.projects.count
        return more > 0 ? L10n.Quota.History.moreBuckets(names: names, count: more) : names
    }
}

/// Tools ranked by calls, with the weekly stack of tool kinds beside them.
struct UsageToolsCard: View, Equatable {
    let density: Theme.Density
    let tools: UsageDashboardSnapshot.ToolUsage

    var body: some View {
        CardShell(density: density, spacing: 10) {
            UsageCardHeader(density: density, title: L10n.Workbench.Usage.Tools.title) {
                if tools.totalCalls > 0 {
                    Text(L10n.Workbench.Usage.Count.calls(count: tools.totalCalls))
                        .font(.system(size: 11, weight: .semibold, design: .rounded).monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            if tools.rows.isEmpty {
                UsageEmptyMessage(density: density, text: L10n.Workbench.Usage.Tools.empty, systemImage: "wrench.and.screwdriver")
            } else {
                HStack(alignment: .top, spacing: 16) {
                    table
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                        .layoutPriority(1)
                    if !tools.weeks.isEmpty {
                        weekly
                            .frame(width: 168)
                    }
                }
            }
            // Greedy tail: beside a taller card the surface stretches to the
            // row's height instead of stopping short of its neighbour.
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var table: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Spacer()
                Text(L10n.Workbench.Usage.Tools.calls).frame(width: 52, alignment: .trailing)
                Text(L10n.Workbench.Page.Sessions.title).frame(width: 56, alignment: .trailing)
                Text(L10n.Workbench.Usage.Tools.share).frame(width: 74, alignment: .trailing)
            }
            .font(.system(size: 9.5, weight: .semibold))
            .foregroundStyle(.tertiary)
            ForEach(tools.rows) { tool in
                HStack(spacing: 8) {
                    RoundedRectangle(cornerRadius: 2, style: .continuous)
                        .fill(tool.category.tint)
                        .frame(width: 7, height: 7)
                        .help(tool.category.title)
                    Text(tool.name)
                        .font(.system(size: 12, design: .monospaced))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 6)
                    Text(AppLocale.number(tool.calls))
                        .frame(width: 52, alignment: .trailing)
                    Text(AppLocale.number(tool.sessions))
                        .foregroundStyle(.secondary)
                        .frame(width: 56, alignment: .trailing)
                    HStack(spacing: 4) {
                        UsageShareBar(fraction: tool.share / max(0.0001, tools.rows.first?.share ?? 1), tint: tool.category.tint.opacity(0.8), height: 4)
                        Text(UsageDashboardFormat.percent(tool.share))
                            .foregroundStyle(.secondary)
                            .frame(width: 30, alignment: .trailing)
                    }
                    .frame(width: 74)
                }
                .font(.system(size: 11, design: .rounded).monospacedDigit())
            }
            if tools.remainderCount > 0 {
                Text(L10n.Workbench.Usage.Tools.more(count: tools.remainderCount))
                    .font(.system(size: 10.5))
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private var weekly: some View {
        let maximum = max(1, tools.weeks.map(\.total).max() ?? 1)
        let categories = UsageToolCategory.allCases.filter { category in
            tools.weeks.contains { $0.count(category) > 0 }
        }
        return VStack(alignment: .leading, spacing: 8) {
            Text(L10n.Workbench.Usage.Tools.weekly)
                .font(.system(size: 9.5, weight: .semibold))
                .foregroundStyle(.tertiary)
            UsageWeeklyStacks(weeks: tools.weeks, categories: categories, maximum: maximum)
                .equatable()
                .overlay {
                    // Tooltips per week on plain hit areas over the drawing.
                    HStack(spacing: 3) {
                        ForEach(tools.weeks) { week in
                            Color.clear
                                .contentShape(Rectangle())
                                .help(L10n.Workbench.Usage.Tools.week(date: UsageDashboardFormat.day(week.start), count: week.total))
                        }
                    }
                }
            .frame(height: 96)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 64), spacing: 4, alignment: .leading)], alignment: .leading, spacing: 3) {
                ForEach(categories, id: \.self) { category in
                    HStack(spacing: 4) {
                        RoundedRectangle(cornerRadius: 2, style: .continuous)
                            .fill(category.tint)
                            .frame(width: 7, height: 7)
                        Text(category.title)
                            .lineLimit(1)
                    }
                    .font(.system(size: 9.5))
                    .foregroundStyle(.secondary)
                }
            }
        }
    }
}

/// The weekly stacks as one drawing surface.
private struct UsageWeeklyStacks: View, Equatable {
    let weeks: [UsageDashboardSnapshot.ToolWeek]
    let categories: [UsageToolCategory]
    let maximum: Int

    var body: some View {
        Canvas { context, size in
            guard !weeks.isEmpty else { return }
            let gap: CGFloat = 3
            let width = (size.width - gap * CGFloat(weeks.count - 1)) / CGFloat(weeks.count)
            for (index, week) in weeks.enumerated() {
                let x = CGFloat(index) * (width + gap)
                var y = size.height
                for category in categories {
                    let count = week.count(category)
                    guard count > 0 else { continue }
                    let height = max(1, size.height * CGFloat(count) / CGFloat(max(1, maximum)))
                    y -= height
                    context.fill(Path(CGRect(x: x, y: y, width: width, height: height)), with: .color(category.tint))
                    y -= 1
                }
            }
        }
        .accessibilityHidden(true)
    }
}
