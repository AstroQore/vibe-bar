import Foundation

/// Decides how a content-height report may touch a popover that is on
/// screen. Growth applies immediately — an opening popover must reach its
/// content height without a visible delay. A shrink never applies
/// immediately: SwiftUI's first layout pass after reopening or switching
/// pages reports a transiently tiny height before the cards have measured,
/// and applying it snapped the visible popover down to its minimum height
/// for a beat ("the page reflows to minimum height"). The caller holds a
/// shrink for a settle window instead and applies it only if no larger
/// report supersedes it.
///
/// Only the decision lives here so it can be tested; the windows, the
/// coalescing, and the actual frame write stay with the AppKit controller.
public enum PopoverResizeGate {
    public enum Verdict: Equatable {
        /// Growth, or a width change that must stay in sync: apply now.
        case applyNow
        /// Lower than what is on screen: hold for the settle window.
        case holdForSettle
        /// No meaningful change from what is on screen.
        case ignore
    }

    public static func verdict(
        currentHeight: CGFloat,
        targetHeight: CGFloat,
        currentWidth: CGFloat,
        targetWidth: CGFloat
    ) -> Verdict {
        let widthChanged = abs(currentWidth - targetWidth) > 1
        let heightDelta = targetHeight - currentHeight
        if abs(heightDelta) <= 1 {
            return widthChanged ? .applyNow : .ignore
        }
        if heightDelta < 0, !widthChanged {
            return .holdForSettle
        }
        return .applyNow
    }
}
