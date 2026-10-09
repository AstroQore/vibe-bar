import SwiftUI
import VibeBarCore

/// One card per harness: score and rating, the four parts of the score,
/// and the prompt measurements behind them. The formula lives in Core
/// (`UsageDashboardBuilder.healthScores`) and is spelled out in the score's
/// tooltip.
struct UsageHealthSection: View, Equatable {
    let density: Theme.Density
    let health: [UsageDashboardSnapshot.HarnessHealth]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(L10n.Workbench.Usage.Health.title)
                    .font(.system(size: density.titleFontSize, weight: .semibold))
                Text(L10n.Workbench.Usage.Health.subtitle)
                    .font(.system(size: max(10, density.subtitleFontSize - 1)))
                    .foregroundStyle(.secondary)
            }
            if health.isEmpty {
                CardShell(density: density) {
                    UsageEmptyMessage(density: density, text: L10n.Workbench.Usage.Health.empty, systemImage: "stethoscope")
                }
            } else {
                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 300), spacing: density.interSectionSpacing, alignment: .top)],
                    alignment: .leading,
                    spacing: density.interSectionSpacing
                ) {
                    ForEach(health) { entry in
                        UsageHealthCard(density: density, health: entry)
                    }
                }
            }
        }
    }
}

struct UsageHealthCard: View, Equatable {
    let density: Theme.Density
    let health: UsageDashboardSnapshot.HarnessHealth

    var body: some View {
        CardShell(density: density, spacing: 12) {
            header
            subscores
            Divider().opacity(0.5)
            metrics
            if !health.models.isEmpty {
                models
            }
            Text(L10n.Workbench.Usage.Health.composition)
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 10) {
            HarnessBrandBadge(harness: health.harness, iconSize: 16, containerSize: 26, brandColored: true)
            VStack(alignment: .leading, spacing: 2) {
                Text(health.harness.displayName)
                    .font(.system(size: 13.5, weight: .semibold))
                Text(L10n.Workbench.Usage.Health.counts(
                    requests: AppLocale.number(health.requests),
                    sessions: AppLocale.number(health.sessions)
                ))
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 1) {
                Text(health.score.map(AppLocale.number) ?? "—")
                    .font(.system(size: 26, weight: .bold, design: .rounded).monospacedDigit())
                    .foregroundStyle(health.rating.tint)
                Text(health.rating.title)
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(health.rating.tint)
            }
            .help(L10n.Workbench.Usage.Health.scoreHelp)
        }
    }

    private var subscores: some View {
        HStack(spacing: 10) {
            subscore(L10n.Usage.Mix.Flow.cache, health.cacheScore)
            subscore(L10n.Workbench.Usage.Health.Sub.leanStart, health.leanStartScore)
            subscore(L10n.Workbench.Usage.Health.Sub.pace, health.paceScore)
            subscore(L10n.Workbench.Usage.Health.Sub.reliability, health.reliabilityScore)
        }
    }

    private func subscore(_ title: String, _ value: Int?) -> some View {
        let rating = UsageDashboardSnapshot.HealthRating(score: value)
        return VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(title)
                    .font(.system(size: 9.5, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
                Spacer(minLength: 0)
                Text(value.map(AppLocale.number) ?? "—")
                    .font(.system(size: 10.5, weight: .semibold, design: .rounded).monospacedDigit())
            }
            UsageShareBar(fraction: Double(value ?? 0) / 100, tint: rating.tint, height: 4)
        }
        .frame(maxWidth: .infinity)
    }

    private var metrics: some View {
        Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 5) {
            GridRow {
                metric(L10n.Workbench.Usage.Health.Metric.typical, tokens(health.typicalPrompt))
                metric(L10n.Workbench.Usage.Health.Metric.largest, tokens(health.maxPrompt))
            }
            GridRow {
                metric(L10n.Workbench.Usage.Health.Metric.start, tokens(health.startSize))
                metric(L10n.Workbench.Usage.Health.Metric.growth, tokens(health.growthPerRequest))
            }
            GridRow {
                metric(L10n.Workbench.Usage.Health.Metric.cacheHit, UsageDashboardFormat.percent(health.cacheHitRate))
                metric(L10n.Workbench.Usage.Health.Metric.window, health.contextWindow.map { UsageDashboardFormat.tokens(Int64($0)) } ?? "—")
            }
            if let failures = health.toolFailureRate {
                GridRow {
                    metric(L10n.Workbench.Usage.Health.Metric.failures, UsageDashboardFormat.percent(failures, digits: 1))
                    Color.clear.gridCellUnsizedAxes([.horizontal, .vertical])
                }
            }
        }
    }

    private func metric(_ title: String, _ value: String) -> some View {
        HStack(spacing: 6) {
            Text(title)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer(minLength: 4)
            Text(value)
                .font(.system(size: 11.5, weight: .semibold, design: .rounded).monospacedDigit())
        }
        .font(.system(size: 11))
        .frame(maxWidth: .infinity)
    }

    private var models: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(L10n.Workbench.Usage.Health.models)
                .font(.system(size: 9.5, weight: .semibold))
                .foregroundStyle(.tertiary)
            HStack(spacing: 5) {
                ForEach(health.models, id: \.self) { model in
                    Text(UsageDashboardFormat.modelName(model))
                        .font(.system(size: 10.5, weight: .medium))
                        .lineLimit(1)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2.5)
                        .background(Capsule().fill(health.harness.usageTint.opacity(0.12)))
                        .help(model)
                }
            }
        }
    }

    private func tokens(_ value: Int64?) -> String {
        value.map(UsageDashboardFormat.tokens) ?? "—"
    }
}
