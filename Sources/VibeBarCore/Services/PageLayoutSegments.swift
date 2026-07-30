import Foundation

/// Ordered groups a page's cards flow through, in every mode.
///
/// `PageLayoutMode.compact` asks `PageLayoutPacker` for the shortest two-column
/// arrangement of a whole page, and the shortest page is free to slot an
/// analytics card between two quota cards. That is exactly what a user who
/// wants "my quotas together, packed as tight as they go, everything else
/// below" does not want. Segments put that grouping back under the user's
/// control without giving up the packing: inside a segment the packer is still
/// free, across segments the reading order is fixed.
///
/// A segment is a **vertical ordering constraint, not a horizontal band**: every
/// card in segment *k* renders above every card in segment *k+1* within its own
/// column, and the two columns are never made to line up at the boundary. That
/// distinction is the whole feature — bands used to make the shorter column wait
/// for the taller one, which drew a visible hole at every boundary.
///
/// All three modes obey the ordering: `compact` packs the segments as a relay,
/// `auto` plans them in order, and `manual` stable-sorts its saved columns by
/// segment index.
///
/// Segments live *beside* `PageLayoutConfig.columns`, never inside it:
/// `PageLayoutConfig.normalized` folds every column past the second into the
/// last one and dedupes globally, which would flatten any structure stored
/// there into two flat columns.
public enum PageLayoutSegments {
    /// Most segments one page may hold. A segment the user cannot tell apart
    /// from its neighbour is worse than no segment, and the cap also keeps a
    /// hand-edited settings file from asking the editor to draw fifty headers.
    public static let maximumCount = 6

    /// One module as the segmenter sees it: an identity plus the family it
    /// belongs to, which is what the default segmentation groups by.
    public struct Module: Hashable, Sendable {
        public let id: PageLayoutModuleID
        public let phase: OverviewMasonryPlanner.Phase

        public init(id: PageLayoutModuleID, phase: OverviewMasonryPlanner.Phase) {
            self.id = id
            self.phase = phase
        }
    }

    /// Phases that share a segment in the Overview's default segmentation: the
    /// pinned summary header, then the quota cards packed among themselves,
    /// then cost together with the analytics derived from it.
    ///
    /// This is the answer to the complaint segments exist for — a user who
    /// picks Compact on the Overview gets a minimal-height quota block without
    /// having to arrange anything.
    static let overviewPhaseGroups: [[OverviewMasonryPlanner.Phase]] = [
        [.summary],
        [.quota],
        [.cost, .auxiliary]
    ]

    /// Segmentation a page gets when the user has not chosen one.
    ///
    /// Provider pages are a single segment: every mode there keeps meaning
    /// exactly what it always meant, one arrangement of the whole page.
    public static func defaultSegments(
        modules: [Module],
        page: PageLayoutPageID
    ) -> [[PageLayoutModuleID]] {
        guard page.isOverview else { return normalized([modules.map(\.id)]) }
        return normalized(
            overviewPhaseGroups.map { group in
                modules.filter { group.contains($0.phase) }.map(\.id)
            }
        )
    }

    /// Drops empty identifiers and empty segments, collapses an identifier that
    /// appears in more than one segment onto its first occurrence, and folds
    /// segments past `maximumCount` into the last one.
    ///
    /// Identifiers this build does not recognize are preserved verbatim, for the
    /// same reason `PageLayoutModuleID` is a string wrapper: a segment written
    /// by a newer build has to survive a downgrade's round trip rather than
    /// being quietly dropped from the user's arrangement.
    public static func normalized(_ segments: [[PageLayoutModuleID]]) -> [[PageLayoutModuleID]] {
        var result: [[PageLayoutModuleID]] = []
        var seen = Set<PageLayoutModuleID>()
        for segment in segments {
            var group: [PageLayoutModuleID] = []
            for moduleID in segment where !moduleID.rawValue.isEmpty {
                guard seen.insert(moduleID).inserted else { continue }
                group.append(moduleID)
            }
            guard !group.isEmpty else { continue }
            if result.count < maximumCount {
                result.append(group)
            } else {
                result[result.count - 1].append(contentsOf: group)
            }
        }
        return result
    }

    /// Segment membership to render right now: the saved segments reconciled
    /// against the modules the page can actually draw this pass.
    ///
    /// - Saved segments with no chosen segmentation (`stored` empty) fall back
    ///   to `defaultSegments`, which is what every page did before segments
    ///   existed.
    /// - A saved module the page cannot draw is left out of the result. It stays
    ///   in the *saved* segments — see `mergingEdit`.
    /// - A module the saved segments have never seen joins the one its family
    ///   defaults to, clamped into range: a page saved with fewer segments than
    ///   the default has nowhere else to put it.
    /// - A segment whose cards have all gone is not drawn.
    ///
    /// Every available module appears exactly once in the result.
    public static func resolve(
        stored: [[PageLayoutModuleID]],
        available: [PageLayoutModuleID],
        defaultSegments: [[PageLayoutModuleID]]
    ) -> [[PageLayoutModuleID]] {
        var availableSet = Set<PageLayoutModuleID>()
        var orderedAvailable: [PageLayoutModuleID] = []
        for moduleID in available
        where !moduleID.rawValue.isEmpty && availableSet.insert(moduleID).inserted {
            orderedAvailable.append(moduleID)
        }

        let defaults = normalized(defaultSegments)
        var defaultIndex: [PageLayoutModuleID: Int] = [:]
        for (index, group) in defaults.enumerated() {
            for moduleID in group { defaultIndex[moduleID] = index }
        }

        let base = normalized(stored.isEmpty ? defaults : stored)
        var segments = base.map { $0.filter(availableSet.contains) }
        guard !segments.isEmpty else {
            return orderedAvailable.isEmpty ? [] : [orderedAvailable]
        }

        var placed = Set(segments.flatMap { $0 })
        for moduleID in orderedAvailable where !placed.contains(moduleID) {
            let target = min(defaultIndex[moduleID] ?? segments.count - 1, segments.count - 1)
            segments[target].append(moduleID)
            placed.insert(moduleID)
        }
        return normalized(segments)
    }

