import Foundation

/// Integer rectangle in device pixels, origin top-left.
public struct EInkRect: Sendable, Equatable {
    public var x: Int
    public var y: Int
    public var width: Int
    public var height: Int

    public init(x: Int, y: Int, width: Int, height: Int) {
        self.x = x
        self.y = y
        self.width = max(0, width)
        self.height = max(0, height)
    }

    public var maxX: Int { x + width }
    public var maxY: Int { y + height }

    public func contains(_ other: EInkRect) -> Bool {
        other.x >= x && other.y >= y && other.maxX <= maxX && other.maxY <= maxY
    }

    public func inset(by insets: EInkInsets) -> EInkRect {
        EInkRect(
            x: x + insets.leading,
            y: y + insets.top,
            width: width - insets.leading - insets.trailing,
            height: height - insets.top - insets.bottom
        )
    }
}

public struct EInkInsets: Sendable, Equatable {
    public var top: Int
    public var leading: Int
    public var bottom: Int
    public var trailing: Int

    public init(top: Int = 0, leading: Int = 0, bottom: Int = 0, trailing: Int = 0) {
        self.top = top
        self.leading = leading
        self.bottom = bottom
        self.trailing = trailing
    }

    public init(all: Int) { self.init(top: all, leading: all, bottom: all, trailing: all) }

    public static let zero = EInkInsets()
    public var horizontal: Int { leading + trailing }
    public var vertical: Int { top + bottom }
}

/// How a box asks for space along one axis.
public enum EInkLength: Sendable, Equatable {
    /// As big as the content needs.
    case auto
    /// Exactly this many device pixels.
    case points(Int)
    /// Share of the leftover space, `flex-grow`-style.
    case flex(Int)
}

/// Main-axis distribution. `between` only applies when nothing flexes.
public enum EInkMainAlignment: Sendable, Equatable {
    case start, center, end, between
}

public enum EInkCrossAlignment: Sendable, Equatable {
    case start, center, end, stretch
}

public enum EInkInk: Sendable, Equatable {
    case none, white, black
}

/// One node of the layout tree.
///
/// A deliberately tiny flex subset — row / column, fixed sizes, one flex
/// factor, gap, padding, and start / center / end / between distribution.
/// It exists because the device JSON is sent with absolute positions: Satori
/// never gets to lay anything out, so what this engine computes is exactly
/// what the panel shows, and the same numbers drive the preview.
public struct EInkNode: Sendable, Equatable {
    public enum Kind: Sendable, Equatable {
        case row
        case column
        case text(String, font: EInkFont, alignment: EInkTextAlignment)
        /// A 1-bit PNG data URI; both dimensions must be `.points`.
        case image(String)
        /// Solid black rectangle — dividers and bar fills.
        case fill
        /// Bordered track, filled left-to-right to `percent`.
        case horizontalBar(percent: Int)
        /// Bordered track, filled bottom-up to `percent`.
        case verticalBar(percent: Int)
        /// Rasterized arc with the percentage printed in the middle.
        case ring(percent: Int, stroke: Int, labelFont: EInkFont)
    }

    public var kind: Kind
    public var width: EInkLength = .auto
    public var height: EInkLength = .auto
    public var padding: EInkInsets = .zero
    public var gap = 0
    public var justify: EInkMainAlignment = .start
    public var align: EInkCrossAlignment = .stretch
    public var children: [EInkNode] = []

    public init(
        _ kind: Kind,
        width: EInkLength = .auto,
        height: EInkLength = .auto,
        padding: EInkInsets = .zero,
        gap: Int = 0,
        justify: EInkMainAlignment = .start,
        align: EInkCrossAlignment = .stretch,
        children: [EInkNode] = []
    ) {
        self.kind = kind
        self.width = width
        self.height = height
        self.padding = padding
        self.gap = gap
        self.justify = justify
        self.align = align
        self.children = children
    }

    var isRow: Bool { if case .row = kind { return true }; return false }
    var isColumn: Bool { if case .column = kind { return true }; return false }
    var isContainer: Bool { isRow || isColumn }
}

/// A resolved, absolutely positioned box. The encoder turns each of these
/// into exactly one device element.
public struct EInkDrawBox: Sendable, Equatable {
    public enum Content: Sendable, Equatable {
        case text(String, font: EInkFont, alignment: EInkTextAlignment)
        case image(String)
        /// Solid black.
        case fill
        /// 1 px black outline over white.
        case outline
        case ring(percent: Int, stroke: Int)
    }

