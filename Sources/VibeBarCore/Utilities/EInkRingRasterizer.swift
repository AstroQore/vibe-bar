import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Draws the quota rings the Canvas API cannot: its element set is only
/// `div` / `span` / `img`, and `clip-path` polygons render unreliably on the
/// panel, so an arc has to arrive as a 1-bit PNG.
///
/// The arc starts at 12 o'clock and sweeps clockwise, over a 1 px track, at
/// 6× supersampling so the threshold to black-or-white lands on a clean edge.
/// Results are memoized by `(percent, size, stroke)`: a carousel redraws the
/// same handful of rings every refresh, and the encode is the expensive part.
public enum EInkRingRasterizer {
    public enum RasterError: Error, Equatable, Sendable {
        case invalidSize(Int)
        case contextUnavailable
        case encodingFailed
    }

    public static let supersample = 6
    /// Gray level at or above which a downsampled pixel becomes white.
    public static let threshold: UInt8 = 140

    /// `data:image/png;base64,…` for the ring, ready to drop into an `img`.
    public static func dataURI(percent: Int, size: Int, stroke: Int) throws -> String {
        let key = CacheKey(percent: max(0, min(100, percent)), size: size, stroke: stroke)
        if let cached = cache.value(for: key) { return cached }
        let data = try pngData(percent: key.percent, size: size, stroke: stroke)
        let uri = "data:image/png;base64," + data.base64EncodedString()
        cache.store(uri, for: key)
        return uri
    }

    /// The raw 1-bit PNG. Exposed for tests and for anything that needs the
    /// bytes rather than the URI.
    public static func pngData(percent: Int, size: Int, stroke: Int) throws -> Data {
        guard size >= 8, size <= 512 else { throw RasterError.invalidSize(size) }
        let clamped = max(0, min(100, percent))
        let strokeWidth = max(1, min(size / 2, stroke))
        let gray = try renderGray(percent: clamped, size: size, stroke: strokeWidth)
        return try encodeMonochromePNG(gray: gray, size: size)
    }

    // MARK: - Drawing

    /// 8-bit gray, `size × size`, already downsampled from the 6× canvas.
    private static func renderGray(percent: Int, size: Int, stroke: Int) throws -> [UInt8] {
        let scale = supersample
        let big = size * scale
        guard let space = CGColorSpace(name: CGColorSpace.linearGray) ?? CGColorSpace(name: CGColorSpace.genericGrayGamma2_2),
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

        let center = CGPoint(x: Double(big) / 2, y: Double(big) / 2)
        let trackWidth = Double(scale)
        let outerRadius = Double(big) / 2 - trackWidth / 2

        // 1 px track.
        context.setStrokeColor(gray: 0, alpha: 1)
        context.setLineWidth(trackWidth)
        context.addArc(
            center: center,
            radius: outerRadius,
            startAngle: 0,
            endAngle: 2 * .pi,
            clockwise: false
        )
        context.strokePath()

        if percent > 0 {
            // A filled pie from 12 o'clock clockwise, then the middle punched
            // back out to `stroke` thickness — the same construction the
            // verified demo used, which keeps the arc ends square.
            let sweep = 2 * Double.pi * Double(percent) / 100
            let start = -Double.pi / 2
            context.setFillColor(gray: 0, alpha: 1)
            context.beginPath()
            context.move(to: center)
            context.addArc(
                center: center,
                radius: Double(big) / 2,
                startAngle: start,
                endAngle: start + sweep,
                clockwise: false
            )
            context.closePath()
            context.fillPath()

            let innerRadius = Double(big) / 2 - Double(stroke * scale)
            if innerRadius > trackWidth {
                context.setFillColor(gray: 1, alpha: 1)
                context.addArc(center: center, radius: innerRadius, startAngle: 0, endAngle: 2 * .pi, clockwise: false)
                context.fillPath()
                context.setStrokeColor(gray: 0, alpha: 1)
                context.setLineWidth(trackWidth)
                context.addArc(center: center, radius: innerRadius, startAngle: 0, endAngle: 2 * .pi, clockwise: false)
                context.strokePath()
            }
        }

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
        // CoreGraphics origin is bottom-left; the PNG rows run top-down.
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

    private static func encodeMonochromePNG(gray: [UInt8], size: Int) throws -> Data {
        let bytesPerRow = (size + 7) / 8
        var bits = [UInt8](repeating: 0, count: bytesPerRow * size)
        for row in 0..<size {
            for column in 0..<size {
                // 1 == white in a gray color space.
                guard gray[row * size + column] >= threshold else { continue }
                bits[row * bytesPerRow + column / 8] |= UInt8(0x80 >> (column % 8))
            }
        }
        guard let space = CGColorSpace(name: CGColorSpace.linearGray) ?? CGColorSpace(name: CGColorSpace.genericGrayGamma2_2),
              let provider = CGDataProvider(data: Data(bits) as CFData),
              let image = CGImage(
                width: size,
                height: size,
                bitsPerComponent: 1,
                bitsPerPixel: 1,
                bytesPerRow: bytesPerRow,
                space: space,
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
                provider: provider,
                decode: nil,
                shouldInterpolate: false,
                intent: .defaultIntent
              )
        else { throw RasterError.encodingFailed }

        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            output as CFMutableData,
            UTType.png.identifier as CFString,
            1,
            nil
        ) else { throw RasterError.encodingFailed }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw RasterError.encodingFailed }
        return output as Data
    }

    // MARK: - Cache

    struct CacheKey: Hashable, Sendable {
        var percent: Int
        var size: Int
        var stroke: Int
    }

    /// A plain lock rather than an actor: the encoder is synchronous and runs
    /// off the main thread already, and making it `async` would push `await`
    /// into every preset builder for no benefit.
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
            if storage.count > 512 { storage.removeAll(keepingCapacity: true) }
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
