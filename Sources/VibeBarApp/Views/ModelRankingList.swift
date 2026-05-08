import SwiftUI
import VibeBarCore

/// Scrollable model ranking — top N models by spend with share-of-total %.
///
/// Sourced from `CostSnapshot.modelBreakdowns`, which is populated from all
/// scanned model usage. Top Model intentionally uses a separate 7-day list.
///
/// Default shows 5 entries; the embedded ScrollView lets the user see more
/// if the user has been across many models.
struct ModelRankingList: View {
    let breakdowns: [CostSnapshot.ModelBreakdown]
    let density: Theme.Density
    var maxHeight: CGFloat = 180
    /// Right-hand subtitle next to "Model Ranking". Defaults to "All time"; the
    /// Overview's combined card overrides to "All providers · all time" so the
    /// scope is unambiguous.
    var subtitle: String = "All time"

    @EnvironmentObject var environment: AppEnvironment

    init(snapshot: CostSnapshot?, density: Theme.Density, maxHeight: CGFloat = 180, subtitle: String = "All time") {
        self.breakdowns = snapshot?.modelBreakdowns ?? []
        self.density = density
        self.maxHeight = maxHeight
        self.subtitle = subtitle
    }

    init(
        breakdowns: [CostSnapshot.ModelBreakdown],
        density: Theme.Density,
        maxHeight: CGFloat = 180,
        subtitle: String = "All time"
    ) {
        self.breakdowns = breakdowns
        self.density = density
        self.maxHeight = maxHeight
        self.subtitle = subtitle
    }

    var body: some View {
        let models = filteredModels(breakdowns)
        if !models.isEmpty {
            VStack(alignment: .leading, spacing: density.bucketRowSpacing) {
                HStack(alignment: .firstTextBaseline) {
                    Text("Model Ranking")
                        .font(.system(size: density.bucketTitleFontSize, weight: .semibold))
                    Spacer()
                    Text(subtitle)
                        .font(.system(size: density.resetCountdownFontSize))
                        .foregroundStyle(.tertiary)
                    SectionRefreshButton(isRefreshing: false) {
                        environment.refreshCostUsage()
                    }
                    .padding(.leading, 4)
                }
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(Array(models.enumerated()), id: \.element.id) { index, model in
                            row(rank: index + 1, model: model, total: total(models))
                        }
                    }
                }
                .frame(maxHeight: maxHeight)
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
    }

    private func filteredModels(_ models: [CostSnapshot.ModelBreakdown]) -> [CostSnapshot.ModelBreakdown] {
        models.filter { model in
            isValidModelName(model.modelName) && model.costUSD > 0
        }
    }

    private func isValidModelName(_ raw: String) -> Bool {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }

        let normalized = trimmed.lowercased()
        let invalidNames: Set<String> = [
            "-", "--", "_", "unknown", "null", "none", "n/a", "na", "model", "models"
        ]
        guard !invalidNames.contains(normalized) else { return false }

        // Numeric placeholders like "0", "1", or "2" are common artifacts
        // from malformed transcript entries and should not compete with real
        // model names such as "o1" or "gpt-5".
        return normalized.rangeOfCharacter(from: .letters) != nil
    }

    private func total(_ models: [CostSnapshot.ModelBreakdown]) -> Double {
        models.reduce(0) { $0 + $1.costUSD }
    }

    @ViewBuilder
    private func row(rank: Int, model: CostSnapshot.ModelBreakdown, total: Double) -> some View {
        let share = total > 0 ? (model.costUSD / total) * 100 : 0
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline) {
                Text("#\(rank)")
                    .font(.system(size: max(9, density.subtitleFontSize - 1), weight: .bold, design: .rounded).monospacedDigit())
                    .foregroundStyle(rankColor(rank))
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                    .frame(width: 34, alignment: .leading)
                Text(model.modelName)
                    .font(.system(size: density.subtitleFontSize, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 6)
                Text(formatCost(model.costUSD))
                    .font(.system(size: density.subtitleFontSize, weight: .semibold, design: .rounded).monospacedDigit())
                    .foregroundStyle(.primary)
                Text("\(Int(share.rounded()))%")
                    .font(.system(size: density.resetCountdownFontSize, design: .rounded).monospacedDigit())
                    .foregroundStyle(.tertiary)
                    .frame(width: 32, alignment: .trailing)
            }
            // Inline share bar so eye-tracking the column is easy.
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color.primary.opacity(0.05))
                    Capsule()
                        .fill(rankColor(rank).opacity(0.6))
                        .frame(width: max(2, proxy.size.width * share / 100))
                }
            }
            .frame(height: 4)
        }
        .padding(.vertical, 2)
    }

    private func rankColor(_ rank: Int) -> Color {
        switch rank {
        case 1: return Color(red: 0.96, green: 0.78, blue: 0.30)   // gold
        case 2: return Color(red: 0.78, green: 0.78, blue: 0.78)   // silver
        case 3: return Color(red: 0.85, green: 0.55, blue: 0.30)   // bronze
        default: return Color.secondary
        }
    }

    private func formatCost(_ value: Double) -> String {
        if value < 0.01 { return "$0.00" }
        if value < 100  { return String(format: "$%.2f", value) }
        return String(format: "$%.0f", value)
    }
}
