import Foundation

/// A CLI whose local session logs Vibe Bar can list, read, resume, and
/// (on explicit request) delete.
///
/// `antigravity` is listed and readable like the rest, but its sessions
/// cannot be deleted: the CLI and IDE hold live SQLite handles on the
/// conversation databases, so its adapter fails closed with
/// `SessionDeleteError.unsupportedProvider`.
public enum SessionProvider: String, Codable, Sendable, CaseIterable, Hashable {
    case claude
    case codex
    case grok
    case gemini
    case antigravity

    public var displayName: String {
        switch self {
        case .claude: return "Claude Code"
        case .codex: return "Codex"
        case .grok: return "Grok"
        case .gemini: return "Gemini CLI"
        case .antigravity: return "AntiGravity"
        }
    }
}

/// One discovered session, described well enough to render a row and
/// act on it without reopening the transcript.
public struct SessionSummary: Identifiable, Hashable, Codable, Sendable {
    /// `messageCount` value used when counting would have required
    /// reading a large file during metadata extraction.
    public static let unknownMessageCount = -1

    public let provider: SessionProvider
    public let sessionID: String
    /// Provider-specific flavor (AntiGravity's `cli` vs IDE surface, for
    /// instance). `nil` when the provider has exactly one shape.
    public let providerVariant: String?
    public let title: String?
    public let summary: String?
    public let projectDir: String?
    public let createdAt: Date?
    public let lastActiveAt: Date?
    /// Canonical on-disk origin. Part of `id` because the same session
    /// id can legitimately appear under two roots (Claude's
    /// `~/.claude` and `~/.config/claude`).
    public let sourcePath: String
    public let sizeBytes: Int64
    public let messageCount: Int

    public var id: String { "\(provider.rawValue):\(sessionID):\(sourcePath)" }

    public var hasKnownMessageCount: Bool { messageCount >= 0 }

    public init(
        provider: SessionProvider,
        sessionID: String,
        providerVariant: String? = nil,
        title: String? = nil,
        summary: String? = nil,
        projectDir: String? = nil,
        createdAt: Date? = nil,
        lastActiveAt: Date? = nil,
        sourcePath: String,
        sizeBytes: Int64 = 0,
        messageCount: Int = SessionSummary.unknownMessageCount
    ) {
        self.provider = provider
        self.sessionID = sessionID
        self.providerVariant = providerVariant
        self.title = title
        self.summary = summary
        self.projectDir = projectDir
        self.createdAt = createdAt
        self.lastActiveAt = lastActiveAt
        self.sourcePath = sourcePath
        self.sizeBytes = sizeBytes
        self.messageCount = messageCount
    }

    /// Copy with a hydrated title / project directory. Codex resolves
    /// both from a side index after the per-file pass.
    public func withTitle(_ newTitle: String?, projectDir newProjectDir: String? = nil) -> SessionSummary {
        SessionSummary(
            provider: provider,
            sessionID: sessionID,
            providerVariant: providerVariant,
            title: newTitle ?? title,
            summary: summary,
            projectDir: newProjectDir ?? projectDir,
            createdAt: createdAt,
            lastActiveAt: lastActiveAt,
            sourcePath: sourcePath,
            sizeBytes: sizeBytes,
            messageCount: messageCount
        )
    }
}

public enum SessionSummaryOrder: String, Sendable, Hashable {
    case recentFirst
    case oldestFirst
    case byProject
}

/// A bounded window from the session index. The Workbench renders one page at
/// a time instead of publishing every historical session into SwiftUI.
public struct SessionSummaryPage: Sendable, Equatable {
    public let summaries: [SessionSummary]
    public let totalCount: Int
    public let offset: Int
    public let limit: Int

    public init(summaries: [SessionSummary], totalCount: Int, offset: Int, limit: Int) {
        self.summaries = summaries
        self.totalCount = totalCount
        self.offset = offset
        self.limit = limit
    }
}

