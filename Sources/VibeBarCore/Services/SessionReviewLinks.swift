import Foundation

/// Which index rows are sessions of their own, and how the rest attach.
///
/// Codex writes every Auto Review ("guardian") pass as a rollout of its own,
/// and the kit tags those rows `providerVariant = "auto-review:<parent>"`.
/// They are not sessions a person started: the Sessions page folds them into
/// the session they reviewed, and an agent asking `sessions.list` for "what
/// was worked on" should get the same answer. That rule used to be spelled
/// out at each call site — the Workbench passed the exclusion, the MCP tools
/// did not, and an agent saw thousands of review rows the page hid.
///
/// Everything that lists or searches the index goes through here, so the
/// Workbench and the MCP surface cannot disagree about what a row is.
public enum SessionVisibleRows {
    /// Rows whose `providerVariant` starts with this are Auto Review
    /// children. The exact predicate `SessionIndexStore.summaryPage`
    /// applies in SQL when it is handed this prefix.
    public static let hiddenVariantPrefix = CodexSessionAdapter.autoReviewVariantPrefix

    /// True when a row is listed as a session of its own. Mirrors the SQL
    /// exclusion in `page` exactly, so a host-side check of an index row can
    /// never disagree with the page it came from.
    public static func isListed(_ summary: SessionSummary) -> Bool {
        !(summary.providerVariant?.hasPrefix(hiddenVariantPrefix) ?? false)
    }

    /// The session an Auto Review row belongs to, or `nil` for anything else.
    ///
    /// Also `nil` for a row that names *itself* — see `isSelfLinkedReview`:
    /// a row cannot be folded into itself.
    public static func reviewParentID(of summary: SessionSummary) -> String? {
        guard summary.provider == .codex,
              let parent = CodexSessionAdapter.autoReviewParentSessionID(providerVariant: summary.providerVariant),
              parent.caseInsensitiveCompare(summary.sessionID) != .orderedSame
        else { return nil }
        return parent
    }

    /// An Auto Review row the kit linked to itself.
    ///
    /// Codex before 0.142 wrote the guardian's own id into
    /// `session_meta.session_id`. `CodexReviewLinkRepair` rewrites those rows
    /// at index time, and `SessionIndexReparse` v2 has them re-read — but a
    /// row indexed before that stays in this shape until the re-read lands.
    /// Until then it is still a review, not a session: hidden from the list by
    /// the same SQL exclusion as any other, and dropped from search by `fold`,
    /// so neither the Sessions page nor an agent sees it as a row of its own.
    public static func isSelfLinkedReview(_ summary: SessionSummary) -> Bool {
        guard summary.provider == .codex,
              let parent = CodexSessionAdapter.autoReviewParentSessionID(providerVariant: summary.providerVariant)
        else { return false }
        return parent.caseInsensitiveCompare(summary.sessionID) == .orderedSame
    }

    // MARK: - Listing

    /// One page of listed sessions. Every product list read goes through
    /// this — the Workbench page, its label scan, and `sessions.list` — so
    /// the Auto Review exclusion is applied in SQL, where `totalCount` and
    /// paging stay exact, rather than filtered out of a page afterwards.
    public static func page(
        _ index: SessionIndexService,
        providers: [SessionProvider]? = nil,
        harnesses: [Harness]? = nil,
        since: Date? = nil,
        projectIncludes: [String] = [],
        projectExcludes: [String] = [],
        order: SessionSummaryOrder = .recentFirst,
        offset: Int = 0,
        limit: Int = 250
    ) async throws -> SessionSummaryPage {
        try await index.summaryPage(
            providers: providers,
            harnesses: harnesses,
            since: since,
            projectIncludes: projectIncludes,
            projectExcludes: projectExcludes,
            excludingProviderVariantPrefix: hiddenVariantPrefix,
            order: order,
            offset: offset,
            limit: limit
        )
    }

    // MARK: - Searching

    /// One search hit after folding: the listed row it lands on, and — when
    /// the text matched inside one of that row's Auto Reviews — which one.
    ///
    /// `hit.matchedSeq` is kept as the index reported it, so it counts
    /// messages of `matchedReview` when that is set, not of `hit.summary`.
    /// The Workbench translates it into the merged transcript; the MCP
    /// surface hands it out next to the review's own id.
    public struct FoldedHit: Sendable, Hashable {
        public let hit: SessionSearchHit
        public let matchedReview: SessionSummary?

