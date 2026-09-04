import AppKit
import SwiftUI
import VibeBarCore

@MainActor
enum ProviderBrandIcon {
    /// Finished glyphs, keyed by everything that can change one.
    ///
    /// Every brand mark used to be re-read from disk (or re-parsed from the
    /// inline SVG), resized, and composited through an off-screen
    /// `lockFocus` pass on *every* SwiftUI body evaluation. A Workbench
    /// Requests page draws one badge per row, so scrolling a 30-day ledger
    /// meant a hundred `NSImage(contentsOf:)` calls per frame. The assets are
    /// static, so the result of that pipeline is a pure function of the key
    /// below and can be memoized for the life of the process.
    private static var renderCache: [RenderKey: NSImage] = [:]
    /// Decoded, resized source marks. Never handed to a caller — the tinted
    /// path only uses them as a draw source, and the untinted path vends a
    /// copy so a caller's `isTemplate` never leaks back into the cache.
    private static var sourceCache: [SourceKey: NSImage] = [:]
    /// Sizes come from layout, so a pathological caller could feed fractional
    /// values forever. Dropping the whole cache past this many entries keeps
    /// the memoization bounded without pretending to be an LRU.
    private static let cacheLimit = 512

    private struct SourceKey: Hashable {
        let name: String
        let width: CGFloat
        let height: CGFloat
    }

    private struct RenderKey: Hashable {
        /// `nil` is the Vibe Bar glyph drawn for a `MenuBarItemKind`, which
        /// ignores the kind itself.
        let name: String?
        let width: CGFloat
        let height: CGFloat
        let tint: NSColor?
        let appearance: String?
        let includeStatusDot: Bool
    }

    /// Everything the pipeline needs to draw one mark: which art, and how far
    /// past the canvas to draw it. `ToolType` and `BrandMark` both resolve to
    /// one of these, so a brand no tool can name still shares the cache, the
    /// tint compositing and the overshoot rule.
    struct MarkSource {
        let resourceName: String
        let drawScale: CGFloat
        /// Two brands ship as string literals rather than files on disk.
        var inlineSVG: String?
    }

    static func image(
        for kind: MenuBarItemKind,
        size: NSSize = NSSize(width: 16, height: 16),
        tint: NSColor? = nil,
        appearance: NSAppearance? = nil
    ) -> NSImage? {
        let key = RenderKey(
            name: nil,
            width: size.width,
            height: size.height,
            tint: tint,
            appearance: appearance?.name.rawValue,
            includeStatusDot: false
        )
        if let cached = renderCache[key] { return cached }
        let image = vibeBarGlyphImage(
            size: size, tint: tint, appearance: appearance, includeStatusDot: false
        )
        if let image { store(image, for: key) }
        return image
    }

    static func image(
        for tool: ToolType,
        size: NSSize = NSSize(width: 16, height: 16),
        tint: NSColor? = nil,
        appearance: NSAppearance? = nil
    ) -> NSImage? {
        image(for: tool.markSource, size: size, tint: tint, appearance: appearance)
    }

    static func image(
        for mark: BrandMark,
        size: NSSize = NSSize(width: 16, height: 16),
        tint: NSColor? = nil,
        appearance: NSAppearance? = nil
    ) -> NSImage? {
        image(for: mark.markSource, size: size, tint: tint, appearance: appearance)
    }

    private static func image(
        for mark: MarkSource,
        size: NSSize,
        tint: NSColor?,
        appearance: NSAppearance?
    ) -> NSImage? {
        let key = RenderKey(
            name: mark.resourceName,
            width: size.width,
            height: size.height,
            tint: tint,
            appearance: appearance?.name.rawValue,
            includeStatusDot: false
        )
        if let cached = renderCache[key] { return cached }
        guard let source = sourceImage(for: mark, size: size) else { return nil }
        guard let tint else {
            // The cached source stays untouched: `isTemplate` is a property of
            // the image object, and the tinted path draws from the same one.
            let template = (source.copy() as? NSImage) ?? source
            template.isTemplate = true
            store(template, for: key)
            return template
        }
        let image = drawWithAppearance(appearance) {
            let image = NSImage(size: size)
            image.lockFocus()
            let rect = NSRect(origin: .zero, size: size)
            let sourceRect = sourceDrawRect(scale: mark.drawScale, in: rect)
            NSColor.clear.setFill()
            rect.fill()
            tint.setFill()
            rect.fill()
            source.draw(in: sourceRect, from: .zero, operation: .destinationIn, fraction: 1)
            image.unlockFocus()
            image.isTemplate = false
            return image
        }
        store(image, for: key)
        return image
    }

    private static func store(_ image: NSImage, for key: RenderKey) {
        if renderCache.count >= cacheLimit { renderCache.removeAll(keepingCapacity: true) }
        renderCache[key] = image
    }

    /// Brand accents made legible as glyph tints, one stable instance per tool.
    ///
    /// Two problems solved in one place.
    ///
    /// **Cache identity.** `Theme.providerAccent` builds a fresh `Color` on
    /// every call, and `.grok`'s is *dynamic*, so its identity changes each
    /// time. Handed straight to `RenderKey` it would miss `renderCache` on
    /// every body evaluation and undo the memoization above. One instance per
    /// tool keeps the key stable; the dynamic colour still resolves per
    /// appearance at draw time, and the key already carries the appearance.
    ///
    /// **Contrast.** That palette was authored for fills and chart strokes,
    /// which sit on tinted chips. As a glyph tint several of them fall under
    /// the 3:1 that a meaningful non-text graphic needs — Codex's teal is
    /// 2.06:1 on white and 2.54:1 on a selected row — and these lists are
    /// exactly where the glyph is doing work. The hue is the brand's; only
    /// its brightness moves, and only as far as the threshold, measured
    /// against the row the mark is actually drawn on.
    private static var accentCache: [ToolType: NSColor] = [:]

