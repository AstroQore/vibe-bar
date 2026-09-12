import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// The one place a grey buffer becomes the 1-bit PNG the panel draws.
///
/// Every mark the device shows — a ring, a heatmap, a monogram, a provider's
/// logo rasterized by the App — arrives here as 8-bit grey and leaves as a
/// thresholded PNG, because the device's own dithering would smear a 14 px
/// glyph into noise. Sharing the encoder is what keeps them all agreeing on
/// which side of the threshold a pixel falls.
public enum EInkBitmap {
    public enum BitmapError: Error, Equatable, Sendable {
        case encodingFailed
    }

    /// How much of the square has to be inked before a mark reads at all.
    ///
    /// A thin mark thresholded at 14 px can come back as a handful of stray
    /// pixels — recognisable on a Mac, mush on the panel — so a caller that
    /// lands under this floor is told to draw it bolder rather than ship it.
    public static let minimumInkCoverage = 0.06

    /// The share of pixels that would be black at this threshold.
    public static func inkCoverage(gray: [UInt8], threshold: UInt8) -> Double {
        guard !gray.isEmpty else { return 0 }
        return Double(gray.count { $0 < threshold }) / Double(gray.count)
    }

    /// One pass of 1 px dilation: every pixel takes the darkest of itself and
    /// its four neighbours. What "render it bold" means for a mark whose
    /// strokes are thinner than a device pixel.
    public static func dilated(gray: [UInt8], size: Int) -> [UInt8] {
        guard size > 0, gray.count == size * size else { return gray }
        var result = gray
        for row in 0..<size {
            for column in 0..<size {
                var darkest = gray[row * size + column]
                if row > 0 { darkest = min(darkest, gray[(row - 1) * size + column]) }
                if row < size - 1 { darkest = min(darkest, gray[(row + 1) * size + column]) }
                if column > 0 { darkest = min(darkest, gray[row * size + column - 1]) }
                if column < size - 1 { darkest = min(darkest, gray[row * size + column + 1]) }
                result[row * size + column] = darkest
            }
        }
        return result
    }

    /// `data:image/png;base64,…` for a thresholded square.
    public static func dataURI(gray: [UInt8], size: Int, threshold: UInt8) throws -> String {
        try "data:image/png;base64," + monochromePNG(gray: gray, size: size, threshold: threshold)
            .base64EncodedString()
    }

    /// 8-bit grey, top-down, `size × size`, thresholded to a 1-bit PNG.
    public static func monochromePNG(gray: [UInt8], size: Int, threshold: UInt8) throws -> Data {
        let bytesPerRow = (size + 7) / 8
        var bits = [UInt8](repeating: 0, count: bytesPerRow * size)
        for row in 0..<size {
            for column in 0..<size where gray[row * size + column] >= threshold {
                // 1 == white in a grey colour space.
                bits[row * bytesPerRow + column / 8] |= UInt8(0x80 >> (column % 8))
            }
        }
        guard let space = CGColorSpace(name: CGColorSpace.linearGray)
                ?? CGColorSpace(name: CGColorSpace.genericGrayGamma2_2),
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
        else { throw BitmapError.encodingFailed }

        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            output as CFMutableData,
            UTType.png.identifier as CFString,
            1,
            nil
        ) else { throw BitmapError.encodingFailed }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw BitmapError.encodingFailed }
        return output as Data
    }
}
