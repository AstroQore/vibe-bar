import XCTest
@testable import VibeBarCore

final class ProtobufWireReaderTests: XCTestCase {
    // MARK: - Fixture writer

    private func varint(_ value: UInt64) -> [UInt8] {
        var bytes: [UInt8] = []
        var remaining = value
        while remaining > 0x7F {
            bytes.append(UInt8(remaining & 0x7F) | 0x80)
            remaining >>= 7
        }
        bytes.append(UInt8(remaining & 0x7F))
        return bytes
    }

    private func tag(_ field: UInt64, _ wire: UInt64) -> [UInt8] {
        varint((field << 3) | wire)
    }

    private func varintField(_ field: UInt64, _ value: UInt64) -> [UInt8] {
        tag(field, 0) + varint(value)
    }

    private func bytesField(_ field: UInt64, _ payload: [UInt8]) -> [UInt8] {
        tag(field, 2) + varint(UInt64(payload.count)) + payload
    }

    private func stringField(_ field: UInt64, _ value: String) -> [UInt8] {
        bytesField(field, [UInt8](value.utf8))
    }

    // MARK: - Wire types

    func testEveryWireTypeDecodesToItsOwnCase() {
        let bytes = varintField(1, 300)
            + stringField(2, "hello")
            + tag(3, 5) + [0x78, 0x56, 0x34, 0x12]
            + tag(4, 1) + [0x08, 0x07, 0x06, 0x05, 0x04, 0x03, 0x02, 0x01]

        let fields = ProtobufWireReader.fields(in: bytes)
        XCTAssertEqual(fields.map(\.number), [1, 2, 3, 4])
        XCTAssertEqual(fields[0].unsigned, 300)
        XCTAssertEqual(fields[1].text, "hello")
        guard case let .fixed32(small) = fields[2].value else { return XCTFail("expected fixed32") }
        XCTAssertEqual(small, 0x1234_5678, "fixed32 is little-endian on the wire")
        guard case let .fixed64(large) = fields[3].value else { return XCTFail("expected fixed64") }
        XCTAssertEqual(large, 0x0102_0304_0506_0708)
    }

    func testRepeatedFieldsAreKeptInOrder() {
        let bytes = stringField(1, "first") + stringField(1, "second") + stringField(1, "third")
        let texts = ProtobufWireReader.fields(in: bytes).filter { $0.number == 1 }.compactMap(\.text)
        XCTAssertEqual(texts, ["first", "second", "third"])
    }

    func testNestedMessagesAreLeftToTheCaller() {
        let inner = stringField(1, "inside")
        let bytes = bytesField(9, inner)
        let fields = ProtobufWireReader.fields(in: bytes)
        XCTAssertEqual(fields.count, 1)
        // The reader hands back the raw payload; recursion is the caller's
        // decision, which is what lets one pass stay flat and bounded.
        guard let payload = fields[0].bytes else { return XCTFail("expected bytes") }
        XCTAssertEqual(ProtobufWireReader.fields(in: Array(payload))[0].text, "inside")
    }

    func testNonUTF8BytesAreNotReportedAsText() {
        let bytes = bytesField(1, [0xFF, 0xFE, 0xFD])
        let field = ProtobufWireReader.fields(in: bytes)[0]
        XCTAssertNil(field.text)
        XCTAssertEqual(field.bytes.map(Array.init), [0xFF, 0xFE, 0xFD])
    }

    // MARK: - Malformed input

    func testATruncatedFieldKeepsEverythingBeforeIt() {
        let bytes = stringField(1, "kept") + tag(2, 2) + varint(50) + [UInt8](repeating: 0x41, count: 3)
        let fields = ProtobufWireReader.fields(in: bytes)
        XCTAssertEqual(fields.map(\.number), [1], "a length past the end ends the pass")
        XCTAssertEqual(fields[0].text, "kept")
    }

    func testTruncatedFixedWidthFieldsStopThePass() {
        for wire: UInt64 in [1, 5] {
            let bytes = stringField(1, "kept") + tag(2, wire) + [0x01]
            XCTAssertEqual(ProtobufWireReader.fields(in: bytes).map(\.number), [1])
        }
    }

    func testARemovedGroupWireTypeStopsThePass() {
        let bytes = stringField(1, "kept") + tag(2, 3) + stringField(4, "unreachable")
        XCTAssertEqual(ProtobufWireReader.fields(in: bytes).map(\.number), [1])
    }

    func testAZeroKeyEndsThePassBecauseFieldZeroIsIllegal() {
        let bytes = stringField(1, "kept") + [0x00] + stringField(2, "unreachable")
        XCTAssertEqual(ProtobufWireReader.fields(in: bytes).map(\.number), [1])
    }

    func testEmptyInputDecodesToNothing() {
        XCTAssertTrue(ProtobufWireReader.fields(in: []).isEmpty)
    }

    // MARK: - Bounds

    func testTheFieldLimitBoundsThePass() {
        let bytes = (0..<50).flatMap { _ in varintField(1, 1) }
        XCTAssertEqual(ProtobufWireReader.fields(in: bytes, limit: 10).count, 10)
        XCTAssertEqual(ProtobufWireReader.fields(in: bytes).count, 50)
    }

    func testAnOverlongVarintIsRefusedRatherThanWrapped() {
        // Eleven continuation bytes: past the 64-bit shift ceiling.
        let bytes = stringField(1, "kept") + tag(2, 0) + [UInt8](repeating: 0x80, count: 11)
        XCTAssertEqual(ProtobufWireReader.fields(in: bytes).map(\.number), [1])
    }

    func testDecodingIsScopedToAGivenRange() {
        let prefix = stringField(1, "before")
        let bytes = prefix + stringField(2, "inside")
        let fields = ProtobufWireReader.fields(in: bytes, range: prefix.count..<bytes.count)
        XCTAssertEqual(fields.map(\.number), [2])
        XCTAssertEqual(fields[0].text, "inside")
    }
}
