import Foundation

/// Ordered bands a page's cards are packed into, one band at a time.
///
/// `PageLayoutMode.compact` asks `PageLayoutPacker` for the shortest two-column
/// arrangement of a whole page, and the shortest page is free to slot an
/// analytics card between two quota cards. That is exactly what a user who
/// wants "my quotas together, packed as tight as they go, everything else
/// below" does not want. Segments put that grouping back under the user's
/// control without giving up the packing: inside a band the packer is still
/// free, across bands the reading order is fixed.
///
/// Segments live *beside* `PageLayoutConfig.columns`, never inside it:
/// `PageLayoutConfig.normalized` folds every column past the second into the
/// last one and dedupes globally, which would flatten any structure stored
/// there into two flat columns.
public enum PageLayoutSegments {
    /// Most bands one page may hold. A band the user cannot tell apart from its
    /// neighbour is worse than no band, and the cap also keeps a hand-edited
    /// settings file from asking the editor to draw fifty headers.
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

    /// Phases that share a band in the Overview's default segmentation: the
    /// pinned summary header, then the quota cards packed among themselves,
    /// then cost together with the analytics derived from it.
    ///
    /// This is the answer to the complaint segments exist for — a user who
    /// picks Compact on the Overview gets a minimal-height quota block without
    /// having to arrange anything.
    static let overviewBands: [[OverviewMasonryPlanner.Phase]] = [
        [.summary],
        [.quota],
        [.cost, .auxiliary]
    ]

    /// Segmentation a page gets when the user has not chosen one.
    ///
    /// Provider pages are a single band: `compact` there keeps meaning exactly
    /// what it always meant, one packing of the whole page.
    public static func defaultSegments(
        modules: [Module],
        page: PageLayoutPageID
    ) -> [[PageLayoutModuleID]] {
        guard page.isOverview else { return normalized([modules.map(\.id)]) }
        return normalized(
            overviewBands.map { band in
                modules.filter { band.contains($0.phase) }.map(\.id)
            }
        )
    }

    /// Drops empty identifiers and empty bands, collapses an identifier that
    /// appears in more than one band onto its first occurrence, and folds bands
    /// past `maximumCount` into the last one.
    ///
    /// Identifiers this build does not recognize are preserved verbatim, for the
    /// same reason `PageLayoutModuleID` is a string wrapper: a band written by a
    /// newer build has to survive a downgrade's round trip rather than being
    /// quietly dropped from the user's arrangement.
    public static func normalized(_ segments: [[PageLayoutModuleID]]) -> [[PageLayoutModuleID]] {
        var result: [[PageLayoutModuleID]] = []
        var seen = Set<PageLayoutModuleID>()
        for segment in segments {
            var band: [PageLayoutModuleID] = []
            for moduleID in segment where !moduleID.rawValue.isEmpty {
                guard seen.insert(moduleID).inserted else { continue }
                band.append(moduleID)
            }
            guard !band.isEmpty else { continue }
            if result.count < maximumCount {
                result.append(band)
            } else {
                result[result.count - 1].append(contentsOf: band)
            }
        }
        return result
    }

    /// Band membership to render right now: the saved bands reconciled against
    /// the modules the page can actually draw this pass.
    ///
    /// - Saved bands with no chosen segmentation (`stored` empty) fall back to
    ///   `defaultSegments`, which is what every page did before segments
    ///   existed.
    /// - A saved module the page cannot draw is left out of the result. It stays
    ///   in the *saved* bands — see `mergingEdit`.
    /// - A module the saved bands have never seen joins the band its family
    ///   defaults to, clamped into range: a page saved with fewer bands than the
    ///   default has nowhere else to put it.
    /// - A band whose cards have all gone is not drawn.
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
        for (index, band) in defaults.enumerated() {
            for moduleID in band { defaultIndex[moduleID] = index }
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

    /// Fold an edit made against the *resolved* bands back into the *saved*
    /// ones, without forgetting modules the page cannot draw right now.
    ///
    /// The same contract `PageLayoutResolver.mergingEdit` gives the columns, and
    /// for the same reason: the editor can only drag what is on screen, so
    /// persisting its output verbatim would erase the band of every module that
    /// happened to be missing — a quota group before the first refresh, the cost
    /// cards before any session log is found — and moving one card would
    /// silently reset the rest of the page.
    ///
    /// A hidden module follows its surviving bandmates — the user dragged (or
    /// left) the band, and the module belongs to it wherever it went. A band
    /// whose every module is hidden has no bandmate to follow and is re-created
    /// where it was saved, next to its nearest surviving stored neighbour:
    /// clamping it into the last visible band instead would collapse the saved
    /// grouping the first time the user dragged anything else, and the module
    /// would come back in the wrong band. Only an explicit reset forgets a page.
    public static func mergingEdit(
        _ edited: [[PageLayoutModuleID]],
        into stored: [[PageLayoutModuleID]],
        available: [PageLayoutModuleID]
    ) -> [[PageLayoutModuleID]] {
        let availableSet = Set(available)
        var segments = normalized(edited)
        let storedBands = normalized(stored)
        guard !segments.isEmpty else { return storedBands }

        var editedIndex: [PageLayoutModuleID: Int] = [:]
        for (index, band) in segments.enumerated() {
            for moduleID in band { editedIndex[moduleID] = index }
        }

        // Bands that lost every module to unavailability, queued for
        // re-insertion after the band holding their nearest preceding stored
        // anchor. The user may have reordered bands, so positions are not
        // necessarily monotone in stored order — a stable sort by position
        // (stored order as the tie-break) makes the offset insertion exact.
        var pending: [(position: Int, band: [PageLayoutModuleID])] = []
        var lastAnchoredPosition = -1
        for band in storedBands {
            let hidden = band.filter { !availableSet.contains($0) && editedIndex[$0] == nil }
            if let anchor = band.first(where: { editedIndex[$0] != nil }) {
                let anchorIndex = editedIndex[anchor]!
                lastAnchoredPosition = anchorIndex
                guard !hidden.isEmpty else { continue }
                segments[anchorIndex].append(contentsOf: hidden)
            } else if !hidden.isEmpty {
                pending.append((position: lastAnchoredPosition + 1, band: hidden))
            }
        }
        let ordered = pending.enumerated().sorted {
            ($0.element.position, $0.offset) < ($1.element.position, $1.offset)
        }
        for (inserted, item) in ordered.enumerated() {
            segments.insert(
                item.element.band,
                at: min(item.element.position + inserted, segments.count)
            )
        }
        return normalized(segments)
    }
}
