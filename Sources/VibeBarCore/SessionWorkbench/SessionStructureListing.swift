import Foundation

/// What one Sessions-list row borrows from the structure parse: the
/// session's stats (tokens, cost, kind, parent) and the preview of its first
/// prompt, the fallback title for a session that never got one.
public struct SessionStructureListing: Sendable, Hashable {
    public var stats: SessionStats
    public var firstPromptPreview: String?

    public init(stats: SessionStats, firstPromptPreview: String?) {
        self.stats = stats
        self.firstPromptPreview = firstPromptPreview
    }

    public init(structure: SessionStructure) {
        self.stats = structure.stats
        let live = structure.turns.filter { $0.status != .abandoned }
        let human = live.first { $0.prompt.origin == .human && !($0.prompt.preview ?? "").isEmpty }
        let any = live.first { !($0.prompt.preview ?? "").isEmpty }
        self.firstPromptPreview = (human ?? any)?.prompt.preview
    }

    /// The best title the parse can offer: the session's own, then its
    /// first prompt. Nil when it has neither.
    public var title: String? {
        if let title = stats.title?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty { return title }
        if let preview = firstPromptPreview?.trimmingCharacters(in: .whitespacesAndNewlines), !preview.isEmpty {
            return preview
        }
        return nil
    }

    /// Tokens worth showing: zero, and the "unknown" of a cut session, are
    /// both absent.
    public var displayTokens: Int? {
        guard stats.usageSource != .unavailable, stats.usageSource != .none, stats.totalTokens > 0 else { return nil }
        return stats.totalTokens
    }

    /// Whether the session is a thread of another one (or a headless run),
    /// which the list folds rather than lists.
    public var isThread: Bool {
        SessionThreadTree.nestedKinds.contains(stats.kind) || SessionThreadTree.filteredKinds.contains(stats.kind)
    }
}

/// One row of `SessionStructureStore.threadKindCounts()`.
public struct SessionThreadKindCount: Sendable, Hashable {
    public var provider: SessionProvider
    public var originator: String?
    public var kind: SessionStructureKind
    public var count: Int

    public init(provider: SessionProvider, originator: String?, kind: SessionStructureKind, count: Int) {
        self.provider = provider
        self.originator = originator
        self.kind = kind
        self.count = count
    }
}

/// Where a listed session ran, for rows that did not come from a local
/// transcript alone. Every row today is `.local` and carries none (`nil`);
/// the Sessions list keeps a slot for it so a cloud-controlled or cloud-run
/// session, or a delegated Codex task with no transcript of its own, can
/// join the list as a row with its own badge and link rather than as a new
/// kind of list.
public enum SessionRowOrigin: String, Sendable, Hashable, CaseIterable {
    case local
    /// Run locally, steered from a cloud surface.
    case cloudControlled
    /// Run on the provider's servers; the local store is a cache or nothing.
    case cloudRun
    /// Handed off to another agent (a Codex dot task) — possibly no
    /// transcript on this Mac at all.
    case delegated
}
