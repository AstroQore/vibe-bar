import AppKit
import Foundation

/// The point sizes the conversation pane draws prompts and answers at. The
/// pane hands its density's sizes to the model, which builds every turn's
/// text at them off the main actor.
public struct SessionRichTextStyle: Sendable, Hashable {
    public var promptSize: CGFloat
    public var answerSize: CGFloat

    public init(promptSize: CGFloat = 13, answerSize: CGFloat = 13.5) {
        self.promptSize = promptSize
        self.answerSize = answerSize
    }
}

/// A parsed Markdown document as one attributed string: headings, prose,
/// code blocks, tables and rules, laid out by a single text view.
///
/// One text view per prompt or answer instead of a SwiftUI text per run of
/// prose and a grid cell per table cell: opening a conversation built and
/// measured hundreds of those views in one frame. The string is built once
/// per text and size (`SessionMarkdownCache.richText`), off the main actor;
/// it holds AppKit fonts, dynamic colours and text blocks and is never
/// mutated after it is built, which is what makes sharing it safe.
public struct SessionRichText: @unchecked Sendable, Hashable {
    public let attributed: NSAttributedString
    /// The Markdown it was built from, for copying.
    public let source: String

    public init(attributed: NSAttributedString, source: String) {
        self.attributed = attributed
        self.source = source
    }

    /// Identity, not contents: a text is built once per source and size, so
    /// two values for the same turn share the string.
    public static func == (lhs: SessionRichText, rhs: SessionRichText) -> Bool {
        lhs.attributed === rhs.attributed
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(ObjectIdentifier(attributed))
    }

    public static func make(_ document: SessionMarkdownDocument, fontSize: CGFloat) -> SessionRichText {
        var builder = SessionRichTextBuilder(fontSize: fontSize)
        return SessionRichText(attributed: builder.build(document), source: document.source)
    }
}

// MARK: - Builder

struct SessionRichTextBuilder {
    let fontSize: CGFloat
    private let out = NSMutableAttributedString()
    private let fonts: Fonts

    init(fontSize: CGFloat) {
        self.fontSize = fontSize
        self.fonts = Fonts(size: fontSize)
    }

    /// Space between segments, as the stacked SwiftUI version had it.
    static let segmentSpacing: CGFloat = 8

    mutating func build(_ document: SessionMarkdownDocument) -> NSAttributedString {
        let segments = document.segments
        for (index, segment) in segments.enumerated() {
            let spacing = index == segments.count - 1 ? 0 : Self.segmentSpacing
            switch segment {
            case let .heading(level, text):
                appendHeading(level: level, text: text, isFirst: index == 0, spacing: spacing)
            case let .prose(text):
                appendProse(text, spacing: spacing)
            case let .code(language, text):
                appendCode(language: language, text: text, spacing: spacing)
            case let .table(header, rows):
                appendTable(header: header, rows: rows, spacing: spacing)
            case .rule:
                appendRule(spacing: spacing)
            }
        }
        // Every paragraph above ends in a newline; the last one need not.
        if out.length > 0, out.string.hasSuffix("\n") {
            out.deleteCharacters(in: NSRange(location: out.length - 1, length: 1))
        }
        return out.copy() as! NSAttributedString
    }

    // MARK: Segments

    private mutating func appendHeading(level: Int, text: AttributedString, isFirst: Bool, spacing: CGFloat) {
        let style = NSMutableParagraphStyle()
        style.paragraphSpacingBefore = isFirst ? 0 : (level <= 2 ? 4 : 2)
        style.paragraphSpacing = spacing
        let bump: CGFloat = switch level {
        case 1: 5
        case 2: 3
        case 3: 1.5
        default: 0.5
        }
        let base = NSFont.systemFont(ofSize: fontSize + bump, weight: level <= 2 ? .bold : .semibold)
        appendInline(text, base: base, paragraph: style, flatten: true)
        out.append(NSAttributedString(string: "\n", attributes: [.font: base, .paragraphStyle: style]))
    }

