import Foundation

/// The persistence side effects `RemoteCoreConfigStore.install` performs,
/// gathered behind one value so the retry path can be exercised without
/// touching the real credential Vault or `~/.vibebar/`. `.live` is the only
/// sink product code uses.
struct RemoteCoreConfigSink {
    var loadConfig: () throws -> RemoteCoreConfig
    var writeConfig: (RemoteCoreConfig) throws -> Void
    var storeIdentity: (RemoteCoreIdentity) throws -> Void
    var storeBearerToken: (String, UUID) throws -> Void
    var deleteBearerToken: (UUID) throws -> Void
    var storePendingEnrollment: (RemoteEnrollmentResult) throws -> Void
    var loadPendingEnrollment: () throws -> RemoteEnrollmentResult
    var deletePendingEnrollment: () throws -> Void

    static let live = RemoteCoreConfigSink(
        loadConfig: { try RemoteCoreConfigStore.load() },
        writeConfig: {
            try VibeBarLocalStore.writeJSON($0, to: VibeBarLocalStore.remoteCoreConfigURL)
        },
        storeIdentity: { try RemoteCoreIdentityStore.store($0) },
        storeBearerToken: {
            try RemoteCoreIdentityStore.storeRelayBearerToken($0, workspaceID: $1)
        },
        deleteBearerToken: { try RemoteCoreIdentityStore.deleteRelayBearerToken(workspaceID: $0) },
        storePendingEnrollment: { try RemoteCoreIdentityStore.storePendingEnrollment($0) },
        loadPendingEnrollment: { try RemoteCoreIdentityStore.pendingEnrollment() },
        deletePendingEnrollment: { try RemoteCoreIdentityStore.deletePendingEnrollment() }
    )
}

public enum RemoteCoreConfigStore {
    public static func load() throws -> RemoteCoreConfig {
        let decoded = try VibeBarLocalStore.readJSON(
            RemoteCoreConfig.self,
            from: VibeBarLocalStore.remoteCoreConfigURL
        )
        return try RemoteCoreConfig(
            schema: decoded.schema,
            workspaceID: decoded.workspaceID,
            coreDeviceID: decoded.coreDeviceID,
            relayURL: decoded.relayURL,
            coreEpoch: decoded.coreEpoch,
            ingestKeyID: decoded.ingestKeyID,
            probeSigningPublicKeys: decoded.probeSigningPublicKeys
        )
    }

    /// Install a workspace binding.
    ///
    /// Every write here is last-wins — the Vault replaces an entry with the
    /// same service/account, and the config file is written atomically — so
    /// calling this twice with the same provisioning is safe and converges.
    /// That matters for the enrollment path: a one-time pairing code is spent
    /// the moment the control center answers, so a Keychain or filesystem
    /// failure afterwards must be recoverable by retrying the local save with
    /// the result already in hand, not by requesting another code.
    public static func install(_ provisioning: RemoteCoreProvisioning) throws {
        try install(provisioning, sink: .live)
    }

    static func install(
        _ provisioning: RemoteCoreProvisioning,
        sink: RemoteCoreConfigSink
    ) throws {
        guard provisioning.schema == 1 else { throw RemoteSyncError.invalidConfiguration }
        let previous = try? sink.loadConfig()
        let config = try RemoteCoreConfig(
            workspaceID: provisioning.workspaceID,
            coreDeviceID: provisioning.coreDeviceID,
            relayURL: provisioning.relayURL,
            coreEpoch: provisioning.coreEpoch,
            ingestKeyID: provisioning.ingestKeyID,
            probeSigningPublicKeys: provisioning.probeSigningPublicKeys
        )
        // Store the secret first. A crash can leave an unused Vault entry, but
        // never a plaintext config that claims to be usable without a token.
        try sink.storeBearerToken(provisioning.relayBearerToken, provisioning.workspaceID)
        try sink.writeConfig(config)
        // Replacing workspace A with workspace B must not strand A's
        // still-valid Relay credential in the Vault. Best-effort, and only
        // after the new configuration has committed, so a cleanup failure
        // can't break an otherwise successful install.
        if let previous, previous.workspaceID != provisioning.workspaceID {
            try? sink.deleteBearerToken(previous.workspaceID)
        }
    }

    /// Commit an enrollment obtained from the web control center. Identical to
    /// the provisioning-file path once the identity is in place: the Core keys
    /// were minted during the exchange rather than before it, so they have to
    /// land in the Vault before the workspace binding that depends on them.
    /// Retryable for the same reason `install(_ provisioning:)` is.
    public static func install(_ enrollment: RemoteEnrollmentResult) throws {
        try install(enrollment, sink: .live)
    }

