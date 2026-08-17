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
                    if model.isLedgerAvailable {
                        UsageHeroCards(density: density, summary: model.summary)
                        trendAndProviderMix
                        UsageBreakdownTables(density: density, model: model)
                    } else {
                        unavailableCard
                    }
                }
                .padding(.horizontal, density.popoverPaddingH)
                .padding(.vertical, density.popoverPaddingV)
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task { model.activate() }
    }

    /// The chart and provider mix are intentionally peers: the first answers
    /// "when", the second answers "who". `ViewThatFits` keeps that reading
    /// order when the Workbench narrows instead of compressing either surface
    /// into an unreadable card.
    private var trendAndProviderMix: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: density.interSectionSpacing) {
                UsageTrendChartView(density: density, model: model)
                    .frame(minWidth: 480, maxWidth: .infinity)
                UsageCompositionCards(
                    density: density,
                    summary: model.summary,
                    providers: model.companyProviderStats
                )
                .frame(minWidth: 300, maxWidth: .infinity)
            }
            VStack(alignment: .leading, spacing: density.interSectionSpacing) {
                UsageTrendChartView(density: density, model: model)
                UsageCompositionCards(
                    density: density,
                    summary: model.summary,
                    providers: model.companyProviderStats
                )
            }
        }
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
