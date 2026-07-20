import SwiftUI
import AppKit
import VibeBarCore

/// The Misc tab inside the Overview popover. Renders a card for each
/// visible provider instance. Multiple visible instances for the same
/// provider collapse into one provider card with an aggregate state
/// followed by per-copy states.
struct MiscProvidersPage: View {
    let density: Theme.Density

    @EnvironmentObject var settingsStore: SettingsStore

    var body: some View {
        ColumnMasonryLayout(columns: density.miscColumnCount, spacing: density.interSectionSpacing) {
            ForEach(providerGroups) { group in
                if group.instances.count == 1, let instance = group.instances.first {
                    MiscProviderCard(instance: instance, density: density)
                } else {
                    MiscProviderGroupCard(group: group, density: density)
                }
            }
        }
    }

    private var providerGroups: [MiscProviderInstanceGroup] {
        var groups: [MiscProviderInstanceGroup] = []
        for instance in settingsStore.settings.visibleMiscProviderInstances {
            if let index = groups.firstIndex(where: { $0.tool == instance.tool }) {
                groups[index].instances.append(instance)
            } else {
                groups.append(MiscProviderInstanceGroup(tool: instance.tool, instances: [instance]))
            }
        }
        return groups
    }
}

private struct MiscProviderInstanceGroup: Identifiable {
    var tool: ToolType
    var instances: [MiscProviderInstance]

    var id: String { tool.rawValue }
}

private struct MiscProviderCard: View {
    let instance: MiscProviderInstance
    let density: Theme.Density

    @EnvironmentObject var environment: AppEnvironment
    @EnvironmentObject var quotaService: QuotaService

    private var tool: ToolType { instance.tool }
    private var accountID: String { AccountStore.miscAccountId(forInstanceID: instance.id) }

    var body: some View {
        MiscProviderCardShell(density: density) {
            header
            Divider().opacity(0.25)
            MiscQuotaBody(
                tool: tool,
                density: density,
                quota: environment.quota(for: instance),
                liveError: quotaService.lastErrorByAccount[accountID],
                lastUpdated: quotaService.lastUpdatedByAccount[accountID],
                isCompact: false
            )
        }
    }

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
                if let subtitle = headerSubtitle {
                    Text(subtitle.text)
                        .font(.system(size: density.subtitleFontSize))
                        .foregroundStyle(subtitle.isPrimary ? .secondary : .tertiary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 4)
            BorderlessIconButton(
                systemImage: "arrow.clockwise",
                help: "Refresh \(tool.menuTitle)",
                size: density.subtitleFontSize
            ) {
                environment.refresh(instance)
            }
            .disabled(quotaService.inFlightAccountIds.contains(accountID))
        }
    }

    private var headerSubtitle: (text: String, isPrimary: Bool)? {
        if let displayName = instance.displayName {
            if let plan = environment.quota(for: instance)?.plan, !plan.isEmpty {
                return ("\(displayName) · \(plan)", true)
            }
            return (displayName, true)
        }
        if let plan = environment.quota(for: instance)?.plan, !plan.isEmpty {
            return (plan, true)
        }
        return (tool.subtitle, false)
    }
}

private struct MiscProviderGroupCard: View {
    let group: MiscProviderInstanceGroup
    let density: Theme.Density

    @EnvironmentObject var environment: AppEnvironment
    @EnvironmentObject var quotaService: QuotaService

    var body: some View {
        MiscProviderCardShell(density: density) {
            header
            Divider().opacity(0.25)
            MiscQuotaBody(
                tool: group.tool,
                density: density,
                quota: aggregateQuota,
                liveError: aggregateQuota?.error,
                lastUpdated: latestUpdated,
                isCompact: false
            )
            if shouldShowPerInstanceRows {
                Divider().opacity(0.2)
                VStack(alignment: .leading, spacing: max(6, density.bucketRowSpacing)) {
                    ForEach(Array(group.instances.enumerated()), id: \.element.id) { index, instance in
                        MiscProviderInstanceStatusRow(
                            instance: instance,
                            ordinal: index + 1,
                            density: density
                        )
                        if index < group.instances.count - 1 {
                            Divider().opacity(0.16)
                        }
                    }
                }
            }
        }
    }

