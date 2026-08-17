import Foundation

/// Claude Cowork sessions: the throwaway workspace Claude.app writes for
/// each local agent run, at
/// `~/Library/Application Support/Claude/local-agent-mode-sessions/
///  <space>/<x>/local_<uuid>/.claude/projects/<encoded-cwd>/<uuid>.jsonl`.
///
/// The transcripts are byte-for-byte the same JSONL Claude Code writes, so
/// every parser is `ClaudeSessionAdapter`'s; only the roots, the harness
/// stamp, and the delete answer differ.
///
/// **Read-only, permanently.** These files live inside another app's
/// container: Claude.app owns their lifecycle, may hold them open, and
/// removing one is how a workspace gets half-deleted rather than cleaned up.
/// `deletionPlan` therefore fails closed, and the containment fence in
/// `SessionDeleter` never gets a plan to check (AGENTS.md § 5).
public struct ClaudeCoworkSessionAdapter: SessionProviderAdapter {
    public let provider: SessionProvider = .claudeCowork

    public init() {}

    public func roots(homeDirectory: String) -> [URL] {
        [CostUsageScanner.claudeCoworkRoot(homeDirectory: homeDirectory)]
    }

    /// The same sweep the cost scanner uses, so a Cowork transcript can
    /// never be counted for cost and missing from the session list.
    public func discoverSessionFiles(homeDirectory: String) -> [URL] {
        CostUsageScanner.collectClaudeCoworkJSONL(
            under: CostUsageScanner.claudeCoworkRoot(homeDirectory: homeDirectory)
        )
        .sorted { $0.path < $1.path }
    }

    // MARK: - Metadata

    public func extractMetadata(fileURL: URL) throws -> SessionSummary {
        try ClaudeSessionAdapter.summary(
            fileURL: fileURL,
            provider: .claudeCowork,
            harness: .claudeCowork
        )
    }

    // MARK: - Transcript

    public func parseTranscript(fileURL: URL, range: Range<Int>?) throws -> TranscriptDocument {
        try ClaudeSessionAdapter.transcript(fileURL: fileURL, range: range)
    }

    // MARK: - Deletion

    public func deletionPlan(for summary: SessionSummary, homeDirectory: String) throws -> SessionDeletionPlan {
        throw SessionDeleteError.providerIsReadOnly(.claudeCowork)
    }
}
