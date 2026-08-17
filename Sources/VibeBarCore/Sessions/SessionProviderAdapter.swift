import Foundation

/// Failure modes shared by every adapter's read paths.
public enum SessionParseError: Error, Hashable, Sendable {
    /// The file could not be opened or contained nothing usable.
    case unreadable(String)
    /// The file was readable but is not a session of this provider's
    /// shape — a rollout whose filename id contradicts its header, a
    /// Grok summary sitting in a directory named after a different
    /// session, and so on. Discovery treats this as "skip", not "fail".
    case invalidFormat(String)
}

extension SessionParseError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case let .unreadable(detail): return "Unreadable session file: \(detail)"
        case let .invalidFormat(detail): return "Unrecognized session file: \(detail)"
        }
    }
}

/// One file-based CLI's view of its own session store.
///
/// Every method is deliberately per-file and side-effect free so an
/// indexer can fan out across providers, and so a second stage can add
/// a provider (AntiGravity) or a consumer (a full-text index) without
/// touching the existing adapters.
///
/// `homeDirectory` is threaded through the discovery methods rather
/// than captured, matching `CostUsageScanner`: tests point it at a
/// synthetic temp tree, production leaves it at `RealHomeDirectory.path`.
public protocol SessionProviderAdapter: Sendable {
    var provider: SessionProvider { get }

    /// Directories this provider owns. Also the containment fence the
    /// deleter checks every removal target against, so a root must
    /// never be broader than the provider's own session store.
    func roots(homeDirectory: String) -> [URL]

    /// Session files under `roots`. Missing directories yield `[]`;
    /// symlinks are skipped.
    func discoverSessionFiles(homeDirectory: String) -> [URL]

    /// Cheap metadata for a list row. Reads only the head / tail of
    /// large files and never throws on individual malformed lines.
    func extractMetadata(fileURL: URL) throws -> SessionSummary

    /// Full transcript, optionally sliced by message index.
    func parseTranscript(fileURL: URL, range: Range<Int>?) throws -> TranscriptDocument

    /// What removing this session means on disk, plus the inputs the
    /// deleter re-asserts before it removes anything.
    func deletionPlan(for summary: SessionSummary, homeDirectory: String) throws -> SessionDeletionPlan
}

public extension SessionProviderAdapter {
    func parseTranscript(fileURL: URL) throws -> TranscriptDocument {
        try parseTranscript(fileURL: fileURL, range: nil)
    }

    /// Discover + describe in one pass, dropping files that do not
    /// parse. Adapters that reject a file (`invalidFormat`) drop out
    /// here rather than failing the whole sweep.
    func discoverSessions(homeDirectory: String) -> [SessionSummary] {
        discoverSessionFiles(homeDirectory: homeDirectory).compactMap {
            try? extractMetadata(fileURL: $0)
        }
    }
}

/// Provider → adapter lookup, with a stable iteration order.
public struct SessionProviderRegistry: Sendable {
    public let adapters: [any SessionProviderAdapter]
    private let byProvider: [SessionProvider: any SessionProviderAdapter]

    public init(adapters: [any SessionProviderAdapter]) {
        self.adapters = adapters
        var map: [SessionProvider: any SessionProviderAdapter] = [:]
        for adapter in adapters where map[adapter.provider] == nil {
            map[adapter.provider] = adapter
        }
        self.byProvider = map
    }

    /// The adapters shipped today, one per `SessionProvider`.
    ///
    /// AntiGravity, Claude Cowork, and Cursor list and read like the rest but
    /// refuse to plan a delete, because another running app owns those stores
    /// — see `SessionProvider.supportsDeletion`.
    public static func standard(homeDirectory: String = RealHomeDirectory.path) -> SessionProviderRegistry {
        SessionProviderRegistry(adapters: [
            ClaudeSessionAdapter(),
            ClaudeCoworkSessionAdapter(),
            CodexSessionAdapter(homeDirectory: homeDirectory),
            GrokSessionAdapter(),
            CursorSessionAdapter(),
            GeminiSessionAdapter(),
            AntigravitySessionAdapter()
        ])
    }

    public func adapter(for provider: SessionProvider) -> (any SessionProviderAdapter)? {
        byProvider[provider]
    }

    public var providers: [SessionProvider] { adapters.map(\.provider) }
}
