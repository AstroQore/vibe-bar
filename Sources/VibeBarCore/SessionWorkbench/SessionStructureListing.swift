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
        // The outline, not the turns: the sidecar keeps the outline, so a
        // fresh parse and a cached row read the same previews.
        self.firstPromptPreview = Self.firstPromptPreview(in: structure.outline.lazy.map(PromptCandidate.init(outline:)))
    }

    /// One turn as the fallback title reads it.
    public struct PromptCandidate: Sendable, Hashable {
        public var preview: String?
        public var origin: SessionStructure.PromptOrigin?
        public var status: SessionStructure.TurnStatus?

        public init(preview: String?, origin: SessionStructure.PromptOrigin?, status: SessionStructure.TurnStatus?) {
            self.preview = preview
            self.origin = origin
            self.status = status
        }

        public init(outline: SessionTurnOutline) {
            self.init(preview: outline.promptPreview, origin: outline.origin, status: outline.status)
        }
    }

    /// The fallback title's source, on one rule for a fresh parse and a
    /// sidecar row: over every turn not rewound away (`abandoned`), the
    /// first prompt the person typed that has a preview, else the first
    /// prompt of any origin that has one.
    public static func firstPromptPreview<Turns: Sequence>(in turns: Turns) -> String? where Turns.Element == PromptCandidate {
        var fallback: String?
        for turn in turns where turn.status != .abandoned {
            guard let preview = turn.preview, !preview.isEmpty else { continue }
            if turn.origin == .human { return preview }
            if fallback == nil { fallback = preview }
        }
        return fallback
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
