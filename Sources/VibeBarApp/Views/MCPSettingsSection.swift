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
        section("MCP Server") {
            Text("Vibe Bar can expose this Mac's quota, usage, cost and local agent sessions to your coding agents over MCP. The server listens on a Unix domain socket in your home directory — no network port is opened, and no token is created: the socket's file permissions are the access control.")
                .font(.caption)
                .foregroundStyle(.secondary)

            Toggle("Enable the local MCP server", isOn: $settingsStore.settings.mcpServer.enabled)
                .toggleStyle(.switch)
                .controlSize(.small)

            if settingsStore.settings.mcpServer.enabled {
                infoRow("Status", controller.isRunning ? "Listening" : "Not listening")
                infoRow("Socket", controller.socketPath)
                infoRow("Connected clients", "\(controller.connectionCount)")
                infoRow("Last client activity", lastActivityText)
                if let error = controller.startupError {
                    Text(error)
                        .font(.caption2)
                        .foregroundStyle(.orange)
                        .textSelection(.enabled)
                }
                Text("The socket exists only while Vibe Bar is running. Agents configured below report “Vibe Bar is not running” when it is quit, which is the intended behaviour.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private var lastActivityText: String {
        guard let date = controller.lastClientActivityAt else { return "never" }
        return date.formatted(date: .abbreviated, time: .shortened)
    }

    // MARK: - Setup

    private var setupSection: some View {
        section("Connect an agent") {
            Text("The quickest path: paste this into any agent and let it configure itself, install the companion skill, and verify the connection.")
                .font(.caption)
                .foregroundStyle(.secondary)

            copyRow(
                title: "Agent setup prompt",
                subtitle: "One line, works in any agent that can fetch a URL.",
                systemImage: "sparkles",
                value: MCPClientConfig.agentSetupPrompt
            )

            Divider()

            Text("Or configure a client by hand. Every client runs the same command — Vibe Bar's own binary with \(MCPStdioBridge.commandLineFlag), which bridges stdin/stdout to the socket above.")
                .font(.caption)
                .foregroundStyle(.secondary)

            copyRow(
                title: "Claude Code",
                subtitle: "Run in a terminal.",
                systemImage: "terminal",
                value: MCPClientConfig.claudeCodeCommand(executablePath: executablePath)
            )
            copyRow(
                title: "Codex CLI",
                subtitle: "Append to ~/.codex/config.toml.",
                systemImage: "doc.plaintext",
                value: MCPClientConfig.codexTOML(executablePath: executablePath)
            )
            copyRow(
                title: "Cursor",
                subtitle: "Merge into ~/.cursor/mcp.json.",
                systemImage: "curlybraces",
                value: MCPClientConfig.cursorJSON(executablePath: executablePath)
            )
            copyRow(
                title: "Any other stdio client",
                subtitle: "One entry for the client's own mcpServers map.",
                systemImage: "puzzlepiece.extension",
                value: MCPClientConfig.genericJSON(executablePath: executablePath)
            )

            if !isInstalledInApplications {
                Text("Vibe Bar is running from \(executablePath). Move it to /Applications before saving a client config, or the config breaks the next time you rebuild.")
                    .font(.caption2)
                    .foregroundStyle(.orange)
            }
        }
    }

    /// The path an agent should actually launch. Prefer the running bundle so
    /// a config copied from a development build points at that build; fall
    /// back to the canonical install location when there is no bundle at all.
    private var executablePath: String {
        Bundle.main.executableURL?.path ?? MCPClientConfig.canonicalExecutablePath
    }

    private var isInstalledInApplications: Bool {
        executablePath == MCPClientConfig.canonicalExecutablePath
    }

    // MARK: - Behaviour

    private var behaviourSection: some View {
        section("What agents may do") {
            Toggle(
                "Allow agents to refresh quota",
                isOn: $settingsStore.settings.mcpServer.allowRefreshTools
            )
            .toggleStyle(.switch)
            .controlSize(.small)
            .disabled(!settingsStore.settings.mcpServer.enabled)

            Text("With this on, an agent can ask Vibe Bar to re-fetch quota from your providers. Forced refreshes are rate-limited to one every \(Int(MCPServer.forcedRefreshMinimumInterval)) seconds. With it off the read-only tools keep working and quota.refresh reports that refreshing is disabled.")
                .font(.caption)
                .foregroundStyle(.secondary)

            Toggle(
                "Allow agents to install skills",
                isOn: $settingsStore.settings.mcpServer.allowSkillInstall
            )
            .toggleStyle(.switch)
            .controlSize(.small)
            .disabled(!settingsStore.settings.mcpServer.enabled)

            Text("With this on, an agent can call skills.install to add a skill from a GitHub repository or a local folder. It goes through the same Skills manager as Workbench → Skills, so it writes only to ~/.agents/skills and the agent skills directories Vibe Bar manages — never over a folder a different skill already holds. With it off the tool reports that installing is disabled.")
                .font(.caption)
                .foregroundStyle(.secondary)

            Text("Everything else agents can reach is read-only: quota, token usage, cost, provider status, effective model prices, and the local session index (titles, projects, and — when session body indexing is on — message excerpts). Credentials, cookies and organization ids are never exposed, and email addresses are masked.")
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
                    Label(copied == title ? "Copied" : "Copy", systemImage: copied == title ? "checkmark" : systemImage)
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