    static func install(
        _ enrollment: RemoteEnrollmentResult,
        sink: RemoteCoreConfigSink
    ) throws {
        try sink.storeIdentity(enrollment.identity)
        try install(enrollment.provisioning, sink: sink)
        // The binding has committed, so the recovery record has done its job.
        // Best-effort: a leftover record is harmless — `pendingEnrollment()`
        // refuses to hand back one once a workspace is installed, and clears
        // it then.
        try? sink.deletePendingEnrollment()
    }

    // MARK: - Pending enrollment recovery

    /// Remember an enrollment the control center has already consumed, before
    /// trying to install it.
    ///
    /// A pairing code is spent the moment the control center answers, so the
    /// window between "accepted" and "saved" must survive a failed write, a
    /// closed window, and a quit. The record carries the Relay credential and
    /// this Mac's Core private keys, so it goes into the credential Vault and
    /// nowhere else.
    public static func retainPendingEnrollment(_ enrollment: RemoteEnrollmentResult) throws {
        try retainPendingEnrollment(enrollment, sink: .live)
    }

    static func retainPendingEnrollment(
        _ enrollment: RemoteEnrollmentResult,
        sink: RemoteCoreConfigSink
    ) throws {
        try sink.storePendingEnrollment(enrollment)
    }

    /// A retained enrollment that never finished installing, if any.
    ///
    /// Returns nil once this Mac is bound to a workspace: the record is stale
    /// then, and is cleared rather than offered as a resumable action.
    public static func pendingEnrollment() -> RemoteEnrollmentResult? {
        pendingEnrollment(sink: .live)
    }

    static func pendingEnrollment(sink: RemoteCoreConfigSink) -> RemoteEnrollmentResult? {
        guard (try? sink.loadConfig()) == nil else {
            try? sink.deletePendingEnrollment()
            return nil
        }
        return try? sink.loadPendingEnrollment()
    }

    /// Forget a retained enrollment. The workspace still counts this Mac as
    /// its Core, so the user's way back is to revoke this device in the web
    /// control center and join again with a fresh code.
    public static func discardPendingEnrollment() {
        discardPendingEnrollment(sink: .live)
    }

    static func discardPendingEnrollment(sink: RemoteCoreConfigSink) {
        try? sink.deletePendingEnrollment()
    }

    /// Persist a probe roster learned from the Relay during a sync. Only the
    /// set of authorized producers moves: the workspace binding and its Relay
    /// credential are untouched, so a configuration that points anywhere else
    /// is refused rather than silently rebinding this Mac.
    public static func updateProbeRoster(_ config: RemoteCoreConfig) throws {
        let installed = try load()
        guard installed.workspaceID == config.workspaceID,
              installed.coreDeviceID == config.coreDeviceID,
              installed.relayURL == config.relayURL,
              installed.coreEpoch == config.coreEpoch,
              installed.ingestKeyID == config.ingestKeyID
        else { throw RemoteSyncError.invalidConfiguration }
        try VibeBarLocalStore.writeJSON(config, to: VibeBarLocalStore.remoteCoreConfigURL)
    }

    public static func install(from url: URL) throws {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular,
              let permissions = attributes[.posixPermissions] as? NSNumber,
              permissions.intValue & 0o077 == 0,
              let size = attributes[.size] as? NSNumber,
              (1...1_048_576).contains(size.intValue)
        else {
            throw RemoteSyncError.invalidConfiguration
        }
        let provisioning = try JSONDecoder().decode(
            RemoteCoreProvisioning.self,
            from: Data(contentsOf: url)
        )
        try install(provisioning)
    }

    /// Remove this Mac's workspace binding. The relay credential leaves the
    /// Vault first, then the non-secret config file — mirroring install(),
    /// which stores the secret first. The decrypted usage ledger stays: it
    /// is the user's own data and re-provisioning must not lose history.
    public static func uninstall() throws {
        if let config = try? load() {
            try RemoteCoreIdentityStore.deleteRelayBearerToken(
                workspaceID: config.workspaceID
            )
        }
        try VibeBarLocalStore.deleteFile(at: VibeBarLocalStore.remoteCoreConfigURL)
    }

    public static func writePublicDescriptor(to url: URL) throws {
        let descriptor = try RemoteCoreIdentityStore.loadOrCreate().publicDescriptor
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(descriptor)
        try data.write(to: url, options: [.atomic])
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: url.path
        )
    }
}
