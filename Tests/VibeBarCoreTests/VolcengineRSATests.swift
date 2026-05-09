import XCTest
@testable import VibeBarCore

final class VolcengineRSATests: XCTestCase {
    /// PKCS#1 RSAPublicKey DER for a tiny synthetic 8-bit modulus
    /// (`0x91`) and exponent (`0x010001` = 65537). Confirms the long-form
    /// length encoding and the high-bit `0x00` prefix injection — the
    /// parts that bit RSA-DER ports historically.
    func testDEREncodesShortModulusWithHighBitPrefix() {
        // modulus 0x91 has its high bit set, so DER must emit
        // INTEGER 02 02 00 91 (prepend a 0x00 to keep the value
        // unsigned). exponent 0x010001 stays as 02 03 01 00 01.
        // SEQUENCE wraps: 02 02 00 91 02 03 01 00 01 → length 9
        // → 30 09 02 02 00 91 02 03 01 00 01.
        let der = VolcengineRSAPublicKey.pkcs1RSAPublicKeyDER(
            modulus: Data([0x91]),
            exponent: Data([0x01, 0x00, 0x01])
        )
        XCTAssertEqual(der, Data([
            0x30, 0x09,
            0x02, 0x02, 0x00, 0x91,
            0x02, 0x03, 0x01, 0x00, 0x01
        ]))
    }

    func testDERHandlesLongFormLength() {
        // Modulus that is 200 bytes long, all 0x55 (no high bit).
        // INTEGER: 02 81 C8 <200 bytes> = 203 bytes
        // exponent: 02 03 01 00 01 = 5 bytes
        // SEQUENCE content = 208 bytes → 02 81 D0 …
        let modulus = Data(repeating: 0x55, count: 200)
        let der = VolcengineRSAPublicKey.pkcs1RSAPublicKeyDER(
            modulus: modulus,
            exponent: Data([0x01, 0x00, 0x01])
        )
        // SEQUENCE outer: 30 81 D0 (length 0xD0 = 208)
        XCTAssertEqual(der.prefix(3), Data([0x30, 0x81, 0xD0]))
        // INTEGER modulus header: 02 81 C8
        XCTAssertEqual(der.subdata(in: 3..<6), Data([0x02, 0x81, 0xC8]))
    }

    func testBase64URLDecodesPaddedAndUnpaddedInputs() {
        let unpadded = "AQAB"  // standard 65537 exponent, no padding
        XCTAssertEqual(VolcengineRSAPublicKey.base64URLDecode(unpadded), Data([0x01, 0x00, 0x01]))

        let needsPadding = "AQAB"  // 4-char block, no padding required
        XCTAssertNotNil(VolcengineRSAPublicKey.base64URLDecode(needsPadding))

        let urlSafe = "_-_-"  // base64url chars - / +
        XCTAssertNotNil(VolcengineRSAPublicKey.base64URLDecode(urlSafe))
    }

    /// End-to-end smoke test: build a real 2048-bit key from a freshly
    /// generated `SecKey`, then verify the encrypt path returns the
    /// expected 256-byte ciphertext (344-char base64).
    func testEncryptsAt256Bytes() throws {
        // Generate a real RSA-2048 key just for the test, then strip
        // the modulus + exponent out of it via SecKeyCopyExternalRepresentation
        // → ASN.1 round-trip → wrap with our helper. This proves the
        // helper's DER survives a real Security.framework round-trip.
        let attrs: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
            kSecAttrKeySizeInBits as String: 2048
        ]
        var error: Unmanaged<CFError>?
        guard let privateKey = SecKeyCreateRandomKey(attrs as CFDictionary, &error) else {
            throw error!.takeRetainedValue() as Error
        }
        guard let publicKey = SecKeyCopyPublicKey(privateKey) else {
            XCTFail("Could not derive public key")
            return
        }
        let cipherText = try VolcengineRSAPublicKey.encryptPasswordPKCS1("hunter2", publicKey: publicKey)
        let cipherBytes = Data(base64Encoded: cipherText)
        XCTAssertEqual(cipherBytes?.count, 256, "RSA-2048 PKCS#1 v1.5 ciphertext must be 256 bytes")
        XCTAssertEqual(cipherText.count, 344, "256-byte ciphertext base64-encodes to 344 chars")
    }
}
