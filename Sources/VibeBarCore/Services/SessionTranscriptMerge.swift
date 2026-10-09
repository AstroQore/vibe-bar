import Foundation

/// How the Sessions page assembles one transcript from a session and its
/// Codex Auto Reviews, and where it opens.
///
/// The App reads the files (bounded, cancellable, off the main actor); the
/// decisions about what goes in and which message the focus lands on are
/// here, so a reload cannot quietly drop them.
public enum SessionTranscriptMerge {
    /// What a selection asked the transcript to open on.
    ///
    /// A search hit inside an Auto Review counts messages of *that review*,
    /// so the review travels with the seq. The pair is kept for the life of
    /// the selection: "Load entire transcript" re-reads the session, and a
    /// reload that forgot the review would apply a review's message index to
    /// the session's own messages.
    public struct Focus: Sendable, Equatable {
        public let seq: Int?
        public let review: SessionSummary?

        public init(seq: Int? = nil, review: SessionSummary? = nil) {
            self.seq = seq
            self.review = review
        }

        public static let none = Focus()
    }

    /// The transcript to build: which session, where to open, and how much of
    /// its log to read. `nil` `headByteLimit` is the whole log.
    public struct Request: Sendable, Equatable {
        public let summary: SessionSummary
        public let focus: Focus
        public let headByteLimit: Int64?

        public init(summary: SessionSummary, focus: Focus = .none, headByteLimit: Int64?) {
            self.summary = summary
            self.focus = focus
            self.headByteLimit = headByteLimit
        }

        /// The same request without the byte bound — what the truncation
        /// banner's "Load entire transcript" asks for. The focus stays.
        public func wholeLog() -> Request {
            Request(summary: summary, focus: focus, headByteLimit: nil)
        }

        /// The read for the session a conversation pane shows. That is the
        /// selection's own request when it is the selection (a search hit's
        /// focus included); a thread opened from the selection — which
        /// leaves the selection where it was — is read for itself, with the
        /// same byte bound and no focus.
        public static func forShown(_ shown: SessionSummary, selection: Request?, headByteLimit: Int64?) -> Request {
            if let selection, selection.summary.id == shown.id { return selection }
            return Request(summary: shown, headByteLimit: headByteLimit)
        }
    }

    public struct Result: Sendable {
        public let document: TranscriptDocument
        /// Index into `document.messages` to open on, or `nil`.
        public let focusSeq: Int?
    }

    /// The session alone — its head was cut, so its reviews are not loaded,
    /// or it has none. A seq that counts a review's messages has no place
    /// among the session's own, so it is dropped rather than misapplied.
    public static func sessionOnly(_ root: TranscriptDocument, focus: Focus) -> Result {
        Result(document: root, focusSeq: focus.review == nil ? focus.seq : nil)
    }

    /// The session, then each review oldest first behind a divider,
    /// renumbered as one transcript, with the focus translated into that
    /// numbering. `read` returns a review's messages and whether its own
    /// head was cut, or `nil` when it could not be read; cancellation is
    /// checked before each one.
    public static func merged(
        root: TranscriptDocument,
        reviews: [SessionSummary],
        focus: Focus,
        dividerText: String,
        read: (SessionSummary) throws -> (document: TranscriptDocument, headTruncated: Bool)?
    ) throws -> Result {
        var messages = root.messages
        var translated = focus.review == nil ? focus.seq : nil
        var reviewTruncated = false
        for review in reviews.sorted(by: { ($0.createdAt ?? .distantPast) < ($1.createdAt ?? .distantPast) }) {
            try Task.checkCancellation()
            guard let child = try read(review) else { continue }
            reviewTruncated = reviewTruncated || child.headTruncated
            messages.append(SessionMessage(
                seq: messages.count,
                role: .system,
                text: dividerText,
                timestamp: review.createdAt
            ))
            let start = messages.count
            messages.append(contentsOf: child.document.messages)
            if review.id == focus.review?.id,
               let seq = focus.seq,
               let index = child.document.messages.firstIndex(where: { $0.seq == seq }) {
                translated = start + index
            }
        }
        // Renumbering copies every message, so it is worth not starting on a
        // result nobody will read.
        try Task.checkCancellation()
        let renumbered = messages.enumerated().map { index, message in
            SessionMessage(seq: index, role: message.role, text: message.text, timestamp: message.timestamp)
        }
        return Result(
            document: TranscriptDocument(
                messages: renumbered,
                totalMessageCount: renumbered.count,
                truncated: reviewTruncated
            ),
            focusSeq: translated
        )
    }
}
