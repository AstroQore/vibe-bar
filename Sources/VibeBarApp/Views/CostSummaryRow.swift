import SwiftUI
import VibeBarCore

/// 4-column timeframe summary: Today / 7d / 30d / All. Hidden when no JSONL
/// session logs were found (otherwise we'd mislead web-only users into
/// thinking they spent $0 this month).
struct CostSummaryRow: View {
    let snapshot: CostSnapshot?
    let density: Theme.Density

    var body: some View {
        if let snapshot, snapshot.jsonlFilesFound > 0 {
            HStack(alignment: .top, spacing: 0) {
                ForEach(CostTimeframe.allCases) { tf in
                    column(label: tf.shortLabel, cost: tf.cost(in: snapshot), tokens: tf.tokens(in: snapshot))
                    if tf != .all {
                        Divider()
                            .frame(height: 28)
                            .padding(.vertical, 2)
                    }
                }
            }
            .padding(.top, density.bucketRowSpacing)
        } else {
            EmptyView()
        }
    }

    @ViewBuilder
    private func column(label: String, cost: Double, tokens: Int) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label.uppercased())
                .font(.system(size: max(8, density.subtitleFontSize - 2), weight: .semibold))
                .foregroundStyle(.tertiary)
                .tracking(0.4)
            Text(formatCost(cost))
                .font(.system(size: density.bucketTitleFontSize, weight: .semibold, design: .rounded).monospacedDigit())
                .foregroundStyle(.primary)
            Text(formatTokens(tokens))
                .font(.system(size: max(9, density.subtitleFontSize - 1), design: .rounded).monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 6)
    }

    private func formatCost(_ value: Double) -> String {
        if value < 0.01 { return "$0.00" }
        if value < 100 { return String(format: "$%.2f", value) }
        return String(format: "$%.0f", value)
    }

    private func formatTokens(_ tokens: Int) -> String {
        if tokens < 1_000 { return "\(tokens) tok" }
        if tokens < 1_000_000 { return String(format: "%.1fk tok", Double(tokens) / 1_000) }
        return String(format: "%.2fM tok", Double(tokens) / 1_000_000)
    }
}
