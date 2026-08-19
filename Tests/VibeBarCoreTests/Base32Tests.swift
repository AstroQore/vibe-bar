import XCTest
@testable import VibeBarCore

final class Base32Tests: XCTestCase {
    /// RFC 4648 § 10's own vectors, which pin the alphabet and every
    /// remainder length (0, 2, 4, 5, and 7 symbols in the last group).
    func testRFC4648TestVectors() {
        let vectors: [(String, String)] = [
            ("", ""),
            ("MY======", "f"),
            ("MZXQ====", "fo"),
            ("MZXW6===", "foo"),
            ("MZXW6YQ=", "foob"),
            ("MZXW6YTB", "fooba"),
            ("MZXW6YTBOI======", "foobar")
        ]
        for (encoded, expected) in vectors {
            XCTAssertEqual(Base32.decodeToString(encoded), expected, encoded)
        }
    }

    /// Grok Bot writes its filenames lowercase and without padding, so both
    /// have to decode to the same bytes as the canonical form.
    func testLowercaseAndUnpaddedDecodeTheSame() {
        XCTAssertEqual(Base32.decodeToString("mzxw6ytboi"), "foobar")
        XCTAssertEqual(Base32.decodeToString("MZXW6YTBOI"), "foobar")
        XCTAssertEqual(Base32.decodeToString("mZxW6yTb"), "fooba")
        XCTAssertEqual(Base32.decodeToString("my"), "f")
    }

    func testDecodesARealisticPersistenceKey() {
        let key = "sand.client.slice.account.acct-1.transcript.replicas."
            + "11111111-2222-3333-4444-555555555555"
        let encoded = Base32TestEncoder.encode(key)
        XCTAssertEqual(Base32.decodeToString(encoded), key)
        XCTAssertEqual(Base32.decodeToString(encoded.uppercased()), key)
    }

    func testRejectsSymbolsOutsideTheAlphabet() {
        // 0/1/8/9 and separators are exactly the characters base32 drops to
        // stay unambiguous, so a hex or base64 string must not decode.
        for bad in ["mzxw6ytb0i", "mzxw6ytb1i", "mzxw6ytb8i", "MZXW-YTB", "mzxw ytb", "!", "mzxw6ytb+"] {
            XCTAssertNil(Base32.decode(bad), bad)
        }
    }

    func testRejectsPaddingThatIsNotTrailing() {
        XCTAssertNil(Base32.decode("MZ=XW6YTB"))
        XCTAssertNil(Base32.decode("=MY"))
    }

    /// A single leftover symbol carries five bits, which cannot complete a
    /// byte — that is a truncated encoding, not a short one.
    func testRejectsATruncatedFinalGroup() {
        XCTAssertNil(Base32.decode("M"))
        XCTAssertNil(Base32.decode("MZXW6Y"))
    }

    /// The unused low bits of a final group are defined to be zero. Accepting
    /// non-zero ones would make several distinct strings decode alike, and
    /// filenames are identity here.
    func testRejectsNonZeroPaddingBits() {
        XCTAssertEqual(Base32.decodeToString("MY"), "f")
        XCTAssertNil(Base32.decode("MZ"))
    }

    func testDecodesEveryByteValue() {
        let bytes = Data((0...255).map(UInt8.init))
        XCTAssertEqual(Base32.decode(Base32TestEncoder.encode(bytes)), bytes)
    }
}

/// The other half of the codec, for fixtures only.
///
/// Lowercase and unpadded — the shape Grok Bot writes its filenames in. Tests
/// need it to build a synthetic store; product code only ever decodes, so
/// this deliberately lives in the test target.
enum Base32TestEncoder {
    static func encode(_ text: String) -> String {
        encode(Data(text.utf8))
    }

    static func encode(_ data: Data) -> String {
        let alphabet = Array("abcdefghijklmnopqrstuvwxyz234567")
        var out = ""
        var buffer = 0
        var bits = 0
        for byte in data {
            buffer = (buffer << 8) | Int(byte)
            bits += 8
            while bits >= 5 {
                bits -= 5
                out.append(alphabet[(buffer >> bits) & 0x1F])
            }
        }
        if bits > 0 {
            out.append(alphabet[(buffer << (5 - bits)) & 0x1F])
        }
        return out
    }
}
