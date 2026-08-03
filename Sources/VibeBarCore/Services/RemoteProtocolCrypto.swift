import Foundation
import CryptoKit
import CoreFoundation

enum RemoteCanonicalJSON {
    static func encode(_ value: Any) throws -> Data {
        var output = Data()
        try append(value, to: &output)
        return output
    }

    private static func append(_ value: Any, to output: inout Data) throws {
        switch value {
        case is NSNull:
            output.append(contentsOf: "null".utf8)
        case let number as NSNumber:
            if CFGetTypeID(number) == CFBooleanGetTypeID() {
                output.append(contentsOf: (number.boolValue ? "true" : "false").utf8)
            } else {
                guard !Self.isFloatingPoint(number) else {
                    throw RemoteSyncError.invalidEnvelope
                }
                let integer = number.int64Value
                guard NSNumber(value: integer) == number else {
                    throw RemoteSyncError.invalidEnvelope
                }
                output.append(contentsOf: String(integer).utf8)
            }
        case let string as String:
            appendString(string, to: &output)
        case let array as [Any]:
            output.append(0x5B)
            for (index, item) in array.enumerated() {
                if index > 0 { output.append(0x2C) }
                try append(item, to: &output)
            }
            output.append(0x5D)
        case let object as [String: Any]:
            output.append(0x7B)
            for (index, key) in object.keys.sorted().enumerated() {
                if index > 0 { output.append(0x2C) }
                appendString(key, to: &output)
                output.append(0x3A)
                guard let item = object[key] else { throw RemoteSyncError.invalidEnvelope }
                try append(item, to: &output)
            }
            output.append(0x7D)
        default:
            throw RemoteSyncError.invalidEnvelope
        }
    }

    private static func isFloatingPoint(_ number: NSNumber) -> Bool {
        let type = String(cString: number.objCType)
        return type == "f" || type == "d"
    }

    private static func appendString(_ value: String, to output: inout Data) {
        output.append(0x22)
        for scalar in value.unicodeScalars {
            switch scalar.value {
            case 0x22: output.append(contentsOf: "\\\"".utf8)
            case 0x5C: output.append(contentsOf: "\\\\".utf8)
            case 0x08: output.append(contentsOf: "\\b".utf8)
            case 0x09: output.append(contentsOf: "\\t".utf8)
            case 0x0A: output.append(contentsOf: "\\n".utf8)
            case 0x0C: output.append(contentsOf: "\\f".utf8)
            case 0x0D: output.append(contentsOf: "\\r".utf8)
            case 0x00...0x1F:
                output.append(contentsOf: String(format: "\\u%04x", scalar.value).utf8)
            default:
                output.append(contentsOf: String(scalar).utf8)
            }
        }
        output.append(0x22)
    }
}

struct RemoteOpenedEnvelope {
    let sequence: Int64
    let producerID: UUID
    let plaintext: Data
}

enum RemoteProtocolCrypto {
    private static let requiredEnvelopeKeys: Set<String> = [
        "protocol_version", "minimum_consumer_version", "workspace_id", "stream",
        "producer_id", "sequence", "core_epoch", "key_id", "created_at", "expires_at",
        "ephemeral_public_key", "nonce", "ciphertext", "signing_public_key", "signature"
    ]