public enum SessionRole: String, Codable, Sendable, CaseIterable, Hashable {
    case user
    case assistant
    case tool
    case system
    case other
}

public struct SessionMessage: Identifiable, Hashable, Codable, Sendable {
    /// Zero-based position among the messages the adapter kept.
    public let seq: Int
    public let role: SessionRole
    public let text: String
    public let timestamp: Date?

    public var id: Int { seq }

    public init(seq: Int, role: SessionRole, text: String, timestamp: Date?) {
        self.seq = seq
        self.role = role
        self.text = text
        self.timestamp = timestamp
    }
}

public struct TranscriptDocument: Hashable, Codable, Sendable {
    public let messages: [SessionMessage]
    /// Count before any `range` slice, so a paging UI knows the extent.
    public let totalMessageCount: Int
    public let truncated: Bool

    public init(messages: [SessionMessage], totalMessageCount: Int, truncated: Bool) {
        self.messages = messages
        self.totalMessageCount = totalMessageCount
        self.truncated = truncated
    }

    public static let empty = TranscriptDocument(messages: [], totalMessageCount: 0, truncated: false)
}

/// A delete described as data, not as a closure.
///
/// The plan carries both what to remove and what the deleter must
/// re-assert immediately before removing it: re-parse
/// `validationSourcePath` and require the session id to still be
/// `expectedSessionID`. Keeping the re-assertion inputs in the plan
/// means a plan can be built, shown to the user, and executed later
/// without the executor trusting the stale summary it came from.
public struct SessionDeletionPlan: Hashable, Codable, Sendable {
    public let provider: SessionProvider
    public let pathsToRemove: [String]
    /// File the deleter re-parses to confirm identity. Must itself be
    /// inside one of the provider roots.
    public let validationSourcePath: String
    public let expectedSessionID: String

    public init(
        provider: SessionProvider,
        pathsToRemove: [String],
        validationSourcePath: String,
        expectedSessionID: String
    ) {
        self.provider = provider
        self.pathsToRemove = pathsToRemove
        self.validationSourcePath = validationSourcePath
        self.expectedSessionID = expectedSessionID
    }
}

public enum SessionDeleteError: Error, Hashable, Codable, Sendable {
    /// No adapter can plan a delete for this provider.
    case unsupportedProvider
    /// A path in the plan resolves outside every provider root.
    case pathEscapesProviderRoot
    /// The removal target is itself a symlink; following it would
    /// delete something the provider never wrote.
    case symlinkedTarget
    /// Re-parsing the validation file produced a different session id.
    case sessionIDMismatch
    /// The validation file could not be re-parsed at all.
    case validationUnreadable
    case removalFailed(String)

    public var message: String {
        switch self {
        case .unsupportedProvider:
            return "Deleting sessions is not supported for this provider."
        case .pathEscapesProviderRoot:
            return "Refused: the target resolves outside the provider's session directory."
        case .symlinkedTarget:
            return "Refused: the target is a symbolic link."
        case .sessionIDMismatch:
            return "Refused: the file on disk no longer matches this session."
        case .validationUnreadable:
            return "Refused: the session file could not be re-read for verification."
        case let .removalFailed(reason):
            return "Removal failed: \(reason)"
        }
    }
}

extension SessionDeleteError: LocalizedError {
    public var errorDescription: String? { message }
}

public struct SessionDeleteOutcome: Hashable, Sendable {
    public let summary: SessionSummary
    public let success: Bool
    public let failureReason: SessionDeleteError?

    public init(summary: SessionSummary, success: Bool, failureReason: SessionDeleteError?) {
        self.summary = summary
        self.success = success
        self.failureReason = failureReason
    }

    public static func succeeded(_ summary: SessionSummary) -> SessionDeleteOutcome {
        SessionDeleteOutcome(summary: summary, success: true, failureReason: nil)
    }

    public static func failed(_ summary: SessionSummary, _ reason: SessionDeleteError) -> SessionDeleteOutcome {
        SessionDeleteOutcome(summary: summary, success: false, failureReason: reason)
    }
}
