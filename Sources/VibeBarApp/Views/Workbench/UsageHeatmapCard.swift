import SwiftUI
import VibeBarCore

/// Requests by local weekday × hour: one `Canvas` of 168 cells, a legend,
/// and the busiest slot. The hover tooltip lives in its own overlay view
/// (`UsageHeatmapHover`) so a pointer move re-renders only the overlay —
/// the grid is `Equatable` and drawn once per snapshot. See AGENTS.md § 7.
struct UsageHeatmapCard: View, Equatable {
    let density: Theme.Density
    let heatmap: UsageDashboardSnapshot.Heatmap

    static let labelWidth: CGFloat = 30
    static let axisHeight: CGFloat = 14
    static let gap: CGFloat = 2

    var body: some View {
        CardShell(density: density, spacing: 12) {
            UsageCardHeader(
                density: density,
                title: L10n.Workbench.Usage.Heatmap.title,
                subtitle: L10n.Workbench.Usage.Heatmap.subtitle
            )
            if heatmap.totalRequests == 0 {
                UsageEmptyMessage(density: density, text: L10n.Workbench.Usage.Heatmap.empty, systemImage: "calendar")
            } else {
                grid
                    .frame(height: 7 * 15 + 6 * Self.gap + Self.axisHeight)
                footer
            }
            // Greedy tail: beside a taller card the surface stretches to the
            // row's height instead of stopping short of its neighbour.
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var grid: some View {
        HStack(alignment: .top, spacing: 6) {
            VStack(alignment: .trailing, spacing: Self.gap) {
                ForEach(Array(UsageDashboardFormat.mondayFirstWeekdays.enumerated()), id: \.offset) { _, name in
                    Text(name)
                        .font(.system(size: 9.5))
                        .foregroundStyle(.secondary)
                        .frame(height: 15)
                }
            }
            .frame(width: Self.labelWidth, alignment: .trailing)
            VStack(spacing: 0) {
                UsageHeatmapGrid(cells: heatmap.cells, maximum: heatmap.maximum)
                    .equatable()
                    .overlay {
                        UsageHeatmapHover(cells: heatmap.cells)
                    }
                HStack(spacing: 0) {
                    ForEach([0, 6, 12, 18], id: \.self) { hour in
                        Text(UsageDashboardFormat.hour(hour))
                            .font(.system(size: 9))
                            .foregroundStyle(.tertiary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .frame(height: Self.axisHeight)
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 10) {
            if let weekday = heatmap.busiestWeekday, let hour = heatmap.busiestHour {
                Label {
                    Text(L10n.Workbench.Usage.Heatmap.busiest(slot: UsageDashboardFormat.slot(weekday: weekday, hour: hour)))
                } icon: {
                    Image(systemName: "flame")
                }
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            HStack(spacing: 4) {
                Text(L10n.Usage.YearHeatmap.less)
                ForEach(0..<5, id: \.self) { step in
                    RoundedRectangle(cornerRadius: 2, style: .continuous)
                        .fill(UsageHeatmapGrid.color(level: Double(step) / 4))
                        .frame(width: 10, height: 10)
                }
                Text(L10n.Usage.YearHeatmap.more)
            }
            .font(.system(size: 9.5))
            .foregroundStyle(.tertiary)
        }
    }
}

/// The 7 × 24 grid as one drawing surface.
struct UsageHeatmapGrid: View, Equatable {
    let cells: [Int]
    let maximum: Int

    static func color(level: Double) -> Color {
        level <= 0
            ? Theme.barTrack
            : WorkbenchPorcelain.accent.opacity(0.18 + 0.82 * min(1, level))
    }

    var body: some View {
        Canvas { context, size in
            let gap = UsageHeatmapCard.gap
            let width = (size.width - 23 * gap) / 24
            let height = (size.height - 6 * gap) / 7
            guard width > 0, height > 0 else { return }
            let scale = maximum > 0 ? Double(maximum) : 1
            for weekday in 0..<7 {
                for hour in 0..<24 {
                    let value = cells[weekday * 24 + hour]
                    // Square root so a single busy hour does not wash out
                    // the rest of the week.
                    let level = value > 0 ? max(0.08, (Double(value) / scale).squareRoot()) : 0
                    let rect = CGRect(
                        x: CGFloat(hour) * (width + gap),
                        y: CGFloat(weekday) * (height + gap),
                        width: width,
                        height: height
                    )
                    context.fill(Path(roundedRect: rect, cornerRadius: 2.5), with: .color(Self.color(level: level)))
                }
            }
        }
        .accessibilityLabel(L10n.Workbench.Usage.Heatmap.subtitle)
    }
}

/// Hover state for the grid, kept out of the grid's body.
private struct UsageHeatmapHover: View {
    let cells: [Int]
    @State private var hovered: (weekday: Int, hour: Int, location: CGPoint)?

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .topLeading) {
                Color.clear
                    .contentShape(Rectangle())
                    .onContinuousHover { phase in
                        switch phase {
                        case .active(let location):
                            let gap = UsageHeatmapCard.gap
                            let width = (geometry.size.width + gap) / 24
                            let height = (geometry.size.height + gap) / 7
                            let hour = Int(location.x / width)
                            let weekday = Int(location.y / height)
                            if (0..<24).contains(hour), (0..<7).contains(weekday) {
                                hovered = (weekday, hour, location)
                            } else {
                                hovered = nil
                            }
                        case .ended:
                            hovered = nil
                        }
                    }
                if let hovered {
                    let value = cells[hovered.weekday * 24 + hovered.hour]
                    UsageTooltip {
                        Text(L10n.Workbench.Usage.Heatmap.cell(
                            slot: UsageDashboardFormat.slot(weekday: hovered.weekday, hour: hovered.hour),
                            count: value
                        ))
                        .fontWeight(.semibold)
                    }
                    .offset(
                        x: min(max(0, hovered.location.x - 70), max(0, geometry.size.width - 150)),
                        y: hovered.location.y > geometry.size.height / 2 ? hovered.location.y - 34 : hovered.location.y + 14
                    )
                }
            }
        }
    }
}
