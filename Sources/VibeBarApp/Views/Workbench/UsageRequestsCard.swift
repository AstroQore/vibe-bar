import SwiftUI
import VibeBarCore

/// The request log the previous page's Requests tab held: every ledger row in
/// the query, newest first, paged with the ledger's keyset cursor. The only
/// per-request view on the page — the cards above aggregate the same rows.
struct UsageRequestsCard: View {
    let density: Theme.Density
    let model: UsageStatsViewModel

    private static var timeFormatter: DateFormatter { AppLocale.dateFormatter(template: "MMMdHHmmss") }

    var body: some View {
        CardShell(density: density, spacing: 8) {
            UsageCardHeader(density: density, title: L10n.Usage.Breakdown.requests) {
                if model.requestTotal > 0 {
                    Text(L10n.Usage.requestCount(count: AppLocale.number(model.requestTotal)))
                        .font(.system(size: 11, weight: .semibold, design: .rounded).monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            if model.requestRows.isEmpty {
                if model.isLoadingRequests {
                    ProgressView().controlSize(.small).frame(maxWidth: .infinity, minHeight: 60)
                } else {
                    UsageEmptyMessage(density: density, text: L10n.Usage.Table.emptyRequests, systemImage: "list.bullet.rectangle")
                }
            } else {
                header
                LazyVStack(spacing: 0) {
                    ForEach(model.requestRows) { row in
                        UsageRequestRowView(row: row, time: Self.timeFormatter.string(from: row.date))
                    }
                }
                HStack {
                    Text(L10n.Workbench.Usage.Recent.showing(
                        shown: AppLocale.number(model.requestRows.count),
                        total: AppLocale.number(max(model.requestTotal, model.requestRows.count))
                    ))
                    .font(.system(size: 10.5))
                    .foregroundStyle(.tertiary)
                    Spacer()
                    if model.hasMoreRequests {
                        Button {
                            model.loadMoreRequests()
                        } label: {
                            Text(model.isLoadingRequests
                                ? L10n.Usage.Table.loadingMore
                                : L10n.Usage.Table.loadMore(remaining: max(0, model.requestTotal - model.requestRows.count)))
                                .font(.system(size: 11, weight: .semibold))
                        }
                        .buttonStyle(WorkbenchPillButtonStyle())
                        .disabled(model.isLoadingRequests)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .onAppear { model.loadRequestsIfNeeded() }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Text(L10n.Usage.Table.Column.time).frame(width: 118, alignment: .leading)
            Text(L10n.Usage.Table.Column.harness).frame(width: 120, alignment: .leading)
            Text(L10n.Usage.Table.Column.model).frame(maxWidth: .infinity, alignment: .leading)
            Text(L10n.Usage.Tokens.input).frame(width: 62, alignment: .trailing)
            Text(L10n.Usage.Tokens.output).frame(width: 58, alignment: .trailing)
            Text(L10n.Usage.Mix.Flow.cache).frame(width: 74, alignment: .trailing)
            Text(L10n.Cost.title).frame(width: 64, alignment: .trailing)
        }
        .font(.system(size: 9.5, weight: .semibold))
        .foregroundStyle(.tertiary)
        .lineLimit(1)
        .padding(.horizontal, 6)
    }
}

private struct UsageRequestRowView: View, Equatable {
    let row: UsageRequestRow
    let time: String

    var body: some View {
        HStack(spacing: 10) {
            Text(time)
                .foregroundStyle(.secondary)
                .frame(width: 118, alignment: .leading)
            HStack(spacing: 5) {
                HarnessBrandIconView(harness: row.harness, size: 11, brandColored: true)
                Text(row.harness.displayName).lineLimit(1)
            }
            .frame(width: 120, alignment: .leading)
            Text(UsageDashboardFormat.modelName(row.model))
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
                .help(row.model)
            Text(UsageDashboardFormat.tokens(row.freshInput)).frame(width: 62, alignment: .trailing)
            Text(UsageDashboardFormat.tokens(row.output)).frame(width: 58, alignment: .trailing)
            Text(UsageDashboardFormat.tokens(row.cacheRead + row.cacheCreation)).frame(width: 74, alignment: .trailing)
            Text(row.costMicros.map(UsageFormatting.compactUSD) ?? L10n.Usage.Table.unpriced)
                .foregroundStyle(row.costMicros == nil ? Color.orange : Color.primary)
                .frame(width: 64, alignment: .trailing)
        }
        .font(.system(size: 11, design: .rounded).monospacedDigit())
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
    }
}
