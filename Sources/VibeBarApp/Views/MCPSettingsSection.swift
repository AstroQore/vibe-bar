import AppKit
import SwiftUI
import VibeBarCore

/// Settings pane for the local MCP server.
///
/// The pane's whole job is to get an agent connected in one paste, so the copy
/// buttons are the primary content and the switches are secondary. Nothing
/// here can leak: the socket path is not a secret, and there is no token to
/// show because there is no token — see `MCPSocketServer`.
struct MCPSettingsSection: View {
    let density: Theme.Density
    @ObservedObject var controller: MCPController
    @EnvironmentObject private var settingsStore: SettingsStore

    @State private var copied: String?
    @State private var copiedResetTask: Task<Void, Never>?

    var body: some View {
        VStack(alignment: .leading, spacing: density.interSectionSpacing) {
            statusSection
            setupSection
            behaviourSection
        }
    }

    // MARK: - Status

    private var statusSection: some View {
        section(L10n.Settings.mcpTitle) {
            Text(L10n.Settings.mcpIntro)
                .font(.caption)
                .foregroundStyle(.secondary)

            Toggle(L10n.Settings.mcpEnable, isOn: $settingsStore.settings.mcpServer.enabled)
                .toggleStyle(.switch)
                .controlSize(.small)

            if settingsStore.settings.mcpServer.enabled {
                infoRow(L10n.Settings.mcpStatus, controller.isRunning ? L10n.Settings.mcpListening : L10n.Settings.mcpNotListening)
                infoRow(L10n.Settings.mcpSocket, controller.displaySocketPath)
                infoRow(L10n.Settings.mcpConnectedClients, AppLocale.number(controller.connectionCount))
                infoRow(L10n.Settings.mcpLastActivity, lastActivityText)
                if let error = controller.startupError {
                    Text(error)
                        .font(.caption2)
                        .foregroundStyle(.orange)
                        .textSelection(.enabled)
                }
                Text(L10n.Settings.mcpSocketLifetime)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private var lastActivityText: String {
        guard let date = controller.lastClientActivityAt else { return "never" }
        return AppLocale.string(date, dateStyle: .medium, timeStyle: .short)
    }

    // MARK: - Setup

    private var setupSection: some View {
        section(L10n.Settings.mcpConnectAgent) {
            Text(L10n.Settings.mcpQuickestPath)
                .font(.caption)
                .foregroundStyle(.secondary)

            copyRow(
                title: L10n.Settings.mcpSetupPrompt,
                subtitle: L10n.Settings.mcpSetupPromptDetail,
                systemImage: "sparkles",
                value: MCPClientConfig.agentSetupPrompt
            )

            Divider()

            Text(L10n.Settings.mcpManualIntro(flag: MCPStdioBridge.commandLineFlag))
                .font(.caption)
                .foregroundStyle(.secondary)

            copyRow(
                title: "Claude Code",
                subtitle: L10n.Settings.mcpRunInTerminal,
                systemImage: "terminal",
                value: MCPClientConfig.claudeCodeCommand(executablePath: executablePath)
            )
            copyRow(
                title: "Codex CLI",
                subtitle: L10n.Settings.mcpAppendCodexConfig,
                systemImage: "doc.plaintext",
                value: MCPClientConfig.codexTOML(executablePath: executablePath)
            )
            copyRow(
                title: "Cursor",
                subtitle: L10n.Settings.mcpMergeCursorConfig,
                systemImage: "curlybraces",
                value: MCPClientConfig.cursorJSON(executablePath: executablePath)
            )
            copyRow(
                title: L10n.Settings.mcpOtherStdioClient,
                subtitle: L10n.Settings.mcpOtherStdioDetail,
                systemImage: "puzzlepiece.extension",
                value: MCPClientConfig.genericJSON(executablePath: executablePath)
            )

            if !isInstalledInApplications {
                Text(L10n.Settings.mcpMovePrompt(path: executablePath))
                    .font(.caption2)
                    .foregroundStyle(.orange)
            }
        }
    }

    /// The path an agent should actually launch. Prefer the running bundle so
    /// a config copied from a development build points at that build; fall
    /// back to the canonical install location when there is no bundle at all.
    private var executablePath: String {
        // Demo mode documents the installed app, not the build it runs from.
        if DemoMode.isEnabled { return MCPClientConfig.canonicalExecutablePath }
        return Bundle.main.executableURL?.path ?? MCPClientConfig.canonicalExecutablePath
    }

    private var isInstalledInApplications: Bool {
        executablePath == MCPClientConfig.canonicalExecutablePath
    }

    // MARK: - Behaviour

    private var behaviourSection: some View {
        section(L10n.Settings.mcpWhatAgentsMayDo) {
            Toggle(
                L10n.Settings.mcpAllowRefresh,
                isOn: $settingsStore.settings.mcpServer.allowRefreshTools
            )
            .toggleStyle(.switch)
            .controlSize(.small)
            .disabled(!settingsStore.settings.mcpServer.enabled)

            Text(L10n.Settings.mcpAllowRefreshDetail(
                seconds: Int(MCPServer.forcedRefreshMinimumInterval)
            ))
                .font(.caption)
                .foregroundStyle(.secondary)

            Toggle(
                L10n.Settings.mcpAllowSkills,
                isOn: $settingsStore.settings.mcpServer.allowSkillInstall
            )
            .toggleStyle(.switch)
            .controlSize(.small)
            .disabled(!settingsStore.settings.mcpServer.enabled)

            Text(L10n.Settings.mcpAllowSkillsDetail)
                .font(.caption)
                .foregroundStyle(.secondary)

            Text(L10n.Settings.mcpReadOnlyDetail)
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
    }

    // MARK: - Helpers

    private func copyRow(
        title: String,
        subtitle: String,
        systemImage: String,
        value: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .font(.caption.weight(.medium))
                    Text(subtitle)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                Button {
                    copy(value, label: title)
                } label: {
                    Label(
                        copied == title ? L10n.Common.copied : L10n.Common.copy,
                        systemImage: copied == title ? "checkmark" : systemImage
                    )
                }
                .controlSize(.small)
            }
            Text(value)
                .font(.caption2.monospaced())
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .lineLimit(6)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func copy(_ value: String, label: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
        copied = label
        copiedResetTask?.cancel()
        copiedResetTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            if copied == label { copied = nil }
        }
    }

    private func infoRow(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 128, alignment: .leading)
            Text(value)
                .font(.caption.monospaced())
                .textSelection(.enabled)
        }
    }

    private func section<Content: View>(
        _ title: String,
        @ViewBuilder content: @escaping () -> Content
    ) -> some View {
        SettingsSectionCard(title: title, density: density, content: content)
    }
}
