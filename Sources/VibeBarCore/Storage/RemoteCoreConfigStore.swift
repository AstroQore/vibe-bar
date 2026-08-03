import Foundation

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

    public static func install(_ provisioning: RemoteCoreProvisioning) throws {
        guard provisioning.schema == 1 else { throw RemoteSyncError.invalidConfiguration }
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
        try RemoteCoreIdentityStore.storeRelayBearerToken(
            provisioning.relayBearerToken,
            workspaceID: provisioning.workspaceID
        )
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