        public init(hit: SessionSearchHit, matchedReview: SessionSummary?) {
            self.hit = hit
            self.matchedReview = matchedReview
        }
    }

    public struct SearchResult: Sendable {
        /// Folded and deduplicated, in the index's ranking order.
        public let hits: [FoldedHit]
        /// How many hits the index returned before folding. A caller that
        /// pages on "fewer than asked for means there are no more" must
        /// compare against this, because folding merges several hits into one.
        public let rankedCount: Int
    }

    /// Parent ids the hits need resolved, deduplicated in first-seen order.
    public static func reviewParentIDs(in hits: [SessionSearchHit]) -> [String] {
        var seen: Set<String> = []
        var out: [String] = []
        for hit in hits {
            guard let parent = reviewParentID(of: hit.summary), seen.insert(parent).inserted else { continue }
            out.append(parent)
        }
        return out
    }

    /// Replace every Auto Review hit with the row it belongs to.
    ///
    /// A parent that is not in the index (its rollout was removed outside
    /// Vibe Bar) leaves the review standing as a row of its own: that file is
    /// the only record left of the work, and a search that silently drops it
    /// cannot be told apart from one that found nothing. A self-linked review
    /// (`isSelfLinkedReview`) is dropped instead: it is waiting on the re-read
    /// that gives it a parent or makes it a session, and what it will become
    /// is not knowable from the row. A row reached twice — the parent and one
    /// of its reviews both matched — is kept once, at its best rank.
    public static func fold(
        _ hits: [SessionSearchHit],
        parents: [String: SessionSummary]
    ) -> [FoldedHit] {
        var out: [FoldedHit] = []
        var seen: Set<String> = []
        out.reserveCapacity(hits.count)
        for hit in hits {
            if isSelfLinkedReview(hit.summary) { continue }
            if let parentID = reviewParentID(of: hit.summary),
               let parent = parents[parentID],
               isListed(parent) {
                guard seen.insert(parent.id).inserted else { continue }
                out.append(FoldedHit(
                    hit: SessionSearchHit(summary: parent, snippet: hit.snippet, matchedSeq: hit.matchedSeq),
                    matchedReview: hit.summary
                ))
            } else {
                guard seen.insert(hit.summary.id).inserted else { continue }
                out.append(FoldedHit(hit: hit, matchedReview: nil))
            }
        }
        return out
    }

    /// Look the parents up, one exact-row query each. Cancellation is
    /// checked per id so an abandoned search stops paying immediately.
    public static func resolveParents(
        _ index: SessionIndexService,
        ids: [String]
    ) async -> [String: SessionSummary] {
        var out: [String: SessionSummary] = [:]
        for id in ids {
            guard !Task.isCancelled else { break }
            if let parent = try? await index.summary(provider: .codex, sessionID: id) {
                out[id] = parent
            }
        }
        return out
    }

    /// Full-text search, folded. What `sessions.search` runs; the Workbench
    /// runs the same three steps with a per-generation parent cache between
    /// them.
    public static func search(
        _ index: SessionIndexService,
        query: String,
        providers: [SessionProvider]? = nil,
        harnesses: [Harness]? = nil,
        scopes: Set<SessionSearchScope> = SessionSearchScope.defaultScopes,
        projectIncludes: [String] = [],
        projectExcludes: [String] = [],
        limit: Int = 50
    ) async throws -> SearchResult {
        let ranked = try await index.search(
            query,
            providers: providers,
            harnesses: harnesses,
            scopes: scopes,
            projectIncludes: projectIncludes,
            projectExcludes: projectExcludes,
            limit: limit
        )
        let parents = await resolveParents(index, ids: reviewParentIDs(in: ranked))
        return SearchResult(hits: fold(ranked, parents: parents), rankedCount: ranked.count)
    }
}

// MARK: - Index-time repair