    private mutating func appendProse(_ text: AttributedString, spacing: CGFloat) {
        let start = out.length
        let style = NSMutableParagraphStyle()
        style.lineSpacing = 2.5
        appendInline(text, base: fonts.body, paragraph: style, flatten: false)
        out.append(NSAttributedString(string: "\n", attributes: [.font: fonts.body, .paragraphStyle: style]))
        // List items carry their marker as text ("•  ", "2. "); hang the
        // wrapped lines under the item's text rather than under the marker.
        let range = NSRange(location: start, length: out.length - start)
        let string = out.string as NSString
        var paragraphs: [NSRange] = []
        string.enumerateSubstrings(in: range, options: [.byParagraphs, .substringNotRequired]) { _, _, enclosing, _ in
            paragraphs.append(enclosing)
        }
        for (position, paragraph) in paragraphs.enumerated() {
            let line = string.substring(with: paragraph)
            let indent = Self.hangingIndent(for: line, font: fonts.body)
            guard indent > 0 || position == paragraphs.count - 1 else { continue }
            let hung = style.mutableCopy() as! NSMutableParagraphStyle
            hung.headIndent = indent
            if position == paragraphs.count - 1 { hung.paragraphSpacing = spacing }
            out.addAttribute(.paragraphStyle, value: hung, range: paragraph)
        }
    }

    private mutating func appendCode(language: String?, text: String, spacing: CGFloat) {
        let block = SessionRoundedTextBlock(fill: Colors.codeFill, stroke: Colors.hairline)
        block.setValue(100, type: .percentageValueType, for: .width)
        block.setWidth(10, type: .absoluteValueType, for: .padding, edge: .minX)
        block.setWidth(10, type: .absoluteValueType, for: .padding, edge: .maxX)
        block.setWidth(8, type: .absoluteValueType, for: .padding, edge: .minY)
        block.setWidth(8, type: .absoluteValueType, for: .padding, edge: .maxY)
        block.setWidth(spacing, type: .absoluteValueType, for: .margin, edge: .maxY)
        let style = NSMutableParagraphStyle()
        style.textBlocks = [block]
        if let language, !language.isEmpty {
            let labelStyle = style.mutableCopy() as! NSMutableParagraphStyle
            labelStyle.paragraphSpacing = 4
            out.append(NSAttributedString(string: language + "\n", attributes: [
                .font: fonts.codeLabel,
                .foregroundColor: Colors.tertiary,
                .paragraphStyle: labelStyle
            ]))
        }
        out.append(NSAttributedString(string: (text.isEmpty ? " " : text) + "\n", attributes: [
            .font: fonts.code,
            .foregroundColor: Colors.label,
            .paragraphStyle: style
        ]))
    }

    private mutating func appendTable(header: [AttributedString], rows: [[AttributedString]], spacing: CGFloat) {
        let columns = max(1, header.count)
        let all = [header] + rows
        // The card is drawn by the table around its cells (a table cannot
        // sit inside another block, and its own padding is not applied).
        let table = SessionCardTextTable(rows: all.count, fill: Colors.tableFill, stroke: Colors.hairline, divider: Colors.divider)
        table.numberOfColumns = columns
        table.layoutAlgorithm = .automaticLayoutAlgorithm
        table.collapsesBorders = true
        table.setValue(100, type: .percentageValueType, for: .width)
        for (row, cells) in all.enumerated() {
            for column in 0..<columns {
                let cell = NSTextTableBlock(table: table, startingRow: row, rowSpan: 1, startingColumn: column, columnSpan: 1)
                let isLastRow = row == all.count - 1
                cell.setWidth(column == 0 ? 10 : 7, type: .absoluteValueType, for: .padding, edge: .minX)
                cell.setWidth(column == columns - 1 ? 10 : 7, type: .absoluteValueType, for: .padding, edge: .maxX)
                cell.setWidth(row == 0 ? 8 : 2.5, type: .absoluteValueType, for: .padding, edge: .minY)
                cell.setWidth(row == 0 ? 5 : (isLastRow ? 8 : 2.5), type: .absoluteValueType, for: .padding, edge: .maxY)
                let style = NSMutableParagraphStyle()
                style.textBlocks = [cell]
                let text = column < cells.count ? cells[column] : AttributedString()
                appendInline(text, base: row == 0 ? fonts.tableHeader : fonts.table, paragraph: style, flatten: true)
                out.append(NSAttributedString(string: "\n", attributes: [.font: fonts.table, .paragraphStyle: style]))
            }
        }
        // A cell's margin does not reach the paragraph after the table; an
        // empty line of the segment spacing's height does.
        if spacing > 0 {
            let gap = NSMutableParagraphStyle()
            gap.minimumLineHeight = spacing
            gap.maximumLineHeight = spacing
            out.append(NSAttributedString(string: "\n", attributes: [.font: NSFont.systemFont(ofSize: 1), .paragraphStyle: gap]))
        }
    }

