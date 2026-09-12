import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Draws the 7 × 24 activity grid as a pre-thresholded 1-bit PNG.
///
/// It is an image rather than 168 `div`s for two reasons, and only the second
/// one is about taste: the Canvas API caps a payload at 80 elements, and the
/// panel's own dithering would smear a 2 px dot into grey noise. The PNG ships
/// already black-and-white and the element carries `img-dither-none`, so what
/// the panel prints is exactly what this drew.
///
/// Dot size comes from the cell's *quantile*, not from its share of the
/// maximum: one all-night session would otherwise flatten every other hour to
/// a single pixel, and the question the grid answers is "when do I work", not
/// "when was my single busiest hour".
public enum EInkHeatmapRasterizer {
    public enum RasterError: Error, Equatable, Sendable {
        case invalidSize(Int)
        case contextUnavailable
        case encodingFailed
    }

    /// The four dot diameters, smallest (no activity) first.
    public static let dotDiameters = [0, 1, 2, 3]

    /// `data:image/png;base64,…` for the grid.
    ///
    /// `weekdaysAcross` puts the seven days on the x axis (the portrait
    /// arrangement) instead of the twenty-four hours (landscape).
    public static func dataURI(
        heatmap: EInkHeatmap,
        cellSize: Int,
        weekdaysAcross: Bool
    ) throws -> String {
        let key = CacheKey(
            signature: signature(of: heatmap),
            cellSize: cellSize,
            weekdaysAcross: weekdaysAcross
        )
        if let cached = cache.value(for: key) { return cached }
        let data = try pngData(heatmap: heatmap, cellSize: cellSize, weekdaysAcross: weekdaysAcross)
        let uri = "data:image/png;base64," + data.base64EncodedString()
        cache.store(uri, for: key)
        return uri
    }

    public static func size(cellSize: Int, weekdaysAcross: Bool) -> (width: Int, height: Int) {
        weekdaysAcross ? (cellSize * 7, cellSize * 24) : (cellSize * 24, cellSize * 7)
    }

    public static func pngData(
        heatmap: EInkHeatmap,
        cellSize: Int,
        weekdaysAcross: Bool
    ) throws -> Data {
        guard cellSize >= 3, cellSize <= 64 else { throw RasterError.invalidSize(cellSize) }
        let size = size(cellSize: cellSize, weekdaysAcross: weekdaysAcross)
        let bytesPerRow = (size.width + 7) / 8
        // 1 == white in a gray colour space, so start the sheet white.
        var bits = [UInt8](repeating: 0xFF, count: bytesPerRow * size.height)
        let levels = quantileLevels(heatmap)

        for weekday in 0..<7 {
            for hour in 0..<24 {
                let diameter = dotDiameters[levels[weekday][hour]]
                guard diameter > 0 else { continue }
                let column = weekdaysAcross ? weekday : hour
                let rowIndex = weekdaysAcross ? hour : weekday
                let originX = column * cellSize + (cellSize - diameter) / 2
                let originY = rowIndex * cellSize + (cellSize - diameter) / 2
                for y in originY..<(originY + diameter) {
                    guard y >= 0, y < size.height else { continue }
                    for x in originX..<(originX + diameter) {
                        guard x >= 0, x < size.width else { continue }
                        bits[y * bytesPerRow + x / 8] &= ~UInt8(0x80 >> (x % 8))
                    }
                }
            }
        }
        return try encode(bits: bits, width: size.width, height: size.height, bytesPerRow: bytesPerRow)
    }

    /// `0...3` per cell: empty, and then the three quantiles of the non-empty
    /// cells.
    public static func quantileLevels(_ heatmap: EInkHeatmap) -> [[Int]] {
        let values = heatmap.cells.flatMap { $0 }.filter { $0 > 0 }.sorted()
        guard !values.isEmpty else { return Array(repeating: Array(repeating: 0, count: 24), count: 7) }
        func quantile(_ fraction: Double) -> Int {
            let index = min(values.count - 1, max(0, Int((Double(values.count - 1) * fraction).rounded())))
            return values[index]
        }
        let low = quantile(1.0 / 3)
        let high = quantile(2.0 / 3)
        return heatmap.cells.map { row in
            row.map { value in
                if value <= 0 { return 0 }
                if value <= low { return 1 }
                if value <= high { return 2 }
                return 3
            }
        }
    }

    // MARK: - Encoding

    private static func encode(bits: [UInt8], width: Int, height: Int, bytesPerRow: Int) throws -> Data {
        guard let space = CGColorSpace(name: CGColorSpace.linearGray)
                ?? CGColorSpace(name: CGColorSpace.genericGrayGamma2_2),
              let provider = CGDataProvider(data: Data(bits) as CFData),
              let image = CGImage(
                width: width,
                height: height,
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

    /// The levels, not the counts: two refreshes an hour apart almost always
    /// draw the same dots, and the cache should hit then.
    static func signature(of heatmap: EInkHeatmap) -> String {
        quantileLevels(heatmap).map { $0.map(String.init).joined() }.joined(separator: "|")
    }

    struct CacheKey: Hashable, Sendable {
        var signature: String
        var cellSize: Int
        var weekdaysAcross: Bool
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
            if storage.count > 32 { storage.removeAll(keepingCapacity: true) }
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