/// Points an old guardian rollout at the session it actually reviewed.
///
/// The kit links a guardian rollout through
/// `firstString(session_meta.session_id, session_meta.parent_thread_id)`.
/// From the Codex 0.142 release on, `session_id` names the root conversation
/// and that is right. Before it, `session_id` was the rollout's *own* id —
/// 0.137 through the 0.142 pre-releases recorded the real parent only in
/// `parent_thread_id`, and 0.124–0.136 recorded no parent at all. Those rows
/// came out as `auto-review:<self>`:
/// excluded from the list as a review, attached to no parent, so neither
/// visible nor deletable.
///
/// This runs on the indexing adapters only (`BoundedSessionAdapter`), after
/// the kit's own metadata pass, and only for a row in that self-linked
/// shape: it re-reads the rollout's `session_meta` and takes
/// `parent_thread_id` when there is one. When there is none the variant is
/// dropped, so the rollout becomes an ordinary listed session that the user
/// can open and delete — which is what it is, for want of anything to fold
/// it into. `SessionIndexReparse` v2 drops the cursors of rows indexed
/// before this existed, so they are read again once.
public enum CodexReviewLinkRepair {
    /// How much of the rollout head the header read may touch. The
    /// `session_meta` record carries the base instructions and runs to tens
    /// of kilobytes; this only stops a newline-free file from being read
    /// whole.
    static let headerByteLimit = 4 * 1024 * 1024

    public static func repaired(_ summary: SessionSummary, fileURL: URL) -> SessionSummary {
        guard summary.provider == .codex,
              let target = CodexSessionAdapter.autoReviewParentSessionID(providerVariant: summary.providerVariant),
              target.caseInsensitiveCompare(summary.sessionID) == .orderedSame
        else { return summary }
        let parent = parentThreadID(fileURL: fileURL).flatMap { candidate -> String? in
            candidate.caseInsensitiveCompare(summary.sessionID) == .orderedSame ? nil : candidate
        }
        return summary.replacingProviderVariant(
            parent.map { CodexSessionAdapter.autoReviewVariantPrefix + $0 }
        )
    }

    /// `session_meta.payload.parent_thread_id` of the first `session_meta`
    /// record in the head — the record the kit's own pass read.
    static func parentThreadID(fileURL: URL) -> String? {
        let head = JSONLHeadTail.headLines(url: fileURL, count: 10, maxBytes: headerByteLimit)
        for line in head {
            guard let object = SessionParsing.json(line),
                  object["type"] as? String == "session_meta"
            else { continue }
            let payload = object["payload"] as? [String: Any]
            return SessionParsing.string(payload?["parent_thread_id"])
        }
        return nil
    }
}

extension SessionSummary {
    /// The same row under another variant. Field-by-field because the kit's
    /// summary is immutable; a field the kit adds later takes its default
    /// here, which for this one rewrite (a guardian header) loses nothing.
    func replacingProviderVariant(_ variant: String?) -> SessionSummary {
        SessionSummary(
            provider: provider,
            sessionID: sessionID,
            providerVariant: variant,
            harness: harness,
            model: model,
            title: title,
            summary: summary,
            projectDir: projectDir,
            createdAt: createdAt,
            lastActiveAt: lastActiveAt,
            sourcePath: sourcePath,
            sizeBytes: sizeBytes,
            messageCount: messageCount
        )
    }
}

// MARK: - Deletion

/// What deleting a session takes with it.
///
/// An Auto Review rollout is part of the session it reviewed — the Sessions
/// page shows it inside that transcript and never as a row — so deleting
/// the session deletes its reviews too. Leaving them behind stranded them:
/// hidden from the list as reviews, attached to nothing, and holding the
/// bulk of the disk (they re-send the whole conversation each pass).
///
/// Every file still goes through `SessionDeleter`, review or not, so each
/// one gets the same containment, symlink and re-parsed-id checks.
public enum SessionDeletionCascade {
    public struct Plan: Sendable, Equatable {
        /// What the user picked, in the order they picked it.
        public let selected: [SessionSummary]
        /// Their Auto Reviews, oldest first, none of them also in `selected`.
        public let reviews: [SessionSummary]

        /// Bytes on disk of `reviews`, and of everything in the plan —
        /// summed once here, because a confirmation dialog reads them on
        /// every render.
        public let reviewBytes: Int64
        public let totalBytes: Int64

        public init(selected: [SessionSummary], reviews: [SessionSummary]) {
            self.selected = selected
            self.reviews = reviews
            let reviewBytes = reviews.reduce(Int64(0)) { $0 + max(0, $1.sizeBytes) }
            self.reviewBytes = reviewBytes
            self.totalBytes = selected.reduce(reviewBytes) { $0 + max(0, $1.sizeBytes) }
        }

        /// Every file the plan names, reviews first — the order `execute`
        /// works in.
        public var all: [SessionSummary] { reviews + selected }
        public var count: Int { selected.count + reviews.count }
    }