    static func brandAccent(for tool: ToolType) -> NSColor {
        if let cached = accentCache[tool] { return cached }
        let base = NSColor(Theme.providerAccent(for: tool))
        let light = legible(base, in: NSAppearance(named: .aqua))
        let dark = legible(base, in: NSAppearance(named: .darkAqua))
        let color = NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
        }
        accentCache[tool] = color
        return color
    }

    /// The contrast a non-text graphic needs to stay identifiable.
    private static let minimumGlyphContrast = 3.0

    /// How strongly a selected session row tints itself with its own accent.
    /// `SessionListView.rowFill` — 0.16 at rest, 0.20 under the pointer.
    private static let selectedRowAccentOpacity = 0.20

    /// The ground one of these glyphs actually sits on, worst case.
    ///
    /// Not the window background: the Workbench paints
    /// `WorkbenchPorcelain.windowFill`, and a *selected* row lays its own
    /// provider accent over that — pulling the ground toward the very hue
    /// being drawn on it, which is the least contrast the mark ever has.
    /// Measuring against plain white instead overstated it by half a step:
    /// Codex read 3.03:1 on paper and 2.54:1 on a selected row.
    ///
    /// The fill's own alpha is ignored. It sits on a window background of
    /// nearly its own tone, so compositing it would move the answer less than
    /// the rounding already does.
    private static func rowSurfaceLuminance(accent: [Double], isDark: Bool) -> Double {
        guard let fill = NSColor(WorkbenchPorcelain.windowFill(for: isDark ? .dark : .light))
            .usingColorSpace(.sRGB)
        else { return isDark ? 0.0143 : 1 }
        let ground = [
            Double(fill.redComponent), Double(fill.greenComponent), Double(fill.blueComponent)
        ]
        return luminance(zip(ground, accent).map {
            $0 * (1 - selectedRowAccentOpacity) + $1 * selectedRowAccentOpacity
        })
    }

    /// `base` resolved in `appearance` and then blended toward that
    /// appearance's opposite extreme until it clears `minimumGlyphContrast`
    /// against the row it will be drawn on, or left alone if it already does.
    private static func legible(_ base: NSColor, in appearance: NSAppearance?) -> NSColor {
        guard let appearance else { return base }
        var resolved = base
        appearance.performAsCurrentDrawingAppearance {
            resolved = base.usingColorSpace(.sRGB) ?? base
        }
        guard let srgb = resolved.usingColorSpace(.sRGB) else { return resolved }
        let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        // Toward white on a dark ground, toward black on a light one.
        let toward: Double = isDark ? 1 : 0
        var components = [
            Double(srgb.redComponent), Double(srgb.greenComponent), Double(srgb.blueComponent)
        ]
        let surface = rowSurfaceLuminance(accent: components, isDark: isDark)
        // 50 steps of 2% is enough to reach either extreme, and stops at the
        // first mix that clears the bar rather than washing the hue out.
        for step in 0...50 {
            let mix = Double(step) * 0.02
            let mixed = components.map { $0 * (1 - mix) + toward * mix }
            if contrast(luminance(mixed), surface) >= minimumGlyphContrast || step == 50 {
                components = mixed
                break
            }
        }
        return NSColor(
            srgbRed: CGFloat(components[0]),
            green: CGFloat(components[1]),
            blue: CGFloat(components[2]),
            alpha: srgb.alphaComponent
        )
    }

    private static func luminance(_ rgb: [Double]) -> Double {
        let linear = rgb.map { channel -> Double in
            channel <= 0.03928 ? channel / 12.92 : pow((channel + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear[0] + 0.7152 * linear[1] + 0.0722 * linear[2]
    }

    private static func contrast(_ a: Double, _ b: Double) -> Double {
        (max(a, b) + 0.05) / (min(a, b) + 0.05)
    }

    static func fallbackSystemImage(for kind: MenuBarItemKind) -> String {
        "chart.bar"
    }

    static func fallbackSystemImage(for tool: ToolType) -> String {
        switch tool {
        case .codex:  return "sparkle.magnifyingglass"
        case .claude: return "sparkles"
        case .alibaba, .alibabaTokenPlan, .gemini, .antigravity, .grok, .copilot, .zai, .minimax, .kimi, .cursor, .mimo, .iflytek, .tencentHunyuan, .tencentTokenPlan, .volcengine, .volcengineAgentPlan, .baiduQianfan, .openCodeGo, .kilo, .kiro, .ollama, .openRouter, .warp:
            return tool.miscFallbackSymbol
        }
    }

    private static func vibeBarGlyphImage(
        size: NSSize,
        tint: NSColor?,
        appearance: NSAppearance?,
        includeStatusDot: Bool
    ) -> NSImage? {
        drawWithAppearance(appearance) {
            let canvas = NSImage(size: size)
            canvas.lockFocus()
            let rect = NSRect(origin: .zero, size: size)
            NSColor.clear.setFill()
            rect.fill()

            let resolvedTint = tint ?? NSColor.labelColor
            resolvedTint.setFill()
            resolvedTint.withAlphaComponent(0.86).setStroke()

            let side = max(1, min(size.width, size.height))
            let scale = side / 20
            let origin = NSPoint(
                x: floor((size.width - 20 * scale) / 2),
                y: floor((size.height - 20 * scale) / 2)
            )
            func scaledRect(x: CGFloat, y: CGFloat, width: CGFloat, height: CGFloat) -> NSRect {
                NSRect(
                    x: origin.x + x * scale,
                    y: origin.y + y * scale,
                    width: width * scale,
                    height: height * scale
                )
            }

            let topBar = NSBezierPath(
                roundedRect: scaledRect(x: 2.4, y: 13.2, width: 15.2, height: 4.0),
                xRadius: 2.0 * scale,
                yRadius: 2.0 * scale
            )
            topBar.lineWidth = max(0.85, 1.05 * scale)
            topBar.stroke()

            let dotXs: [CGFloat] = [4.5, 6.7, 8.9]
            for dotX in dotXs {
                NSBezierPath(
                    ovalIn: scaledRect(x: dotX, y: 14.55, width: 1.0, height: 1.0)
                ).fill()
            }

            NSBezierPath(
                roundedRect: scaledRect(x: 13.8, y: 14.35, width: 2.7, height: 1.4),
                xRadius: 0.7 * scale,
                yRadius: 0.7 * scale
            ).fill()

            let bars: [(x: CGFloat, height: CGFloat)] = [
                (2.8, 8.5),
                (6.9, 5.6),
                (11.0, 7.1),
                (15.1, 9.2)
            ]
            for bar in bars {
                NSBezierPath(
                    roundedRect: scaledRect(x: bar.x, y: 2.2, width: 2.4, height: bar.height),
                    xRadius: 1.2 * scale,
                    yRadius: 1.2 * scale
                ).fill()
            }

            if includeStatusDot {
                let dotSize = max(4, size.width * 0.28)
                let dotRect = NSRect(
                    x: size.width - dotSize,
                    y: 0,
                    width: dotSize,
                    height: dotSize
                )
                NSColor.systemGreen.setFill()
                NSBezierPath(ovalIn: dotRect).fill()
            }

            canvas.unlockFocus()
            canvas.isTemplate = tint == nil && !includeStatusDot
            return canvas
        }
    }

    private static func sourceImage(for mark: MarkSource, size: NSSize) -> NSImage? {
        let key = SourceKey(name: mark.resourceName, width: size.width, height: size.height)
        if let cached = sourceCache[key] { return cached }
        guard let image = decodeSourceImage(for: mark, size: size) else { return nil }
        if sourceCache.count >= cacheLimit { sourceCache.removeAll(keepingCapacity: true) }
        sourceCache[key] = image
        return image
    }

    private static func decodeSourceImage(for mark: MarkSource, size: NSSize) -> NSImage? {
        if let url = providerIconURL(named: mark.resourceName),
           let image = NSImage(contentsOf: url) {
            image.size = size
            return image
        }

        guard let svg = mark.inlineSVG, let image = NSImage(data: Data(svg.utf8)) else { return nil }
        image.size = size
        return image
    }

    /// Resolving a bundle resource hits the filesystem, so the answer is
    /// memoized alongside the decoded marks: `Bundle.main.url(forResource:)`
    /// used to run once per row per render.
    private static var iconURLCache: [String: URL?] = [:]

    private static func providerIconURL(named name: String) -> URL? {
        if let cached = iconURLCache[name] { return cached }
        let resolved = resolveProviderIconURL(named: name)
        iconURLCache[name] = resolved
        return resolved
    }

    private static func resolveProviderIconURL(named name: String) -> URL? {
        if let url = Bundle.main.url(
            forResource: name,
            withExtension: "svg",
            subdirectory: "ProviderIcons"
        ) {
            return url
        }

        let localURL = repoRootURL()
            .appendingPathComponent("Resources", isDirectory: true)
            .appendingPathComponent("ProviderIcons", isDirectory: true)
            .appendingPathComponent("\(name).svg")
        if FileManager.default.fileExists(atPath: localURL.path) {
            return localURL
        }
        return nil
    }

    private static func sourceDrawRect(scale: CGFloat, in rect: NSRect) -> NSRect {
        let width = rect.width * scale
        let height = rect.height * scale
        return NSRect(
            x: rect.midX - width / 2,
            y: rect.midY - height / 2,
            width: width,
            height: height
        )
    }

    private static func repoRootURL() -> URL {
        var url = URL(fileURLWithPath: #filePath)
        url.deleteLastPathComponent()
        url.deleteLastPathComponent()
        return url.deletingLastPathComponent()
    }

    private static func drawWithAppearance(_ appearance: NSAppearance?, _ body: () -> NSImage) -> NSImage {
        if let appearance {
            var image: NSImage?
            appearance.performAsCurrentDrawingAppearance {
                image = body()
            }
            return image ?? body()
        }
        return body()
    }

    static let openAISVG = """
    <svg width="100" height="100" viewBox="0 0 100 100" fill="none" xmlns="http://www.w3.org/2000/svg">
    <path d="M83.7733 42.8087C84.6678 40.1149 84.9771 37.2613 84.6807 34.4385C84.3843 31.6156 83.489 28.8885 82.0544 26.4394C77.6908 18.8436 68.9203 14.9365 60.3548 16.7725C57.9831 14.1344 54.9591 12.1668 51.5864 11.0673C48.2137 9.96772 44.611 9.77498 41.1402 10.5084C37.6694 11.2418 34.4527 12.8755 31.8132 15.2455C29.1736 17.6155 27.204 20.6383 26.1024 24.0103C23.3212 24.5806 20.6938 25.738 18.3958 27.405C16.0977 29.0721 14.1819 31.2104 12.7765 33.6772C8.36538 41.2609 9.3669 50.8267 15.2527 57.3327C14.3549 60.0251 14.0424 62.8782 14.3361 65.7012C14.6298 68.5241 15.523 71.2518 16.9558 73.7017C21.325 81.3002 30.1011 85.207 38.6712 83.3686C40.5554 85.4904 42.8707 87.1858 45.4623 88.3416C48.0539 89.4975 50.8622 90.0871 53.6999 90.0713C62.4793 90.079 70.2575 84.4114 72.9393 76.0515C75.7201 75.4802 78.347 74.3225 80.6449 72.6555C82.9427 70.9886 84.8587 68.8507 86.2649 66.3846C90.6227 58.8145 89.6172 49.3005 83.7733 42.8087ZM53.6999 84.8356C50.1955 84.8411 46.801 83.6129 44.1116 81.3661L44.5848 81.098L60.5123 71.9043C60.9087 71.6718 61.2379 71.3402 61.4674 70.942C61.6969 70.5439 61.8189 70.0929 61.8215 69.6333V47.1769L68.5553 51.072C68.6225 51.1063 68.6694 51.1707 68.6814 51.2456V69.854C68.6641 78.1208 61.9667 84.8183 53.6999 84.8356ZM21.4977 71.0843C19.7402 68.0497 19.1092 64.4925 19.7156 61.0386L20.1885 61.3225L36.1321 70.5165C36.5266 70.748 36.9757 70.87 37.4331 70.87C37.8905 70.87 38.3396 70.748 38.7341 70.5165L58.21 59.2883V67.0628C58.2081 67.1031 58.1973 67.1424 58.1782 67.1779C58.1591 67.2134 58.1322 67.2441 58.0996 67.2678L41.9671 76.5722C34.798 80.7022 25.6388 78.2463 21.4977 71.0843ZM17.3026 36.3898C19.0723 33.3357 21.8655 31.0062 25.1878 29.8138V48.7376C25.1818 49.1949 25.2986 49.6453 25.5261 50.042C25.7535 50.4387 26.0833 50.7671 26.4809 50.9928L45.8622 62.1739L39.1283 66.069C39.0919 66.0883 39.0513 66.0984 39.0101 66.0984C38.9689 66.0984 38.9283 66.0883 38.8919 66.069L22.7908 56.7809C15.6359 52.6337 13.1822 43.4816 17.3026 36.3112V36.3898ZM72.624 49.2426L53.1792 37.9512L59.8976 34.0718C59.9341 34.0524 59.9747 34.0423 60.016 34.0423C60.0573 34.0423 60.0979 34.0524 60.1344 34.0718L76.2355 43.3761C78.6973 44.7966 80.7043 46.8882 82.0221 49.4065C83.3398 51.9249 83.914 54.7661 83.6775 57.5985C83.4411 60.431 82.4038 63.1377 80.6867 65.4027C78.9696 67.6677 76.6436 69.3975 73.9803 70.3901V51.466C73.9663 51.0096 73.834 50.5647 73.5962 50.1749C73.3584 49.7851 73.0234 49.4638 72.624 49.2426ZM79.3261 39.1657L78.8529 38.8815L62.9411 29.6089C62.5442 29.376 62.0924 29.2532 61.6322 29.2532C61.172 29.2532 60.7202 29.376 60.3233 29.6089L40.8629 40.8374V33.0628C40.8587 33.0233 40.8654 32.9834 40.882 32.9473C40.8987 32.9113 40.9248 32.8803 40.9575 32.8579L57.0586 23.5692C59.5263 22.1476 62.3478 21.458 65.193 21.5811C68.0382 21.7042 70.7896 22.6348 73.1253 24.2642C75.461 25.8936 77.2845 28.1543 78.3825 30.782C79.4806 33.4097 79.8077 36.2957 79.3257 39.1025V39.1657H79.3261ZM37.1888 52.9484L30.455 49.069C30.4213 49.0487 30.3925 49.0212 30.3707 48.9884C30.3488 48.9557 30.3345 48.9186 30.3286 48.8797V30.3188C30.3323 27.4714 31.1466 24.6839 32.6761 22.2822C34.2057 19.8805 36.3874 17.9639 38.9661 16.7564C41.5448 15.549 44.4139 15.1005 47.2381 15.4636C50.0622 15.8267 52.7247 16.9862 54.9141 18.8067L54.4409 19.0748L38.5134 28.2686C38.117 28.5011 37.7879 28.8327 37.5584 29.2308C37.329 29.629 37.207 30.0799 37.2045 30.5395L37.1888 52.9487V52.9484ZM40.8472 45.0632L49.5209 40.0643L58.21 45.0635V55.0615L49.5523 60.0608L40.8632 55.0615L40.8472 45.0632Z" fill="white"/>
    </svg>
    """

    static let claudeSVG = """
    <svg width="100" height="100" viewBox="0 0 100 100" fill="none" xmlns="http://www.w3.org/2000/svg">
    <path d="M25.7146 63.2153L41.4393 54.3917L41.7025 53.6226L41.4393 53.1976H40.6705L38.0394 53.0359L29.054 52.7929L21.2624 52.4691L13.7134 52.0644L11.8111 51.6594L10.0303 49.3118L10.2123 48.138L11.8111 47.0657L14.0981 47.2681L19.1574 47.6119L26.7467 48.138L32.2516 48.4618L40.4073 49.3118H41.7025L41.8846 48.7857L41.4393 48.4618L41.0955 48.138L33.243 42.8155L24.7432 37.1894L20.2909 33.9513L17.8824 32.3119L16.6684 30.774L16.1422 27.4147L18.328 25.0062L21.2624 25.2088L22.0112 25.4112L24.9861 27.6979L31.3407 32.616L39.6381 38.7273L40.8525 39.7391L41.3381 39.395L41.399 39.1523L40.8525 38.2415L36.3394 30.0858L31.5227 21.7883L29.3775 18.3478L28.811 16.2837C28.6087 15.4334 28.4669 14.7252 28.4669 13.8549L30.9563 10.4753L32.3321 10.0303L35.6515 10.4756L37.0479 11.6897L39.112 16.4052L42.4513 23.8327L47.6321 33.9313L49.15 36.9265L49.9594 39.6991L50.2632 40.5491H50.7894V40.0632L51.2141 34.3766L52.0035 27.3944L52.7726 18.4087L53.0358 15.8793L54.2905 12.8435L56.7795 11.2041L58.7224 12.135L60.3212 14.422L60.0986 15.899L59.1474 22.0718L57.2857 31.7458L56.0713 38.2218H56.7795L57.5892 37.4121L60.8677 33.061L66.3723 26.18L68.801 23.448L71.6342 20.4325L73.4556 18.9957H76.8962L79.4255 22.7601L78.2926 26.6456L74.7509 31.1384L71.8163 34.943L67.607 40.6097L64.9758 45.1431L65.2188 45.5072L65.8464 45.4466L75.358 43.4228L80.4984 42.4917L86.6304 41.4393L89.4033 42.7346L89.7065 44.0502L88.6135 46.7419L82.0566 48.3607L74.3662 49.8989L62.9118 52.6109L62.77 52.7121L62.9321 52.9144L68.0925 53.4L70.2987 53.5214H75.7021L85.7601 54.2702L88.3912 56.0108L89.9697 58.1358L89.7065 59.7545L85.6589 61.8189L80.1949 60.5236L67.4452 57.4881L63.0735 56.3952H62.4665V56.7596L66.1093 60.3213L72.7877 66.3523L81.1461 74.1236L81.5707 76.0462L80.4984 77.5638L79.3649 77.4021L72.0186 71.8772L69.1854 69.3879L62.77 63.9844H62.3453V64.5509L63.8223 66.7164L71.6342 78.4544L72.0389 82.0567L71.4725 83.2308L69.4487 83.939L67.2222 83.534L62.6485 77.1189L57.9333 69.8937L54.1284 63.4177L53.6631 63.6809L51.4167 87.8651L50.3644 89.0995L47.9356 90.0303L45.9121 88.4924L44.8392 86.0031L45.9118 81.0852L47.2071 74.6701L48.2594 69.5699L49.2106 63.2356L49.7773 61.131L49.7367 60.9892L49.2715 61.0498L44.4954 67.607L37.23 77.4224L31.4825 83.5746L30.1063 84.1211L27.7181 82.8864L27.9408 80.6805L29.2763 78.7177L37.2297 68.5988L42.026 62.3248L45.1227 58.7025L45.1024 58.176H44.9204L23.7917 71.8975L20.0274 72.3831L18.4083 70.8655L18.6106 68.3761L19.3798 67.5664L25.7343 63.195L25.7146 63.2153Z" fill="white"/>
    </svg>
    """
}

struct ProviderBrandIconView: View {
    @Environment(\.colorScheme) private var colorScheme
    let kind: MenuBarItemKind
    var size: CGFloat = 16

    var body: some View {
        Group {
            if let image = ProviderBrandIcon.image(
                for: kind,
                size: NSSize(width: size, height: size),
                tint: NSColor.labelColor,
                appearance: nsAppearance(for: colorScheme)
            ) {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
            } else {
                Image(systemName: ProviderBrandIcon.fallbackSystemImage(for: kind))
                    .resizable()
                    .scaledToFit()
            }
        }
        .frame(width: size, height: size)
        .foregroundStyle(.primary)
        .accessibilityHidden(true)
    }

    private func nsAppearance(for colorScheme: ColorScheme) -> NSAppearance? {
        switch colorScheme {
        case .dark:  return NSAppearance(named: .darkAqua)
        case .light: return NSAppearance(named: .aqua)
        @unknown default: return nil
        }
    }
}

struct ProviderBrandBadge: View {
    let kind: MenuBarItemKind
    var iconSize: CGFloat = 17
    var containerSize: CGFloat = 24

    var body: some View {
        // Companion to `ToolBrandBadge` — same naked-glyph treatment
        // so the menu-bar / overview kind icons match the per-tool
        // brand marks instead of wearing the old rounded-rectangle
        // wrapper.
        ProviderBrandIconView(kind: kind, size: effectiveIconSize)
            .frame(width: containerSize, height: containerSize, alignment: .center)
            .accessibilityHidden(true)
    }

    private var effectiveIconSize: CGFloat {
        min(containerSize, max(iconSize, containerSize * 0.85))
    }
}

struct ToolBrandIconView: View {
    @Environment(\.colorScheme) private var colorScheme
    let tool: ToolType
    var size: CGFloat = 16
    /// Paint the mark in the brand's own colour rather than the label colour.
    ///
    /// Off by default and meant to stay that way for most surfaces: a mark
    /// beside its own name does not need to shout, and a page full of brand
    /// colours reads as noise. A list whose whole job is telling harnesses
    /// apart at a glance is the exception — `Theme.providerAccent`.
    ///
    /// The tint is not the raw palette entry: `ProviderBrandIcon.brandAccent`
    /// lifts it to 3:1 against the row it lands on, selection tint included.
    /// Half the palette was authored for fills on tinted chips and does not
    /// clear that on its own — Codex's teal is 2.06:1 on white, and Ollama's
    /// near-black 1.22:1 on a dark list.
    var brandColored: Bool = false

    var body: some View {
        Group {
            if let image = ProviderBrandIcon.image(
                for: tool,
                size: NSSize(width: size, height: size),
                tint: brandColored
                    ? ProviderBrandIcon.brandAccent(for: tool)
                    : NSColor.labelColor,
                appearance: nsAppearance(for: colorScheme)
            ) {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
            } else {
                Image(systemName: ProviderBrandIcon.fallbackSystemImage(for: tool))
                    .resizable()
                    .scaledToFit()
            }
        }
        .frame(width: size, height: size)
        .foregroundStyle(brandColored ? Theme.providerAccent(for: tool) : .primary)
        .accessibilityHidden(true)
    }

    private func nsAppearance(for colorScheme: ColorScheme) -> NSAppearance? {
        switch colorScheme {
        case .dark:  return NSAppearance(named: .darkAqua)
        case .light: return NSAppearance(named: .aqua)
        @unknown default: return nil
        }
    }
}

struct ToolBrandBadge: View {
    let tool: ToolType
    var iconSize: CGFloat = 17
    var containerSize: CGFloat = 24
    var brandColored: Bool = false

    var body: some View {
        // Render the brand glyph naked — AQ flagged that the
        // background fill + stroke on the outer rounded rectangle
        // looked like the icon was "套了一层" (wrapped in an extra
        // layer), especially for ChatGPT and Claude whose brand
        // marks already have rounded silhouettes. The fixed
        // `containerSize` frame is kept so call sites that align
        // multiple badges horizontally don't shift after the
        // chrome comes off.
        ToolBrandIconView(tool: tool, size: effectiveIconSize, brandColored: brandColored)
            .frame(width: containerSize, height: containerSize, alignment: .center)
            .accessibilityHidden(true)
    }

    private var effectiveIconSize: CGFloat {
        min(containerSize, max(iconSize, containerSize * 0.85))
    }
}

/// A brand the `ToolType` axis cannot name.
///
/// That axis is L2 — the thing whose quota is being read. Two kinds of brand
/// sit off it. An **L1 company** above a pair of tools: SpaceXAI over Grok and
/// Cursor, Google AI over Gemini and AntiGravity. And an **L2 SubProvider that
/// shares another tool's account**: Grok Bot's quota arrives inside Cursor's,
/// so the tool axis says Cursor and only the bucket says otherwise.
///
/// Drawing those from a member is how the SpaceXAI tab wore Grok's slash, the
/// Google AI tab wore Gemini's spark, and Grok Bot wore Cursor's cursor.
enum BrandMark: String, CaseIterable, Hashable {
    case spaceXAI
    case googleAI
    case grokBot

    /// The L1 company mark for a core provider, where the company has one the
    /// representative tool does not already wear. OpenAI and Anthropic are
    /// absent on purpose: `ProviderIcon-codex` and `ProviderIcon-claude` *are*
    /// those companies' marks, so their tabs were never wrong.
    static func company(for tool: ToolType) -> BrandMark? {
        switch tool.coreProviderRepresentative {
        case .gemini: return .googleAI
        case .grok:   return .spaceXAI
        default:      return nil
        }
    }

    /// The mark an L2 SubProvider wears when it is not its tool's own, keyed
    /// by the bucket — the same seam `quotaSubProviderName(bucketID:)` names
    /// it by, so the icon and the label can never disagree.
    static func subProvider(tool: ToolType, bucketID: String?) -> BrandMark? {
        guard tool == .cursor, bucketID == "grok_bot_weekly" else { return nil }
        return .grokBot
    }

    var providerIconResourceName: String {
        switch self {
        case .spaceXAI: return "ProviderIcon-spacexai"
        case .googleAI: return "ProviderIcon-googleai"
        case .grokBot:  return "ProviderIcon-grokbot"
        }
    }

    /// The same overshoot every tool mark uses, for the same reason.
    ///
    /// These three arrived fitted edge-to-edge in their own viewBox, so this
    /// was 1 for a while — and at 1 the source's canvas boundary lands exactly
    /// on the visible edge and draws a faint frame around the glyph. The tool
    /// marks never show it because they are authored with a tenth of the
    /// canvas as margin on each side, which is precisely what 1.25 crops away.
    /// Their viewBoxes now carry that same margin, so they overshoot too.
    var providerIconDrawScale: CGFloat { 1.25 }

    var fallbackSystemImage: String {
        switch self {
        case .spaceXAI: return "x.circle"
        case .googleAI: return "g.circle"
        case .grokBot:  return "circle.dashed"
        }
    }

    /// Whose palette entry tints this mark when a surface asks for colour.
    ///
    /// The marks have no accents of their own — `Theme.providerAccent` is
    /// keyed by `ToolType` — so each borrows the one its company already
    /// owns. Grok Bot is xAI's app, so it takes xAI's.
    var accentTool: ToolType {
        switch self {
        case .spaceXAI, .grokBot: return .grok
        case .googleAI:           return .gemini
        }
    }

    var markSource: ProviderBrandIcon.MarkSource {
        ProviderBrandIcon.MarkSource(
            resourceName: providerIconResourceName,
            drawScale: providerIconDrawScale
        )
    }
}

/// A brand mark that is not a tool, drawn exactly as `ToolBrandIconView` draws
/// one that is.
struct BrandMarkIconView: View {
    @Environment(\.colorScheme) private var colorScheme
    let mark: BrandMark
    var size: CGFloat = 16
    /// Paint the mark in its company's colour — same terms, and the same
    /// 3:1 lift, as `ToolBrandIconView.brandColored`.
    var brandColored: Bool = false

    var body: some View {
        Group {
            if let image = ProviderBrandIcon.image(
                for: mark,
                size: NSSize(width: size, height: size),
                tint: brandColored
                    ? ProviderBrandIcon.brandAccent(for: mark.accentTool)
                    : NSColor.labelColor,
                appearance: nsAppearance(for: colorScheme)
            ) {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
            } else {
                Image(systemName: mark.fallbackSystemImage)
                    .resizable()
                    .scaledToFit()
            }
        }
        .frame(width: size, height: size)
        .foregroundStyle(brandColored ? Theme.providerAccent(for: mark.accentTool) : .primary)
        .accessibilityHidden(true)
    }

    private func nsAppearance(for colorScheme: ColorScheme) -> NSAppearance? {
        switch colorScheme {
        case .dark:  return NSAppearance(named: .darkAqua)
        case .light: return NSAppearance(named: .aqua)
        @unknown default: return nil
        }
    }
}

/// Brand icon for a surface that names an L1 company — a tab, a sidebar row, a
/// settings section heading. Falls back to the representative tool's mark
/// where the company has no separate one.
struct CompanyBrandIconView: View {
    let tool: ToolType
    var size: CGFloat = 16

    var body: some View {
        if let mark = BrandMark.company(for: tool) {
            BrandMarkIconView(mark: mark, size: size)
        } else {
            ToolBrandIconView(tool: tool, size: size)
        }
    }
}

/// `ToolBrandBadge` for a surface that names an L1 company.
struct CompanyBrandBadge: View {
    let tool: ToolType
    var iconSize: CGFloat = 17
    var containerSize: CGFloat = 24

    var body: some View {
        CompanyBrandIconView(tool: tool, size: min(containerSize, max(iconSize, containerSize * 0.85)))
            .frame(width: containerSize, height: containerSize, alignment: .center)
            .accessibilityHidden(true)
    }
}

extension MenuBarBrandLogo {
    /// The picture this build has for the block, if any. `nil` draws the
    /// tool's own mark, which is what the block would have been before the
    /// company or SubProvider got a mark of its own.
    var brandMark: BrandMark? {
        switch level {
        case .company: return BrandMark.company(for: tool)
        case .subProvider: return BrandMark.subProvider(tool: tool, bucketID: bucketId)
        }
    }

    /// Whose accent a "brand" colour uses for this block.
    var accentTool: ToolType { brandMark?.accentTool ?? tool }
}

/// Brand icon for a composed logo block that names a company or a
/// SubProvider — the tool's own mark when this build has no separate one.
struct BrandLogoIconView: View {
    let logo: MenuBarBrandLogo
    var size: CGFloat = 16

    var body: some View {
        if let mark = logo.brandMark {
            BrandMarkIconView(mark: mark, size: size)
        } else {
            ToolBrandIconView(tool: logo.tool, size: size)
        }
    }
}

/// Brand icon for a quota section: its tool's mark, unless the bucket names a
/// SubProvider with one of its own.
struct QuotaBrandIconView: View {
    let tool: ToolType
    let bucketID: String?
    var size: CGFloat = 16

    var body: some View {
        if let mark = BrandMark.subProvider(tool: tool, bucketID: bucketID) {
            BrandMarkIconView(mark: mark, size: size)
        } else {
            ToolBrandIconView(tool: tool, size: size)
        }
    }
}

/// The mark a **harness** wears — the CLI or app a session came from.
///
/// Almost every harness is drawn as its own tool: Cursor gets Cursor's mark
/// rather than xAI's, AntiGravity its own rather than Gemini's, while the
/// chip that *groups* them still says "SpaceXAI" / "Google AI". Grok Bot is
/// the one harness with no tool of its own — its quota rides in on Cursor's
/// `grok_bot_weekly` bucket — so it is resolved to its own `BrandMark`
/// instead of borrowing the account holder's mark or Grok Build's.
struct HarnessBrandIconView: View {
    let harness: Harness
    var size: CGFloat = 16
    var brandColored: Bool = false

    var body: some View {
        if let mark = harness.brandMark {
            BrandMarkIconView(mark: mark, size: size, brandColored: brandColored)
        } else {
            ToolBrandIconView(tool: harness.quotaTool, size: size, brandColored: brandColored)
        }
    }
}

/// `HarnessBrandIconView` in the badge frame the session lists align on.
struct HarnessBrandBadge: View {
    let harness: Harness
    var iconSize: CGFloat = 17
    var containerSize: CGFloat = 24
    var brandColored: Bool = false

    var body: some View {
        HarnessBrandIconView(harness: harness, size: iconSize, brandColored: brandColored)
            .frame(width: containerSize, height: containerSize, alignment: .center)
            .accessibilityHidden(true)
    }
}

extension Harness {
    /// The mark this harness wears when its quota tool is the wrong answer.
    /// `nil` — the usual case — means "draw `quotaTool`".
    var brandMark: BrandMark? {
        self == .grokBot ? .grokBot : nil
    }
}

extension ToolType {
    var providerIconResourceName: String {
        switch self {
        case .codex:       return "ProviderIcon-codex"
        case .claude:      return "ProviderIcon-claude"
        case .alibaba:     return "ProviderIcon-alibaba"
        case .alibabaTokenPlan: return "ProviderIcon-alibaba"
        case .gemini:      return "ProviderIcon-gemini"
        case .antigravity: return "ProviderIcon-antigravity"
        case .grok:        return "ProviderIcon-grok"
        case .copilot:     return "ProviderIcon-copilot"
        case .zai:         return "ProviderIcon-zai"
        case .minimax:     return "ProviderIcon-minimax"
        case .kimi:        return "ProviderIcon-kimi"
        case .cursor:      return "ProviderIcon-cursor"
        case .mimo:        return "ProviderIcon-mimo"
        case .iflytek:     return "ProviderIcon-iflytek"
        case .tencentHunyuan:   return "ProviderIcon-tencentHunyuan"
        case .tencentTokenPlan: return "ProviderIcon-tencentHunyuan"
        case .volcengine:  return "ProviderIcon-volcengine"
        case .volcengineAgentPlan: return "ProviderIcon-volcengine"
        case .baiduQianfan: return "ProviderIcon-baiduQianfan"
        case .openCodeGo:  return "ProviderIcon-opencodego"
        case .kilo:        return "ProviderIcon-kilo"
        case .kiro:        return "ProviderIcon-kiro"
        case .ollama:      return "ProviderIcon-ollama"
        case .openRouter:  return "ProviderIcon-openrouter"
        case .warp:        return "ProviderIcon-warp"
        }
    }

    var markSource: ProviderBrandIcon.MarkSource {
        ProviderBrandIcon.MarkSource(
            resourceName: providerIconResourceName,
            drawScale: providerIconDrawScale,
            inlineSVG: inlineProviderIconSVG
        )
    }

    /// Two brands never got a file: their paths live in `ProviderBrandIcon`.
    var inlineProviderIconSVG: String? {
        switch self {
        case .codex:  return ProviderBrandIcon.openAISVG
        case .claude: return ProviderBrandIcon.claudeSVG
        default:      return nil
        }
    }

    var providerIconDrawScale: CGFloat {
        switch self {
        // All dedicated and linked tools render at the same overshoot scale.
        // The previous 1.0 for codex/claude let the SVG paths reach
        // the canvas edge — the anti-aliased boundary that produced
        // read as a "细线" (thin line / halo) around the glyph, while
        // the 1.25 brands (gemini/grok) overshot the canvas and got
        // clipped to crisp edges. Same scale → same edge treatment →
        // no halo on either pair.
        case .codex, .claude, .gemini, .antigravity, .grok, .copilot, .cursor:
            return 1.25
        case .alibaba, .alibabaTokenPlan, .minimax, .kimi, .mimo, .iflytek, .tencentHunyuan, .tencentTokenPlan, .volcengine, .volcengineAgentPlan, .baiduQianfan, .openCodeGo, .kilo, .kiro, .ollama, .openRouter, .warp:
            return 1.36
        case .zai:
            return 1.5
        }
    }

    /// SF Symbol used as the misc-card icon when the provider doesn't
    /// have a brand SVG bundled. Picked for visual variety + a hint
    /// of the provider's identity. Easy to swap once we have brand
    /// assets on disk.
    var miscFallbackSymbol: String {
        switch self {
        case .codex, .claude:
            return "sparkles"
        case .alibaba:     return "cube.transparent"
        case .alibabaTokenPlan: return "creditcard"
        case .gemini:      return "sparkle"
        case .antigravity: return "arrow.up.forward.app"
        case .grok:        return "x.circle"
        case .copilot:     return "chevron.left.forward.slash.chevron.right"
        case .zai:         return "z.circle"
        case .minimax:     return "function"
        case .kimi:        return "moon.stars"
        case .cursor:      return "cursorarrow.rays"
        case .mimo:        return "m.square.fill"
        case .iflytek:     return "waveform"
        case .tencentHunyuan:   return "globe.asia.australia"
        case .tencentTokenPlan: return "creditcard.circle"
        case .volcengine:  return "flame.fill"
        case .volcengineAgentPlan: return "flame.circle.fill"
        case .baiduQianfan: return "pawprint.fill"
        case .openCodeGo:  return "terminal"
        case .kilo:        return "k.circle.fill"
        case .kiro:        return "command"
        case .ollama:      return "cloud"
        case .openRouter:  return "point.3.connected.trianglepath.dotted"
        case .warp:        return "terminal.fill"
        }
    }
}
