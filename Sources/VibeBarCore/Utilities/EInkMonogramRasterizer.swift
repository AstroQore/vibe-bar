import CoreGraphics
import CoreText
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// The mark a provider with no art gets: two letters in a 1 px box.
///
/// The panel's element set has no way to draw a rounded outline around live
/// text — `div` borders are square and a `span` cannot be boxed — and more to
/// the point, a monogram has to survive the same thresholding the real marks
/// do. So it is rasterized here, exactly like the rings: supersampled, drawn
/// in the bundled faces, and thresholded to black or white before it leaves.
public enum EInkMonogramRasterizer {
    public enum RasterError: Error, Equatable, Sendable {
        case invalidSize(Int)
        case contextUnavailable
        case encodingFailed
    }

    public static let supersample = 4
    /// Gray at or above which a downsampled pixel becomes white. Lower than
    /// the ring's, because two letters inside a box are mostly edge and a
    /// stricter threshold eats their strokes.
    public static let threshold: UInt8 = 150

    public static func dataURI(initials: String, size: Int) throws -> String {
        let key = CacheKey(initials: initials, size: size)
        if let cached = cache.value(for: key) { return cached }
        let uri = try "data:image/png;base64," + pngData(initials: initials, size: size).base64EncodedString()
        cache.store(uri, for: key)
        return uri
    }

    /// The raw 1-bit PNG, `size × size`.
    public static func pngData(initials: String, size: Int) throws -> Data {
        guard size >= 8, size <= 128 else { throw RasterError.invalidSize(size) }
        let gray = try renderGray(initials: String(initials.prefix(2)), size: size)
        return try encodeMonochromePNG(gray: gray, size: size)
    }

    // MARK: - Drawing

    private static func renderGray(initials: String, size: Int) throws -> [UInt8] {
        let scale = supersample
        let big = size * scale
        guard let space = CGColorSpace(name: CGColorSpace.linearGray)
                ?? CGColorSpace(name: CGColorSpace.genericGrayGamma2_2),
              let context = CGContext(
                data: nil,
                width: big,
                height: big,
                bitsPerComponent: 8,
                bytesPerRow: big,
                space: space,
                bitmapInfo: CGImageAlphaInfo.none.rawValue
              )
        else { throw RasterError.contextUnavailable }

        context.setFillColor(gray: 1, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: big, height: big))
        context.setShouldAntialias(true)

        // A 1 px box at panel scale, rounded by a quarter of its side.
        let inset = Double(scale) / 2
        let box = CGRect(
            x: inset,
            y: inset,
            width: Double(big) - Double(scale),
            height: Double(big) - Double(scale)
        )
        let radius = box.width / 4
        context.setStrokeColor(gray: 0, alpha: 1)
        context.setLineWidth(Double(scale))
        context.addPath(CGPath(roundedRect: box, cornerWidth: radius, cornerHeight: radius, transform: nil))
        context.strokePath()

        // The bundled bold sans, sized to the box rather than to the panel's
        // 12 px pixel face: two letters of pixel type do not fit inside a
        // 14 px square, and a monogram that spills its own box is worse than
        // no monogram at all.
        let font = EInkFonts.font(.sansBold, size: Double(big) * 0.5)
        let attributed = NSAttributedString(
            string: initials,
            attributes: [
                NSAttributedString.Key(kCTFontAttributeName as String): font,
                NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 0, alpha: 1)
            ]
        )
        let line = CTLineCreateWithAttributedString(attributed)
        let bounds = CTLineGetBoundsWithOptions(line, .useOpticalBounds)
        context.textPosition = CGPoint(
            x: (Double(big) - bounds.width) / 2 - bounds.origin.x,
            y: (Double(big) - bounds.height) / 2 - bounds.origin.y
        )
        CTLineDraw(line, context)

        guard let large = context.makeImage(),
              let small = CGContext(
                data: nil,
                width: size,
                height: size,
                bitsPerComponent: 8,
                bytesPerRow: size,
                space: space,
                bitmapInfo: CGImageAlphaInfo.none.rawValue
              )
        else { throw RasterError.contextUnavailable }
        small.interpolationQuality = .high
        small.draw(large, in: CGRect(x: 0, y: 0, width: size, height: size))
        guard let pixels = small.data else { throw RasterError.contextUnavailable }
        let buffer = pixels.bindMemory(to: UInt8.self, capacity: size * size)
        var flipped = [UInt8](repeating: 0, count: size * size)
        for row in 0..<size {
            let source = (size - 1 - row) * small.bytesPerRow
            for column in 0..<size {
                flipped[row * size + column] = buffer[source + column]
            }
        }
        return flipped
    }

    // MARK: - Encoding

    static func encodeMonochromePNG(gray: [UInt8], size: Int) throws -> Data {
        try EInkBitmap.monochromePNG(gray: gray, size: size, threshold: threshold)
    }

    // MARK: - Cache

    struct CacheKey: Hashable, Sendable {
        var initials: String
        var size: Int
    }

    private final class Cache: @unchecked Sendable {
        private let lock = NSLock()
        private var storage: [CacheKey: String] = [:]

        func value(for key: CacheKey) -> String? {
            lock.lock()
            defer { lock.unlock() }
            return storage[key]
        }

        func store(_ value: String, for key: CacheKey) {
            lock.lock()
            defer { lock.unlock() }
            if storage.count > 256 { storage.removeAll(keepingCapacity: true) }
            storage[key] = value
        }

        func removeAll() {
            lock.lock()
            defer { lock.unlock() }
            storage.removeAll()
        }
    }

    private static let cache = Cache()

    public static func clearCache() { cache.removeAll() }
}