    /// Carry out `plan`: every review first, then each selected session
    /// whose reviews all went.
    ///
    /// A review that fails a safety check or its removal keeps its session:
    /// deleting the session anyway would leave that review hidden (it is
    /// still a review) and attached to nothing — the stranded state this
    /// cascade exists to prevent. The kept session is reported as failed with
    /// the review's own reason, so what stayed, and why, reaches the user
    /// alongside the review that stayed with it. `delete` is
    /// `SessionDeleter.delete` in the app; it is called at most twice, with
    /// the reviews and then with the sessions cleared to go.
    public static func execute(
        _ plan: Plan,
        delete: ([SessionSummary]) -> [SessionDeleteOutcome]
    ) -> [SessionDeleteOutcome] {
        let reviewOutcomes = plan.reviews.isEmpty ? [] : delete(plan.reviews)
        var reasons: [String: SessionDeleteError] = [:]
        for outcome in reviewOutcomes where !outcome.success {
            reasons[outcome.summary.id] = outcome.failureReason
        }
        let removed = Set(reviewOutcomes.filter(\.success).map(\.summary.id))
        // Any review not reported removed blocks its session — including one
        // the deleter returned no outcome for at all.
        var blocked: [String: SessionDeleteError] = [:]
        for review in plan.reviews where !removed.contains(review.id) {
            guard let parent = SessionVisibleRows.reviewParentID(of: review), blocked[parent] == nil else {
                continue
            }
            blocked[parent] = reasons[review.id] ?? .validationUnreadable
        }
        var cleared: [SessionSummary] = []
        var kept: [SessionDeleteOutcome] = []
        for target in plan.selected {
            if target.provider == .codex,
               SessionVisibleRows.reviewParentID(of: target) == nil,
               let reason = blocked[target.sessionID] {
                kept.append(.failed(target, reason))
            } else {
                cleared.append(target)
            }
        }
        let selectedOutcomes = cleared.isEmpty ? [] : delete(cleared)
        return reviewOutcomes + kept + selectedOutcomes
    }

    /// Sessions among `targets` whose reviews go with them: deletable Codex
    /// rows that are not reviews themselves (a review has none of its own).
    public static func parentIDs(of targets: [SessionSummary]) -> [String] {
        var seen: Set<String> = []
        var out: [String] = []
        for target in targets
        where target.provider == .codex
            && target.provider.supportsDeletion
            && SessionVisibleRows.reviewParentID(of: target) == nil {
            guard seen.insert(target.sessionID).inserted else { continue }
            out.append(target.sessionID)
        }
        return out
    }

    /// Fold the reviews the index returned into a plan. Only reviews whose
    /// parent is among `selected` are taken, and each file at most once —
    /// a review the user also ticked by hand (reachable through search) is
    /// counted with the selection, not twice.
    public static func plan(
        selected: [SessionSummary],
        reviews candidates: [SessionSummary]
    ) -> Plan {
        let parents = Set(parentIDs(of: selected))
        var seen = Set(selected.map(\.id))
        var reviews: [SessionSummary] = []
        for review in candidates {
            guard let parent = SessionVisibleRows.reviewParentID(of: review),
                  parents.contains(parent),
                  seen.insert(review.id).inserted
            else { continue }
            reviews.append(review)
        }
        return Plan(selected: selected, reviews: reviews)
    }

    /// Ceiling on reviews one deletion collects. A single session has a few
    /// hundred at the very most; the cap only keeps a pathological selection
    /// from turning the confirmation into an unbounded read.
    public static let reviewLimit = 20_000

    /// The plan for `selected`, with its reviews read from `reviewIndex`.
    /// A review index that cannot answer yields a plan without reviews —
    /// the selection itself is still the user's to delete.
    public static func plan(
        selected: [SessionSummary],
        reviewIndex: SessionReviewIndex
    ) async -> Plan {
        let parents = parentIDs(of: selected)
        guard !parents.isEmpty else { return Plan(selected: selected, reviews: []) }
        do {
            let reviews = try await reviewIndex.reviews(forParents: parents, limit: reviewLimit)
            if reviews.count >= reviewLimit {
                SafeLog.warn("Session delete: Auto Review lookup stopped at \(reviewLimit) rows")
            }
            return plan(selected: selected, reviews: reviews)
        } catch {
            SafeLog.warn("Session delete: Auto Review lookup failed; deleting the selection alone")
            return Plan(selected: selected, reviews: [])
        }
    }
}
