import SwiftUI
import VibeBarCore

enum RemoteSyncStatusCopy {
    static func title(for code: String) -> String {
        switch code {
        case "network_offline": return L10n.Settings.remoteSyncOffline
        case "network_timeout": return L10n.Settings.remoteSyncTimeout
        case "host_lookup_failed": return L10n.Settings.remoteSyncHostLookupFailed
        case "connection_failed": return L10n.Settings.remoteSyncConnectionFailed
        case "secure_connection_failed": return L10n.Settings.remoteSyncSecureConnectionFailed
        case "relay_http_401", "relay_http_403": return L10n.Settings.remoteSyncRejected
        case "relay_http_429", "relay_http_503": return L10n.Settings.remoteSyncBusy
        case "sequence_gap": return L10n.Settings.remoteSyncSequenceGap
        case "invalid_signature", "unauthorized_producer": return L10n.Settings.remoteSyncUnverifiedProbe
        case "invalid_response": return L10n.Settings.remoteSyncInvalidResponse
        case "sync_failed", "transport_failed": return L10n.Settings.remoteSyncTransportFailed
        default: return L10n.Settings.remoteSyncUnknown
        }
    }

    static func detail(for code: String) -> String {
        switch code {
        case "network_timeout", "connection_failed", "secure_connection_failed",
             "relay_http_429", "relay_http_503":
            return L10n.Settings.remoteSyncRetryDetail
        case "network_offline", "host_lookup_failed":
            return L10n.Settings.remoteSyncNetworkDetail
        case "relay_http_401", "relay_http_403":
            return L10n.Settings.remoteSyncRejectedDetail
        case "sequence_gap":
            return L10n.Settings.remoteSyncSequenceGapDetail
        case "invalid_signature", "unauthorized_producer":
            return L10n.Settings.remoteSyncUnverifiedProbeDetail
        default:
            return L10n.Settings.remoteSyncUnknownDetail
        }
    }
}

/// A compact token count and a dollar amount in the *app's* language rather
/// than the process locale — "1.2K" against "1.2万". A bare
/// `.number.notation(.compactName)` asks `Locale.current`, which is the
/// machine's language and not `AppSettings.language`.
private var tokenFormat: IntegerFormatStyle<Int> {
    .number.notation(.compactName).locale(AppLocale.current)
}

private var costFormat: FloatingPointFormatStyle<Double>.Currency {
    .currency(code: "USD").locale(AppLocale.current)
}

struct RemoteMachinesPage: View {
    let density: Theme.Density

    @EnvironmentObject private var service: RemoteProbeService
    @EnvironmentObject private var settingsStore: SettingsStore

    var body: some View {
        VStack(alignment: .leading, spacing: density.interSectionSpacing) {
            if !service.isConfigured {
                stateCard(
                    icon: "lock.slash",
                    title: L10n.Popover.machinesNotConfigured,
                    detail: L10n.Popover.machinesNotConfiguredDetail
                )
            } else if service.machines.isEmpty {
                stateCard(
                    icon: service.isRefreshing ? "arrow.triangle.2.circlepath" : "server.rack",
                    title: service.isRefreshing ? L10n.Popover.machinesChecking : L10n.Popover.machinesNoData,
                    detail: service.lastErrorCode.map { RemoteSyncStatusCopy.detail(for: $0) }
                        ?? L10n.Popover.machinesNoDataDetail
                )
            } else {
                if let error = service.lastErrorCode {
                    syncErrorBanner(error)
                }
                machineGrid
            }
        }
    }

    /// One machine gets a single readable column; a fleet gets the same
    /// two-column waterfall the Misc page uses, so tall cards don't leave a
    /// half-empty page behind them.
    @ViewBuilder
    private var machineGrid: some View {
        if service.machines.count > 1 {
            ColumnMasonryLayout(columns: 2, spacing: density.interSectionSpacing) {
                ForEach(service.machines) { machine in
                    machineCard(machine)
                        .overviewMasonryItem(id: machine.id, phase: .auxiliary)
                }
            }
        } else {
            ForEach(service.machines) { machine in
                machineCard(machine)
                    .frame(maxWidth: 720, alignment: .leading)
            }
        }
    }

    private func machineCard(_ machine: RemoteMachineSummary) -> some View {
        CardShell(density: density) {
            header(machine)
            Divider().opacity(0.25)
            metrics(machine)
            if !machine.byTool.isEmpty {
                toolBreakdown(machine)
            }
            Divider().opacity(0.2)
            footer(machine)
        }
    }

