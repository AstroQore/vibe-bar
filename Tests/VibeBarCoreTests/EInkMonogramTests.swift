import AppKit
import CoreGraphics
import Foundation
import ImageIO
import XCTest
@testable import VibeBarCore

/// The mark a provider with no art gets.
///
/// The owner's panel printed "ChatGPT Agentic" as `CV` and "Claude" as `Cr`:
/// the letters were upside down, and an upside-down `A` is a `V`. A bitmap
/// context's memory runs top-down while its drawing origin is bottom-left, and
/// "converting" between the two by reversing the rows turns the picture over —
/// invisible on a ring, fatal on type.
///
/// So the test renders the same two letters through a path that shares no code
/// with the rasterizer — `NSAttributedString` into an `NSImage` — and asks
/// whether the two agree on which way up they are.
final class EInkMonogramTests: XCTestCase {
    private let size = 48

    override func setUp() {
        super.setUp()
        EInkMonogramRasterizer.clearCache()
    }

    // MARK: - Orientation

    func testTheMonogramIsDrawnTheSameWayUpAsAppKitDrawsIt() throws {
        let drawn = try profile(rasterized("CL"))
        let reference = try profile(appKitRendered("CL"))
        let upright = correlation(drawn, reference)
        let upsideDown = correlation(drawn, reference.reversed())
        XCTAssertGreaterThan(
            upright,
            upsideDown,
            "the rasterized monogram matches AppKit's mirror image better than AppKit itself"
        )
    }

    /// The same thing said without a reference, so a failure names the shape
    /// rather than a correlation: an `L` is bottom-heavy.
    func testAnLHasMoreInkInItsLowerHalfThanItsUpper() throws {
        let rows = try profile(rasterized("LL"))
        let top = rows.prefix(rows.count / 2).reduce(0, +)
        let bottom = rows.suffix(rows.count / 2).reduce(0, +)
        XCTAssertGreaterThan(bottom, top, "the foot of an L is at the bottom")
    }

    /// And the box around them is still square, still one panel pixel, and
    /// still leaves the letters room — the flip was the only thing wrong.
    func testTheBoxStillFramesTheLetters() throws {
        let pixels = try rasterized("CL")
        // The corners are rounded away, so the box is read at the mid-edges.
        XCTAssertTrue(isInk(pixels, row: 0, column: size / 2), "top edge")
        XCTAssertTrue(isInk(pixels, row: size - 1, column: size / 2), "bottom edge")
        XCTAssertTrue(isInk(pixels, row: size / 2, column: 0), "left edge")
        XCTAssertTrue(isInk(pixels, row: size / 2, column: size - 1), "right edge")
        // And the letters keep clear of it. Read down the middle third, away
        // from the rounded corners, where the frame is one pixel and the
        // column beside it belongs to the letters or to nobody.
        for row in (size / 3)..<(2 * size / 3) {
            XCTAssertFalse(isInk(pixels, row: row, column: 3), "the letters ran into the box")
        }
    }

    // MARK: - Initials

    /// Two words give their initials; one word gives its first two letters.
    func testTheInitialsComeFromTheSubProvidersOwnName() {
        XCTAssertEqual(EInkLogo.monogram(for: "ChatGPT Agentic"), "CA")
        XCTAssertEqual(EInkLogo.monogram(for: "Claude"), "CL")
        XCTAssertEqual(EInkLogo.monogram(for: "AntiGravity"), "AN")
        XCTAssertEqual(EInkLogo.monogram(for: "Grok Bot"), "GB")
        XCTAssertEqual(EInkLogo.monogram(for: "Gemini Web"), "GW")
        XCTAssertEqual(EInkLogo.monogram(for: ""), "??")
    }

    // MARK: - Rendering

    /// What the panel is sent, decoded back to pixels.
    private func rasterized(_ initials: String) throws -> [UInt8] {
        let png = try EInkMonogramRasterizer.pngData(initials: initials, size: size)
        guard let source = CGImageSourceCreateWithData(png as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else { throw RenderFailure.decode }
        return try pixels(of: image)
    }

    /// The same letters through AppKit's own text drawing, which shares no
    /// code with the rasterizer.
    private func appKitRendered(_ initials: String) throws -> [UInt8] {
        let image = NSImage(size: NSSize(width: size, height: size))
        image.lockFocus()
        NSColor.white.setFill()
        NSRect(x: 0, y: 0, width: size, height: size).fill()
        let attributed = NSAttributedString(
            string: initials,
            attributes: [
                .font: NSFont.boldSystemFont(ofSize: CGFloat(size) * 0.5),
                .foregroundColor: NSColor.black
            ]
        )
        let bounds = attributed.size()
        attributed.draw(
            at: NSPoint(
                x: (CGFloat(size) - bounds.width) / 2,
                y: (CGFloat(size) - bounds.height) / 2
            )
        )
        image.unlockFocus()
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            throw RenderFailure.decode
        }
        return try pixels(of: cgImage)
    }

    private enum RenderFailure: Error { case decode }

    /// 8-bit grey, top-down. A bitmap context's row 0 is the top of the
    /// picture, and drawing a `CGImage` into it puts the image's first row
    /// there — no reversing, which is the whole point of this file.
    private func pixels(of image: CGImage) throws -> [UInt8] {
        guard let space = CGColorSpace(name: CGColorSpace.linearGray),
              let context = CGContext(
                data: nil,
                width: size,
                height: size,
                bitsPerComponent: 8,
                bytesPerRow: size,
                space: space,
                bitmapInfo: CGImageAlphaInfo.none.rawValue
              )
        else { throw RenderFailure.decode }
        context.setFillColor(gray: 1, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: size, height: size))
        context.draw(image, in: CGRect(x: 0, y: 0, width: size, height: size))
        guard let data = context.data else { throw RenderFailure.decode }
        let buffer = data.bindMemory(to: UInt8.self, capacity: size * size)
        return (0..<(size * size)).map { buffer[$0] }
    }

    private func isInk(_ pixels: [UInt8], row: Int, column: Int) -> Bool {
        pixels[row * size + column] < 128
    }

    /// Ink per row, with the frame's own columns left out so the box — which
    /// is symmetric and would drown the letters — does not vote.
    private func profile(_ pixels: [UInt8]) throws -> [Double] {
        (0..<size).map { row in
            (4..<(size - 4)).reduce(0.0) { total, column in
                total + (isInk(pixels, row: row, column: column) ? 1 : 0)
            }
        }
    }

    private func correlation(_ lhs: [Double], _ rhs: [Double]) -> Double {
        let count = Double(min(lhs.count, rhs.count))
        let meanL = lhs.reduce(0, +) / count
        let meanR = rhs.reduce(0, +) / count
        var covariance = 0.0
        var varianceL = 0.0
        var varianceR = 0.0
        for index in 0..<Int(count) {
            let dl = lhs[index] - meanL
            let dr = rhs[index] - meanR
            covariance += dl * dr
            varianceL += dl * dl
            varianceR += dr * dr
        }
        guard varianceL > 0, varianceR > 0 else { return 0 }
        return covariance / (varianceL * varianceR).squareRoot()
    }
}
