import CryptoKit
import Foundation

enum PrivacyPreservingHash {
    /// Lowercase hex digits, indexed by nibble.
    private static let hexDigits: [UInt8] = Array("0123456789abcdef".utf8)

    /// `"<prefix>-<sha256 hex>"`.
    ///
    /// The digest is rendered through a nibble lookup table rather than 32
    /// `String(format: "%02x")` calls: this runs once per session file per
    /// scan pass (~15k times on a heavy install, plus once per pricing
    /// revision), and the formatter round-trips dominated it. Output is
    /// byte-identical — the cache keys it produces are persisted, so it has
    /// to be.
    static func fileComponent(prefix: String, rawValue: String) -> String {
        let digest = SHA256.hash(data: Data(rawValue.utf8))
        var bytes: [UInt8] = []
        bytes.reserveCapacity(prefix.utf8.count + 1 + SHA256.byteCount * 2)
        bytes.append(contentsOf: prefix.utf8)
        bytes.append(UInt8(ascii: "-"))
        for byte in digest {
            bytes.append(hexDigits[Int(byte >> 4)])
            bytes.append(hexDigits[Int(byte & 0x0F)])
        }
        return String(decoding: bytes, as: UTF8.self)
    }
}
