import Foundation
import CryptoKit

public struct RemoteCoreIdentity: Sendable {
    public let signingPrivateKey: P256.Signing.PrivateKey
    public let recipientPrivateKey: P256.KeyAgreement.PrivateKey

    public var publicDescriptor: RemoteCorePublicDescriptor {
        RemoteCorePublicDescriptor(
            signingPublicKey: signingPrivateKey.publicKey.x963Representation,
            recipientPublicKey: recipientPrivateKey.publicKey.x963Representation
        )
    }
}

public enum RemoteCoreIdentityStore {
    private static let service = "com.astroqore.VibeBar.remote-sync"
    private static let identityAccount = "core-identity-v1"

    private struct Payload: Codable {
        let schema: Int
        let signingPrivateKey: Data
        let recipientPrivateKey: Data

        private enum CodingKeys: String, CodingKey {
            case schema
            case signingPrivateKey = "signing_private_key"
            case recipientPrivateKey = "recipient_private_key"
        }
    }

    public static func loadOrCreate() throws -> RemoteCoreIdentity {
        do {
            let data = try VibeBarCredentialVault.readData(
                service: service,
                account: identityAccount
            )
            let payload = try JSONDecoder().decode(Payload.self, from: data)
            guard payload.schema == 1 else { throw RemoteSyncError.invalidConfiguration }
            return RemoteCoreIdentity(
                signingPrivateKey: try P256.Signing.PrivateKey(
                    rawRepresentation: payload.signingPrivateKey
                ),
                recipientPrivateKey: try P256.KeyAgreement.PrivateKey(
                    rawRepresentation: payload.recipientPrivateKey
                )
            )
        } catch KeychainStore.KeychainError.itemNotFound {
            let identity = RemoteCoreIdentity(
                signingPrivateKey: P256.Signing.PrivateKey(),
                recipientPrivateKey: P256.KeyAgreement.PrivateKey()
            )
            try store(identity)
            return identity
        }
    }

    /// Persist an identity generated elsewhere. Joining a workspace with a
    /// one-time code mints a fresh keypair and registers its public halves
    /// with the control center, so the private halves must replace whatever
    /// this Mac held — the previously exported descriptor no longer describes
    /// the workspace's Core recipient key.
    static func store(_ identity: RemoteCoreIdentity) throws {
        let payload = Payload(
            schema: 1,
            signingPrivateKey: identity.signingPrivateKey.rawRepresentation,
            recipientPrivateKey: identity.recipientPrivateKey.rawRepresentation
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try VibeBarCredentialVault.writeData(
            service: service,
            account: identityAccount,
            data: try encoder.encode(payload)
        )
    }

    public static func relayBearerToken(workspaceID: UUID) throws -> String {
        try VibeBarCredentialVault.readString(
            service: service,
            account: relayAccount(workspaceID)
        )
    }

    static func storeRelayBearerToken(_ token: String, workspaceID: UUID) throws {
        guard (32...512).contains(token.utf8.count),
              token.unicodeScalars.allSatisfy({ !$0.properties.isWhitespace })
        else { throw RemoteSyncError.invalidConfiguration }
        try VibeBarCredentialVault.writeString(
            service: service,
            account: relayAccount(workspaceID),
            value: token
        )
    }

    static func deleteRelayBearerToken(workspaceID: UUID) throws {
        do {
            try VibeBarCredentialVault.delete(
                service: service,
                account: relayAccount(workspaceID)
            )
        } catch KeychainStore.KeychainError.itemNotFound {
            // Already gone — deletion is idempotent.
        }
    }

    private static func relayAccount(_ workspaceID: UUID) -> String {
        "relay:" + workspaceID.uuidString.lowercased()
    }
}
