import Foundation

/// Reconciles a saved page layout with what the page can actually render right
/// now.
///
/// The saved arrangement and the live module set drift apart constantly: the
/// user disables a provider, a build adds a card, an account logs out. The
/// resolver's contract is that neither drift direction can lose a card:
///
/// - Configured modules that are no longer available are dropped.
/// - Available modules the config has never seen are appended to the column
///   they occupy in `defaultConfig`, after that column's configured items, in
///   their default relative order.
/// - Every available module appears exactly once in the result.
///
/// A module that is available but absent from `defaultConfig` too (a card this
/// build knows nothing about) lands at the end of the left column — arbitrary,
/// but deterministic, and visible rather than silently missing.
public enum PageLayoutResolver {
    public static func resolve(
        configured: PageLayoutConfig?,
        available: [PageLayoutModuleID],
        defaultConfig: PageLayoutConfig
    ) -> PageLayoutConfig {
        // Re-run both through `init` so a caller-built config that skipped the
        // invariants cannot leak duplicates into the result.
        let defaults = PageLayoutConfig(
            ratio: defaultConfig.ratio,
            columns: defaultConfig.columns,
            measuredHeights: defaultConfig.measuredHeights
        )
        let base = configured.map {
            PageLayoutConfig(ratio: $0.ratio, columns: $0.columns, measuredHeights: $0.measuredHeights)
        } ?? PageLayoutConfig(ratio: defaults.ratio)

        var availableSet = Set<PageLayoutModuleID>()
        var orderedAvailable: [PageLayoutModuleID] = []
        for moduleID in available where availableSet.insert(moduleID).inserted {
            orderedAvailable.append(moduleID)
        }

        // 1. Keep the configured arrangement, minus anything that went away.
        var columns = [[PageLayoutModuleID]](repeating: [], count: PageLayoutConfig.columnCount)
        var placed = Set<PageLayoutModuleID>()
        for (index, column) in base.columns.enumerated() {
            for moduleID in column where availableSet.contains(moduleID) {
                guard placed.insert(moduleID).inserted else { continue }
                columns[index].append(moduleID)
            }
        }

        // 2. Append everything new at its default position.
        struct Newcomer {
            let moduleID: PageLayoutModuleID
            let column: Int
            let defaultRank: Int
            let arrival: Int
        }
        var newcomers: [Newcomer] = []
        for (arrival, moduleID) in orderedAvailable.enumerated() where !placed.contains(moduleID) {
            if let column = defaults.columnIndex(of: moduleID),
               let rank = defaults.columns[column].firstIndex(of: moduleID) {
                newcomers.append(Newcomer(moduleID: moduleID, column: column, defaultRank: rank, arrival: arrival))
            } else {
                newcomers.append(Newcomer(moduleID: moduleID, column: 0, defaultRank: .max, arrival: arrival))
            }
        }
        // Sorting globally by default rank preserves each column's default
        // relative order once the entries are appended column by column.
        newcomers.sort { lhs, rhs in
            lhs.defaultRank == rhs.defaultRank
                ? lhs.arrival < rhs.arrival
                : lhs.defaultRank < rhs.defaultRank
        }
        for newcomer in newcomers {
            columns[newcomer.column].append(newcomer.moduleID)
        }

        // A config with no modules carries no ratio intent either — that is
        // what a heights-only store entry for an untouched page looks like.
        let ratio = base.isEmpty ? defaults.ratio : base.ratio

        var heights = defaults.measuredHeights
        for (moduleID, height) in base.measuredHeights {
            heights[moduleID] = height
        }

        return PageLayoutConfig(ratio: ratio, columns: columns, measuredHeights: heights)
    }

    /// Fold an edit made against the *resolved* layout back into the *saved*
    /// one, without forgetting modules that happen to be unavailable right now.
    ///
    /// The editor can only arrange what the page can currently draw, so the
    /// config coming out of a drag names available modules only. Persisting
    /// that directly would erase the saved position of every module that was
    /// temporarily missing — a quota group before the first refresh, the cost
    /// cards while no session logs have been found — and moving one card would
    /// silently reset the rest of the page. So:
    ///
    /// - Available modules take the column and order the edit gives them.
    /// - Modules the save file still knows about but the page cannot draw stay
    ///   in their saved column, re-anchored behind the nearest saved neighbour
    ///   that is still visible, preserving their relative order.
    /// - The ratio comes from the edit; heights merge, edit winning.
    ///
    /// Only an explicit reset (`PageLayoutStore.resetConfig`) forgets a page.
    ///
    /// - Parameter edited: the arrangement the user just produced. Expected to
    ///   name every currently available module exactly once — which is what
    ///   `resolve(configured:available:defaultConfig:)` returns.
    public static func mergingEdit(
        _ edited: PageLayoutConfig,
        into stored: PageLayoutConfig?,
        available: [PageLayoutModuleID]
    ) -> PageLayoutConfig {
        guard let stored else { return edited }
        let availableSet = Set(available)

        var columns: [[PageLayoutModuleID]] = []
        for index in 0..<PageLayoutConfig.columnCount {
            var column = edited.column(index)
            let savedColumn = stored.column(index)
            for (position, moduleID) in savedColumn.enumerated() {
                guard !availableSet.contains(moduleID),
                      !column.contains(moduleID)
                else { continue }
                // Walk back through the saved order for the nearest neighbour
                // that survived into this column and sit behind it. Because
                // hidden modules are re-inserted in saved order, a run of them
                // finds its own predecessor and stays intact.
                var insertion = 0
                for earlier in stride(from: position - 1, through: 0, by: -1) {
                    if let anchor = column.firstIndex(of: savedColumn[earlier]) {
                        insertion = anchor + 1
                        break
                    }
                }
                column.insert(moduleID, at: insertion)
            }
            columns.append(column)
        }

        var heights = stored.measuredHeights
        for (moduleID, height) in edited.measuredHeights {
            heights[moduleID] = height
        }
        return PageLayoutConfig(ratio: edited.ratio, columns: columns, measuredHeights: heights)
    }
}
