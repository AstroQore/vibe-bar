import AppKit
import SwiftUI
import VibeBarCore

/// The contents column's entries: an AppKit table rather than a lazy
/// SwiftUI stack.
///
/// The column opens on its last entry. A lazy stack can only land there by
/// measuring every entry above it, and a session of a few hundred turns paid
/// for that on each open; a table knows its row heights up front (one or
/// two preview lines, decided by a string measurement) and builds only the
/// rows on screen, so opening, jumping and following the conversation cost
/// the same at ten turns as at a thousand.
struct SessionOutlineTable: NSViewRepresentable {
    let entries: [SessionConversationTOCEntry]
    let currentTurn: Int?
    /// Changes when a new session's contents arrive: the table then starts
    /// at its end, as the conversation does.
    let contentToken: Int
    let select: (Int) -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSScrollView {
        let table = OutlineTableView()
        table.headerView = nil
        table.backgroundColor = .clear
        table.intercellSpacing = NSSize(width: 0, height: 1)
        table.selectionHighlightStyle = .none
        table.allowsEmptySelection = true
        table.usesAutomaticRowHeights = false
        table.style = .plain
        table.focusRingType = .none
        let column = NSTableColumn(identifier: OutlineCell.identifier)
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)
        table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        table.dataSource = context.coordinator
        table.delegate = context.coordinator
        table.target = context.coordinator
        table.action = #selector(Coordinator.clicked(_:))
        table.setAccessibilityLabel(L10n.Workbench.Sessions.Toc.heading)

        let scroll = OutlineScrollView()
        scroll.documentView = table
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = true
        scroll.contentInsets = NSEdgeInsets(top: 6, left: 0, bottom: 6, right: 0)
        scroll.automaticallyAdjustsContentInsets = false
        context.coordinator.table = table
        context.coordinator.scroll = scroll
        table.onResize = { [weak coordinator = context.coordinator] in coordinator?.widthChanged() }
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.select = select
        context.coordinator.update(entries: entries, current: currentTurn, token: contentToken)
    }

    // MARK: - Coordinator

    @MainActor
    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
        weak var table: OutlineTableView?
        weak var scroll: OutlineScrollView?
        var select: (Int) -> Void = { _ in }
        private var entries: [SessionConversationTOCEntry] = []
        private var current: Int?
        private var token: Int?
        /// Per entry, at the width they were measured for.
        private var twoLine: [Bool] = []
        private var measuredWidth: CGFloat = 0
        private var follow: Task<Void, Never>?
        /// The table still holds the previous session's entries, hidden.
        private var hidesStale = false

        func update(entries: [SessionConversationTOCEntry], current: Int?, token: Int) {
            guard let table else { return }
            let tokenChanged = token != self.token
            self.token = token
            if entries.isEmpty, !self.entries.isEmpty {
                // A session is loading: hide the old entries rather than
                // reload an empty table — the new ones replace them anyway.
                scroll?.alphaValue = 0
                hidesStale = true
                return
            }
            if entries != self.entries || hidesStale {
                // A session's entries arrive after the pane cleared the old
                // ones; that is when the column jumps to its end.
                let arrived = hidesStale || self.entries.isEmpty
                if hidesStale {
                    hidesStale = false
                    scroll?.alphaValue = 1
                }
                self.entries = entries
                self.current = current
                twoLine = []
                measuredWidth = 0
                table.reloadData()
                if arrived || tokenChanged, !entries.isEmpty {
                    table.scrollRowToVisible(entries.count - 1)
                }
                return
            }
            if tokenChanged, !entries.isEmpty, current == self.current {
                table.scrollRowToVisible(entries.count - 1)
                return
            }
            guard current != self.current else { return }
            let old = self.current
            self.current = current
            for turn in [old, current].compactMap({ $0 }) {
                guard let row = row(forTurn: turn) else { continue }
                if let rowView = table.rowView(atRow: row, makeIfNecessary: false) as? OutlineRowView {
                    rowView.isCurrent = turn == current
                }
                if let cell = table.view(atColumn: 0, row: row, makeIfNecessary: false) as? OutlineCell {
                    cell.isCurrent = turn == current
                }
            }
            scheduleFollow()
        }

        /// Keep the current entry in view as the conversation scrolls — once
        /// it settles, and not while the pointer is over the column, where a
        /// jump would fight the reader.
        private func scheduleFollow() {
            follow?.cancel()
            follow = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(280))
                guard let self, !Task.isCancelled, let table = self.table, let scroll = self.scroll,
                      !scroll.isPointerInside, let current = self.current, let row = self.row(forTurn: current)
                else { return }
                let rect = table.rect(ofRow: row)
                let visible = scroll.contentView.documentVisibleRect
                guard !visible.insetBy(dx: 0, dy: 8).contains(rect) else { return }
                let y = max(0, rect.midY - visible.height / 2)
                scroll.contentView.scroll(to: NSPoint(x: 0, y: min(y, max(0, table.frame.height - visible.height))))
                scroll.reflectScrolledClipView(scroll.contentView)
            }
        }

        private func row(forTurn turn: Int) -> Int? {
            // Entries are in turn order; usually index == turn.
            if entries.indices.contains(turn), entries[turn].turnIndex == turn { return turn }
            return entries.firstIndex { $0.turnIndex == turn }
        }

        func widthChanged() {
            guard let table, !entries.isEmpty else { return }
            let width = previewWidth(in: table)
            guard abs(width - measuredWidth) > 0.5 else { return }
            let before = twoLine
            measure(width: width)
            let changed = IndexSet(before.indices.filter { before[$0] != twoLine[$0] })
            if before.count != twoLine.count {
                table.noteHeightOfRows(withIndexesChanged: IndexSet(integersIn: 0..<entries.count))
            } else if !changed.isEmpty {
                table.noteHeightOfRows(withIndexesChanged: changed)
            }
        }

        private func previewWidth(in table: NSTableView) -> CGFloat {
            max(40, table.bounds.width - OutlineCell.previewInset)
        }

        /// One or two preview lines per entry, from the widths the model
        /// measured with the entries (a string measurement only for one it
        /// did not).
        private func measure(width: CGFloat) {
            measuredWidth = width
            twoLine = entries.map { entry in
                guard entry.preview != nil else { return false }
                var natural = CGFloat(entry.previewWidth)
                if natural <= 0 {
                    natural = (OutlineCell.previewText(for: entry) as NSString)
                        .size(withAttributes: [.font: SessionConversationTOCEntry.previewFont]).width
                }
                return natural > width
            }
        }

        // MARK: Data source and delegate

        func numberOfRows(in tableView: NSTableView) -> Int { entries.count }

        func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
            if twoLine.count != entries.count { measure(width: previewWidth(in: tableView)) }
            return twoLine[row] ? OutlineCell.twoLineHeight : OutlineCell.oneLineHeight
        }

        func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
            let view = tableView.makeView(withIdentifier: OutlineRowView.identifier, owner: nil) as? OutlineRowView ?? OutlineRowView()
            view.identifier = OutlineRowView.identifier
            view.isCurrent = entries[row].turnIndex == current
            return view
        }

        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            let cell = tableView.makeView(withIdentifier: OutlineCell.identifier, owner: nil) as? OutlineCell ?? OutlineCell()
            cell.identifier = OutlineCell.identifier
            cell.show(entries[row], isCurrent: entries[row].turnIndex == current)
            let turn = entries[row].turnIndex
            cell.press = { [weak self] in self?.select(turn) }
            return cell
        }

        @objc func clicked(_ sender: NSTableView) {
            let row = sender.clickedRow
            guard entries.indices.contains(row) else { return }
            select(entries[row].turnIndex)
        }
    }
}

