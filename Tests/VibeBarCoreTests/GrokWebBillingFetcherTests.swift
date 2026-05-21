import XCTest
@testable import VibeBarCore

/// Locks the gRPC-web framing and protobuf scanner that
/// `GrokWebBillingFetcher` uses. The wire format is owned by xAI and
/// could shift without notice; these tests are the canary.
final class GrokWebBillingFetcherTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_799_000_000)

    // MARK: - Protobuf scanner

    func testParsesUsedPercentAndResetFromHandCraftedFrame() throws {
        let reset: UInt64 = 1_800_000_000
        let payload = Self.protobufPayload(usedPercent: 42.5, resetEpoch: reset)
        let frame = Self.grpcFrame(payload)

        let snapshot = try GrokWebBillingFetcher.parseGRPCWebResponse(frame, now: now)
        XCTAssertEqual(snapshot.usedPercent, 42.5, accuracy: 0.001)
        XCTAssertEqual(snapshot.resetsAt, Date(timeIntervalSince1970: TimeInterval(reset)))
    }

    func testIgnoresUnrelatedEarlierFloatAndPicksBillingField() throws {
        var payload = Data()
        // Field 9, fixed32 — unrelated in-range float that must NOT win.
        payload.append(0x4D)
        var unrelated = Float(7).bitPattern.littleEndian
        withUnsafeBytes(of: &unrelated) { payload.append(contentsOf: $0) }
        // Field 1, fixed32 — the real monthly used-percent.
        payload.append(0x0D)
        var usage = Float(42).bitPattern.littleEndian
        withUnsafeBytes(of: &usage) { payload.append(contentsOf: $0) }
        // Field 2, varint — reset timestamp.
        payload.append(0x10)
        payload.append(contentsOf: Self.varint(1_800_000_001))

        let snapshot = try GrokWebBillingFetcher.parseGRPCWebResponse(
            Self.grpcFrame(payload),
            now: now
        )
        XCTAssertEqual(snapshot.usedPercent, 42, accuracy: 0.001)
    }

    func testPrefersFutureBillingEndOverRecentBillingStart() throws {
        let recentStart: UInt64 = 1_800_000_000
        let billingEnd: UInt64 = 1_802_592_000
        var payload = Data()
        // Field 1, fixed32 — used percent.
        payload.append(0x0D)
        var percent = Float(33).bitPattern.littleEndian
        withUnsafeBytes(of: &percent) { payload.append(contentsOf: $0) }
        // Field 2, varint — billing start (close to "now", filtered out).
        payload.append(0x10)
        payload.append(contentsOf: Self.varint(recentStart))
        // Field 3, varint — billing end (the real reset, in the future).
        payload.append(0x18)
        payload.append(contentsOf: Self.varint(billingEnd))

        let snapshot = try GrokWebBillingFetcher.parseGRPCWebResponse(
            Self.grpcFrame(payload),
            now: Date(timeIntervalSince1970: TimeInterval(recentStart + 1_800))
        )
        XCTAssertEqual(snapshot.resetsAt, Date(timeIntervalSince1970: TimeInterval(billingEnd)))
    }

    func testParsesNoUsageYetResponseAsZeroPercent() throws {
        // Golden bytes captured from a brand-new SuperGrok account — no
        // fixed32 usage field, but a future-dated reset timestamp and
        // the `[1, 6, ...]` "future allotments" marker xAI sends to
        // signal "monthly budget known but not consumed yet".
        let data = Data([
            0x00, 0x00, 0x00, 0x00, 0x37, 0x0A, 0x35, 0x12,
            0x00, 0x1A, 0x00, 0x22, 0x06, 0x08, 0x80, 0xDA,
            0xCF, 0xCF, 0x06, 0x2A, 0x06, 0x08, 0x80, 0x97,
            0xF3, 0xD0, 0x06, 0x32, 0x09, 0x0A, 0x05, 0x08,
            0xEA, 0x0F, 0x10, 0x04, 0x12, 0x00, 0x32, 0x09,
            0x0A, 0x05, 0x08, 0xEA, 0x0F, 0x10, 0x03, 0x12,
            0x00, 0x32, 0x09, 0x0A, 0x05, 0x08, 0xEA, 0x0F,
            0x10, 0x02, 0x12, 0x00, 0x80, 0x00, 0x00, 0x00,
            0x0F, 0x67, 0x72, 0x70, 0x63, 0x2D, 0x73, 0x74,
            0x61, 0x74, 0x75, 0x73, 0x3A, 0x30, 0x0D, 0x0A,
        ])

        let snapshot = try GrokWebBillingFetcher.parseGRPCWebResponse(
            data,
            now: Date(timeIntervalSince1970: 1_768_000_000)
        )
        XCTAssertEqual(snapshot.usedPercent, 0)
        XCTAssertEqual(snapshot.resetsAt, Date(timeIntervalSince1970: 1_780_272_000))
    }

    func testRejectsResetOnlyPayloadThatLacksUsageAndNoUsageMarker() {
        var payload = Data()
        // Only a reset timestamp — no usage field, no `[1, 6]` marker.
        payload.append(0x10)
        payload.append(contentsOf: Self.varint(1_800_000_001))

        do {
            _ = try GrokWebBillingFetcher.parseGRPCWebResponse(Self.grpcFrame(payload), now: now)
            XCTFail("Expected parseFailure")
        } catch let error as QuotaError {
            guard case .parseFailure = error else {
                return XCTFail("Expected .parseFailure, got \(error)")
            }
        } catch {
            XCTFail("Expected QuotaError, got \(error)")
        }
    }

    // MARK: - gRPC-web framing

    func testDataFramesSkipTrailerFrames() {
        let payload = Self.protobufPayload(usedPercent: 12.25, resetEpoch: 1_800_000_001)
        let trailer = Data("grpc-status: 0\r\n".utf8)
        let combined = Self.grpcFrame(payload) + Self.grpcFrame(trailer, flags: 0x80)
        let frames = GrokWebBillingFetcher.dataFrames(from: combined)
        XCTAssertEqual(frames, [payload])
    }

    func testTrailerFieldsExtractGrpcStatus() {
        let trailer = Self.grpcFrame(
            Data("grpc-status: 16\r\ngrpc-message: token%20expired\r\n".utf8),
            flags: 0x80
        )
        let fields = GrokWebBillingFetcher.grpcWebTrailerFields(from: trailer)
        XCTAssertEqual(fields["grpc-status"], "16")
        XCTAssertEqual(fields["grpc-message"], "token expired")
    }

    // MARK: - Helpers

    private static func protobufPayload(usedPercent: Float, resetEpoch: UInt64) -> Data {
        var data = Data()
        data.append(0x0D)  // field 1, fixed32
        var percentBits = usedPercent.bitPattern.littleEndian
        withUnsafeBytes(of: &percentBits) { data.append(contentsOf: $0) }
        data.append(0x10)  // field 2, varint
        data.append(contentsOf: varint(resetEpoch))
        return data
    }

    private static func grpcFrame(_ payload: Data, flags: UInt8 = 0x00) -> Data {
        var data = Data([flags])
        let length = UInt32(payload.count).bigEndian
        withUnsafeBytes(of: length) { data.append(contentsOf: $0) }
        data.append(payload)
        return data
    }

    private static func varint(_ value: UInt64) -> [UInt8] {
        var remaining = value
        var bytes: [UInt8] = []
        repeat {
            var byte = UInt8(remaining & 0x7F)
            remaining >>= 7
            if remaining != 0 { byte |= 0x80 }
            bytes.append(byte)
        } while remaining != 0
        return bytes
    }
}