    /// Where each module sits in the segment order. A module no segment claims
    /// ranks after every one that is claimed, so it sorts to the end rather than
    /// jumping to the front.
    public static func ordering(
        _ segments: [[PageLayoutModuleID]]
    ) -> [PageLayoutModuleID: Int] {
        var result: [PageLayoutModuleID: Int] = [:]
        for (index, segment) in segments.enumerated() {
            for moduleID in segment where result[moduleID] == nil {
                result[moduleID] = index
            }
        }
        return result
    }

    /// Re-order hand-arranged columns so they obey the segmentation.
    ///
    /// This is what makes `manual` honour segments without taking the drag
    /// editor away from it: the user still decides which column a card is in and
    /// where among its own segment-mates it sits, and the segmentation decides
    /// which block of the column that is. The sort is stable, so the relative
    /// order the user dragged *within* a segment is preserved exactly.
    public static func sortedColumns(
        _ columns: [[PageLayoutModuleID]],
        segments: [[PageLayoutModuleID]]
    ) -> [[PageLayoutModuleID]] {
        guard segments.count > 1 else { return columns }
        let rank = ordering(segments)
        let unsegmented = segments.count
        return columns.map { column in
            column.enumerated()
                .sorted { lhs, rhs in
                    let lhsRank = rank[lhs.element] ?? unsegmented
                    let rhsRank = rank[rhs.element] ?? unsegmented
                    return lhsRank == rhsRank ? lhs.offset < rhs.offset : lhsRank < rhsRank
                }
                .map(\.element)
        }
    }

    /// Fold an edit made against the *resolved* segments back into the *saved*
    /// ones, without forgetting modules the page cannot draw right now.
    ///
    /// The same contract `PageLayoutResolver.mergingEdit` gives the columns, and
    /// for the same reason: the editor can only drag what is on screen, so
    /// persisting its output verbatim would erase the segment of every module
    /// that happened to be missing — a quota group before the first refresh, the
    /// cost cards before any session log is found, a card the user switched off
    /// — and moving one card would silently reset the rest of the page.
    ///
    /// An off-screen module follows its surviving segment-mates — the user
    /// dragged (or left) the segment, and the module belongs to it wherever it
    /// went. A segment whose every module is off screen has no mate to follow
    /// and is re-created where it was saved, next to its nearest surviving
    /// stored neighbour: clamping it into the last visible segment instead would
    /// collapse the saved grouping the first time the user dragged anything
    /// else, and the module would come back in the wrong place. Only an explicit
    /// reset forgets a page.
    ///
    /// A module `edited` names explicitly is always honoured, available or not —
    /// which is how the editor moves a switched-off card, the one off-screen
    /// case it can actually see and drag.
    public static func mergingEdit(
        _ edited: [[PageLayoutModuleID]],
        into stored: [[PageLayoutModuleID]],
        available: [PageLayoutModuleID]
    ) -> [[PageLayoutModuleID]] {
        let availableSet = Set(available)
        var segments = normalized(edited)
        let storedSegments = normalized(stored)
        guard !segments.isEmpty else { return storedSegments }

        var editedIndex: [PageLayoutModuleID: Int] = [:]
        for (index, group) in segments.enumerated() {
            for moduleID in group { editedIndex[moduleID] = index }
        }

        // Segments that lost every module to unavailability, queued for
        // re-insertion after the segment holding their nearest preceding stored
        // anchor. The user may have reordered them, so positions are not
        // necessarily monotone in stored order — a stable sort by position
        // (stored order as the tie-break) makes the offset insertion exact.
        var pending: [(position: Int, orphans: [PageLayoutModuleID])] = []
        var lastAnchoredPosition = -1
        for group in storedSegments {
            let offScreen = group.filter { !availableSet.contains($0) && editedIndex[$0] == nil }
            if let anchor = group.first(where: { editedIndex[$0] != nil }) {
                let anchorIndex = editedIndex[anchor]!
                lastAnchoredPosition = anchorIndex
                guard !offScreen.isEmpty else { continue }
                segments[anchorIndex].append(contentsOf: offScreen)
            } else if !offScreen.isEmpty {
                pending.append((position: lastAnchoredPosition + 1, orphans: offScreen))
            }
        }
        let ordered = pending.enumerated().sorted {
            ($0.element.position, $0.offset) < ($1.element.position, $1.offset)
        }
        var insertedCount = 0
        for item in ordered {
            let position = min(item.element.position + insertedCount, segments.count)
            if segments.count < maximumCount {
                segments.insert(item.element.orphans, at: position)
                insertedCount += 1
            } else {
                // The editor offered "Add Segment" against the segments it could
                // see, so the page can be at the cap before the off-screen
                // segment is back. Folding here, into its preceding neighbour,
                // keeps the final `normalized` from collapsing a segment the
                // user just made — losing an invisible segment's separateness
                // costs less than losing a visible one's.
                segments[max(0, position - 1)].append(contentsOf: item.element.orphans)
            }
        }
        return normalized(segments)
    }
}