    private mutating func appendRule(spacing: CGFloat) {
        let block = NSTextBlock()
        block.setValue(100, type: .percentageValueType, for: .width)
        block.setWidth(0.5, type: .absoluteValueType, for: .border, edge: .minY)
        block.setBorderColor(Colors.divider, for: .minY)
        block.setWidth(2, type: .absoluteValueType, for: .margin, edge: .minY)
        block.setWidth(max(2, spacing), type: .absoluteValueType, for: .margin, edge: .maxY)
        let style = NSMutableParagraphStyle()
        style.textBlocks = [block]
        style.maximumLineHeight = 1
        out.append(NSAttributedString(string: "\u{00A0}\n", attributes: [
            .font: NSFont.systemFont(ofSize: 1),
            .paragraphStyle: style
        ]))
    }

    // MARK: Inline

    /// Appends `text` with its emphasis, inline code, strikethrough and
    /// links. `flatten` turns line breaks into spaces (a heading or table
    /// cell is one paragraph).
    private mutating func appendInline(_ text: AttributedString, base: NSFont, paragraph: NSParagraphStyle, flatten: Bool) {
        for run in text.runs {
            var piece = String(text[run.range].characters)
            if flatten { piece = piece.replacingOccurrences(of: "\n", with: " ") }
            guard !piece.isEmpty else { continue }
            let intent = run.inlinePresentationIntent ?? []
            var font = base
            var attributes: [NSAttributedString.Key: Any] = [.foregroundColor: Colors.label, .paragraphStyle: paragraph]
            if intent.contains(.code) {
                font = NSFont.monospacedSystemFont(ofSize: max(8, base.pointSize - 1), weight: .regular)
                attributes[.backgroundColor] = Colors.inlineCodeFill
            }
            var traits: NSFontDescriptor.SymbolicTraits = []
            if intent.contains(.stronglyEmphasized) { traits.insert(.bold) }
            if intent.contains(.emphasized) { traits.insert(.italic) }
            if !traits.isEmpty {
                let descriptor = font.fontDescriptor.withSymbolicTraits(font.fontDescriptor.symbolicTraits.union(traits))
                font = NSFont(descriptor: descriptor, size: font.pointSize) ?? font
            }
            if intent.contains(.strikethrough) {
                attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
            }
            if let link = run.link {
                attributes[.link] = link
            }
            attributes[.font] = font
            out.append(NSAttributedString(string: piece, attributes: attributes))
        }
    }

    /// The width of a list item's marker, or 0 for any other paragraph.
    static func hangingIndent(for line: String, font: NSFont) -> CGFloat {
        let leading = line.prefix(while: { $0 == " " })
        let rest = line.dropFirst(leading.count)
        var marker = ""
        if rest.hasPrefix("•  ") {
            marker = String(leading) + "•  "
        } else if let dot = rest.firstIndex(of: "."), rest[..<dot].allSatisfy(\.isNumber), !rest[..<dot].isEmpty,
                  rest[rest.index(after: dot)...].hasPrefix(" ") {
            marker = String(leading) + String(rest[...dot]) + " "
        } else {
            return 0
        }
        return ceil((marker as NSString).size(withAttributes: [.font: font]).width)
    }

    // MARK: Fonts and colours

    struct Fonts {
        let body: NSFont
        let code: NSFont
        let codeLabel: NSFont
        let table: NSFont
        let tableHeader: NSFont

        init(size: CGFloat) {
            body = .systemFont(ofSize: size)
            code = .monospacedSystemFont(ofSize: max(8, size - 1.5), weight: .regular)
            codeLabel = .monospacedSystemFont(ofSize: 9.5, weight: .semibold)
            table = .systemFont(ofSize: size - 0.5)
            tableHeader = .systemFont(ofSize: size - 0.5, weight: .semibold)
        }
    }

    /// Dynamic colours: the strings are shared between light and dark
    /// windows and resolve when drawn.
    enum Colors {
        static let label = NSColor.labelColor
        static let tertiary = NSColor.tertiaryLabelColor
        static let codeFill = primary(opacity: 0.05)
        static let tableFill = primary(opacity: 0.035)
        static let inlineCodeFill = primary(opacity: 0.07)
        static let hairline = primary(opacity: 0.08)
        static let divider = primary(opacity: 0.12)

        static func primary(opacity: CGFloat) -> NSColor {
            NSColor(name: nil) { appearance in
                let dark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                return NSColor(white: dark ? 1 : 0, alpha: opacity)
            }
        }
    }
}

// MARK: - Rounded blocks

