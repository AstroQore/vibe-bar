import AppKit
import SwiftUI
import VibeBarCore

/// A 1:1 drawing of what the e-ink panel will show.
///
/// Paper, not chrome: pure white ground, black ink, no shadow, no blur, no
/// rounded corners beyond a hairline frame — the rest of Settings is the flat
/// card recipe, and this one rectangle is allowed to look like the device
/// because it *is* the device (see `docs/DESIGN.md`).
///
/// Three rules keep it honest:
///
/// - **Same geometry as the device.** The boxes come from
///   `EInkPreviewPlanner`, which runs the same `EInkBoxLayout.resolve` the
///   encoder runs. Nothing is laid out again here.
/// - **Same glyphs as the device.** Text is drawn with the bundled
///   `EInkFonts` faces at the box's own size — Fusion Pixel 12 for the pixel
///   role, the ChillDuanSans subsets for the sans role — so a label that fits
///   here fits there.
/// - **No work in `body`.** The plan arrives already resolved; `body` maps
///   boxes onto views and nothing else. No `TimelineView` either: a preview
///   shows the snapshot's own countdown text, which is what the panel will
///   show until the next push.
struct EInkPreviewView: View {
    let plan: EInkPreviewPlan
    /// Whole-paper magnification. 1 is device pixels; 2 and 3 are the sizes
    /// the settings pane uses. It scales the finished canvas rather than
    /// re-laying it out, so the pixel grid stays square.
    var scale: CGFloat = 1

    private var paperWidth: CGFloat { CGFloat(plan.panelWidth) }
    private var paperHeight: CGFloat { CGFloat(plan.panelHeight) }

    var body: some View {
        paper
            .frame(width: paperWidth, height: paperHeight)
            .scaleEffect(scale, anchor: .topLeading)
            .frame(width: paperWidth * scale, height: paperHeight * scale, alignment: .topLeading)
            .overlay(
                Rectangle()
                    .strokeBorder(Color.primary.opacity(0.22), lineWidth: 1)
            )
            .accessibilityHidden(true)
    }

    /// The authored canvas is **centred** in the paper and then turned about
    /// its own centre. That centring is not cosmetic: a portrait layout is
    /// authored 152 × 296 inside a 296 × 152 panel, and the encoder spends the
    /// same `(panel − authored) / 2` offsets before its root `rotate()`.
    /// Pinning the canvas to the top-left instead would rotate it out of the
    /// paper and clip most of the slide away.
    private var paper: some View {
        ZStack(alignment: .center) {
            Color.white
            canvas
                .frame(width: CGFloat(plan.authoredWidth), height: CGFloat(plan.authoredHeight))
                .rotationEffect(.degrees(plan.rotationDegrees))
        }
        .frame(width: paperWidth, height: paperHeight)
        .clipped()
    }

    private var canvas: some View {
        ZStack(alignment: .topLeading) {
            Color.white
            ForEach(Array(plan.boxes.enumerated()), id: \.offset) { entry in
                box(entry.element)
            }
        }
    }

    @ViewBuilder
    private func box(_ drawBox: EInkDrawBox) -> some View {
        let frame = drawBox.frame
        content(drawBox)
            .frame(width: CGFloat(frame.width), height: CGFloat(frame.height), alignment: alignment(drawBox))
            .modifier(ClipIfNeeded(active: drawBox.clipsContent))
            .offset(x: CGFloat(frame.x), y: CGFloat(frame.y))
    }

    private func alignment(_ drawBox: EInkDrawBox) -> Alignment {
        guard case let .text(_, _, textAlignment) = drawBox.content else { return .topLeading }
        switch textAlignment {
        case .leading: return .leading
        case .center: return .center
        case .trailing: return .trailing
        }
    }

    @ViewBuilder
    private func content(_ drawBox: EInkDrawBox) -> some View {
        switch drawBox.content {
        case let .text(string, font, _):
            Text(string)
                .font(Font(EInkPreviewFonts.ctFont(for: font)))
                .foregroundStyle(Color.black)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: true)
        case let .image(dataURI):
            pixelImage(EInkPreviewFonts.image(dataURI: dataURI), size: drawBox.frame)
        case .fill:
            Rectangle().fill(Color.black)
        case .outline:
            Rectangle()
                .strokeBorder(Color.black, lineWidth: 1)
                .background(Rectangle().fill(Color.white))
        case let .ring(percent, stroke):
            pixelImage(
                EInkPreviewFonts.ring(percent: percent, size: drawBox.frame.width, stroke: stroke),
                size: drawBox.frame
            )
        }
    }

    @ViewBuilder
    private func pixelImage(_ image: NSImage?, size: EInkRect) -> some View {
        if let image {
            // `.interpolation(.none)` is the whole point: a 1-bit raster
            // magnified with smoothing stops looking like the panel.
            Image(nsImage: image)
                .resizable()
                .interpolation(.none)
                .antialiased(false)
                .frame(width: CGFloat(size.width), height: CGFloat(size.height))
        } else {
            Color.clear
        }
    }
}

/// Applies `.clipped()` only where the layout says the box clips, because
/// clipping an `.auto` text box would shave a glyph the device draws fine.
private struct ClipIfNeeded: ViewModifier {
    let active: Bool

    func body(content: Content) -> some View {
        if active { content.clipped() } else { content }
    }
}

/// Bridges the Core drawing vocabulary onto AppKit: fonts, data-URI images,
/// and the ring raster.
///
/// The two caches exist because the same handful of rings and the same few
/// fonts are asked for on every preview redraw, and both answers cost a
/// CoreGraphics round trip. `EInkRingRasterizer` memoizes its data URIs
/// already; this memoizes the decoded `NSImage`s on top of it.
@MainActor
enum EInkPreviewFonts {
    /// The device has no bold pixel face, so a bold pixel role draws in the
    /// same 12 px bitmap — synthesising weight here would put a preview a
    /// pixel or two wider than the panel.
    static func ctFont(for font: EInkFont) -> CTFont {
        switch font {
        case .pixel12:
            return EInkFonts.font(.pixel, size: EInkFonts.pixelPointSize)
        case let .sans(size, bold):
            return EInkFonts.font(bold ? .sansBold : .sans, size: CGFloat(size))
        }
    }

    static func image(dataURI: String) -> NSImage? {
        if let cached = imageCache[dataURI] { return cached }
        guard let comma = dataURI.range(of: ","),
              let data = Data(base64Encoded: String(dataURI[comma.upperBound...]))
        else { return nil }
        let image = NSImage(data: data)
        if let image { imageCache[dataURI] = image }
        return image
    }

    static func ring(percent: Int, size: Int, stroke: Int) -> NSImage? {
        let key = RingKey(percent: percent, size: size, stroke: stroke)
        if let cached = ringCache[key] { return cached }
        guard let data = try? EInkRingRasterizer.pngData(percent: percent, size: size, stroke: stroke),
              let image = NSImage(data: data)
        else { return nil }
        ringCache[key] = image
        return image
    }

    private struct RingKey: Hashable {
        let percent: Int
        let size: Int
        let stroke: Int
    }

    /// Bounded so a Studio session that scrubs a percentage cannot grow this
    /// without limit; the previews only ever need a handful at a time.
    private static let cacheLimit = 96
    private static var imageCache: [String: NSImage] = [:] {
        didSet { if imageCache.count > cacheLimit { imageCache.removeAll() } }
    }

    private static var ringCache: [RingKey: NSImage] = [:] {
        didSet { if ringCache.count > cacheLimit { ringCache.removeAll() } }
    }
}
