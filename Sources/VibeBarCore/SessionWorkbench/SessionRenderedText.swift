import CoreGraphics
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

/// A prompt or an answer as the pane will draw it: whatever the pane's
/// renderer built from the parsed Markdown (an attributed string, in the
/// app), carried opaquely so Core stays free of drawing types.
///
/// Built once per text and size (`SessionMarkdownCache.rendered`) off the
/// main actor, never mutated afterwards — which is what makes handing it
/// across threads safe — and compared by identity: two values for the same
/// turn share the object.
public struct SessionRenderedText: @unchecked Sendable, Hashable {
    public let object: AnyObject
    /// The Markdown it was built from, for copying.
    public let source: String

    public init(object: AnyObject, source: String) {
        self.object = object
        self.source = source
    }

    public static func == (lhs: SessionRenderedText, rhs: SessionRenderedText) -> Bool {
        lhs.object === rhs.object
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(ObjectIdentifier(object))
    }
}

/// What the pane draws with, given to `SessionConversationModel` so the
/// work happens while it prepares a session rather than in a view: a
/// renderer for turn text, and a measure of a contents preview's one-line
/// width. Both run off the main actor; either may be absent (tests, a
/// surface without that column), and the pane then does without.
public struct SessionConversationRendering: Sendable {
    public var text: (@Sendable (SessionMarkdownDocument, CGFloat) -> AnyObject)?
    public var previewWidth: (@Sendable (String) -> Double)?

    public init(
        text: (@Sendable (SessionMarkdownDocument, CGFloat) -> AnyObject)? = nil,
        previewWidth: (@Sendable (String) -> Double)? = nil
    ) {
        self.text = text
        self.previewWidth = previewWidth
    }

    public static let none = SessionConversationRendering()
}

// MARK: - Contents column metrics

extension SessionConversationTOCEntry {
    /// `entries(from:)` with each preview's one-line width measured by
    /// `measure`, so the column knows every row's height without laying any
    /// row out. Called off the main actor.
    public static func measuredEntries(
        from outline: [SessionTurnOutline],
        measure: (@Sendable (String) -> Double)?
    ) -> [SessionConversationTOCEntry] {
        var out = entries(from: outline)
        guard let measure else { return out }
        for index in out.indices {
            guard let preview = out[index].preview else { continue }
            out[index].previewWidth = measure(preview)
        }
        return out
    }
}