    public var frame: EInkRect
    public var content: Content
    /// Only a box whose width the author fixed clips its content.
    ///
    /// An `.auto` text box is measured, and a measurement can be a pixel or
    /// two short of what the device's font actually draws; clipping it would
    /// shave the last glyph off a footer that fits fine. Letting it spill is
    /// exactly what the verified demo did, and what `longestInMiddle` budgets
    /// for. A fixed-width column, by contrast, must clip — a long provider
    /// name running into the bar beside it is worse than a truncated one.
    public var clipsContent: Bool

    public init(frame: EInkRect, content: Content, clipsContent: Bool = false) {
        self.frame = frame
        self.content = content
        self.clipsContent = clipsContent
    }
}

/// Resolves an `EInkNode` tree to absolute integer boxes.
public enum EInkBoxLayout {
    /// `bounds` is the safe area every emitted box is kept inside — the frame
    /// minus the 6 px margin by default.
    ///
    /// Clamping happens at the leaves rather than during recursion because
    /// text is deliberately allowed to be wider than the column it sits in:
    /// "AntiGravity" is 62 px in the device's pixel font and no five-column
    /// landscape layout has that much per cell, so the ported presets order
    /// the columns (`longestInMiddle`) to spend a neighbour's slack instead of
    /// truncating the name. Clamping keeps that spill inside the panel.
    public static func resolve(
        _ root: EInkNode,
        in frame: EInkRect,
        bounds: EInkRect? = nil
    ) -> [EInkDrawBox] {
        var boxes: [EInkDrawBox] = []
        let safe = bounds ?? frame.inset(by: EInkInsets(all: Int(EInkCanvasLayout.safeMargin)))
        // A root that states its own size keeps it (clamped to the panel), so
        // a preset authored at 152 × 296 lays out at 152 × 296 even when the
        // caller hands it the landscape frame.
        var rootRect = frame
        if case let .points(width) = root.width { rootRect.width = min(frame.width, max(0, width)) }
        if case let .points(height) = root.height { rootRect.height = min(frame.height, max(0, height)) }
        place(root, in: rootRect, bounds: safe, into: &boxes)
        return boxes
    }

    static func clamp(_ rect: EInkRect, to bounds: EInkRect) -> EInkRect {
        var result = rect
        result.width = min(result.width, bounds.width)
        result.height = min(result.height, bounds.height)
        result.x = min(max(result.x, bounds.x), bounds.maxX - result.width)
        result.y = min(max(result.y, bounds.y), bounds.maxY - result.height)
        return result
    }

    // MARK: - Intrinsic sizing

    public static func intrinsicWidth(_ node: EInkNode) -> Int {
        if case let .points(value) = node.width { return max(0, value) }
        switch node.kind {
        case let .text(content, font, _):
            return EInkTextMetrics.width(content, font: font)
        case .image, .fill, .ring:
            return 0
        case .horizontalBar:
            return 0
        case .verticalBar:
            return 0
        case .row:
            let children = node.children.map(intrinsicWidth)
            return node.padding.horizontal + children.reduce(0, +) + node.gap * max(0, node.children.count - 1)
        case .column:
            let children = node.children.map(intrinsicWidth)
            return node.padding.horizontal + (children.max() ?? 0)
        }
    }

    public static func intrinsicHeight(_ node: EInkNode) -> Int {
        if case let .points(value) = node.height { return max(0, value) }
        switch node.kind {
        case let .text(_, font, _):
            return font.lineHeight
        case .image, .fill, .ring, .horizontalBar, .verticalBar:
            return 0
        case .row:
            let children = node.children.map(intrinsicHeight)
            return node.padding.vertical + (children.max() ?? 0)
        case .column:
            let children = node.children.map(intrinsicHeight)
            return node.padding.vertical + children.reduce(0, +) + node.gap * max(0, node.children.count - 1)
        }
    }

    // MARK: - Placement

