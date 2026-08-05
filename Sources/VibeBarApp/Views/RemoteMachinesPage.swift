import SwiftUI
import VibeBarCore

struct RemoteMachinesPage: View {
    let density: Theme.Density

    @EnvironmentObject private var service: RemoteProbeService
    @EnvironmentObject private var settingsStore: SettingsStore

    var body: some View {
        VStack(alignment: .leading, spacing: density.interSectionSpacing) {
            if !service.isConfigured {
                stateCard(
                    icon: "lock.slash",
                    title: "Remote Core is not configured",
                    detail: "Create a Core descriptor, provision a workspace-scoped Relay credential, then import the signed provisioning file. No inbound port is required on this Mac."
                )
            } else if service.machines.isEmpty {
                stateCard(
                    icon: service.isRefreshing ? "arrow.triangle.2.circlepath" : "server.rack",
                    title: service.isRefreshing ? "Checking the Relay…" : "No remote machine data yet",
                    detail: service.lastErrorCode.map { "Sync state: \($0)" }
                        ?? "The Relay is connected. A Probe will appear after its first encrypted batch is decrypted and imported."
                )
            } else {
                if let error = service.lastErrorCode {
                    HStack(spacing: 7) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                        Text("Latest sync: \(error)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                LazyVStack(alignment: .leading, spacing: density.interSectionSpacing) {
                    ForEach(service.machines) { machine in
                        machineCard(machine)
                    }
                }
            }
        }
    }

    private func stateCard(icon: String, title: String, detail: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 24, weight: .medium))
                .foregroundStyle(.secondary)
            Text(title)
                .font(.system(size: density.titleFontSize, weight: .semibold))
            Text(detail)
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 430)
        }
        .frame(maxWidth: .infinity)
        .padding(28)
        .background(cardBackground)
    }

    private func machineCard(_ machine: RemoteMachineSummary) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .center, spacing: 10) {
                Image(systemName: "server.rack")
                    .font(.system(size: 17, weight: .medium))
                    .frame(width: 28, height: 28)
                    .background(Circle().fill(Color.accentColor.opacity(0.14)))
                VStack(alignment: .leading, spacing: 2) {
                    Text(machine.alias)
                        .font(.system(size: density.titleFontSize, weight: .semibold))
                    Text("\(machine.platform) · Probe \(machine.probeVersion)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                freshness(machine)
            }

            HStack(spacing: 0) {
                metric("Today", machine.todayTokens)
                Divider().frame(height: 34)
                metric("7 days", machine.last7DaysTokens)
                Divider().frame(height: 34)
                metric("30 days", machine.last30DaysTokens)
                Divider().frame(height: 34)
                VStack(alignment: .trailing, spacing: 2) {
                    Text(machine.last30DaysCostUSD, format: .currency(code: "USD"))
                        .font(.system(size: 14, weight: .semibold, design: .rounded))
                    Text("30-day cost")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .trailing)
            }

            if !machine.byTool.isEmpty {
                Divider().opacity(0.45)
                HStack(spacing: 8) {
                    ForEach(machine.byTool) { usage in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(toolLabel(usage.tool))
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                            Text(usage.tokens, format: .number.notation(.compactName))
                                .font(.system(size: 12, weight: .semibold, design: .rounded))
                        }
                        .padding(.horizontal, 9)
                        .padding(.vertical, 6)
                        .background(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(Color.primary.opacity(0.045))
                        )
                    }
                    Spacer(minLength: 0)
                }
            }

            HStack(spacing: 6) {
                ForEach(machine.sourceStatuses.keys.sorted(), id: \.self) { source in
                    let status = machine.sourceStatuses[source] ?? "error"
                    Text("\(toolLabel(source)) · \(status)")
                        .font(.system(size: 9.5, weight: .medium))
                        .foregroundStyle(status == "ok" ? Color.secondary : Color.orange)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(Capsule().fill(Color.primary.opacity(0.04)))
                }
                Spacer(minLength: 0)
                Toggle("Include in totals", isOn: includedInTotals(machine))
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .font(.caption2)
                    .help("Add this machine's decrypted usage to Overview and provider cost pages on this Core")
                Text("seq \(machine.lastSequence)")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(16)
        .background(cardBackground)
    }

    private func metric(_ title: String, _ value: Int) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value, format: .number.notation(.compactName))
                .font(.system(size: 14, weight: .semibold, design: .rounded))
            Text(title)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
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
            label = "Live"
            color = .green
        case .delayed:
            label = "Delayed"
            color = .orange
        case .stale:
            label = "Stale"
            color = .red
        }
        return HStack(spacing: 5) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(label).font(.caption.weight(.semibold))
        }
        .foregroundStyle(color)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Capsule().fill(color.opacity(0.10)))
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

    private var cardBackground: some View {
        RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(Color.primary.opacity(0.035))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(Color.primary.opacity(0.07), lineWidth: 0.7)
            )
    }

    private func toolLabel(_ raw: String) -> String {
        switch raw {
        case "codex": return "Codex"
        case "claude": return "Claude"
        case "antigravity": return "AntiGravity"
        case "grok": return "Grok"
        default: return raw
        }
    }
}
