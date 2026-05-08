import SwiftUI
import AppKit
import VibeBarCore

/// The Misc tab inside the Overview popover. Renders a card for each
/// provider in `ToolType.miscProviders`, regardless of credential
/// presence. Adapters land in subsequent commits; for now every card
/// shows a "Set up" placeholder that opens the matching Settings
/// section.
struct MiscProvidersPage: View {
    let density: Theme.Density

    @EnvironmentObject var environment: AppEnvironment
    @EnvironmentObject var quotaService: QuotaService

    var body: some View {
        // Two columns at regular / spacious density, single column
        // at compact. Mirrors the Overview waterfall but without the
        // anchored quota cards (every misc card is interchangeable).
        let columns = density.popoverWidth >= 460 ? 2 : 1
        ColumnMasonryLayout(columns: columns, spacing: density.interSectionSpacing, anchoredItems: 0) {
            ForEach(ToolType.miscProviders, id: \.self) { tool in
                MiscProviderCard(tool: tool, density: density)
            }
        }
    }
}

/// Single-provider card on the Misc page. Three states:
/// - **Set up** — no credential configured. CTA opens Settings.
/// - **Loaded** — `AccountQuota` carries usage buckets; render them.
/// - **Error** — adapter returned a `QuotaError`; render its message
///   as a soft tint.
struct MiscProviderCard: View {
    let tool: ToolType
    let density: Theme.Density

    @EnvironmentObject var environment: AppEnvironment
    @EnvironmentObject var quotaService: QuotaService
    @EnvironmentObject var settingsStore: SettingsStore

    var body: some View {
        VStack(alignment: .leading, spacing: density.cardSpacing) {
            header
            Divider().opacity(0.25)
            content
        }
        .padding(density.cardPadding)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: density.cardCornerRadius, style: .continuous)
                .fill(.background.tertiary.opacity(0.6))
        )
        .overlay(
            RoundedRectangle(cornerRadius: density.cardCornerRadius, style: .continuous)
                .stroke(.separator.opacity(0.4), lineWidth: 0.5)
        )
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: tool.miscFallbackSymbol)
                .font(.system(size: density.bucketTitleFontSize, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 18, alignment: .leading)
            VStack(alignment: .leading, spacing: 2) {
                Text(tool.menuTitle)
                    .font(.system(size: density.bucketTitleFontSize, weight: .semibold))
                    .lineLimit(1)
                if let plan = quota?.plan, !plan.isEmpty {
                    Text(plan)
                        .font(.system(size: density.subtitleFontSize))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                } else {
                    Text(tool.subtitle)
                        .font(.system(size: density.subtitleFontSize))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 4)
            BorderlessIconButton(
                systemImage: "arrow.clockwise",
                help: "Refresh \(tool.menuTitle)",
                size: density.subtitleFontSize
            ) {
                guard let account = environment.account(for: tool) else { return }
                Task { _ = await quotaService.refresh(account) }
            }
            .disabled(isRefreshing)
        }
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        if let error = quota?.error {
            errorState(error)
        } else if let buckets = quota?.buckets, !buckets.isEmpty {
            VStack(alignment: .leading, spacing: density.bucketRowSpacing) {
                ForEach(buckets) { bucket in
                    miscBucketRow(bucket)
                }
                if let updated = quotaService.lastUpdatedByAccount[accountId] {
                    Text("Updated \(ResetCountdownFormatter.updatedAgo(from: updated, now: Date()))")
                        .font(.system(size: density.resetCountdownFontSize))
                        .foregroundStyle(.tertiary)
                }
            }
        } else {
            setupState
        }
    }

    private func miscBucketRow(_ bucket: QuotaBucket) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text(bucket.title)
                    .font(.system(size: density.bucketTitleFontSize - 1, weight: .medium))
                Spacer()
                Text("\(Int(bucket.usedPercent.rounded()))%")
                    .font(.system(size: density.bucketPercentFontSize, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(Theme.barColor(percent: bucket.usedPercent, mode: settingsStore.settings.displayMode))
            }
            ProgressView(value: min(max(bucket.usedPercent, 0), 100), total: 100)
                .progressViewStyle(.linear)
                .tint(Theme.barColor(percent: bucket.usedPercent, mode: settingsStore.settings.displayMode))
                .frame(height: density.bucketBarHeight)
            if let countdown = ResetCountdownFormatter.string(from: bucket.resetAt) {
                Text("Resets \(countdown)")
                    .font(.system(size: density.resetCountdownFontSize))
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private var setupState: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Not configured.")
                .font(.system(size: density.subtitleFontSize))
                .foregroundStyle(.secondary)
            Button {
                environment.showSettingsWindow()
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "gearshape")
                    Text("Set up in Settings")
                }
                .font(.system(size: density.subtitleFontSize, weight: .medium))
            }
            .buttonStyle(.borderless)
            .foregroundStyle(Color.accentColor)
        }
    }

    private func errorState(_ error: QuotaError) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 4) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                Text(error.userFacingMessage)
                    .font(.system(size: density.subtitleFontSize))
                    .foregroundStyle(.primary)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Button {
                environment.showSettingsWindow()
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "gearshape")
                    Text("Open Settings")
                }
                .font(.system(size: density.resetCountdownFontSize))
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
        }
    }

    // MARK: - State helpers

    private var accountId: String {
        AccountStore.miscAccountId(for: tool)
    }

    private var quota: AccountQuota? {
        environment.quota(for: tool)
    }

    private var isRefreshing: Bool {
        quotaService.inFlightAccountIds.contains(accountId)
    }
}
