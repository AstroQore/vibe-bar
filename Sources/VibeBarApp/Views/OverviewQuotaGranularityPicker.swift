import SwiftUI
import VibeBarCore

extension OverviewQuotaGranularity {
    var label: String {
        switch self {
        case .company: L10n.Settings.OverviewGranularity.company
        case .subProvider: L10n.Settings.OverviewGranularity.subProvider
        case .model: L10n.Settings.OverviewGranularity.model
        }
    }
}

struct OverviewQuotaGranularityPicker: View {
    @EnvironmentObject private var settingsStore: SettingsStore
    var body: some View {
        Picker(L10n.Settings.OverviewGranularity.title, selection: $settingsStore.settings.overviewQuotaGranularity) {
            ForEach(OverviewQuotaGranularity.allCases, id: \.self) { value in
                Text(value.label).tag(value)
            }
        }
        .pickerStyle(.menu)
        .fixedSize()
        .help(L10n.Settings.OverviewGranularity.help)
    }
}

/// Finer cards reuse the original bucket content, forecasts, freshness and
/// error rows. Splitting a card never changes the quota calculations.
struct OverviewQuotaPartitionCard: View {
    let partition: OverviewQuotaPartition
    let density: Theme.Density
    @EnvironmentObject private var environment: AppEnvironment
    @EnvironmentObject private var settingsStore: SettingsStore
    @EnvironmentObject private var quotaService: QuotaService

    private var accounts: [AccountIdentity] {
        let candidates = partition.tool == .gemini
            ? environment.accountStore.accounts(for: .gemini).sorted { $0.id < $1.id }
            : (environment.account(for: partition.tool).map { [$0] } ?? [])
        guard partition.granularity == .model, !partition.bucketIDs.isEmpty else { return candidates }
        let wanted = Set(partition.bucketIDs)
        return candidates.filter { account in
            guard let buckets = quotaService.cachedQuota(for: account.id)?.buckets, !buckets.isEmpty else { return true }
            return buckets.contains { wanted.contains($0.id) }
        }
    }

    var body: some View {
        let accounts = accounts
        let plan = settingsStore.settings.planBadgeLabel(for: partition.tool,
            quotaPlan: accounts.compactMap { quotaService.cachedQuota(for: $0.id)?.plan }.first,
            accountPlan: accounts.compactMap(\.plan).first)
        CardShell(density: density) {
            HStack {
                ProviderSectionTitle(tool: partition.tool, title: partition.tool.vendorName, subtitle: nil,
                    titleFontSize: density.titleFontSize, subtitleFontSize: density.subtitleFontSize,
                    iconSize: 16, badgeSize: 24)
                Spacer()
                Button { environment.refresh(partition.tool) } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.borderless).help(L10n.Common.refresh)
                    .disabled(accounts.contains { quotaService.inFlightAccountIds.contains($0.id) })
            }
            HStack(spacing: 6) {
                if partition.suppressGroupTitles { BrandMarkIconView(mark: .grokBot, size: 13) }
                else { ToolBrandIconView(tool: partition.tool, size: 13) }
                Text(partition.subProvider).font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
                Spacer(minLength: 4)
                if let plan { PlanBadgeView(text: plan, fontSize: max(9, density.subtitleFontSize - 1)) }
            }
            if accounts.isEmpty {
                content(accountId: nil)
            } else {
                ForEach(accounts, id: \.id) { account in content(accountId: account.id) }
            }
        }
    }

    private func content(accountId: String?) -> some View {
        ProviderQuotaCard(tool: partition.tool, accountId: accountId, density: density, compact: false,
            embedded: true, includedBucketIDs: partition.bucketIDs.isEmpty ? nil : Set(partition.bucketIDs),
            suppressGroupTitles: partition.suppressGroupTitles, showsResetCredits: partition.showsSharedMetadata)
    }
}
