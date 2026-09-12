import AppKit
import CoreGraphics
import Foundation
import VibeBarCore

/// The menu bar's brand marks, rasterized for the panel.
///
/// The same art identifies the same providers in the menu bar, the popover and
/// the Workbench, so a slot that shows a logo instead of "ChatGPT Agentic" is
/// not introducing a symbol — it is reusing the one the reader already knows,
/// and buying back the 92 px the words cost on a 284 px row.
///
/// Everything is resolved up front, on the main actor, because
/// `ProviderBrandIcon` is main-actor bound and the assembler that asks for a
/// mark runs off it. The table is small — a handful of tools at two sizes, a
/// few hundred bytes each — and rasterizing at refresh time would put a
/// `lockFocus` pass on the sync path for art that never changes.
struct EInkBrandLogos: EInkLogoProviding {
    /// `EInkLogo.key`-shaped entries: "<tool>@<size>".
    private let table: [String: String]

    @MainActor
    init(tools: [ToolType] = ToolType.allCases, sizes: [Int] = EInkLogo.sizes) {
        var table: [String: String] = [:]
        for tool in tools {
            for size in sizes {
                guard let uri = Self.dataURI(for: tool, size: size) else { continue }
                table["\(tool.rawValue)@\(size)"] = uri
            }
        }
        self.table = table
    }

    func logoDataURI(tool: ToolType, size: Int) -> String? {
        table["\(tool.rawValue)@\(size)"]
    }

    // MARK: - Rasterizing

    /// Gray at or above which a downsampled pixel becomes white.
    ///
    /// Half way: the marks are flat black on transparent, so anything the 4×
    /// downsample leaves more than half covered is ink.
    static let threshold: UInt8 = 128
    static let supersample = 4

    @MainActor
    static func dataURI(for tool: ToolType, size: Int) -> String? {
        guard size >= 8, size <= 128 else { return nil }
        let big = size * supersample
        // Tinted black rather than plain: the tinted path is the one that
        // applies each mark's own overshoot, and the marks are authored white
        // on nothing — their shape is alpha, not colour, which is exactly why
        // the menu bar draws them as templates.
        guard let mark = ProviderBrandIcon.image(
            for: tool,
            size: NSSize(width: big, height: big),
            tint: .black
        ) else { return nil }
        guard var gray = coverage(mark, big: big, size: size) else { return nil }
        // A mark whose strokes are thinner than a device pixel — the
        // Anthropic "A", a hairline monogram — thresholds to a scatter of
        // dots at 14 px. Drawing it one pixel bolder is what the panel needs
        // to show a shape rather than noise.
        if EInkBitmap.inkCoverage(gray: gray, threshold: threshold) < EInkBitmap.minimumInkCoverage {
            gray = EInkBitmap.dilated(gray: gray, size: size)
        }
        // Still nothing to look at: better no mark than a blank box where a
        // provider's name used to be — the slot falls back to words.
        guard EInkBitmap.inkCoverage(gray: gray, threshold: threshold) > 0.01 else { return nil }
        return try? EInkBitmap.dataURI(gray: gray, size: size, threshold: threshold)
    }

    /// The mark's alpha, box-averaged down to `size × size` of 8-bit grey with
    /// the PNG's top-down row order. Ink is where the mark covered the pixel,
    /// which is the only thing a 1-bit panel can ask about it.
    @MainActor
    private static func coverage(_ image: NSImage, big: Int, size: Int) -> [UInt8]? {
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: big,
            pixelsHigh: big,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: big * 4,
            bitsPerPixel: 32
        ) else { return nil }
        let previous = NSGraphicsContext.current
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSGraphicsContext.current?.cgContext.clear(CGRect(x: 0, y: 0, width: big, height: big))
        image.draw(
            in: NSRect(x: 0, y: 0, width: big, height: big),
            from: .zero,
            operation: .sourceOver,
            fraction: 1
        )
        NSGraphicsContext.current = previous

        guard let planes = rep.bitmapData else { return nil }
        let bytesPerRow = rep.bytesPerRow
        var gray = [UInt8](repeating: 255, count: size * size)
        for row in 0..<size {
            for column in 0..<size {
                var total = 0
                for dy in 0..<supersample {
                    for dx in 0..<supersample {
                        let y = row * supersample + dy
                        let x = column * supersample + dx
                        total += Int(planes[y * bytesPerRow + x * 4 + 3])
                    }
                }
                gray[row * size + column] = UInt8(max(0, 255 - total / (supersample * supersample)))
            }
        }
        return gray
    }
}