    static func openIngestEnvelope(
        _ data: Data,
        config: RemoteCoreConfig,
        identity: RemoteCoreIdentity,
        acceptedAt: Date = Date()
    ) throws -> RemoteOpenedEnvelope {
        // Structural validation. Every check here is exactly as before EXCEPT
        // the two that pin an envelope to the *current* generation —
        // `core_epoch` and `key_id`. Those are decided below, after the
        // signature proves the producer, so that an authenticated batch from an
        // earlier generation can be classified `.supersededEnvelope` instead of
        // a fatal `.invalidEnvelope`. `core_epoch` is still required to be a
        // positive integer and `key_id` a string; only their equality with the
        // config moves.
        guard data.count <= 1_048_576,
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(object.keys) == requiredEnvelopeKeys,
              exactInteger(object["protocol_version"]) == 1,
              exactInteger(object["minimum_consumer_version"]) == 1,
              object["stream"] as? String == "ingest",
              let workspaceRaw = object["workspace_id"] as? String,
              let workspaceID = UUID(uuidString: workspaceRaw),
              workspaceID == config.workspaceID,
              let producerRaw = object["producer_id"] as? String,
              let producerID = UUID(uuidString: producerRaw),
              let expectedSigningKey = config.probeSigningPublicKeys[producerID],
              let sequence = exactInteger(object["sequence"]), sequence > 0,
              let coreEpoch = exactInteger(object["core_epoch"]), coreEpoch > 0,
              let keyID = object["key_id"] as? String,
              let createdRaw = object["created_at"] as? String,
              let expiresRaw = object["expires_at"] as? String,
              let createdAt = parseTimestamp(createdRaw),
              let expiresAt = parseTimestamp(expiresRaw),
              createdAt <= acceptedAt.addingTimeInterval(5 * 60),
              expiresAt > acceptedAt,
              expiresAt > createdAt,
              expiresAt.timeIntervalSince(createdAt) <= 366 * 24 * 60 * 60,
              let ephemeralRaw = object["ephemeral_public_key"] as? String,
              let ephemeralData = Data(base64Encoded: ephemeralRaw),
              ephemeralData.count == 65,
              let nonceRaw = object["nonce"] as? String,
              let nonceData = Data(base64Encoded: nonceRaw), nonceData.count == 12,
              let ciphertextRaw = object["ciphertext"] as? String,
              let ciphertext = Data(base64Encoded: ciphertextRaw), ciphertext.count >= 16,
              let signingRaw = object["signing_public_key"] as? String,
              let signingData = Data(base64Encoded: signingRaw),
              signingData == expectedSigningKey,
              let signatureRaw = object["signature"] as? String,
              let signatureData = Data(base64Encoded: signatureRaw), signatureData.count == 64
        else { throw RemoteSyncError.invalidEnvelope }

        // Generation gates that must stay fatal are decided BEFORE the signature
        // check, so their error (`.invalidEnvelope`) is preserved exactly as the
        // pre-restructure guard produced it, whether the signature is valid or
        // not:
        //   * current epoch but a key id that is not the current generation's;
        //   * a future epoch — the Core is behind and this must surface, never
        //     silently skip forward.
        let expectedEpoch = Int64(config.coreEpoch)
        if coreEpoch == expectedEpoch, keyID != config.ingestKeyID {
            throw RemoteSyncError.invalidEnvelope
        }
        if coreEpoch > expectedEpoch {
            throw RemoteSyncError.invalidEnvelope
        }

        var unsigned = object
        unsigned.removeValue(forKey: "signature")
        let signature = try P256.Signing.ECDSASignature(rawRepresentation: signatureData)
        let signingKey = try P256.Signing.PublicKey(x963Representation: signingData)
        guard signingKey.isValidSignature(
            signature,
            for: try RemoteCanonicalJSON.encode(unsigned)
        ) else { throw RemoteSyncError.invalidSignature }

        // The signature verified against a producer key already in the config's
        // roster: forging it requires that probe's signing private key, which is
        // game-over-equivalent. Only now, with the producer proven, is a batch
        // from a strictly earlier Core generation classified as superseded
        // backlog. It is never decrypted or imported — the caller skips and
        // acknowledges it. A current-generation envelope (equal epoch, matching
        // key id) falls through to decryption unchanged.
        if coreEpoch < expectedEpoch {
            throw RemoteSyncError.supersededEnvelope
        }

        let ephemeralKey = try P256.KeyAgreement.PublicKey(x963Representation: ephemeralData)
        let secret = try identity.recipientPrivateKey.sharedSecretFromKeyAgreement(
            with: ephemeralKey
        )
        let symmetricKey = secret.hkdfDerivedSymmetricKey(
            using: SHA256.self,
            salt: Data("VibeBar Sync Protocol v1\0".utf8),
            sharedInfo: hkdfInfo(
                workspaceID: config.workspaceID,
                producerID: producerID,
                sequence: sequence
            ),
            outputByteCount: 32
        )
        var header = object
        header.removeValue(forKey: "ciphertext")
        header.removeValue(forKey: "signature")
        let sealed = try AES.GCM.SealedBox(
            nonce: AES.GCM.Nonce(data: nonceData),
            ciphertext: ciphertext.dropLast(16),
            tag: ciphertext.suffix(16)
        )
        let plaintext: Data
        do {
            plaintext = try AES.GCM.open(
                sealed,
                using: symmetricKey,
                authenticating: RemoteCanonicalJSON.encode(header)
            )
        } catch {
            throw RemoteSyncError.decryptionFailed
        }
        return RemoteOpenedEnvelope(
            sequence: sequence,
            producerID: producerID,
            plaintext: plaintext
        )
    }

    private static func exactInteger(_ value: Any?) -> Int64? {
        guard let number = value as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID()
        else { return nil }
        let type = String(cString: number.objCType)
        guard type != "f", type != "d" else { return nil }
        return number.int64Value
    }

    private static func hkdfInfo(
        workspaceID: UUID,
        producerID: UUID,
        sequence: Int64
    ) -> Data {
        var output = Data("vibebar/envelope/v1\0ingest\0".utf8)
        output.append(contentsOf: workspaceID.uuidString.lowercased().utf8)
        output.append(0)
        output.append(contentsOf: producerID.uuidString.lowercased().utf8)
        output.append(0)
        var bigEndian = UInt64(sequence).bigEndian
        withUnsafeBytes(of: &bigEndian) { output.append(contentsOf: $0) }
        return output
    }

    static func parseTimestamp(_ raw: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: raw) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: raw)
    }
}
