import SwiftUI
import Charts
import VibeBarCore

private enum CostHistoryGranularity: String, CaseIterable, Identifiable {
    case hour = "Hour"
    case day = "Day"
    case week = "Week"
    case month = "Month"
    var id: String { rawValue }
}

private struct CostChartPoint: Identifiable, Equatable {
    let date: Date
    let costUSD: Double
    let totalTokens: Int
    let models: [CostSnapshot.ModelBreakdown]
    var id: Date { date }
}

/// Cost history with hour/day/week/month grouping, model-aware hover detail,
/// and an inline model inspector. The inspector is absent until a point is
/// selected, then expands as part of the card; `ColumnMasonryLayout` keeps the
/// current column assignments stable while live item heights change so the
/// expanded card does not jump across the Overview.
struct CostHistoryView: View {
    let tool: ToolType
    let snapshot: CostSnapshot?
    let density: Theme.Density
    var chartHeight: CGFloat = 130
    var titleOverride: String? = nil

    @State private var timeframe: CostTimeframe = .month
    @State private var granularity: CostHistoryGranularity = .day
    @State private var hoveredDate: Date?
    @State private var inspectedPoint: CostChartPoint?

    @EnvironmentObject var environment: AppEnvironment

    var body: some View {
        let points = chartPoints
        let total = points.reduce(0) { $0 + $1.costUSD }
        let average = points.isEmpty ? 0 : total / Double(points.count)
        let peak = points.map(\.costUSD).max() ?? 0

        VStack(alignment: .leading, spacing: density.cardSpacing) {
            VStack(alignment: .trailing, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(titleOverride ?? "Cost History")
                        .font(.system(size: density.bucketTitleFontSize, weight: .semibold))
                    Spacer(minLength: 8)
                    SectionRefreshButton(isRefreshing: false) {
                        environment.refreshCostUsage()
                    }
                }
                HStack(spacing: 6) {
                    Spacer(minLength: 0)
                    CostTimeframeSelector(selection: $timeframe, density: density)
                        .fixedSize(horizontal: true, vertical: false)
                    granularityControl
                }
            }

            chart(points: points, average: average)

            if inspectedPoint != nil {
                inlineModelInspector
            }

            HStack(spacing: 16) {
                metric(label: "Total", value: formatCost(total))
                metric(label: "Avg/\(granularity.rawValue.lowercased())", value: formatCost(average))
                metric(label: "Peak", value: formatCost(peak))
                Spacer()
                Text(timeframeNote(pointCount: points.count))
                    .font(.system(size: density.resetCountdownFontSize))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(density.cardPadding)
        .background(
            RoundedRectangle(cornerRadius: density.cardCornerRadius, style: .continuous)
                .fill(.background.tertiary.opacity(0.6))
        )
        .overlay(
            RoundedRectangle(cornerRadius: density.cardCornerRadius, style: .continuous)
                .stroke(.separator.opacity(0.4), lineWidth: 0.5)
        )
        .onChange(of: timeframe) { _, _ in
            granularity = preferredGranularity(for: timeframe)
            clearSelection()
        }
    }

    @ViewBuilder
    private func chart(points: [CostChartPoint], average: Double) -> some View {
        if points.isEmpty {
            VStack(spacing: 4) {
                Text(granularity == .hour ? "Building hourly detail…" : "Building history…")
                    .font(.system(size: density.subtitleFontSize))
                    .foregroundStyle(.tertiary)
                Text("Cost samples appear after the next local scan.")
                    .font(.system(size: density.resetCountdownFontSize))
                    .foregroundStyle(.tertiary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 24)
        } else {
            Chart {
                if granularity == .hour {
                    ForEach(points) { point in
                        AreaMark(
                            x: .value("Hour", point.date, unit: .hour),
                            y: .value("Cost", point.costUSD)
                        )
                        .interpolationMethod(.monotone)
                        .foregroundStyle(
                            LinearGradient(
                                colors: [Color.accentColor.opacity(0.22), Color.accentColor.opacity(0.04)],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )
                        LineMark(
                            x: .value("Hour", point.date, unit: .hour),
                            y: .value("Cost", point.costUSD)
                        )
                        .interpolationMethod(.monotone)
                        .foregroundStyle(Color.accentColor)
                        .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                        .opacity(pointOpacity(point))
                        if point.costUSD > 0 {
                            PointMark(
                                x: .value("Hour", point.date, unit: .hour),
                                y: .value("Cost", point.costUSD)
                            )
                            .symbolSize(24)
                            .foregroundStyle(point.costUSD > average * 1.5 ? Color.orange : Color.accentColor)
                        }
                    }
                } else {
                    ForEach(points) { point in
                        BarMark(
                            x: .value("Period", point.date, unit: chartCalendarComponent),
                            y: .value("Cost", point.costUSD)
                        )
                        .foregroundStyle(point.costUSD > average * 1.5 ? Color.orange : Color.accentColor)
                        .cornerRadius(2)
                        .opacity(pointOpacity(point))
                    }
                }
                if average > 0 {
                    RuleMark(y: .value("Avg", average))
                        .foregroundStyle(Color.accentColor.opacity(0.5))
                        .lineStyle(StrokeStyle(lineWidth: 1.2, dash: [4, 3]))
                }
            }
            .chartXScale(domain: chartDomain(points))
            .chartYAxis {
                AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) { value in
                    AxisGridLine().foregroundStyle(.secondary.opacity(0.15))
                    AxisValueLabel {
                        if let raw = value.as(Double.self) {
                            Text(formatAxisCost(raw))
                                .font(.system(size: 9, design: .rounded).monospacedDigit())
                        }
                    }
                }
            }
            .chartXAxis {
                let stride = axisStride(for: points)
                AxisMarks(values: .stride(by: stride.component, count: stride.count)) { value in
                    AxisValueLabel(format: stride.format)
                        .font(.system(size: 9))
                }
            }
            .chartOverlay { proxy in
                hoverOverlay(proxy: proxy, points: points)
            }
            .frame(height: chartHeight)
        }
    }

    private func hoverOverlay(proxy: ChartProxy, points: [CostChartPoint]) -> some View {
        GeometryReader { geometry in
            ZStack(alignment: .topLeading) {
                Rectangle()
                    .fill(Color.clear)
                    .contentShape(Rectangle())
                    .onContinuousHover { phase in
                        switch phase {
                        case .active(let location):
                            let plotMinX = proxy.plotFrame.map { geometry[$0].minX } ?? 0
                            if let date: Date = proxy.value(atX: location.x - plotMinX, as: Date.self) {
                                hoveredDate = nearestPoint(to: date, in: points)?.date
                            }
                        case .ended:
                            hoveredDate = nil
                        }
                    }
                    .onTapGesture {
                        guard let hovered = hoveredPoint(in: points) else { return }
                        inspectedPoint = inspectedPoint?.date == hovered.date ? nil : hovered
                    }

                if let hovered = hoveredPoint(in: points), inspectedPoint == nil {
                    compactTooltip(hovered)
                        .offset(x: tooltipX(for: hovered.date, proxy: proxy, geometry: geometry))
                }
            }
        }
    }

    private func compactTooltip(_ point: CostChartPoint) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(tooltipDate(point.date))
                    .font(.system(size: 10, weight: .semibold))
                Spacer(minLength: 8)
                Text(formatCost(point.costUSD))
                    .font(.system(size: 10, weight: .semibold, design: .rounded).monospacedDigit())
            }
            Text(formatTokens(point.totalTokens))
                .font(.system(size: 9, design: .rounded).monospacedDigit())
                .foregroundStyle(.secondary)
            ForEach(point.models.prefix(3)) { model in
                modelRow(model)
            }
            if point.models.count > 3 {
                Text("+\(point.models.count - 3) more · click to inspect")
                    .font(.system(size: 8, weight: .medium))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.black.opacity(0.87)))
        .foregroundStyle(.white)
        .frame(width: 190)
        .allowsHitTesting(false)
    }

    @ViewBuilder
    private var inlineModelInspector: some View {
        VStack(alignment: .leading, spacing: 6) {
            Divider()
                .opacity(0.35)

            if let point = inspectedPoint {
                HStack(spacing: 8) {
                    Text("Models · \(tooltipDate(point.date))")
                        .font(.system(size: 10, weight: .semibold))
                    Spacer(minLength: 8)
                    Button {
                        inspectedPoint = nil
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .help("Clear model selection")
                }

                if point.models.isEmpty {
                    Text("Model detail is unavailable for this historical period.")
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                } else {
                    LazyVGrid(
                        columns: [
                            GridItem(.flexible(), spacing: 16, alignment: .leading),
                            GridItem(.flexible(), spacing: 0, alignment: .leading)
                        ],
                        alignment: .leading,
                        spacing: 4
                    ) {
                        ForEach(point.models) { model in
                            inspectedModelRow(model)
                        }
                    }
                }
            }
        }
    }

    private func inspectedModelRow(_ model: CostSnapshot.ModelBreakdown) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(model.modelName)
                .font(.system(size: 9, weight: .medium))
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 4)
            Text(formatCost(model.costUSD))
                .font(.system(size: 9, design: .rounded).monospacedDigit())
            Text(formatTokens(model.totalTokens))
                .font(.system(size: 8, design: .rounded).monospacedDigit())
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }

    private func modelRow(_ model: CostSnapshot.ModelBreakdown) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(model.modelName)
                .font(.system(size: 9, weight: .medium))
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 8)
            Text(formatCost(model.costUSD))
                .font(.system(size: 9, design: .rounded).monospacedDigit())
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Data shaping

    private var availableGranularities: [CostHistoryGranularity] {
        switch timeframe {
        case .today, .yesterday: [.hour]
        case .week: [.day]
        case .month, .all: [.day, .week, .month]
        }
    }

    private func preferredGranularity(for timeframe: CostTimeframe) -> CostHistoryGranularity {
        switch timeframe {
        case .today, .yesterday: .hour
        case .week, .month: .day
        case .all: .month
        }
    }

    private var chartPoints: [CostChartPoint] {
        guard let snapshot else { return [] }
        if timeframe == .today || timeframe == .yesterday {
            let history = timeframe == .today ? snapshot.todayHourlyHistory : snapshot.yesterdayHourlyHistory
            return history.map { point in
                CostChartPoint(
                    date: point.date,
                    costUSD: point.costUSD,
                    totalTokens: point.totalTokens,
                    models: snapshot.topModels(forHour: point.date, limit: .max)
                )
            }
        }

        let filtered = filteredDailyHistory(snapshot)
        guard granularity != .day else {
            return filtered.map { point in
                CostChartPoint(
                    date: point.date,
                    costUSD: point.costUSD,
                    totalTokens: point.totalTokens,
                    models: snapshot.topModels(for: point.date, limit: .max)
                )
            }
        }
        return aggregate(filtered, snapshot: snapshot, by: granularity)
    }

    private func filteredDailyHistory(_ snapshot: CostSnapshot) -> [DailyCostPoint] {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let cutoff: Date?
        switch timeframe {
        case .today: cutoff = today
        case .yesterday: cutoff = calendar.date(byAdding: .day, value: -1, to: today)
        case .week: cutoff = calendar.date(byAdding: .day, value: -6, to: today)
        case .month: cutoff = calendar.date(byAdding: .day, value: -29, to: today)
        case .all: cutoff = nil
        }
        guard let cutoff else { return snapshot.dailyHistory }
        return snapshot.dailyHistory.filter { $0.date >= cutoff && $0.date <= today }
    }

    private func aggregate(
        _ days: [DailyCostPoint],
        snapshot: CostSnapshot,
        by grouping: CostHistoryGranularity
    ) -> [CostChartPoint] {
        let calendar = Calendar.current
        var totals: [Date: (cost: Double, tokens: Int, models: [String: (Double, Int)])] = [:]
        for day in days {
            let component: Calendar.Component = grouping == .week ? .weekOfYear : .month
            guard let key = calendar.dateInterval(of: component, for: day.date)?.start else { continue }
            var value = totals[key] ?? (0, 0, [:])
            value.cost += day.costUSD
            value.tokens += day.totalTokens
            for model in snapshot.topModels(for: day.date, limit: .max) {
                let current = value.models[model.modelName] ?? (0, 0)
                value.models[model.modelName] = (current.0 + model.costUSD, current.1 + model.totalTokens)
            }
            totals[key] = value
        }
        return totals.map { date, value in
            CostChartPoint(
                date: date,
                costUSD: value.cost,
                totalTokens: value.tokens,
                models: value.models.map {
                    CostSnapshot.ModelBreakdown(modelName: $0.key, costUSD: $0.value.0, totalTokens: $0.value.1)
                }.sorted { $0.costUSD > $1.costUSD }
            )
        }.sorted { $0.date < $1.date }
    }

    // MARK: - Presentation helpers

    @ViewBuilder
    private var granularityControl: some View {
        Group {
            if availableGranularities.count > 1 {
                HStack(spacing: 1) {
                    ForEach(availableGranularities) { option in
                        Button {
                            granularity = option
                            clearSelection()
                        } label: {
                            granularityOptionLabel(option, selected: option == granularity)
                        }
                        .buttonStyle(.plain)
                        .focusable(false)
                        .accessibilityLabel("Group cost history by \(option.rawValue.lowercased())")
                    }
                }
            } else {
                Text(granularity.rawValue)
                    .font(.system(size: max(9, density.segmentedFontSize - 1), weight: .semibold, design: .rounded))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 22)
                    .accessibilityLabel("Cost history grouped by \(granularity.rawValue.lowercased())")
            }
        }
        .padding(2)
        .frame(width: 132)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(Color.primary.opacity(0.08))
        )
    }

    private func granularityOptionLabel(
        _ option: CostHistoryGranularity,
        selected: Bool
    ) -> some View {
        Text(option.rawValue)
            .font(.system(size: max(9, density.segmentedFontSize - 1), weight: .semibold, design: .rounded))
            .foregroundStyle(selected ? Color.primary : Color.secondary)
            .lineLimit(1)
            .minimumScaleFactor(0.8)
            .frame(maxWidth: .infinity, minHeight: 22)
            .contentShape(Rectangle())
            .background {
                if selected {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Color.primary.opacity(0.12))
                }
            }
    }

    private var chartCalendarComponent: Calendar.Component {
        switch granularity {
        case .hour: .hour
        case .day: .day
        case .week: .weekOfYear
        case .month: .month
        }
    }

    private var hourlyDomain: ClosedRange<Date> {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let start = timeframe == .yesterday
            ? (calendar.date(byAdding: .day, value: -1, to: today) ?? today)
            : today
        let end = calendar.date(byAdding: .day, value: 1, to: start) ?? start.addingTimeInterval(86_400)
        return start...end
    }

    private func chartDomain(_ points: [CostChartPoint]) -> ClosedRange<Date> {
        if granularity == .hour { return hourlyDomain }
        let start = points.first?.date ?? Date()
        let fallbackSpan: TimeInterval
        switch granularity {
        case .hour: fallbackSpan = 86_400
        case .day: fallbackSpan = 86_400
        case .week: fallbackSpan = 7 * 86_400
        case .month: fallbackSpan = 31 * 86_400
        }
        let end = (points.last?.date ?? start).addingTimeInterval(fallbackSpan)
        return start...max(end, start.addingTimeInterval(fallbackSpan))
    }

    private struct AxisStride {
        let component: Calendar.Component
        let count: Int
        let format: Date.FormatStyle
    }

    private func axisStride(for points: [CostChartPoint]) -> AxisStride {
        let desiredLabels = 6
        let adaptiveCount = max(1, Int(ceil(Double(max(1, points.count)) / Double(desiredLabels))))
        switch granularity {
        case .hour:
            return AxisStride(component: .hour, count: 4, format: .dateTime.hour())
        case .day:
            return AxisStride(
                component: .day,
                count: timeframe == .all ? adaptiveCount : (timeframe == .month ? 5 : 1),
                format: .dateTime.day().month(.abbreviated)
            )
        case .week:
            return AxisStride(
                component: .weekOfYear,
                count: timeframe == .all ? adaptiveCount : 1,
                format: .dateTime.day().month(.abbreviated)
            )
        case .month:
            return AxisStride(
                component: .month,
                count: timeframe == .all ? adaptiveCount : 1,
                format: .dateTime.month(.abbreviated).year(.twoDigits)
            )
        }
    }

    private func hoveredPoint(in points: [CostChartPoint]) -> CostChartPoint? {
        hoveredDate.flatMap { date in points.first { $0.date == date } }
    }

    private func nearestPoint(to date: Date, in points: [CostChartPoint]) -> CostChartPoint? {
        points.min { abs($0.date.timeIntervalSince(date)) < abs($1.date.timeIntervalSince(date)) }
    }

    private func pointOpacity(_ point: CostChartPoint) -> Double {
        guard let selected = inspectedPoint?.date ?? hoveredDate else { return 1 }
        return point.date == selected ? 1 : 0.55
    }

    private func tooltipX(for date: Date, proxy: ChartProxy, geometry: GeometryProxy) -> CGFloat {
        guard let x = proxy.position(forX: date) else { return 0 }
        let plotMinX = proxy.plotFrame.map { geometry[$0].minX } ?? 0
        return min(max(plotMinX + x - 95, 0), max(0, geometry.size.width - 190))
    }

    private func clearSelection() {
        hoveredDate = nil
        inspectedPoint = nil
    }

    private func timeframeNote(pointCount: Int) -> String {
        switch timeframe {
        case .today: "today"
        case .yesterday: "yesterday"
        case .week: "7 days"
        case .month: "30 days"
        case .all: pointCount == 0 ? "" : "\(pointCount) \(granularity.rawValue.lowercased())s"
        }
    }

    @ViewBuilder
    private func metric(label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(label.uppercased())
                .font(.system(size: max(8, density.subtitleFontSize - 2), weight: .semibold))
                .foregroundStyle(.tertiary)
                .tracking(0.4)
            Text(value)
                .font(.system(size: density.bucketTitleFontSize, weight: .semibold, design: .rounded).monospacedDigit())
        }
    }

    private func formatCost(_ value: Double) -> String {
        if value < 0.01 { return "$0.00" }
        if value < 100 { return String(format: "$%.2f", value) }
        return String(format: "$%.0f", value)
    }

    private func formatAxisCost(_ value: Double) -> String {
        value < 1 ? String(format: "$%.2f", value) : String(format: "$%.0f", value)
    }

    private func formatTokens(_ tokens: Int) -> String {
        if tokens < 1_000 { return "\(tokens) tok" }
        if tokens < 1_000_000 { return String(format: "%.1fk tok", Double(tokens) / 1_000) }
        if tokens < 1_000_000_000 { return String(format: "%.2fM tok", Double(tokens) / 1_000_000) }
        return String(format: "%.2fB tok", Double(tokens) / 1_000_000_000)
    }

    private func tooltipDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = granularity == .hour ? "MMM d · HH:00" : "MMM d, yyyy"
        return formatter.string(from: date)
    }
}

private struct CostTimeframeSelector: View {
    @Binding var selection: CostTimeframe
    let density: Theme.Density

    var body: some View {
        HStack(spacing: 1) {
            ForEach(CostTimeframe.allCases) { timeframe in
                Button {
                    selection = timeframe
                } label: {
                    Text(timeframe.shortLabel)
                        .font(.system(size: max(9, density.segmentedFontSize - 1), weight: .semibold, design: .rounded))
                        .foregroundStyle(selection == timeframe ? .primary : .secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                        .padding(.horizontal, 8)
                        .frame(minHeight: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .focusable(false)
                .background {
                    if selection == timeframe {
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(Color.primary.opacity(0.12))
                    }
                }
                .accessibilityLabel(timeframe.label)
            }
        }
        .padding(2)
        .background(RoundedRectangle(cornerRadius: 7).fill(Color.primary.opacity(0.08)))
    }
}
