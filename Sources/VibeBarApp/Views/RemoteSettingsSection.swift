import AppKit
import SwiftUI
import UniformTypeIdentifiers
import VibeBarCore

/// Settings pane for the remote-probe Core. Surfaces everything that was
/// previously reachable only through the hidden `--remote-identity-descriptor`
/// and `--install-remote-provisioning` launch flags: connection status,
/// identity export, provisioning import, and disconnect. Secrets never
/// transit this view — the descriptor is public-key material and the
/// provisioning file is consumed by `RemoteCoreConfigStore.install(from:)`,
/// which routes the bearer token straight into the credential Vault.
struct RemoteSettingsSection: View {
    @ObservedObject var service: RemoteProbeService

    @State private var exportStatus: String?
    @State private var importStatus: String?
    @State private var importError: String?
    @State private var confirmingDisconnect = false

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            statusSection
            provisioningSection
            if service.isConfigured {
                disconnectSection
            }
        }
    }

    // MARK: - Status

    private var statusSection: some View {
        section("Remote Core") {
            if service.isConfigured {
                infoRow("Workspace", service.workspaceID?.uuidString.lowercased() ?? "—")
                infoRow("Relay", service.relayURL?.absoluteString ?? "—")
                infoRow("Registered probes", "\(service.registeredProbeCount)")
                infoRow("Machines synced", "\(service.machines.count)")
                infoRow("Last sync", lastSyncText)
                if let code = service.lastErrorCode {
                    Text("Latest sync error: \(code)")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                }
                Button {
                    Task { await service.refresh() }
                } label: {
                    Label("Sync now", systemImage: "arrow.triangle.2.circlepath")
                }
                .disabled(service.isRefreshing)
            } else {
                Text("This Mac is not connected to a workspace. Remote probes collect normalized usage on your other machines, encrypt it to this Mac's Core keys, and drop it at a Relay — no inbound port is ever opened here.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var lastSyncText: String {
        guard let date = service.lastUpdated else { return "never" }
        return date.formatted(date: .abbreviated, time: .shortened)
    }

    // MARK: - Provisioning

    private var provisioningSection: some View {
        section("Provisioning") {
            Text("Pairing runs in three steps: export this Mac's Core identity, register it with your Relay to produce a provisioning file, then import that file here. The provisioning file embeds a Relay credential — it is stored in the macOS Keychain, never on disk.")
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack(spacing: 10) {
                Button {
                    exportDescriptor()
                } label: {
                    Label("Export Core Identity…", systemImage: "square.and.arrow.up")
                }
                Button {
                    importProvisioning()
                } label: {
                    Label("Import Provisioning File…", systemImage: "square.and.arrow.down")
                }
            }

            if let exportStatus {
                Text(exportStatus)
                    .font(.caption2)
                    .foregroundStyle(.green)
            }
            if let importStatus {
                Text(importStatus)
                    .font(.caption2)
                    .foregroundStyle(.green)
            }
            if let importError {
                Text(importError)
                    .font(.caption2)
                    .foregroundStyle(.orange)
                    .textSelection(.enabled)
            }
        }
    }

    private func exportDescriptor() {
        exportStatus = nil
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "vibebar-core-descriptor.json"
        panel.title = "Export Core Identity Descriptor"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try RemoteCoreConfigStore.writePublicDescriptor(to: url)
            exportStatus = "Descriptor exported. It contains public keys only."
        } catch {
            exportStatus = nil
            importError = "Export failed: \(shortCode(error))"
        }
    }

    private func importProvisioning() {
        importStatus = nil
        importError = nil
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.title = "Import Remote Provisioning File"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try RemoteCoreConfigStore.install(from: url)
            service.reconfigure()
            importStatus = "Provisioning installed. Syncing with the Relay now."
        } catch {
            importError = importHint(for: url, underlying: error)
        }
    }

    /// `install(from:)` rejects group/world-readable files by design; a file
    /// straight out of Downloads usually fails that check. Distinguish the
    /// permissions case so the fix is one obvious command, without loosening
    /// the store's rule.
    private func importHint(for url: URL, underlying error: Error) -> String {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        if let permissions = attributes?[.posixPermissions] as? NSNumber,
           permissions.intValue & 0o077 != 0 {
            return "Import failed: the file must be readable by you alone. Run: chmod 600 \"\(url.path)\" and import again."
        }
        return "Import failed: \(shortCode(error)). Check that this is an unmodified provisioning file for this Mac."
    }

    // MARK: - Disconnect

    private var disconnectSection: some View {
        section("Disconnect") {
            Text("Disconnecting removes this Mac's Relay credential from the Keychain and its workspace binding. Probes keep uploading to the Relay until they are revoked there. Usage already decrypted stays in the local ledger.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Button(role: .destructive) {
                confirmingDisconnect = true
            } label: {
                Label("Disconnect from Workspace…", systemImage: "bolt.slash")
            }
            .confirmationDialog(
                "Disconnect from this workspace?",
                isPresented: $confirmingDisconnect,
                titleVisibility: .visible
            ) {
                Button("Disconnect", role: .destructive) {
                    disconnect()
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Reconnecting later requires a new provisioning file.")
            }
        }
    }

    private func disconnect() {
        do {
            try RemoteCoreConfigStore.uninstall()
            service.reconfigure()
            importStatus = nil
            importError = nil
            exportStatus = nil
        } catch {
            importError = "Disconnect failed: \(shortCode(error))"
        }
    }

    // MARK: - Helpers

    private func shortCode(_ error: Error) -> String {
        (error as? RemoteSyncError)?.code ?? error.localizedDescription
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

    /// Mirrors SettingsView.settingsSection so this pane matches the other
    /// pages without widening that private helper's access.
    private func section<Content: View>(
        _ title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 10) {
                content()
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.primary.opacity(0.045))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(Color.primary.opacity(0.08), lineWidth: 0.6)
            )
        }
    }
}
