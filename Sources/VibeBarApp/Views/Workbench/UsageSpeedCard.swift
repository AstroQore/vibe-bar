import SwiftUI
import VibeBarCore

/// Median output speed and time to first token, per harness and per model,
/// side by side. Every figure is `UsageSpeedSamples.stat` over the timed
/// detail rows of the query — the same per-request numbers the request log's
/// Speed and First token columns show — and the bar under each row is its
/// median against the fastest row of its half.
///
/// `Equatable` on its slice of the snapshot, so a snapshot that leaves the
/// timing unchanged does not re-lay it out.
struct UsageSpeedCard: View, Equatable {
    let density: Theme.Density
    let speed: UsageDashboardSnapshot.Speed

    private static let speedWidth: CGFloat = 76
    private static let firstTokenWidth: CGFloat = 74
    private static let countWidth: CGFloat = 52

    var body: some View {
        CardShell(density: density, spacing: 12) {
            UsageCardHeader(
                density: density,
                title: L10n.Workbench.Usage.Speed.title,
                subtitle: L10n.Workbench.Usage.Speed.subtitle
            ) {
                if speed.timedRequests > 0 {
                    Text(L10n.Workbench.Usage.Speed.samples(count: speed.timedRequests))
                        .font(.system(size: 11, weight: .semibold, design: .rounded).monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            if speed.byHarness.isEmpty {
                UsageEmptyMessage(
                    density: density,
                    text: L10n.Workbench.Usage.Speed.empty,
                    systemImage: "gauge.with.dots.needle.50percent"
                )
            } else {
                HStack(alignment: .top, spacing: density.interSectionSpacing) {
                    half(title: L10n.Workbench.Usage.Speed.byHarness, rows: speed.byHarness)
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                    Divider()
                    half(title: L10n.Workbench.Usage.Speed.byModel, rows: speed.byModel)
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                }
                .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private func half(title: String, rows: [UsageDashboardSnapshot.SpeedRow]) -> some View {
        // Read once per half, not once per row.
        let fastest = rows.compactMap(\.stat.medianTokensPerSecond).max() ?? 0
        return VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 8) {
                Text(title)
                    .frame(maxWidth: .infinity, alignment: .leading)
                UsageHelpLabel(title: L10n.Usage.Table.Column.speed, help: L10n.Usage.Table.speedHelp)
                    .frame(width: Self.speedWidth, alignment: .trailing)
                UsageHelpLabel(title: L10n.Usage.Table.Column.firstToken, help: L10n.Usage.Table.firstTokenHelp)
                    .frame(width: Self.firstTokenWidth, alignment: .trailing)
                Text(L10n.Usage.Table.Column.requests)
                    .frame(width: Self.countWidth, alignment: .trailing)
            }
            .font(.system(size: 9.5, weight: .semibold))
            .foregroundStyle(.tertiary)
            .lineLimit(1)
            ForEach(rows) { row in
                speedRow(row, fastest: fastest)
            }
        }
    }

    private func speedRow(_ row: UsageDashboardSnapshot.SpeedRow, fastest: Double) -> some View {
        let tint = row.harness?.usageTint ?? .teal
        let median = row.stat.medianTokensPerSecond
        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                HStack(spacing: 6) {
                    if let harness = row.harness {
                        HarnessBrandIconView(harness: harness, size: 12, brandColored: true)
                        Text(harness.displayName)
                    } else {
                        Image(systemName: "cpu")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(tint)
                        Text(row.model.map(UsageDashboardFormat.modelName) ?? row.id)
                            .truncationMode(.middle)
                    }
                }
                .font(.system(size: 12, weight: .medium))
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
                Text(UsageDashboardFormat.speed(median))
                    .font(.system(size: 12, weight: .semibold, design: .rounded).monospacedDigit())
                    .frame(width: Self.speedWidth, alignment: .trailing)
                Text(UsageDashboardFormat.firstToken(milliseconds: row.stat.medianFirstTokenMs))
                    .font(.system(size: 11.5, design: .rounded).monospacedDigit())
                    .frame(width: Self.firstTokenWidth, alignment: .trailing)
                Text(AppLocale.number(row.stat.requestsWithTiming))
                    .font(.system(size: 10.5, design: .rounded).monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: Self.countWidth, alignment: .trailing)
            }
            UsageShareBar(
                fraction: fastest > 0 ? (median ?? 0) / fastest : 0,
                tint: tint.opacity(0.85),
                height: 4
            )
        }
        // One tooltip per row: the model id behind a display name, and the
        // spread behind the median.
        .help(rowHelp(row))
        .accessibilityElement(children: .combine)
    }

    private func rowHelp(_ row: UsageDashboardSnapshot.SpeedRow) -> String {
        let spread = row.stat.medianTokensPerSecond.map { median in
            L10n.Workbench.Usage.Speed.p90Help(
                median: UsageDashboardFormat.speedNumber(median),
                p90: UsageDashboardFormat.speedNumber(row.stat.p90TokensPerSecond ?? median)
            )
        }
        return [row.model, spread].compactMap { $0 }.joined(separator: "\n")
    }
}
