import SwiftUI
import VibeBarCore

/// Compact tile showing the user's most-used model by cost in the last 7 days.
/// Format:
///   ```
///   TOP MODEL
///   gpt-5.5
///   $1,234 · 12.3M tok · 43%
///   ```
/// where 43% is this model's share of the last-7-days spend.
struct TopModelTile: View {
    let snapshot: CostSnapshot?
    let density: Theme.Density

    var body: some View {
        if let model = snapshot?.last7DaysModelBreakdowns.first, let snapshot {
            let share = snapshot.last7DaysCostUSD > 0
                ? (model.costUSD / snapshot.last7DaysCostUSD) * 100
                : 0
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 4) {
                    Image(systemName: "trophy.fill")
                        .font(.system(size: max(8, density.subtitleFontSize - 2)))
                        .foregroundStyle(Color(red: 0.96, green: 0.78, blue: 0.30))
                    Text("TOP MODEL")
                        .font(.system(size: max(8, density.subtitleFontSize - 2), weight: .semibold))
                        .foregroundStyle(.tertiary)
                        .tracking(0.4)
                    Text("7D")
                        .font(.system(size: max(8, density.subtitleFontSize - 2), weight: .bold))
                        .foregroundStyle(.secondary)
                }
                Text(model.modelName)
                    .font(.system(size: density.bucketTitleFontSize, weight: .semibold, design: .rounded))
                    .lineLimit(1)
                    .truncationMode(.middle)
                HStack(spacing: 6) {
                    Text(formatCost(model.costUSD))
                        .font(.system(size: density.subtitleFontSize, weight: .semibold, design: .rounded).monospacedDigit())
                        .foregroundStyle(.secondary)
                    Text("·")
                        .font(.system(size: density.subtitleFontSize))
                        .foregroundStyle(.tertiary)
                    Text(formatTokens(model.totalTokens))
                        .font(.system(size: density.subtitleFontSize, design: .rounded).monospacedDigit())
                        .foregroundStyle(.secondary)
                    if share > 0 {
                        Text("·")
                            .font(.system(size: density.subtitleFontSize))
                            .foregroundStyle(.tertiary)
                        Text("\(Int(share.rounded()))% share")
                            .font(.system(size: density.subtitleFontSize, design: .rounded).monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .padding(.horizontal, density.cardPadding - 2)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.accentColor.opacity(0.08))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(Color.accentColor.opacity(0.25), lineWidth: 0.5)
            )
        }
    }

    private func formatCost(_ value: Double) -> String {
        if value < 0.01 { return "$0.00" }
        if value < 100  { return String(format: "$%.2f", value) }
        return String(format: "$%.0f", value)
    }

    private func formatTokens(_ tokens: Int) -> String {
        if tokens < 1_000 { return "\(tokens) tok" }
        if tokens < 1_000_000 { return String(format: "%.1fk tok", Double(tokens) / 1_000) }
        return String(format: "%.2fM tok", Double(tokens) / 1_000_000)
    }
}
