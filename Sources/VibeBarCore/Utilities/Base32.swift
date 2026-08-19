import Foundation

/// RFC 4648 base32, decode only.
///
/// Grok Bot names every file in its persistence directory after the base32
/// of the key it stores — lowercase and unpadded — so reading that store at
/// all means decoding a filename back into
/// `sand.client.slice.account.<id>.transcript.replicas.<uuid>`. Foundation
/// ships base64 and nothing else, hence this.
///
/// Deliberately total and strict in equal measure: a character outside the
/// alphabet, padding in the middle, a truncated group, or a final group whose
/// unused bits are not zero all yield `nil` rather than a best-effort prefix.
/// The caller is deciding whether an arbitrary filename is one of its own, so
/// "almost decodes" has to read as "not mine".
public enum Base32 {
    /// `A-Z2-7`, case-insensitive. `=` is accepted as trailing padding and
    /// otherwise rejected — the encoder Grok Bot uses omits it entirely.
    public static func decode(_ text: String) -> Data? {
        var out = Data()
        out.reserveCapacity(text.unicodeScalars.count * 5 / 8)
        var buffer: UInt32 = 0
        var bits: UInt32 = 0
        var sawPadding = false

        for scalar in text.unicodeScalars {
            if scalar == "=" {
                sawPadding = true
                continue
            }
            // Padding only ever ends a stream; a symbol after it means the
            // string was concatenated or corrupted.
            guard !sawPadding, let value = self.value(of: scalar) else { return nil }
            buffer = (buffer << 5) | UInt32(value)
            bits += 5
            if bits >= 8 {
                bits -= 8
                out.append(UInt8((buffer >> bits) & 0xFF))
            }
        }

        // A whole leftover group (5+ bits) is a truncated encoding, and the
        // bits left over from a valid one are defined to be zero.
        guard bits < 5, buffer & ((1 << bits) - 1) == 0 else { return nil }
        return out
    }

    /// Convenience for the common case: base32 of UTF-8 text.
    public static func decodeToString(_ text: String) -> String? {
        guard let data = decode(text) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private static func value(of scalar: Unicode.Scalar) -> UInt8? {
        switch scalar {
        case "A"..."Z": return UInt8(scalar.value - 65)
        case "a"..."z": return UInt8(scalar.value - 97)
        case "2"..."7": return UInt8(scalar.value - 50 + 26)
        default: return nil
        }
    }
}
