import SwiftUI
import VibeBarCore

/// The Workbench's Usage Stats page.
///
/// One scrolling column, coarse to fine: what is being counted (filters),
/// the four headline numbers, the shape of the range over time, and finally
/// the rows behind it. Every section is a `CardShell` at the window's density,
/// so the page reads as the same material as the popover's cards.
struct UsageStatsPage: View {
    let density: Theme.Density
    @ObservedObject var model: UsageStatsViewModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: density.interSectionSpacing) {
                UsageFiltersBar(density: density, model: model)
                if model.isLedgerAvailable {
                    UsageHeroCards(density: density, summary: model.summary)
                    UsageTrendChartView(density: density, series: model.trend)
                    UsageBreakdownTables(density: density, model: model)
                } else {
                    unavailableCard
                }
            }
            .padding(.horizontal, density.popoverPaddingH)
            .padding(.vertical, density.popoverPaddingV)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task { model.activate() }
    }

    private var unavailableCard: some View {
        CardShell(density: density, alignment: .center) {
            Image(systemName: "externaldrive.badge.exclamationmark")
                .font(.system(size: 26, weight: .light))
                .foregroundStyle(.secondary)
            Text("Usage ledger unavailable")
                .font(.system(size: density.titleFontSize, weight: .semibold))
            Text("The per-request ledger under ~/.vibebar could not be opened, "
                + "so only live cost cards are available this session.")
                .font(.system(size: density.subtitleFontSize))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
        }
        .frame(maxWidth: .infinity)
    }
}