    private static func place(
        _ node: EInkNode,
        in unclampedRect: EInkRect,
        bounds: EInkRect,
        into boxes: inout [EInkDrawBox]
    ) {
        let rect = node.isContainer ? unclampedRect : clamp(unclampedRect, to: bounds)
        switch node.kind {
        case let .text(content, font, alignment):
            if !content.isEmpty {
                let fixedWidth: Bool
                if case .points = node.width { fixedWidth = true } else { fixedWidth = false }
                boxes.append(
                    EInkDrawBox(
                        frame: rect,
                        content: .text(content, font: font, alignment: alignment),
                        clipsContent: fixedWidth
                    )
                )
            }
        case let .image(source):
            boxes.append(EInkDrawBox(frame: rect, content: .image(source)))
        case .fill:
            boxes.append(EInkDrawBox(frame: rect, content: .fill))
        case let .horizontalBar(percent):
            boxes.append(EInkDrawBox(frame: rect, content: .outline))
            let inner = EInkRect(x: rect.x + 1, y: rect.y + 1, width: rect.width - 2, height: rect.height - 2)
            let filled = fillLength(inner.width, percent: percent)
            if filled > 0, inner.height > 0 {
                boxes.append(
                    EInkDrawBox(
                        frame: EInkRect(x: inner.x, y: inner.y, width: filled, height: inner.height),
                        content: .fill
                    )
                )
            }
        case let .verticalBar(percent):
            boxes.append(EInkDrawBox(frame: rect, content: .outline))
            let inner = EInkRect(x: rect.x + 1, y: rect.y + 1, width: rect.width - 2, height: rect.height - 2)
            let filled = fillLength(inner.height, percent: percent)
            if filled > 0, inner.width > 0 {
                boxes.append(
                    EInkDrawBox(
                        frame: EInkRect(x: inner.x, y: inner.maxY - filled, width: inner.width, height: filled),
                        content: .fill
                    )
                )
            }
        case let .ring(percent, stroke, labelFont):
            boxes.append(EInkDrawBox(frame: rect, content: .ring(percent: percent, stroke: stroke)))
            let label = String(percent)
            let labelHeight = min(rect.height, labelFont.lineHeight)
            let labelRect = EInkRect(
                x: rect.x,
                y: rect.y + (rect.height - labelHeight) / 2,
                width: rect.width,
                height: labelHeight
            )
            boxes.append(EInkDrawBox(frame: labelRect, content: .text(label, font: labelFont, alignment: .center)))
        case .row:
            layoutChildren(node, in: rect, horizontal: true, bounds: bounds, into: &boxes)
        case .column:
            layoutChildren(node, in: rect, horizontal: false, bounds: bounds, into: &boxes)
        }
    }

    /// `round(length * percent / 100)`, clamped — a 1 % bar still shows a
    /// pixel only when there is one to show.
    static func fillLength(_ length: Int, percent: Int) -> Int {
        guard length > 0 else { return 0 }
        let clamped = max(0, min(100, percent))
        return min(length, Int((Double(length) * Double(clamped) / 100).rounded()))
    }