// MARK: - Views

final class OutlineTableView: NSTableView {
    var onResize: (() -> Void)?

    /// A click jumps even when the window was not key, as the SwiftUI
    /// buttons around the column do.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func setFrameSize(_ newSize: NSSize) {
        let widthChanged = newSize.width != frame.width
        super.setFrameSize(newSize)
        if widthChanged { onResize?() }
    }
}

/// Knows whether the pointer is over it, for the follow-the-conversation
/// rule.
final class OutlineScrollView: NSScrollView {
    private(set) var isPointerInside = false
    private var area: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let area { removeTrackingArea(area) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(area)
        self.area = area
    }

    override func mouseEntered(with event: NSEvent) { isPointerInside = true }
    override func mouseExited(with event: NSEvent) { isPointerInside = false }
}

/// The current entry's rounded accent fill.
final class OutlineRowView: NSTableRowView {
    static let identifier = NSUserInterfaceItemIdentifier("SessionOutlineRow")

    var isCurrent = false {
        didSet {
            guard isCurrent != oldValue else { return }
            needsDisplay = true
            setAccessibilitySelected(isCurrent)
        }
    }

    override func drawBackground(in dirtyRect: NSRect) {
        guard isCurrent else { return }
        let rect = bounds.insetBy(dx: 6, dy: 0)
        NSColor(WorkbenchPorcelain.accent).withAlphaComponent(0.12).setFill()
        NSBezierPath(roundedRect: rect, xRadius: 7, yRadius: 7).fill()
    }
}

/// Ordinal, prompt preview (up to two lines), and time · steps · failures,
/// drawn by the cell itself: one layer and three string draws per row
/// instead of three text fields, each with its own layer and layout.
final class OutlineCell: NSTableCellView {
    static let identifier = NSUserInterfaceItemIdentifier("SessionOutlineCell")
    static let oneLineHeight: CGFloat = 40
    static let twoLineHeight: CGFloat = 54
    /// Horizontal space around the preview: row inset, padding, ordinal.
    static let previewInset: CGFloat = leading + ordinalWidth + gap + trailing
    private static let leading: CGFloat = 13
    private static let ordinalWidth: CGFloat = 20
    private static let gap: CGFloat = 7
    private static let trailing: CGFloat = 13
    private static let top: CGFloat = 5

