import SwiftUI
import Charts
import VibeBarCore

/// Hourly burn-rate chart — answers "when am I burning fastest?".
/// Aggregates the heatmap across days into a 24-bucket profile so peak hours
/// jump out. Useful for spotting which time of day is most expensive.
struct UsageRateView: View {
    let heatmap: UsageHeatmap
    let density: Theme.Density

    var body: some View {
        VStack(alignment: .leading, spacing: density.cardSpacing) {
            HStack(alignment: .firstTextBaseline) {
                Text("Hourly burn rate")
                    .font(.system(size: density.bucketTitleFontSize, weight: .semibold))
                Spacer()
                if let peak = peakHour {
                    Text("Peak \(formatHour(peak))")
                        .font(.system(size: density.subtitleFontSize))
                        .foregroundStyle(.secondary)
                }
            }
            chart
            Text("Aggregated across all weekdays")
                .font(.system(size: density.resetCountdownFontSize))
                .foregroundStyle(.tertiary)
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
    }

    private var hourTotals: [(hour: Int, tokens: Int)] {
        (0..<24).map { hour in
            let total = heatmap.cells.reduce(0) { $0 + $1[hour] }
            return (hour, total)
        }
    }

    @ViewBuilder
    private var chart: some View {
        let totals = hourTotals
        if totals.allSatisfy({ $0.tokens == 0 }) {
            Text("No data yet")
                .font(.system(size: density.subtitleFontSize))
                .foregroundStyle(.tertiary)
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.vertical, 16)
        } else {
            Chart {
                ForEach(totals, id: \.hour) { entry in
                    BarMark(
                        x: .value("Hour", hourKey(entry.hour)),
                        y: .value("Tokens", entry.tokens),
                        width: .ratio(0.74)
                    )
                    .foregroundStyle(barColor(tokens: entry.tokens))
                    .cornerRadius(2)
                }
            }
            .chartYAxis {
                AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) { value in
                    AxisGridLine().foregroundStyle(.secondary.opacity(0.15))
                    AxisValueLabel {
                        if let raw = value.as(Int.self) {
                            Text(formatTokens(raw))
                                .font(.system(size: 9, design: .rounded).monospacedDigit())
                        }
                    }
                }
            }
            .chartXAxis {
                AxisMarks(values: [0, 6, 12, 18].map(hourKey)) { value in
                    AxisValueLabel {
                        if let key = value.as(String.self), let h = Int(key) {
                            Text(formatHour(h))
                                .font(.system(size: 9, design: .rounded).monospacedDigit())
                        }
                    }
                }
            }
            .frame(height: 140)
        }
    }

    private var peakHour: Int? {
        let totals = hourTotals
        let max = totals.map(\.tokens).max() ?? 0
        guard max > 0 else { return nil }
        return totals.first { $0.tokens == max }?.hour
    }

    private func barColor(tokens: Int) -> Color {
        let max = hourTotals.map(\.tokens).max() ?? 0
        guard max > 0 else { return Color.primary.opacity(0.1) }
        let ratio = Double(tokens) / Double(max)
        if ratio > 0.75 { return Color(red: 0.97, green: 0.55, blue: 0.20) }
        if ratio > 0.4  { return Color(red: 0.42, green: 0.60, blue: 0.97) }
        return Color(red: 0.42, green: 0.60, blue: 0.97).opacity(0.5)
    }

    private func formatHour(_ hour: Int) -> String {
        switch hour {
        case 0:  return "12am"
        case 12: return "12pm"
        default: return hour < 12 ? "\(hour)am" : "\(hour - 12)pm"
        }
    }

    private func hourKey(_ hour: Int) -> String {
        String(format: "%02d", hour)
    }

    private func formatTokens(_ tokens: Int) -> String {
        if tokens < 1_000 { return "\(tokens)" }
        if tokens < 1_000_000 { return String(format: "%.1fk", Double(tokens) / 1_000) }
        return String(format: "%.1fM", Double(tokens) / 1_000_000)
    }
}