    /// True when the per-instance breakdown adds information the
    /// aggregated top section can't show on its own.
    ///
    /// Hide the breakdown when every instance contributes distinct
    /// buckets and is healthy — the aggregated body already lists
    /// every bucket once, so the per-instance rows would just repeat
    /// the same numbers (this is the common Tencent Token Plan case:
    /// one generic + one HY3 clone, no bucket ids overlap).
    ///
    /// Show the breakdown when:
    /// - Any bucket id is contributed by 2+ instances (the aggregator
    ///   averages them, so per-instance rows are how the user sees
    ///   each copy's real number).
    /// - Any instance has no successful quota (`needs login`, network
    ///   error, etc.) — the aggregate suppresses that error if even
    ///   one sibling succeeded, so the per-instance row is the only
    ///   place that failure surfaces.
    private var shouldShowPerInstanceRows: Bool {
        var seenBucketIDs = Set<String>()
        for instance in group.instances {
            guard let quota = environment.quota(for: instance),
                  !quota.buckets.isEmpty,
                  quota.error == nil else {
                return true
            }
            for bucket in quota.buckets where !seenBucketIDs.insert(bucket.id).inserted {
                return true
            }
        }
        return false
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 10) {
            ToolBrandBadge(
                tool: group.tool,
                iconSize: max(17, density.bucketTitleFontSize + 1),
                containerSize: 26
            )
            VStack(alignment: .leading, spacing: 2) {
                Text(group.tool.menuTitle)
                    .font(.system(size: density.bucketTitleFontSize, weight: .semibold))
                    .lineLimit(1)
                Text("\(group.instances.count) independent copies")
                    .font(.system(size: density.subtitleFontSize))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            BorderlessIconButton(
                systemImage: "arrow.clockwise",
                help: "Refresh \(group.tool.menuTitle) copies",
                size: density.subtitleFontSize
            ) {
                for instance in group.instances {
                    environment.refresh(instance)
                }
            }
            .disabled(isRefreshing)
        }
    }

    private var isRefreshing: Bool {
        group.instances.contains { instance in
            quotaService.inFlightAccountIds.contains(AccountStore.miscAccountId(forInstanceID: instance.id))
        }
    }

    private var latestUpdated: Date? {
        group.instances
            .compactMap { quotaService.lastUpdatedByAccount[AccountStore.miscAccountId(forInstanceID: $0.id)] }
            .max()
    }

    private var aggregateQuota: AccountQuota? {
        let queriedAt = group.instances
            .compactMap { environment.quota(for: $0)?.queriedAt }
            .max() ?? Date()
        let results: [MiscQuotaAggregator.SlotResult] = group.instances.enumerated().map { index, instance in
            let accountID = AccountStore.miscAccountId(forInstanceID: instance.id)
            let label = instance.displayTitle(fallback: "Copy \(index + 1)")
            if let quota = environment.quota(for: instance), !quota.buckets.isEmpty {
                return .init(slotID: nil, sourceLabel: label, outcome: .success(quota))
            }
            let error = quotaService.lastErrorByAccount[accountID]
                ?? environment.quota(for: instance)?.error
                ?? .noCredential
            return .init(slotID: nil, sourceLabel: label, outcome: .failure(error))
        }
        let account = AccountIdentity(
            id: "misc-\(group.tool.rawValue)-aggregate",
            tool: group.tool,
            alias: group.tool.menuTitle,
            source: .notConfigured
        )
        return MiscQuotaAggregator.aggregate(
            tool: group.tool,
            account: account,
            results: results,
            queriedAt: queriedAt
        )
    }
}

private struct MiscProviderInstanceStatusRow: View {
    let instance: MiscProviderInstance
    let ordinal: Int
    let density: Theme.Density

    @EnvironmentObject var environment: AppEnvironment
    @EnvironmentObject var quotaService: QuotaService

