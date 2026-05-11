import SwiftUI
import AppKit
import VibeBarCore

/// The Misc tab inside the Overview popover. Renders a card for each
/// provider checked in Misc settings. Hidden providers keep their
/// credentials/config but don't render cards.
struct MiscProvidersPage: View {
    let density: Theme.Density

    @EnvironmentObject var environment: AppEnvironment
    @EnvironmentObject var quotaService: QuotaService
    @EnvironmentObject var settingsStore: SettingsStore

    var body: some View {
        // The Misc page is intentionally denser than the primary
        // overview: every card is reorderable and receives the same
        // third-width column treatment.
        ColumnMasonryLayout(columns: 3, spacing: density.interSectionSpacing, anchoredItems: 0) {
            ForEach(settingsStore.settings.visibleMiscProviderList, id: \.self) { tool in
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
        HStack(alignment: .center, spacing: 10) {
            ToolBrandBadge(
                tool: tool,
                iconSize: max(17, density.bucketTitleFontSize + 1),
                containerSize: 26
            )
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
        let liveError = displayableError(quotaService.lastErrorByAccount[accountId], with: quota)
        if let buckets = quota?.buckets, !buckets.isEmpty {
            VStack(alignment: .leading, spacing: density.bucketRowSpacing) {
                ForEach(buckets) { bucket in
                    miscBucketRow(bucket)
                }
                if let updated = quotaService.lastUpdatedByAccount[accountId] {
                    Text(ResetCountdownFormatter.updatedAgo(from: updated, now: Date()))
                        .font(.system(size: density.resetCountdownFontSize))
                        .foregroundStyle(.tertiary)
                }
                if let liveError {
                    compactErrorText("Update failed: \(liveError.userFacingMessage)")
                }
            }
        } else if let liveError, liveError != .noCredential {
            errorState(liveError)
        } else {
            setupState
        }
    }

    private func displayableError(_ error: QuotaError?, with quota: AccountQuota?) -> QuotaError? {
        guard let error else { return nil }
        guard error.isCredentialState,
              let quota,
              !quota.buckets.isEmpty,
              Date().timeIntervalSince(quota.queriedAt) < 30 * 60
        else {
            return error
        }
        return nil
    }

    private func miscBucketRow(_ bucket: QuotaBucket) -> some View {
        // Honour the user's `displayMode` (used vs remaining) the same
        // way the primary `ProviderBucketRow` does. With the default
        // `.remaining` setting, "92%" means "92% remaining" and the
        // bar fills toward "full". Without this conversion the misc
        // cards always rendered used%, which read inverted next to
        // the OpenAI / Claude cards.
        let mode = settingsStore.settings.displayMode
        let percent = bucket.displayPercent(mode)
        return VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text(bucket.title)
                    .font(.system(size: density.bucketTitleFontSize - 1, weight: .medium))
                Spacer()
                Text("\(Int(percent.rounded()))%")
                    .font(.system(size: density.bucketPercentFontSize, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(Theme.barColor(percent: percent, mode: mode))
            }
            QuotaBarShape(percent: percent, mode: mode, height: density.bucketBarHeight)
            // groupTitle is used by Cursor's on-demand bucket and
            // similar adapters to surface a short dollar / count
            // summary alongside the percent bar.
            if let group = bucket.groupTitle, !group.isEmpty, group != bucket.title {
                Text(group)
                    .font(.system(size: density.resetCountdownFontSize))
                    .foregroundStyle(.tertiary)
            }
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

    private func compactErrorText(_ text: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: "exclamationmark.triangle.fill")
            Text(text)
                .lineLimit(2)
        }
        .font(.system(size: density.resetCountdownFontSize))
        .foregroundStyle(.orange)
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
