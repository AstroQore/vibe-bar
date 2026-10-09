import AppKit
import SwiftUI
import VibeBarCore

/// A prompt or an answer: one read-only, selectable text view over the
/// `SessionRichText` the model built off the main actor.
///
/// One platform view per document replaces a SwiftUI text per run of prose
/// and a grid cell per table cell. Opening a conversation used to build and
/// measure several hundred of those in one frame; this measures once per
/// width and keeps the result. The text is selectable, a right click offers
/// "copy all", and accessibility sees one text element.
struct SessionRichTextView: NSViewRepresentable {
    let text: SessionRichText
    /// Report the width the text uses (a bubble) instead of the width
    /// offered (a column).
    var hugsWidth = false
    /// Lines shown before the rest is cut with an ellipsis; 0 for all.
    var maximumLines = 0
    /// The context menu's "copy all" item.
    var copyTitle: String
    var copy: (String) -> Void

    func makeNSView(context: Context) -> SessionTextView {
        SessionTextView()
    }

    func updateNSView(_ view: SessionTextView, context: Context) {
        view.show(text.attributed, maximumLines: maximumLines)
        view.copyTitle = copyTitle
        let source = text.source
        let copy = self.copy
        view.copyAll = { copy(source) }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView view: SessionTextView, context: Context) -> CGSize? {
        view.show(text.attributed, maximumLines: maximumLines)
        let offered = proposal.width ?? .infinity
        // A probe for the ideal width (nil or infinite) gets the unwrapped
        // width, capped; a probe for the minimum (zero) the same as a
        // narrow column, never a character per line.
        let width = offered.isFinite ? max(offered, 60) : SessionTextView.idealWidth
        return view.fittingSize(width: width, hugs: hugsWidth || !offered.isFinite)
    }
}

/// The text view behind `SessionRichTextView`: TextKit 1 (text tables and
/// blocks need it), no editing, no background, measured per width.
final class SessionTextView: NSTextView {
    static let idealWidth: CGFloat = 640

    var copyAll: (() -> Void)?
    var copyTitle = ""
    private var shown: NSAttributedString?
    private var maximumLines = 0
    private var sizes: [CGFloat: CGSize] = [:]

    init() {
        let storage = NSTextStorage()
        let manager = NSLayoutManager()
        storage.addLayoutManager(manager)
        let container = NSTextContainer(containerSize: NSSize(width: Self.idealWidth, height: .greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        // The container keeps the width it was measured at: SwiftUI sets the
        // frame to that size (or to the narrower used width of a bubble), and
        // tracking the frame would lay the text out a second time.
        container.widthTracksTextView = false
        container.heightTracksTextView = false
        manager.addTextContainer(container)
        super.init(frame: NSRect(x: 0, y: 0, width: Self.idealWidth, height: 1), textContainer: container)
        isEditable = false
        isSelectable = true
        isRichText = true
        drawsBackground = false
        textContainerInset = .zero
        isVerticallyResizable = false
        isHorizontallyResizable = false
        isAutomaticLinkDetectionEnabled = false
        allowsUndo = false
        usesFindPanel = false
        usesFontPanel = false
        linkTextAttributes = [
            .foregroundColor: NSColor.linkColor,
            .cursor: NSCursor.pointingHand
        ]
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override init(frame frameRect: NSRect, textContainer container: NSTextContainer?) {
        super.init(frame: frameRect, textContainer: container)
    }

    func show(_ text: NSAttributedString, maximumLines: Int) {
        guard text !== shown || maximumLines != self.maximumLines else { return }
        shown = text
        self.maximumLines = maximumLines
        textContainer?.maximumNumberOfLines = maximumLines
        textContainer?.lineBreakMode = maximumLines > 0 ? .byTruncatingTail : .byWordWrapping
        textStorage?.setAttributedString(text)
        sizes.removeAll(keepingCapacity: true)
    }

    /// The size the text takes at `width`, laid out once per width.
    func fittingSize(width: CGFloat, hugs: Bool) -> CGSize {
        let key = hugs ? -width : width
        if let size = sizes[key] { return size }
        guard let container = textContainer, let manager = layoutManager else { return .zero }
        if container.containerSize.width != width {
            container.containerSize = NSSize(width: width, height: .greatestFiniteMagnitude)
        }
        manager.ensureLayout(for: container)
        let used = manager.usedRect(for: container)
        let size = CGSize(width: hugs ? min(width, ceil(used.width)) : width, height: max(1, ceil(used.height)))
        sizes[key] = size
        return size
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = super.menu(for: event) ?? NSMenu()
        guard copyAll != nil, !copyTitle.isEmpty else { return menu }
        let item = NSMenuItem(title: copyTitle, action: #selector(copyEverything), keyEquivalent: "")
        item.target = self
        menu.insertItem(item, at: 0)
        menu.insertItem(.separator(), at: 1)
        return menu
    }

    @objc private func copyEverything() {
        copyAll?()
    }
}
