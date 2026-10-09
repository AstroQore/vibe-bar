import SwiftUI
import VibeBarCore

/// The Workbench's Usage page.
///
/// The filter bar is a fixed command surface; the cards scroll under it.
/// Every card takes a slice of one `UsageDashboardSnapshot` and is
/// `Equatable` on it, so a snapshot that changes one number re-lays out
/// only the card that shows it.
struct UsageStatsPage: View {
    let density: Theme.Density
    let model: UsageStatsViewModel
    /// Opens a session on the Sessions page.
    let onOpenSession: (SessionSummary) -> Void

    var body: some View {
        VStack(spacing: 0) {
            UsageFiltersBar(density: density, model: model)
                .padding(.horizontal, density.popoverPaddingH)
                .padding(.top, density.popoverPaddingV)
                .padding(.bottom, max(8, density.popoverPaddingV / 2))

            Divider().opacity(0.45)

            ScrollView {
                // Lazy: a card below the fold is neither built nor measured
                // when a snapshot lands, so a filter change costs the cards on
                // screen, not the page.
                LazyVStack(alignment: .leading, spacing: density.interSectionSpacing) {
                    if !model.isLedgerAvailable {
                        unavailableCard
                    } else if HarnessSelection.isNothing(model.selectedHarnesses) {
                        noHarnessCard
                    } else {
                        content(model.snapshot)
                    }
                }
                .padding(.horizontal, density.popoverPaddingH)
                .padding(.vertical, density.popoverPaddingV)
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task {
            UsageStallProbe.shared.start()
            model.activate()
            // Held open on purpose: the background fill should stop when
            // this page goes away, and a `.task` that returns immediately
            // cannot tell it that.
            await model.pollWhileVisible()
        }
    }

    @ViewBuilder
    private func content(_ snapshot: UsageDashboardSnapshot) -> some View {
        UsageStatusLine(
            density: density,
            coverage: snapshot.coverage,
            isEnriching: model.isEnriching,
            isBuildingIndex: model.isBuildingIndex,
            isLoading: model.isLoading
        )
        .equatable()
        UsageHeroCards(density: density, hero: snapshot.hero)
            .equatable()
        UsageTrendChartView(density: density, trend: snapshot.trend)
            .equatable()
        UsageMixRow(density: density, tokens: snapshot.hero.tokens, mix: snapshot.mix)
            .equatable()
        pair {
            UsageRankingCard(density: density, kind: .projects, ranking: snapshot.projects).equatable()
        } trailing: {
            UsageRankingCard(density: density, kind: .models, ranking: snapshot.models).equatable()
        }
        pair {
            UsageHeatmapCard(density: density, heatmap: snapshot.heatmap).equatable()
        } trailing: {
            UsageSessionShapeCard(density: density, shape: snapshot.shape).equatable()
        }
        UsageTopSessionsCard(density: density, top: snapshot.topSessions, onOpen: onOpenSession)
            .equatable()
        pair {
            UsageSkillsCard(density: density, skills: snapshot.skills).equatable()
        } trailing: {
            UsageToolsCard(density: density, tools: snapshot.tools).equatable()
        }
        UsageHealthSection(density: density, health: snapshot.health)
            .equatable()
        UsageRecentSessionsCard(
            density: density,
            sessions: snapshot.recentSessions,
            totalInRange: snapshot.coverage.sessionsInRange,
            onOpen: onOpenSession
        )
        .equatable()
        UsageRequestsCard(density: density, model: model)
    }

    /// Two cards side by side at the taller one's height.
    private func pair<Leading: View, Trailing: View>(
        @ViewBuilder _ leading: () -> Leading,
        @ViewBuilder trailing: () -> Trailing
    ) -> some View {
        HStack(alignment: .top, spacing: density.interSectionSpacing) {
            leading()
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            trailing()
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    /// The explicit empty selection the All chip can reach. Every number on
    /// this page would be a zero, and a page of zeroes reads as "you used
    /// nothing" rather than "you asked for nothing".
    private var noHarnessCard: some View {
        CardShell(density: density, alignment: .center) {
            Image(systemName: "line.3.horizontal.decrease.circle")
                .font(.system(size: 26, weight: .light))
                .foregroundStyle(.secondary)
            Text(L10n.Usage.NoHarnessSelected.title)
                .font(.system(size: density.titleFontSize, weight: .semibold))
                .multilineTextAlignment(.center)
            Text(L10n.Usage.NoHarnessSelected.detail)
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
            Text(L10n.Usage.LedgerUnavailable.title)
                .font(.system(size: density.titleFontSize, weight: .semibold))
            Text(L10n.Usage.LedgerUnavailable.detail)
                .font(.system(size: density.subtitleFontSize))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
        }
        .frame(maxWidth: .infinity)
    }
}

/// What the page is still working on and what its numbers cover: the
/// background fill's progress, sessions it will not reach, the hourly
/// floor, and a project filter's missing rollups. Nothing when all is in.
struct UsageStatusLine: View, Equatable {
    let density: Theme.Density
    let coverage: UsageDashboardSnapshot.Coverage
    let isEnriching: Bool
    let isBuildingIndex: Bool
    let isLoading: Bool

    private var notes: [(String, String)] {
        var notes: [(String, String)] = []
        if isBuildingIndex {
            notes.append(("arrow.triangle.2.circlepath", L10n.Workbench.Usage.Status.indexEmpty))
        }
        let total = max(0, coverage.analyzable - coverage.skipped)
        if isEnriching, coverage.pending > 0 {
            notes.append(("hourglass", L10n.Workbench.Usage.Status.analyzing(ready: coverage.analyzed, total: total)))
        }
        if coverage.skipped > 0 {
            notes.append(("exclamationmark.circle", L10n.Workbench.Usage.Status.skipped(count: coverage.skipped)))
        }
        if let from = coverage.hourlyFrom {
            notes.append(("clock.badge.questionmark", L10n.Workbench.Usage.Status.hourlyFrom(date: UsageDashboardFormat.day(from))))
        }
        if coverage.excludesRollups {
            notes.append(("folder.badge.questionmark", L10n.Workbench.Usage.Status.projectDetailOnly))
        }
        return notes
    }

    var body: some View {
        let notes = self.notes
        if !notes.isEmpty || isLoading {
            HStack(spacing: 14) {
                if isLoading {
                    ProgressView()
                        .controlSize(.mini)
                }
                ForEach(Array(notes.enumerated()), id: \.offset) { _, note in
                    Label(note.1, systemImage: note.0)
                        .labelStyle(UsageCompactLabelStyle())
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .font(.system(size: 10.5))
            .foregroundStyle(.secondary)
            .frame(minHeight: 16)
        }
    }
}
