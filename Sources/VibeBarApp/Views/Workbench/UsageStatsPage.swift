import SwiftUI
import VibeBarCore

/// The Workbench's Usage Stats page.
///
/// The filter bar is a fixed command surface; only the analytical content
/// scrolls. Keeping the active range/providers in view makes a long table
/// remain explainable instead of losing its query context above the fold.
struct UsageStatsPage: View {
    let density: Theme.Density
    @ObservedObject var model: UsageStatsViewModel

    var body: some View {
        VStack(spacing: 0) {
            UsageFiltersBar(density: density, model: model)
                .padding(.horizontal, density.popoverPaddingH)
                .padding(.top, density.popoverPaddingV)
                .padding(.bottom, max(8, density.popoverPaddingV / 2))

            Divider().opacity(0.45)

            ScrollView {
                VStack(alignment: .leading, spacing: density.interSectionSpacing) {
                    if !model.isLedgerAvailable {
                        unavailableCard
                    } else if HarnessSelection.isNothing(model.selectedHarnesses) {
                        noHarnessCard
                    } else {
                        UsageHeroCards(density: density, summary: model.summary)
                        UsageTrendChartView(density: density, model: model)
                        UsageDistributionDashboard(
                            density: density,
                            summary: model.summary,
                            harnesses: model.harnessStats,
                            providers: model.companyProviderStats,
                            models: model.modelStats,
                            projects: model.projectStats
                        )
                        UsageBreakdownTables(density: density, model: model)
                    }
                }
                .padding(.horizontal, density.popoverPaddingH)
                .padding(.vertical, density.popoverPaddingV)
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task {
            model.activate()
            // Held open on purpose: the auto-refresh poll should stop when
            // this page goes away, and a `.task` that returns immediately
            // cannot tell it that.
            await model.pollWhileVisible()
        }
    }

    /// The explicit empty selection the All chip can reach. Every number on
    /// this page would be a zero, and a page of zeroes reads as "you used
    /// nothing" rather than "you asked for nothing".
    private var noHarnessCard: some View {
        CardShell(density: density, alignment: .center) {
            Image(systemName: "line.3.horizontal.decrease.circle")
                .font(.system(size: 26, weight: .light))
                .foregroundStyle(.secondary)
            Text("No harness selected — pick one above")
                .font(.system(size: density.titleFontSize, weight: .semibold))
                .multilineTextAlignment(.center)
            Text("The All harnesses chip is a switch: click it again to put "
                + "every harness back in the query.")
                .font(.system(size: density.subtitleFontSize))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
        }
        .frame(maxWidth: .infinity)
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
