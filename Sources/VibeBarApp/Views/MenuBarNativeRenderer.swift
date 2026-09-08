import AppKit
import SwiftUI
import VibeBarCore

/// One measured drawing for the status item and every composed-strip preview.
/// Studio magnifies this drawing; it never retypesets tokens in SwiftUI stacks.
@MainActor
enum MenuBarNativeRenderer {
    static func composition(for item: MenuBarItemSettings, registry: QuotaFieldRegistry, quota: (ToolType) -> AccountQuota?) -> MenuBarComposition {
        if let composition = item.composition, composition.isEnabled { return composition }
        var item = item
        // Match the field strip's visibility contract before seeding: no
        // orphan logos/separators when a selected bucket is unavailable.
        item.selectedFieldIds = item.selectedFieldIds.filter { id in
            guard let field = MenuBarFieldCatalog.field(id: id, registry: registry) else { return false }
            return quota(field.tool)?.bucket(id: field.bucketId)?.hasPercentage == true
        }
        let template: MenuBarComposition.Template = item.layout == .compact ? .compact : item.layout == .twoRows ? .twoColumn : .roomy
        var composition = MenuBarComposition.seeded(template: template, from: item, registry: registry,
                                                    groupCatalogLabel: MiniWindowGroupLabelCatalog.defaultLabel(for:))
        for segment in composition.segments.indices {
            for row in MenuBarSegment.Row.allCases {
                for index in composition.segments[segment][row].indices {
                    if case let .quota(fieldId, .displayCount) = composition.segments[segment][row][index].kind {
                        composition.segments[segment][row][index].kind = .quota(fieldId: fieldId, metric: .displayPercent)
                    }
                }
            }
        }
        return composition
    }
    struct Drawing {
        let image: NSImage
        let size: CGSize
        /// Native point coordinates, top-left origin, before magnification.
        let tokens: [UUID: CGRect]
        let columns: [CGRect]
    }

    private struct Item {
        let id: UUID?
        var text: NSAttributedString?
        var image: NSImage?
        var size: CGSize { image?.size ?? text?.size() ?? .zero }
    }
    private struct Row {
        var items: [Item]
        var width: CGFloat { items.reduce(0) { $0 + $1.size.width } }
        var height: CGFloat { items.map { $0.size.height }.max() ?? 0 }
    }
    private struct Column {
        var top: Row
        var bottom: Row?
        var width: CGFloat { ceil(max(top.width, bottom?.width ?? 0)) }
    }

