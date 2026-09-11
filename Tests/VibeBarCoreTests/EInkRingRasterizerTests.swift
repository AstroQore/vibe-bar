import XCTest
@testable import VibeBarCore

final class EInkRingRasterizerTests: XCTestCase {
    private static let pngSignature: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]

    private func dimensions(_ data: Data) -> (width: Int, height: Int)? {
        // IHDR is the first chunk: 8-byte signature, 4-byte length, "IHDR",
        // then two big-endian 32-bit dimensions.
        guard data.count >= 24 else { return nil }
        let bytes = [UInt8](data)
        guard Array(bytes[0..<8]) == Self.pngSignature else { return nil }
        func be32(_ offset: Int) -> Int {
            (Int(bytes[offset]) << 24) | (Int(bytes[offset + 1]) << 16)
                | (Int(bytes[offset + 2]) << 8) | Int(bytes[offset + 3])
        }
        return (be32(16), be32(20))
    }

    func testFortyEightPixelRingIsASmallOneBitPNG() throws {
        EInkRingRasterizer.clearCache()
        let data = try EInkRingRasterizer.pngData(percent: 62, size: 48, stroke: 6)
        let size = try XCTUnwrap(dimensions(data))
        XCTAssertEqual(size.width, 48)
        XCTAssertEqual(size.height, 48)
        XCTAssertLessThanOrEqual(data.count, 1000, "48 px ring grew to \(data.count) bytes")
        XCTAssertGreaterThan(data.count, 50)
    }

    func testDataURIIsBase64PNGAndCached() throws {
        EInkRingRasterizer.clearCache()
        let first = try EInkRingRasterizer.dataURI(percent: 40, size: 44, stroke: 6)
        XCTAssertTrue(first.hasPrefix("data:image/png;base64,"))
        let encoded = String(first.dropFirst("data:image/png;base64,".count))
        let decoded = try XCTUnwrap(Data(base64Encoded: encoded))
        XCTAssertEqual(dimensions(decoded)?.width, 44)
        XCTAssertEqual(try EInkRingRasterizer.dataURI(percent: 40, size: 44, stroke: 6), first)
    }

    func testDistinctPercentagesProduceDistinctImages() throws {
        EInkRingRasterizer.clearCache()
        let empty = try EInkRingRasterizer.pngData(percent: 0, size: 48, stroke: 6)
        let half = try EInkRingRasterizer.pngData(percent: 50, size: 48, stroke: 6)
        let full = try EInkRingRasterizer.pngData(percent: 100, size: 48, stroke: 6)
        XCTAssertNotEqual(empty, half)
        XCTAssertNotEqual(half, full)
    }

    func testOutOfRangeInputsAreClampedOrRejected() throws {
        EInkRingRasterizer.clearCache()
        XCTAssertEqual(
            try EInkRingRasterizer.pngData(percent: 400, size: 48, stroke: 6),
            try EInkRingRasterizer.pngData(percent: 100, size: 48, stroke: 6)
        )
        XCTAssertThrowsError(try EInkRingRasterizer.pngData(percent: 50, size: 2, stroke: 1)) { error in
            XCTAssertEqual(error as? EInkRingRasterizer.RasterError, .invalidSize(2))
        }
    }

    func testRenderingIsDeterministic() throws {
        EInkRingRasterizer.clearCache()
        let first = try EInkRingRasterizer.pngData(percent: 73, size: 48, stroke: 6)
        EInkRingRasterizer.clearCache()
        let second = try EInkRingRasterizer.pngData(percent: 73, size: 48, stroke: 6)
        XCTAssertEqual(first, second)
    }
}