    private var accountID: String { AccountStore.miscAccountId(forInstanceID: instance.id) }
    private var title: String { instance.displayTitle(fallback: "Copy \(ordinal)") }
    private var refreshTitle: String { instance.displayTitle(fallback: "copy \(ordinal)") }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .center, spacing: 6) {
                Text(title)
                    .font(.system(size: density.subtitleFontSize, weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 4)
                BorderlessIconButton(
                    systemImage: "arrow.clockwise",
                    help: "Refresh \(refreshTitle)",
                    size: max(9, density.subtitleFontSize - 1)
                ) {
                    environment.refresh(instance)
                }
                .disabled(quotaService.inFlightAccountIds.contains(accountID))
            }
            MiscQuotaBody(
                tool: instance.tool,
                density: density,
                quota: environment.quota(for: instance),
                liveError: quotaService.lastErrorByAccount[accountID],
                lastUpdated: quotaService.lastUpdatedByAccount[accountID],
                isCompact: true
            )
        }
        .padding(.leading, 6)
    }
}

private struct MiscProviderCardShell<Content: View>: View {
    let density: Theme.Density
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: density.cardSpacing) {
            content()
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
}

private struct MiscQuotaBody: View {
    let tool: ToolType
    let density: Theme.Density
    let quota: AccountQuota?
    let liveError: QuotaError?
    let lastUpdated: Date?
    let isCompact: Bool

    @EnvironmentObject var environment: AppEnvironment
    @EnvironmentObject var settingsStore: SettingsStore

    var body: some View {
        let visibleError = displayableError(liveError, with: quota)
        if let buckets = quota?.buckets, !buckets.isEmpty {
            VStack(alignment: .leading, spacing: max(4, density.bucketRowSpacing - (isCompact ? 2 : 0))) {
                ForEach(buckets) { bucket in
                    miscBucketRow(bucket)
                }
                if let lastUpdated {
                    Text(ResetCountdownFormatter.updatedAgo(from: lastUpdated, now: Date()))
                        .font(.system(size: density.resetCountdownFontSize))
                        .foregroundStyle(.tertiary)
                }
                if let visibleError {
                    compactErrorText("Update failed: \(visibleError.userFacingMessage)")
                }
            }
        } else if let visibleError, visibleError != .noCredential {
            errorState(visibleError)
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
        let mode = settingsStore.settings.displayMode
        let percent = bucket.displayPercent(mode)
        // Most misc adapters (Z.ai, Volcengine, Kimi, MiniMax, …) already
        // emit rawWindowSeconds + resetAt, so the same pace treatment the
        // dedicated cards get works here too; buckets without window data
        // just fall back to the plain bar.
        let now = Date()
        let pace = UsagePace.compute(bucket: bucket, now: now)
        let expectedDisplayed = pace.map { p -> Double in
            switch mode {
            case .used:      return p.expectedUsedPercent
            case .remaining: return 100 - p.expectedUsedPercent
            }
        }
        return VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text(bucket.title)
                    .font(.system(
                        size: density.bucketTitleFontSize - (isCompact ? 2 : 1),
                        weight: .medium
                    ))
                Spacer()
                Text("\(Int(percent.rounded()))%")
                    .font(.system(
                        size: density.bucketPercentFontSize - (isCompact ? 2 : 0),
                        weight: .semibold
                    ))
                    .monospacedDigit()
                    .foregroundStyle(Theme.barColor(percent: percent, mode: mode))
            }
            if let expectedDisplayed {
                PaceMarkerCapsule(
                    usedPercent: percent,
                    expectedPercent: expectedDisplayed,
                    mode: mode,
                    height: max(3, density.bucketBarHeight - (isCompact ? 1 : 0))
                )
            } else {
                QuotaBarShape(
                    percent: percent,
                    mode: mode,
                    height: max(3, density.bucketBarHeight - (isCompact ? 1 : 0))
                )
            }
            if let pace {
                UsagePaceRow(
                    pace: pace,
                    now: now,
                    fontSize: density.resetCountdownFontSize - (isCompact ? 1 : 0)
                )
            }
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
}