    static func render(
        plan: MenuBarRenderPlan,
        quotas: [MenuBarQuotaSnapshot],
        template: MenuBarComposition.Template,
        displayMode: DisplayMode,
        appearance: NSAppearance,
        magnification: CGFloat = 1
    ) -> Drawing {
        let zoom = max(0.1, magnification)
        let base = MenuBarStripMetrics.baseFontSize(template: template, rowCount: plan.isTwoRow ? 2 : 1)
        func makeRow(_ row: MenuBarRenderRow, base: CGFloat) -> Row {
            var items: [Item] = []
            for token in row.tokens {
                if !items.isEmpty, plan.tokenSpacing > 0 {
                    items.append(Item(id: nil, text: NSAttributedString(string: " ", attributes: [
                        .font: NSFont.systemFont(ofSize: max(1, base * plan.tokenSpacing))
                    ])))
                }
                let size = max(4, base * token.fontScale)
                let weight: NSFont.Weight = token.weight == .semibold ? .semibold : token.weight == .medium ? .medium : .regular
                let font = token.monospacedDigits
                    ? NSFont.monospacedDigitSystemFont(ofSize: size, weight: weight)
                    : NSFont.systemFont(ofSize: size, weight: weight)
                let color = MenuBarStripPalette.nsColor(MenuBarStripPalette.paint(
                    for: token.color, quotas: quotas, displayMode: displayMode
                ))
                if let glyph = token.glyph {
                    let side = plan.isTwoRow
                        ? MenuBarStripMetrics.twoRowGlyphSide(fontSize: size)
                        : MenuBarStripMetrics.singleRowGlyphSide(fontSize: size)
                    let image = glyphImage(glyph, side: side, tint: color, appearance: appearance)
                    items.append(Item(id: token.id, image: image))
                } else if let text = token.text {
                    items.append(Item(id: token.id, text: NSAttributedString(string: text, attributes: [
                        .font: font, .foregroundColor: color
                    ])))
                }
            }
            return Row(items: items)
        }
        func makeColumns(_ base: CGFloat) -> [Column] {
            plan.columns.map { Column(top: makeRow($0.top, base: base), bottom: $0.bottom.map { makeRow($0, base: base) }) }
        }
        var columns = makeColumns(base)
        var resolvedBase = base
        if plan.isTwoRow {
            let top = columns.map { $0.top.height }.max() ?? 0
            let bottom = columns.compactMap { $0.bottom?.height }.max() ?? 0
            let fit = MenuBarStripFit.scale(contentHeight: top + bottom + MenuBarStripMetrics.twoRowLineSpacing,
                                           availableHeight: MenuBarStripMetrics.twoRowAvailableHeight())
            if fit < 1 { resolvedBase = base * fit; columns = makeColumns(resolvedBase) }
        }
        if columns.isEmpty {
            columns = [Column(top: Row(items: [Item(id: nil, text: NSAttributedString(string: "—", attributes: [
                .font: NSFont.monospacedDigitSystemFont(ofSize: base, weight: .regular),
                .foregroundColor: NSColor.tertiaryLabelColor
            ]))]))]
        }
        let separator = NSAttributedString(string: plan.columnSeparator ?? "", attributes: [
            .font: NSFont.systemFont(ofSize: resolvedBase), .foregroundColor: NSColor.tertiaryLabelColor
        ])
        let wordGap = plan.tokenSpacing > 0
            ? NSAttributedString(string: " ", attributes: [.font: NSFont.systemFont(ofSize: max(1, resolvedBase * plan.tokenSpacing))]).size().width
            : 0
        let columnGap = plan.isTwoRow ? MenuBarStripMetrics.twoRowColumnSpacing
            : (plan.columnSeparator == nil ? wordGap : wordGap * 2 + separator.size().width)
        let topHeight = ceil(columns.map { $0.top.height }.max() ?? 0)
        let bottomHeight = ceil(columns.compactMap { $0.bottom?.height }.max() ?? 0)
        let contentHeight = plan.isTwoRow ? topHeight + bottomHeight + MenuBarStripMetrics.twoRowLineSpacing : topHeight
        let height = min(max(18, ceil(contentHeight + MenuBarStripMetrics.twoRowVerticalPadding * 2)),
                         max(18, NSStatusBar.system.thickness - 2))
        let width = max(24, ceil(columns.reduce(0) { $0 + $1.width } + CGFloat(max(0, columns.count - 1)) * columnGap + 4))
        let size = CGSize(width: width, height: height)
        let image = NSImage(size: CGSize(width: width * zoom, height: height * zoom))
        image.isTemplate = false
        var frames: [UUID: CGRect] = [:]
        var columnFrames: [CGRect] = []
        appearance.performAsCurrentDrawingAppearance {
            image.lockFocus()
            NSGraphicsContext.current?.cgContext.scaleBy(x: zoom, y: zoom)
            NSColor.clear.setFill()
            NSRect(origin: .zero, size: size).fill()
            func draw(_ row: Row, x start: CGFloat, y: CGFloat, band: CGFloat, columnWidth: CGFloat) {
                var x = start + floor((columnWidth - row.width) / 2)
                for item in row.items {
                    let itemSize = item.size
                    let bottom = max(0, y + floor((band - itemSize.height) / 2))
                    let rect = CGRect(x: x, y: bottom, width: itemSize.width, height: itemSize.height)
                    if let icon = item.image { icon.draw(in: rect) }
                    else { item.text?.draw(at: rect.origin) }
                    if let id = item.id {
                        frames[id] = CGRect(x: x, y: height - bottom - itemSize.height,
                                            width: itemSize.width, height: itemSize.height)
                    }
                    x += itemSize.width
                }
            }
            var x: CGFloat = 2
            for (index, column) in columns.enumerated() {
                columnFrames.append(CGRect(x: x, y: 0, width: column.width, height: height))
                if let bottom = column.bottom {
                    let blockBottom = max(0, floor((height - contentHeight) / 2))
                    draw(bottom, x: x, y: blockBottom, band: bottomHeight, columnWidth: column.width)
                    draw(column.top, x: x, y: blockBottom + bottomHeight + MenuBarStripMetrics.twoRowLineSpacing,
                         band: topHeight, columnWidth: column.width)
                } else {
                    draw(column.top, x: x, y: floor((height - column.top.height) / 2),
                         band: column.top.height, columnWidth: column.width)
                }
                x += column.width
                if index < columns.count - 1, !plan.isTwoRow, plan.columnSeparator != nil {
                    separator.draw(at: CGPoint(x: x + wordGap, y: floor((height - separator.size().height) / 2)))
                }
                x += columnGap
            }
            image.unlockFocus()
        }
        return Drawing(image: image, size: size, tokens: frames, columns: columnFrames)
    }

    private static func glyphImage(_ glyph: MenuBarRenderedToken.Glyph, side: CGFloat, tint: NSColor, appearance: NSAppearance) -> NSImage? {
        let size = NSSize(width: side, height: side)
        switch glyph {
        case let .provider(tool): return ProviderBrandIcon.image(for: tool, size: size, tint: tint, appearance: appearance)
        case let .brand(logo):
            if let mark = logo.brandMark { return ProviderBrandIcon.image(for: mark, size: size, tint: tint, appearance: appearance) }
            return ProviderBrandIcon.image(for: logo.tool, size: size, tint: tint, appearance: appearance)
        case .app: return ProviderBrandIcon.image(for: MenuBarItemKind.compact, size: size, tint: tint, appearance: appearance)
        }
    }
}
