import SwiftUI
import VibeBarCore

struct MenuBarHealthSettingsSection: View {
    @ObservedObject var watchdog: MenuBarBlockWatchdog
    @EnvironmentObject private var environment: AppEnvironment
    @EnvironmentObject private var settingsStore: SettingsStore

    @State private var isRepairing = false
    @State private var repairMessage: String?
    @State private var repairSucceeded = false
    @State private var copiedCommand = false
    @State private var allowListAudit: MenuBarAllowListRepair.AuditOutcome?
    @State private var isAuditing = false
    @State private var auditGeneration = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            statusHeader
            Divider()
            Toggle("Alert when macOS blocks the status item", isOn: alertsEnabled)
            if watchdog.isSuppressed {
                Label(
                    "Alerts were disabled with “Don't check again”. Health checks remain visible here.",
                    systemImage: "bell.slash"
                )
                .font(.caption2)
                .foregroundStyle(.orange)
            }
            Toggle(
                "Automatically repair confirmed allow-list blocks",
                isOn: $settingsStore.settings.menuBarAutoRepairEnabled
            )
            .disabled(DemoMode.isEnabled)
            Text(
                "Off by default. When enabled, three consecutive blocked probes run the narrow repair, "
                    + "restart Control Center, and re-register only Vibe Bar's status item. Full Disk Access is required."
            )
            .font(.caption2)
            .foregroundStyle(.secondary)
            probeDetails
            if let allowListAudit {
                Label(allowListAudit.message, systemImage: auditSymbol(allowListAudit.state))
                    .font(.caption2)
                    .foregroundStyle(auditColor(allowListAudit.state))
            }
            HStack(spacing: 8) {
                Button {
                    checkNow()
                } label: {
                    if isAuditing {
                        ProgressView().controlSize(.small)
                    } else {
                        Label("Check Now", systemImage: "stethoscope")
                    }
                }
                .disabled(isAuditing)
                Button {
                    repair()
                } label: {
                    if isRepairing {
                        ProgressView().controlSize(.small)
                    } else {
                        Label("Repair & Re-register", systemImage: "wrench.and.screwdriver")
                    }
                }
                .disabled(isRepairing || DemoMode.isEnabled)
                Button {
                    copiedCommand = MenuBarAllowListRepair.copyCommand()
                } label: {
                    Label(copiedCommand ? "Copied" : "Copy Repair Command", systemImage: "doc.on.doc")
                }
            }
            if let repairMessage {
                Label(
                    repairMessage,
                    systemImage: repairSucceeded ? "checkmark.circle.fill" : "exclamationmark.triangle.fill"
                )
                .font(.caption2)
                .foregroundStyle(repairSucceeded ? .green : .orange)
            }
            Text(
                "On macOS 26, a hidden app can retain Vibe Bar in its Control Center "
                    + "menuItemLocations and apply its own isAllowed=false state to Vibe Bar. "
                    + "Repair removes only that stale cross-app reference; it never changes another app's show/hide setting."
            )
            .font(.caption2)
            .foregroundStyle(.secondary)
            Link(
                "Open Full Disk Access settings",
                destination: URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!
            )
            .font(.caption2)
        }
        .onAppear { checkNow() }
    }

    private var statusHeader: some View {
        HStack(spacing: 9) {
            Circle()
                .fill(statusColor)
                .frame(width: 10, height: 10)
                .shadow(color: statusColor.opacity(0.35), radius: 3)
            VStack(alignment: .leading, spacing: 2) {
                Text(statusTitle)
                    .font(.system(size: 13, weight: .semibold))
                if let checkedAt = watchdog.report.checkedAt {
                    Text("Checked \(AppLocale.string(checkedAt, dateStyle: .none, timeStyle: .medium))")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
            Spacer()
            Text(watchdog.isSuppressed ? "Alerts off" : "Monitoring")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(watchdog.isSuppressed ? .orange : .secondary)
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(Capsule().fill(Color.primary.opacity(0.05)))
        }
    }

    @ViewBuilder
    private var probeDetails: some View {
        if let probe = watchdog.report.probe {
            Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 5) {
                healthRow("Requested visible", probe.isVisible ? "Yes" : "No")
                healthRow("Button / window", "\(probe.hasButton ? "Yes" : "No") / \(probe.hasWindow ? "Yes" : "No")")
                healthRow("Actually visible", probe.occlusionVisible ? "Yes" : "No")
                healthRow(
                    "Window / menu bar height",
                    "\(Int(probe.windowHeight)) pt / \(probe.menuBarHeights.map { String(Int($0)) }.joined(separator: ", ")) pt"
                )
            }
            .font(.caption.monospacedDigit())
        } else {
            Text("The status item has not produced a readable AppKit probe yet.")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    private func healthRow(_ label: String, _ value: String) -> some View {
        GridRow {
            Text(label).foregroundStyle(.secondary)
            Text(value).foregroundStyle(.primary)
        }
    }

    private var alertsEnabled: Binding<Bool> {
        Binding(
            get: { !watchdog.isSuppressed },
            set: { watchdog.setAlertsEnabled($0) }
        )
    }

    private var statusTitle: String {
        switch watchdog.report.state {
        case .checking: "Checking menu bar status…"
        case .healthy: "Vibe Bar is visible in the menu bar"
        case .blocked: "macOS appears to be blocking Vibe Bar"
        case .inconclusive: "Visibility is temporarily inconclusive"
        case .unavailable: "Menu bar status is unavailable"
        }
    }

    private var statusColor: Color {
        switch watchdog.report.state {
        case .healthy: .green
        case .blocked: .red
        case .inconclusive: .orange
        case .checking, .unavailable: .secondary
        }
    }

    private func repair() {
        guard !isRepairing else { return }
        isRepairing = true
        repairMessage = nil
        copiedCommand = false
        Task {
            let outcome = await environment.repairMenuBarAllowList()
            repairSucceeded = outcome.succeeded
            repairMessage = outcome.message
            isRepairing = false
            checkNow()
        }
    }

    private func checkNow() {
        watchdog.checkNow()
        auditGeneration += 1
        let generation = auditGeneration
        isAuditing = true
        Task {
            let result = await MenuBarAllowListRepair.audit()
            guard generation == auditGeneration else { return }
            allowListAudit = result
            isAuditing = false
        }
    }

    private func auditSymbol(_ state: MenuBarAllowListRepair.AuditOutcome.State) -> String {
        switch state {
        case .clean: "checkmark.shield.fill"
        case .polluted: "exclamationmark.shield.fill"
        case .unavailable: "questionmark.diamond.fill"
        }
    }

    private func auditColor(_ state: MenuBarAllowListRepair.AuditOutcome.State) -> Color {
        switch state {
        case .clean: .green
        case .polluted: .red
        case .unavailable: .orange
        }
    }
}