    private var entry: SessionConversationTOCEntry?
    private var ordinalText = NSAttributedString()
    private var previewText = NSAttributedString()
    private var detailText = NSAttributedString()
    /// Accessibility's press: the same jump a click makes.
    var press: (() -> Void)?

    var isCurrent = false {
        didSet {
            guard isCurrent != oldValue, let entry else { return }
            apply(entry)
        }
    }

    init() {
        super.init(frame: .zero)
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override var isFlipped: Bool { true }

    override func accessibilityPerformPress() -> Bool {
        press?()
        return press != nil
    }

    func show(_ entry: SessionConversationTOCEntry, isCurrent: Bool) {
        self.entry = entry
        self.isCurrent = isCurrent
        apply(entry)
    }

    private func apply(_ entry: SessionConversationTOCEntry) {
        let accent = NSColor(WorkbenchPorcelain.accent)
        let right = NSMutableParagraphStyle()
        right.alignment = .right
        ordinalText = NSAttributedString(string: AppLocale.number(entry.ordinal), attributes: [
            .font: Self.ordinalFont,
            .foregroundColor: isCurrent ? accent : NSColor.secondaryLabelColor.withAlphaComponent(0.8),
            .paragraphStyle: right
        ])
        let text = Self.previewText(for: entry)
        let wrap = NSMutableParagraphStyle()
        wrap.lineBreakMode = .byWordWrapping
        previewText = NSAttributedString(string: text, attributes: [
            .font: Self.previewFont(current: isCurrent),
            .foregroundColor: entry.preview == nil ? NSColor.secondaryLabelColor : NSColor.labelColor,
            .paragraphStyle: wrap
        ])
        detailText = Self.detailText(for: entry)
        alphaValue = entry.status == .abandoned ? 0.5 : 1
        setAccessibilityLabel(AppLocale.number(entry.ordinal) + ". " + text)
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let previewX = Self.leading + Self.ordinalWidth + Self.gap
        let previewWidth = max(10, bounds.width - previewX - Self.trailing)
        let lineHeight = ceil(Self.previewRegularFont.ascender - Self.previewRegularFont.descender + Self.previewRegularFont.leading)
        let lines: CGFloat = bounds.height >= Self.twoLineHeight - 1 ? 2 : 1
        let previewRect = NSRect(x: previewX, y: Self.top, width: previewWidth, height: lineHeight * lines + 1)
        previewText.draw(with: previewRect, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
        // The ordinal sits on the preview's first baseline.
        let baselineShift = Self.previewRegularFont.ascender - Self.ordinalFont.ascender
        ordinalText.draw(
            with: NSRect(x: Self.leading, y: Self.top + baselineShift, width: Self.ordinalWidth, height: lineHeight),
            options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine]
        )
        detailText.draw(
            with: NSRect(x: previewX, y: previewRect.maxY + 1, width: previewWidth, height: 14),
            options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine]
        )
    }

    static func previewText(for entry: SessionConversationTOCEntry) -> String {
        if let preview = entry.preview { return preview }
        switch entry.origin {
        case .automation: return L10n.Workbench.Sessions.Turn.Origin.automation
        case .agent: return L10n.Workbench.Sessions.Turn.Origin.agent
        case .guardianRequest: return L10n.Workbench.Sessions.Turn.Origin.guardianRequest
        case .none, .human: return L10n.Workbench.Sessions.Turn.Origin.none
        }
    }

    static func previewFont(current: Bool) -> NSFont {
        current ? previewCurrentFont : previewRegularFont
    }

    private static let previewRegularFont = NSFont.systemFont(ofSize: 11.5)
    private static let previewCurrentFont = SessionConversationTOCEntry.previewFont
    private static let detailFont = NSFont.monospacedDigitSystemFont(ofSize: 9.5, weight: .regular)
    private static let ordinalFont: NSFont = {
        let base = NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .semibold)
        guard let rounded = base.fontDescriptor.withDesign(.rounded) else { return base }
        return NSFont(descriptor: rounded, size: 10) ?? base
    }()

    private static func detailText(for entry: SessionConversationTOCEntry) -> NSAttributedString {
        let out = NSMutableAttributedString()
        let truncating = NSMutableParagraphStyle()
        truncating.lineBreakMode = .byTruncatingTail
        let quiet: [NSAttributedString.Key: Any] = [.font: detailFont, .foregroundColor: NSColor.tertiaryLabelColor, .paragraphStyle: truncating]
        var parts: [(String, NSColor)] = []
        if let started = entry.startedAt { parts.append((AppLocale.string(started, template: "jmm"), .tertiaryLabelColor)) }
        if entry.steps > 0 { parts.append((L10n.Workbench.Sessions.Turn.steps(count: entry.steps), .tertiaryLabelColor)) }
        if entry.failed > 0 { parts.append((L10n.Workbench.Sessions.Turn.failures(count: entry.failed), .systemRed)) }
        for (index, part) in parts.enumerated() {
            if index > 0 { out.append(NSAttributedString(string: "  ", attributes: quiet)) }
            var attributes = quiet
            attributes[.foregroundColor] = part.1
            out.append(NSAttributedString(string: part.0, attributes: attributes))
        }
        return out
    }
}