    private func header(_ machine: RemoteMachineSummary) -> some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: "server.rack")
                .font(.system(size: max(12, density.bucketTitleFontSize), weight: .medium))
                .foregroundStyle(Color.accentColor)
                .frame(width: 26, height: 26)
                .background(Circle().fill(Color.accentColor.opacity(0.14)))
            VStack(alignment: .leading, spacing: 2) {
                Text(machine.alias)
                    .font(.system(size: density.titleFontSize, weight: .semibold))
                    .lineLimit(1)
                Text(L10n.Settings.remoteMachineDetail(platform: machine.platform, version: machine.probeVersion))
                    .font(.system(size: max(9, density.subtitleFontSize - 1)))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            freshness(machine)
        }
    }

    private func metrics(_ machine: RemoteMachineSummary) -> some View {
        HStack(alignment: .top, spacing: 0) {
            metric(L10n.Cost.timeframeToday, Text(machine.todayTokens, format: tokenFormat))
            metricDivider
            metric(L10n.Cost.timeframeWeek, Text(machine.last7DaysTokens, format: tokenFormat))
            metricDivider
            metric(L10n.Cost.timeframeMonth, Text(machine.last30DaysTokens, format: tokenFormat))
            metricDivider
            metric(
                L10n.Popover.machinesThirtyDayCost,
                Text(machine.last30DaysCostUSD, format: costFormat)
            )
        }
    }

    private func metric(_ title: String, _ value: Text) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.system(size: max(8, density.subtitleFontSize - 2), weight: .semibold))
                .textCase(.uppercase)
                .tracking(0.4)
                .foregroundStyle(.tertiary)
                .lineLimit(1)
            value
                .font(.system(
                    size: density.bucketTitleFontSize,
                    weight: .semibold,
                    design: .rounded
                ).monospacedDigit())
                .foregroundStyle(.primary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var metricDivider: some View {
        Divider()
            .frame(height: 28)
            .padding(.horizontal, 4)
    }

    private func toolBreakdown(_ machine: RemoteMachineSummary) -> some View {
        LazyVGrid(
            columns: [GridItem(.adaptive(minimum: 96), spacing: 6)],
            alignment: .leading,
            spacing: 6
        ) {
            ForEach(machine.byTool) { usage in
                toolChip(usage)
            }
        }
    }

    /// A Probe reports whatever tool ids it scanned, including ones this build
    /// doesn't model yet. Known ids get the provider's brand mark and accent;
    /// anything else stays neutral rather than being dropped.
    private func toolChip(_ usage: RemoteToolUsageSummary) -> some View {
        let tool = ToolType(rawValue: usage.tool)
        let accent = tool.map { Theme.providerAccent(for: $0) }
        return VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 4) {
                if let tool {
                    ToolBrandIconView(tool: tool, size: max(10, density.subtitleFontSize - 1))
                }
                Text(tool?.menuTitle ?? usage.tool.capitalized)
                    .font(.system(size: max(8, density.subtitleFontSize - 2), weight: .medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(usage.tokens, format: tokenFormat)
                    .font(.system(
                        size: density.subtitleFontSize,
                        weight: .semibold,
                        design: .rounded
                    ).monospacedDigit())
                    .foregroundStyle(accent ?? Color.primary)
                if usage.costUSD > 0 {
                    Text(usage.costUSD, format: costFormat)
                        .font(.system(
                            size: max(8, density.subtitleFontSize - 2),
                            design: .rounded
                        ).monospacedDigit())
                        .foregroundStyle(.tertiary)
                }
            }
            .lineLimit(1)
            .minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: chipCornerRadius, style: .continuous)
                .fill(accent?.opacity(0.10) ?? Color.primary.opacity(0.05))
        )
    }

    private func footer(_ machine: RemoteMachineSummary) -> some View {
        HStack(alignment: .center, spacing: density.statusComponentSpacing) {
            ForEach(machine.sourceStatuses.keys.sorted(), id: \.self) { source in
                sourceCapsule(source, status: machine.sourceStatuses[source] ?? Self.unknownSourceStatus)
            }
            Spacer(minLength: 8)
            Text(L10n.Popover.machinesSequence(value: String(machine.lastSequence)))
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.tertiary)
            Toggle(L10n.Popover.machinesIncludeInTotals, isOn: includedInTotals(machine))
                .toggleStyle(.switch)
                .controlSize(.mini)
                .font(.system(size: max(9, density.subtitleFontSize - 1)))
                .fixedSize()
                .help(L10n.Popover.machinesIncludeInTotalsHelp)
        }
    }

    /// The Relay's own status vocabulary, not copy. It is compared against
    /// `"ok"` below and shown beside the source name, so it stays English
    /// for the same reason the error code does — a machine-readable value
    /// inside a translated sentence.
    private static let unknownSourceStatus = "error"

    private func sourceCapsule(_ source: String, status: String) -> some View {
        let isHealthy = status == "ok"
        let label = ToolType(rawValue: source)?.menuTitle ?? source.capitalized
        return Text(L10n.Popover.machinesLabelWithStatus(label: label, status: status))
            .font(.system(size: max(8, density.subtitleFontSize - 3), weight: .medium))
            .foregroundStyle(isHealthy ? Color.secondary : Color.orange)
            .lineLimit(1)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(
                Capsule().fill(
                    isHealthy ? Color.primary.opacity(0.05) : Color.orange.opacity(0.12)
                )
            )
    }

    private func freshness(_ machine: RemoteMachineSummary) -> some View {
        let freshness = RemoteMachineFreshness.evaluate(
            lastSeenAt: machine.lastSeenAt,
            expectedReportIntervalSeconds: machine.expectedReportIntervalSeconds
        )
        let label: String
        let color: Color
        switch freshness {
        case .live:
            label = L10n.Popover.machinesFreshnessLive
            color = .green
        case .delayed:
            label = L10n.Popover.machinesFreshnessDelayed
            color = .orange
        case .stale:
            label = L10n.Popover.machinesFreshnessStale
            color = .red
        }
        return HStack(spacing: 5) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(label)
                .font(.system(size: max(9, density.subtitleFontSize), weight: .semibold))
        }
        .foregroundStyle(color)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Capsule().fill(color.opacity(0.10)))
    }

    private func syncErrorBanner(_ code: String) -> some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 2) {
                Text(RemoteSyncStatusCopy.title(for: code))
                    .fontWeight(.semibold)
                    .foregroundStyle(.primary)
                Text(RemoteSyncStatusCopy.detail(for: code))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text(code)
                    .font(.caption2.monospaced())
                    .foregroundStyle(.tertiary)
            }
            Spacer(minLength: 0)
            Button {
                Task { await service.refresh() }
            } label: {
                Label(L10n.Common.retry, systemImage: "arrow.clockwise")
                    .font(.system(size: max(9, density.segmentedFontSize - 1), weight: .semibold))
                    .padding(.horizontal, 10)
                    .frame(minHeight: 26)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(Color.orange.opacity(0.12))
                    )
            }
            .buttonStyle(.vibeBar)
            .disabled(service.isRefreshing)
        }
        .font(.system(size: density.subtitleFontSize))
        .padding(density.cardPadding)
        .background(
            RoundedRectangle(cornerRadius: density.cardCornerRadius, style: .continuous)
                .fill(Color.orange.opacity(0.08))
        )
        .overlay(
            RoundedRectangle(cornerRadius: density.cardCornerRadius, style: .continuous)
                .stroke(Color.orange.opacity(0.35), lineWidth: 0.5)
        )
    }

    private func stateCard(icon: String, title: String, detail: String) -> some View {
        VStack(spacing: density.cardSpacing) {
            Image(systemName: icon)
                .font(.system(size: density.titleFontSize + 8, weight: .light))
                .foregroundStyle(.secondary)
            Text(title)
                .font(.system(size: density.titleFontSize, weight: .semibold))
            Text(detail)
                .font(.system(size: density.subtitleFontSize))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 430)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, density.cardPadding)
        .padding(.vertical, density.cardPadding * 2)
        .cardSurface(density: density)
    }

    private var chipCornerRadius: CGFloat {
        max(6, density.cardCornerRadius - 6)
    }

    private func includedInTotals(_ machine: RemoteMachineSummary) -> Binding<Bool> {
        Binding(
            get: { settingsStore.settings.remoteCostIncludedMachineIDs.contains(machine.id) },
            set: { included in
                if included {
                    settingsStore.settings.remoteCostIncludedMachineIDs.insert(machine.id)
                } else {
                    settingsStore.settings.remoteCostIncludedMachineIDs.remove(machine.id)
                }
            }
        )
    }
}
