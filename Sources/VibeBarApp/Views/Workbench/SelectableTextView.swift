import AppKit
import SwiftUI

/// Read-only, selectable text backed by a plain `NSTextView`.
///
/// SwiftUI's `Text(...).textSelection(.enabled)` installs a `SelectionOverlay`
/// (an `NSTextField`-hosted `NSViewRepresentable`) whose `updateNSView`
/// re-runs the styled-text layout engine on every graph update. Inside a
/// `LazyVStack` of transcript bubbles with `fixedSize(horizontal: false,
/// vertical: true)` that becomes a layout-invalidation loop — a sampled
/// freeze showed the main thread pinned at ~99 % in
/// `SelectionOverlay.updateNSView` → `StyledTextLayoutEngine.sizeThatFits`
/// for as long as the transcript pane was open. An `NSTextView` lays the
/// string out once per width and hands SwiftUI a fixed height, so the graph
/// has nothing to chase.
///
/// Sizing: `sizeThatFits` measures the used rect for the proposed width via
/// the TextKit 1 layout manager, which is deterministic and cheap for the
/// ≤ 3 000-character bodies the transcript shows before "Show more".
struct SelectableTextView: NSViewRepresentable {
    let text: AttributedString
    let font: NSFont
    let textColor: NSColor

    func makeNSView(context: Context) -> NSTextView {
        let view = MeasuringTextView(frame: .zero)
        view.isEditable = false
        view.isSelectable = true
        view.isRichText = false
        view.drawsBackground = false
        view.isVerticallyResizable = false
        view.isHorizontallyResizable = false
        view.textContainerInset = .zero
        view.textContainer?.lineFragmentPadding = 0
        view.textContainer?.widthTracksTextView = true
        view.textContainer?.lineBreakMode = .byWordWrapping
        view.setContentHuggingPriority(.defaultLow, for: .horizontal)
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        apply(to: view)
        return view
    }

    func updateNSView(_ view: NSTextView, context: Context) {
        apply(to: view)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView view: NSTextView, context: Context) -> CGSize? {
        guard let container = view.textContainer, let layout = view.layoutManager else { return nil }
        let width = proposal.width.map { max(1, $0) } ?? 10_000
        container.size = CGSize(width: width, height: .greatestFiniteMagnitude)
        layout.ensureLayout(for: container)
        let used = layout.usedRect(for: container)
        // A zero rect means layout has not run for this width yet; let SwiftUI
        // fall back to the view's own sizing rather than collapsing the bubble.
        guard used.height > 0 || view.string.isEmpty else { return nil }
        return CGSize(width: proposal.width ?? ceil(used.width), height: ceil(used.height))
    }

    private func apply(to view: NSTextView) {
        var attributed = text
        attributed.font = font
        attributed.foregroundColor = textColor
        let rendered = NSAttributedString(attributed)
        guard let storage = view.textStorage, !storage.isEqual(to: rendered) else { return }
        storage.setAttributedString(rendered)
    }
}

/// `NSTextView` reports an intrinsic size of `noIntrinsicMetric` and asks to
/// scroll; inside SwiftUI we want the opposite — take exactly the frame we
/// were given and let `sizeThatFits` decide the height.
private final class MeasuringTextView: NSTextView {
    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: NSView.noIntrinsicMetric)
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        textContainer?.size = CGSize(width: newSize.width, height: .greatestFiniteMagnitude)
    }
}