/// A text block drawn as a rounded, hairline-bordered card, like the
/// conversation's other cards (the stock block draws square edges).
final class SessionRoundedTextBlock: NSTextBlock {
    let fill: NSColor
    let stroke: NSColor

    init(fill: NSColor, stroke: NSColor) {
        self.fill = fill
        self.stroke = stroke
        super.init()
    }

    required init?(coder: NSCoder) { nil }

    override func drawBackground(withFrame frameRect: NSRect, in controlView: NSView?, characterRange charRange: NSRange, layoutManager: NSLayoutManager) {
        SessionRoundedTextBlock.drawCard(frameRect, fill: fill, stroke: stroke, in: self)
    }

    static func drawCard(_ frame: NSRect, fill: NSColor, stroke: NSColor, in block: NSTextBlock) {
        let margins = NSEdgeInsets(
            top: block.width(for: .margin, edge: .minY),
            left: block.width(for: .margin, edge: .minX),
            bottom: block.width(for: .margin, edge: .maxY),
            right: block.width(for: .margin, edge: .maxX)
        )
        let rect = NSRect(
            x: frame.minX + margins.left,
            y: frame.minY + margins.top,
            width: frame.width - margins.left - margins.right,
            height: frame.height - margins.top - margins.bottom
        ).insetBy(dx: 0.25, dy: 0.25)
        guard rect.width > 0, rect.height > 0 else { return }
        let path = NSBezierPath(roundedRect: rect, xRadius: 8, yRadius: 8)
        fill.setFill()
        path.fill()
        stroke.setStroke()
        path.lineWidth = 0.5
        path.stroke()
    }
}

/// A table that draws its cells as one rounded card — fill, hairline
/// outline, a rule under the header row — the way the conversation's code
/// blocks are drawn.
final class SessionCardTextTable: NSTextTable {
    let rowCount: Int
    let fill: NSColor
    let stroke: NSColor
    let divider: NSColor

    init(rows: Int, fill: NSColor, stroke: NSColor, divider: NSColor) {
        self.rowCount = rows
        self.fill = fill
        self.stroke = stroke
        self.divider = divider
        super.init()
    }

    required init?(coder: NSCoder) { nil }

    override func drawBackground(
        for block: NSTextTableBlock,
        withFrame frameRect: NSRect,
        in controlView: NSView?,
        characterRange charRange: NSRange,
        layoutManager: NSLayoutManager
    ) {
        let row = block.startingRow
        let column = block.startingColumn
        let isTop = row == 0
        let isBottom = row + block.rowSpan >= rowCount
        let isLeft = column == 0
        let isRight = column + block.columnSpan >= numberOfColumns
        // Cells abut exactly; filled as they are, a shared edge that falls
        // between device pixels shows as a seam, so each edge is snapped to
        // the pixel grid below. The table's collapsed outer border reaches
        // half a point past the container.
        var rect = frameRect
        if let width = layoutManager.textContainers.first?.size.width, rect.maxX > width {
            rect.size.width = width - rect.minX
        }
        if rect.minX < 0 {
            rect.size.width += rect.minX
            rect.origin.x = 0
        }
        // Both neighbours round their shared edge to the same device pixel.
        if let controlView {
            rect = controlView.backingAlignedRect(rect, options: .alignAllEdgesNearest)
        }
        guard rect.width > 0, rect.height > 0 else { return }
        let radius: CGFloat = 8
        // Fill: the cell's rectangle, its outer corners rounded.
        let path = Self.path(rect, radius: radius, corners: (isTop && isLeft, isTop && isRight, isBottom && isLeft, isBottom && isRight))
        fill.setFill()
        path.fill()
        // Outline: only the edges on the table's outside.
        let outline = NSBezierPath()
        let inset = rect.insetBy(dx: 0.25, dy: 0.25)
        if isTop {
            outline.move(to: NSPoint(x: isLeft ? inset.minX + radius : inset.minX, y: inset.minY))
            outline.line(to: NSPoint(x: isRight ? inset.maxX - radius : inset.maxX, y: inset.minY))
        }
        if isBottom {
            outline.move(to: NSPoint(x: isLeft ? inset.minX + radius : inset.minX, y: inset.maxY))
            outline.line(to: NSPoint(x: isRight ? inset.maxX - radius : inset.maxX, y: inset.maxY))
        }
        if isLeft {
            outline.move(to: NSPoint(x: inset.minX, y: isTop ? inset.minY + radius : inset.minY))
            outline.line(to: NSPoint(x: inset.minX, y: isBottom ? inset.maxY - radius : inset.maxY))
        }
        if isRight {
            outline.move(to: NSPoint(x: inset.maxX, y: isTop ? inset.minY + radius : inset.minY))
            outline.line(to: NSPoint(x: inset.maxX, y: isBottom ? inset.maxY - radius : inset.maxY))
        }
        // Each corner its own subpath: an arc appended to an open path is
        // joined to the previous point by a straight line.
        func corner(_ center: NSPoint, from start: CGFloat, to end: CGFloat) {
            let radians = start * .pi / 180
            outline.move(to: NSPoint(x: center.x + radius * cos(radians), y: center.y + radius * sin(radians)))
            outline.appendArc(withCenter: center, radius: radius, startAngle: start, endAngle: end)
        }
        if isTop && isLeft { corner(NSPoint(x: inset.minX + radius, y: inset.minY + radius), from: 180, to: 270) }
        if isTop && isRight { corner(NSPoint(x: inset.maxX - radius, y: inset.minY + radius), from: 270, to: 360) }
        if isBottom && isLeft { corner(NSPoint(x: inset.minX + radius, y: inset.maxY - radius), from: 90, to: 180) }
        if isBottom && isRight { corner(NSPoint(x: inset.maxX - radius, y: inset.maxY - radius), from: 0, to: 90) }
        outline.lineWidth = 0.5
        stroke.setStroke()
        outline.stroke()
        // The rule under the header, inside the card's padding.
        if isTop, rowCount > 1 {
            let left = rect.minX + (isLeft ? 10 : 0)
            let right = rect.maxX - (isRight ? 10 : 0)
            let rule = NSBezierPath()
            rule.move(to: NSPoint(x: left, y: rect.maxY - 0.25))
            rule.line(to: NSPoint(x: right, y: rect.maxY - 0.25))
            rule.lineWidth = 0.5
            divider.setStroke()
            rule.stroke()
        }
    }

