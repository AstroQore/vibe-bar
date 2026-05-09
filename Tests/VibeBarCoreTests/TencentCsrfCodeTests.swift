import XCTest
@testable import VibeBarCore

final class TencentCsrfCodeTests: XCTestCase {
    /// Vectors captured live against Tencent's in-page `getCsrfCode`
    /// helper. Any port that returns a different number for these inputs
    /// will fail to authenticate against console-hc BFF endpoints.
    func testKnownVectors() {
        let cases: [(skey: String, expected: Int)] = [
            ("", 5381),
            ("a", 177670),
            ("ab", 5863208),
            ("abc", 193485963),
            ("Hello", 223289465),
            ("0123456789", 995771986),
            ("AAAAAAAAAA", 1955737455),
            ("abcdefghijklmnopqrstuvwxyz", 1779545604),
            ("@AB-_CDe9rkf$wx9z3M", 534475970),
            ("skey1234567890_test_string", 1957107043),
            ("@kvdM2DWjHpHBC9SUMRDtAYK_QH9Awvbf03vpwt5h2KNwM", 1666737623)
        ]
        for (skey, expected) in cases {
            XCTAssertEqual(
                TencentCsrfCode.compute(from: skey),
                expected,
                "csrfCode mismatch for input \(skey.debugDescription)"
            )
        }
    }

    func testReturnsNonNegativeInt() {
        // `& 0x7FFFFFFF` clears the sign bit; result must always be in
        // [0, 2^31 - 1].
        let inputs = [
            "",
            "a",
            "x".repeated(1024),
            String(repeating: "🦊", count: 50),  // multi-unit UTF-16
            String(repeating: "中", count: 50),  // BMP non-ASCII
            String((0...127).map { Character(UnicodeScalar($0)!) })
        ]
        for input in inputs {
            let result = TencentCsrfCode.compute(from: input)
            XCTAssertGreaterThanOrEqual(result, 0, "csrfCode must be non-negative for input \(input.prefix(20))")
            XCTAssertLessThanOrEqual(result, 0x7FFFFFFF, "csrfCode must fit in 31 bits")
        }
    }

    func testDifferentInputsProduceDifferentCodes() {
        // djb2 isn't cryptographic, but trivially different short strings
        // should not collide. If they do, the JS port has drifted.
        let a = TencentCsrfCode.compute(from: "skeyA")
        let b = TencentCsrfCode.compute(from: "skeyB")
        XCTAssertNotEqual(a, b)
    }
}

private extension String {
    func repeated(_ count: Int) -> String {
        String(repeating: self, count: count)
    }
}
