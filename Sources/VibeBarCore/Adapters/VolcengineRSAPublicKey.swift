import Foundation
import Security

/// Helpers for building a `SecKey` RSA public key from Volcengine's
/// JWK and encrypting under PKCS#1 v1.5.
///
/// `SecKeyCreateWithData(_:_:_:)` with `kSecAttrKeyTypeRSA` accepts the
/// raw PKCS#1 `RSAPublicKey` DER:
///
/// ```text
/// RSAPublicKey ::= SEQUENCE {
///     modulus           INTEGER,
///     publicExponent    INTEGER
/// }
/// ```
///
/// We assemble the DER manually so the project doesn't take a second
/// external dependency just for ASN.1.
public enum VolcengineRSAPublicKey {
    public enum RSAError: Error, Equatable {
        case invalidJWK
        case keyCreationFailed(String)
        case encryptionFailed(String)
    }

    /// Build a `SecKey` from base64URL-encoded JWK `n` (modulus) and
    /// `e` (public exponent) values. Both inputs are URL-safe base64
    /// without padding, exactly as JWK serializes them.
    public static func makePublicKey(jwkN: String, jwkE: String) throws -> SecKey {
        guard let modulus = base64URLDecode(jwkN),
              let exponent = base64URLDecode(jwkE),
              !modulus.isEmpty, !exponent.isEmpty else {
            throw RSAError.invalidJWK
        }
        let der = pkcs1RSAPublicKeyDER(modulus: modulus, exponent: exponent)
        let attributes: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
            kSecAttrKeyClass as String: kSecAttrKeyClassPublic,
            kSecAttrKeySizeInBits as String: modulus.count * 8
        ]
        var error: Unmanaged<CFError>?
        guard let key = SecKeyCreateWithData(der as CFData, attributes as CFDictionary, &error) else {
            let message = error?.takeRetainedValue().localizedDescription ?? "SecKeyCreateWithData returned nil"
            throw RSAError.keyCreationFailed(message)
        }
        return key
    }

    /// PKCS#1 v1.5 encrypt the UTF-8 bytes of `plaintext` and base64
    /// the ciphertext.
    public static func encryptPasswordPKCS1(_ plaintext: String, publicKey: SecKey) throws -> String {
        let data = Data(plaintext.utf8)
        var error: Unmanaged<CFError>?
        guard let cipher = SecKeyCreateEncryptedData(
            publicKey,
            .rsaEncryptionPKCS1,
            data as CFData,
            &error
        ) else {
            let message = error?.takeRetainedValue().localizedDescription ?? "SecKeyCreateEncryptedData returned nil"
            throw RSAError.encryptionFailed(message)
        }
        return (cipher as Data).base64EncodedString()
    }

    /// Decode a base64URL string (no padding, `-_` instead of `+/`).
    public static func base64URLDecode(_ raw: String) -> Data? {
        var s = raw
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let pad = (4 - s.count % 4) % 4
        if pad > 0 {
            s.append(String(repeating: "=", count: pad))
        }
        return Data(base64Encoded: s)
    }

    // MARK: - ASN.1 / DER

    /// Build the raw DER for `RSAPublicKey ::= SEQUENCE { modulus, exponent }`.
    static func pkcs1RSAPublicKeyDER(modulus: Data, exponent: Data) -> Data {
        let modulusInt = derInteger(modulus)
        let exponentInt = derInteger(exponent)
        var content = Data()
        content.append(modulusInt)
        content.append(exponentInt)
        return derSequence(content)
    }

    /// ASN.1 INTEGER. Prepends `0x00` when the high bit of the first
    /// byte is set, so positive numbers can't be misread as negative.
    private static func derInteger(_ raw: Data) -> Data {
        var value = raw
        if let first = value.first, first & 0x80 != 0 {
            value.insert(0x00, at: 0)
        }
        return derTLV(tag: 0x02, value: value)
    }

    /// ASN.1 SEQUENCE.
    private static func derSequence(_ content: Data) -> Data {
        derTLV(tag: 0x30, value: content)
    }

    /// Generic Tag-Length-Value emitter with definite long-form length
    /// encoding for payloads ≥ 128 bytes.
    private static func derTLV(tag: UInt8, value: Data) -> Data {
        var out = Data()
        out.append(tag)
        out.append(derLength(value.count))
        out.append(value)
        return out
    }

    private static func derLength(_ length: Int) -> Data {
        if length < 0x80 {
            return Data([UInt8(length)])
        }
        var bytes: [UInt8] = []
        var remaining = length
        while remaining > 0 {
            bytes.insert(UInt8(remaining & 0xFF), at: 0)
            remaining >>= 8
        }
        var header = Data([0x80 | UInt8(bytes.count)])
        header.append(contentsOf: bytes)
        return header
    }
}