    /// A rectangle with the chosen corners rounded (flipped coordinates:
    /// "top" is the smaller y).
    static func path(_ rect: NSRect, radius: CGFloat, corners: (topLeft: Bool, topRight: Bool, bottomLeft: Bool, bottomRight: Bool)) -> NSBezierPath {
        let path = NSBezierPath()
        let r = min(radius, rect.width / 2, rect.height / 2)
        path.move(to: NSPoint(x: rect.minX + (corners.topLeft ? r : 0), y: rect.minY))
        path.line(to: NSPoint(x: rect.maxX - (corners.topRight ? r : 0), y: rect.minY))
        if corners.topRight { path.appendArc(withCenter: NSPoint(x: rect.maxX - r, y: rect.minY + r), radius: r, startAngle: 270, endAngle: 360) }
        path.line(to: NSPoint(x: rect.maxX, y: rect.maxY - (corners.bottomRight ? r : 0)))
        if corners.bottomRight { path.appendArc(withCenter: NSPoint(x: rect.maxX - r, y: rect.maxY - r), radius: r, startAngle: 0, endAngle: 90) }
        path.line(to: NSPoint(x: rect.minX + (corners.bottomLeft ? r : 0), y: rect.maxY))
        if corners.bottomLeft { path.appendArc(withCenter: NSPoint(x: rect.minX + r, y: rect.maxY - r), radius: r, startAngle: 90, endAngle: 180) }
        path.line(to: NSPoint(x: rect.minX, y: rect.minY + (corners.topLeft ? r : 0)))
        if corners.topLeft { path.appendArc(withCenter: NSPoint(x: rect.minX + r, y: rect.minY + r), radius: r, startAngle: 180, endAngle: 270) }
        path.close()
        return path
    }
}

// MARK: - Contents column metrics

extension SessionConversationTOCEntry {
    /// The contents column's preview font, at its widest (the current
    /// entry's weight).
    nonisolated(unsafe) public static let previewFont = NSFont.systemFont(ofSize: 11.5, weight: .semibold)

    /// `entries(from:)` with each preview's one-line width measured, so the
    /// column knows every row's height without laying any row out. Called
    /// off the main actor.
    public static func measuredEntries(from outline: [SessionTurnOutline]) -> [SessionConversationTOCEntry] {
        var out = entries(from: outline)
        let attributes: [NSAttributedString.Key: Any] = [.font: previewFont]
        for index in out.indices {
            guard let preview = out[index].preview else { continue }
            out[index].previewWidth = Double(ceil((preview as NSString).size(withAttributes: attributes).width))
        }
        return out
    }
}
