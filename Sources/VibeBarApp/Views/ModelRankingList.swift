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
    /// Right-hand subtitle next to the card title. Defaults to the all-time
    /// scope; the Overview's combined card overrides it with the
    /// all-providers wording so the scope is unambiguous.
    var subtitle: String = L10n.Cost.modelRankingAllTime

    @EnvironmentObject var environment: AppEnvironment

    init(snapshot: CostSnapshot?, density: Theme.Density, maxHeight: CGFloat = 180, subtitle: String = L10n.Cost.modelRankingAllTime) {
        self.breakdowns = snapshot?.modelBreakdowns ?? []
        self.density = density
        self.maxHeight = maxHeight
        self.subtitle = subtitle
    }

    init(
        breakdowns: [CostSnapshot.ModelBreakdown],
        density: Theme.Density,
        maxHeight: CGFloat = 180,
        subtitle: String = L10n.Cost.modelRankingAllTime
    ) {
        self.breakdowns = breakdowns
        self.density = density
        self.maxHeight = maxHeight
        self.subtitle = subtitle
    }

    var body: some View {
        let models = filteredModels(breakdowns)
        // `total(models)` used to be called inside the loop, so the reduce
        // ran once per row for a number that is the same for every row.
        let totalCost = total(models)
        if !models.isEmpty {
            VStack(alignment: .leading, spacing: density.bucketRowSpacing) {
                HStack(alignment: .firstTextBaseline) {
                    Text(L10n.Cost.modelRankingTitle)
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
                    // Lazy: the list scrolls to as many models as the user has
                    // ever run, and only a handful are on screen at once.
                    LazyVStack(alignment: .leading, spacing: 4) {
                        ForEach(Array(models.enumerated()), id: \.element.id) { index, model in
                            row(rank: index + 1, model: model, total: totalCost)
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
                Text(L10n.Cost.modelRankingRank(rank: rank))
                    .font(.system(size: max(9, density.subtitleFontSize - 1), weight: .bold, design: .rounded).monospacedDigit())
                    .foregroundStyle(rankColor(rank))
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                    .frame(width: 34, alignment: .leading)
                Text(UsageModelNaming.canonicalDisplayName(model.modelName))
                    .font(.system(size: density.subtitleFontSize, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(model.modelName)
                Spacer(minLength: 6)
                Text(formatCost(model.costUSD))
                    .font(.system(size: density.subtitleFontSize, weight: .semibold, design: .rounded).monospacedDigit())
                    .foregroundStyle(.primary)
                Text(L10n.Common.percent(value: Int(share.rounded())))
                    .font(.system(size: density.resetCountdownFontSize, design: .rounded).monospacedDigit())
                    .foregroundStyle(.tertiary)
                    .frame(width: 32, alignment: .trailing)
            }
            // Inline share bar so eye-tracking the column is easy. Drawn in a
            // `Canvas` rather than a `GeometryReader` per row: the bar needs
            // its own width, and a Canvas gets it at draw time instead of
            // adding a layout container to every row of the list.
            Canvas { context, size in
                let track = CGRect(origin: .zero, size: size)
                context.fill(
                    Path(roundedRect: track, cornerRadius: min(track.width, track.height) / 2),
                    with: .color(Color.primary.opacity(0.05))
                )
                let fill = CGRect(
                    x: 0,
                    y: 0,
                    width: max(2, size.width * share / 100),
                    height: size.height
                )
                context.fill(
                    Path(roundedRect: fill, cornerRadius: min(fill.width, fill.height) / 2),
                    with: .color(rankColor(rank).opacity(0.6))
                )
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
