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
    @State private var joinCode = ""
    /// The hosted control center. Editable so a self-hosted deployment can be
    /// paired without a provisioning file; the client still requires HTTPS.
    @State private var controlURL = "https://vibebar.aqor.io"
    @State private var showControlURLField = false
    @State private var isJoining = false
    @State private var joinError: String?
    /// A workspace that accepted this Mac but whose credential is not saved
    /// yet. Mirrors the record in the credential Vault so the pane can offer a
    /// resume; never rendered, never logged.
    @State private var pendingEnrollment: RemoteEnrollmentResult?
    /// True when the pending record came from the Vault on appearance rather
    /// than from a failure in this session — the affordance is then "resume",
    /// not "retry", and deserves an explanation.
    @State private var pendingWasRestored = false
    @State private var confirmingDiscardPending = false

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            statusSection
            provisioningSection
            if service.isConfigured {
                disconnectSection
            }
        }
        // Only here, and only as an offer: a join is never completed behind
        // the user's back.
        .onAppear { restorePendingEnrollment() }
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
            if !service.isConfigured {
                joinWithCode
                Divider()
                Text("Or pair manually.")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
            }
            Text("Pairing runs in three steps: export this Mac's Core identity, register it with your Relay to produce a provisioning file, then import that file here. Importing moves the Relay credential into the macOS Keychain — but the provisioning file itself still contains that credential, so delete the file once the import succeeds.")
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

    // MARK: - Join with code

    /// The one-step path: paste the one-time code the web control center
    /// shows, and this Mac mints a fresh Core keypair, registers its public
    /// halves, and installs the same configuration a provisioning file would
    /// have carried. The code is single-use and short-lived, so it is never
    /// persisted or logged.
    private var joinWithCode: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Join with a code")
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
            Text("Create a Core code in the Vibe Bar control center, then paste it here. This Mac joins as “\(deviceName)”.")
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack(spacing: 8) {
                TextField("VB-XXXXX-XXXXX", text: $joinCode)
                    .textFieldStyle(.roundedBorder)
                    .font(.caption.monospaced())
                    .frame(width: 190)
                    .disabled(isJoining)
                    .onSubmit { join() }
                Button("Join") { join() }
                    .disabled(isJoining || trimmedJoinCode.isEmpty)
                if isJoining {
                    ProgressView()
                        .controlSize(.small)
                }
                Spacer(minLength: 0)
            }

            Toggle("Use a different control center", isOn: $showControlURLField)
                .toggleStyle(.checkbox)
                .font(.caption)
                .disabled(isJoining)
            if showControlURLField {
                TextField("https://vibebar.aqor.io", text: $controlURL)
                    .textFieldStyle(.roundedBorder)
                    .font(.caption.monospaced())
                    .frame(maxWidth: 320)
                    .disabled(isJoining)
            }

            if let joinError {
                Text(joinError)
                    .font(.caption2)
                    .foregroundStyle(.orange)
                    .textSelection(.enabled)
            }
            if pendingEnrollment != nil {
                if pendingWasRestored {
                    Text("A previous join was accepted by the control center but never finished saving on this Mac. Its pairing code is already spent, so resume the save instead of requesting a new code.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                HStack(spacing: 10) {
                    Button {
                        retrySavingEnrollment()
                    } label: {
                        Label(
                            pendingWasRestored ? "Resume saving" : "Retry saving",
                            systemImage: "arrow.clockwise"
                        )
                    }
                    Button("Discard") { confirmingDiscardPending = true }
                }
                .confirmationDialog(
                    "Discard this pending join?",
                    isPresented: $confirmingDiscardPending,
                    titleVisibility: .visible
                ) {
                    Button("Discard", role: .destructive) { discardPendingEnrollment() }
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text("Its pairing code is already spent, and the workspace still counts this Mac as its Core. To join again, revoke this Mac in the web control center, then create a fresh code.")
                }
            }
        }
    }

    private var trimmedJoinCode: String {
        joinCode.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var deviceName: String {
        RemoteEnrollmentClient.defaultDeviceName()
    }

    @MainActor
    private func join() {
        guard !isJoining, !trimmedJoinCode.isEmpty else { return }
        let code = trimmedJoinCode
        let control = controlURL
        joinError = nil
        importStatus = nil
        importError = nil
        pendingEnrollment = nil
        isJoining = true
        Task {
            defer { isJoining = false }
            do {
                let client = try RemoteEnrollmentClient(
                    controlURL: RemoteEnrollmentClient.controlURL(from: control)
                )
                let enrollment = try await client.enrollCore(code: code)
                joinCode = ""
                // The code is spent the moment the control center answers, so
                // put the result somewhere durable *before* touching the
                // config — quitting between here and a successful save must
                // not destroy the only copy. Starting another join supersedes
                // this record; if the Vault write itself fails we simply fall
                // through to the in-memory path, which is no worse than before.
                try? RemoteCoreConfigStore.retainPendingEnrollment(enrollment)
                saveEnrollment(enrollment)
            } catch let error as RemoteEnrollmentError {
                joinError = error.message
            } catch {
                joinError = "Join failed: \(shortCode(error))."
            }
        }
    }

    /// The only place the enrollment reaches disk and the Keychain. Splitting
    /// it out of the network exchange is what makes "Retry saving" possible:
    /// the code has already been consumed by the time this runs, so a local
    /// failure must never send the user back for a second code.
    @MainActor
    private func saveEnrollment(_ enrollment: RemoteEnrollmentResult) {
        do {
            // install() clears the retained record once the binding commits.
            try RemoteCoreConfigStore.install(enrollment)
            pendingEnrollment = nil
            pendingWasRestored = false
            joinError = nil
            service.reconfigure()
            importStatus = "Joined the workspace as this Mac's Core. Syncing with the Relay; machines appear automatically as probes enroll."
        } catch {
            pendingEnrollment = enrollment
            joinError = "The workspace accepted this Mac, but saving its credential here failed: \(shortCode(error)). The pairing code is already used — don't request a new one. Fix the problem (unlock the Keychain, free up disk space) and save again; the join is kept until you do."
        }
    }

    @MainActor
    private func retrySavingEnrollment() {
        guard let enrollment = pendingEnrollment else { return }
        saveEnrollment(enrollment)
    }

    /// Offer an unfinished join from an earlier session. Read-only: the
    /// install itself still waits for the user to ask for it.
    @MainActor
    private func restorePendingEnrollment() {
        guard pendingEnrollment == nil, !service.isConfigured,
              let retained = RemoteCoreConfigStore.pendingEnrollment()
        else { return }
        pendingEnrollment = retained
        pendingWasRestored = true
    }

    @MainActor
    private func discardPendingEnrollment() {
        RemoteCoreConfigStore.discardPendingEnrollment()
        pendingEnrollment = nil
        pendingWasRestored = false
        joinError = nil
    }

    private func exportDescriptor() {
        exportStatus = nil
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "vibebar-core-descriptor.json"
        panel.title = "Export Core Identity Descriptor"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            // Narrow, deliberate exception to the "never write outside
            // ~/.vibebar/" rule (AGENTS.md § coding conventions): the
            // destination is chosen by the user in a save panel, the payload
            // is public-key material only, and the file lands 0600 — the
            // same contract as the --remote-identity-descriptor launch flag.
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
            importStatus = "Provisioning installed. Syncing with the Relay now. Delete the provisioning file — it still contains the Relay credential."
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
            return "Import failed: the file must be readable by you alone. Run: chmod 600 \(shellQuoted(url.path)) and import again."
        }
        return "Import failed: \(shortCode(error)). Check that this is an unmodified provisioning file for this Mac."
    }

    /// POSIX single-quote escaping so a filename containing shell
    /// metacharacters (quotes, `$(...)`) stays inert if the user copies the
    /// suggested command into Terminal.
    private func shellQuoted(_ path: String) -> String {
        "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
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
                Text("Reconnecting later requires a new pairing code or provisioning file.")
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
            joinError = nil
            joinCode = ""
            discardPendingEnrollment()
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