    private static func layoutChildren(
        _ node: EInkNode,
        in rect: EInkRect,
        horizontal: Bool,
        bounds: EInkRect,
        into boxes: inout [EInkDrawBox]
    ) {
        let content = rect.inset(by: node.padding)
        let children = node.children
        guard !children.isEmpty else { return }
        let mainAvailable = horizontal ? content.width : content.height
        let crossAvailable = horizontal ? content.height : content.width

        func mainLength(_ child: EInkNode) -> EInkLength { horizontal ? child.width : child.height }
        func crossLength(_ child: EInkNode) -> EInkLength { horizontal ? child.height : child.width }
        func mainIntrinsic(_ child: EInkNode) -> Int {
            horizontal ? intrinsicWidth(child) : intrinsicHeight(child)
        }
        func crossIntrinsic(_ child: EInkNode) -> Int {
            horizontal ? intrinsicHeight(child) : intrinsicWidth(child)
        }

        var sizes = children.map { child -> Int in
            switch mainLength(child) {
            case let .points(value): max(0, value)
            case .auto: mainIntrinsic(child)
            case .flex: 0
            }
        }
        let gapTotal = node.gap * (children.count - 1)
        let totalFlex = children.reduce(0) { partial, child in
            if case let .flex(factor) = mainLength(child) { return partial + max(0, factor) }
            return partial
        }
        var free = mainAvailable - sizes.reduce(0, +) - gapTotal

        if totalFlex > 0 {
            let share = max(0, free)
            var distributed = 0
            var lastFlexIndex = -1
            for (index, child) in children.enumerated() {
                guard case let .flex(factor) = mainLength(child), factor > 0 else { continue }
                lastFlexIndex = index
            }
            for (index, child) in children.enumerated() {
                guard case let .flex(factor) = mainLength(child), factor > 0 else { continue }
                let value = index == lastFlexIndex
                    ? share - distributed
                    : share * factor / totalFlex
                sizes[index] = max(0, value)
                distributed += sizes[index]
            }
            free = 0
        }

        var offset = horizontal ? content.x : content.y
        var extraGap = 0
        if free > 0 {
            switch node.justify {
            case .start: break
            case .center: offset += free / 2
            case .end: offset += free
            case .between: extraGap = children.count > 1 ? free / (children.count - 1) : 0
            }
        }

        for (index, child) in children.enumerated() {
            let mainSize = sizes[index]
            let crossSize: Int
            switch crossLength(child) {
            case let .points(value): crossSize = max(0, min(crossAvailable, value))
            case .flex: crossSize = crossAvailable
            case .auto: crossSize = node.align == .stretch ? crossAvailable : crossIntrinsic(child)
            }
            let crossOffsetBase = horizontal ? content.y : content.x
            let slack = max(0, crossAvailable - crossSize)
            let crossOffset: Int
            switch node.align {
            case .start, .stretch: crossOffset = crossOffsetBase
            case .center: crossOffset = crossOffsetBase + slack / 2
            case .end: crossOffset = crossOffsetBase + slack
            }
            let childRect = horizontal
                ? EInkRect(x: offset, y: crossOffset, width: mainSize, height: crossSize)
                : EInkRect(x: crossOffset, y: offset, width: crossSize, height: mainSize)
            place(child, in: childRect, bounds: bounds, into: &boxes)
            offset += mainSize + node.gap + extraGap
        }
    }
}

/// Advance-width estimates for the two device fonts.
///
/// The panel's pixel class is `text-pixel-12`, which Phase 0 verified to be
/// Fusion Pixel 12 px (OFL) with a zero-pixel diff against the device: a
/// proportional font whose ASCII glyphs run 4–8 px, whose space is 6 px and
/// whose Han glyphs fill a 12 px cell. The table below reproduces the
/// reference measurement ("AntiGravity" = 62 px) within a pixel and rounds
/// *up* elsewhere, which is the safe direction — a measurement is only ever
/// used to reserve space, so erring wide costs slack and erring narrow costs
/// an overlap.
public enum EInkTextMetrics {
    /// Glyphs from CJK and fullwidth blocks occupy a full 12 px cell.
    static func isWideScalar(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x1100...0x115F, 0x2E80...0xA4CF, 0xAC00...0xD7A3,
             0xF900...0xFAFF, 0xFE30...0xFE4F, 0xFF00...0xFF60, 0xFFE0...0xFFE6,
             0x20000...0x3FFFD:
            true
        default:
            false
        }
    }

    /// Fusion Pixel 12 px advances, bucketed by glyph class.
    static func fusionPixelAdvance(_ scalar: Unicode.Scalar) -> Int {
        switch scalar {
        case " ": 6
        case "i", "l", "j", "t", "f", "r", "I", ".", ",", ":", ";", "'", "|", "!", "(", ")", "[", "]": 5
        case "m", "w", "M", "W": 8
        case "A"..."Z", "0"..."9", "$", "%", "&", "@", "#": 7
        default: 6
        }
    }

    public static func width(_ text: String, font: EInkFont) -> Int {
        switch font {
        case .pixel12:
            return text.unicodeScalars.reduce(0) { total, scalar in
                if isWideScalar(scalar) { return total + 12 }
                return total + fusionPixelAdvance(scalar)
            }
        case let .sans(size, _):
            let narrow = Set<Unicode.Scalar>([".", ",", ":", ";", "'", " "])
            let wide = Double(size) * 0.62
            let thin = Double(size) * 0.32
            let total = text.unicodeScalars.reduce(0.0) { partial, scalar in
                if isWideScalar(scalar) { return partial + Double(size) }
                return partial + (narrow.contains(scalar) ? thin : wide)
            }
            return Int(total.rounded(.up))
        }
    }
}
