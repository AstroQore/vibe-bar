import Foundation

/// One-time repairs to saved page layouts when a *default* position moves.
///
/// Changing `PageModuleCatalog` moves a card only for pages nobody has ever
/// arranged: `PageLayoutResolver` places a module the saved config has never
/// seen at its default position, but a config that already names the module
/// keeps it exactly where it is. That is the right rule — a saved layout is the
/// user's — and it means a shipped default change is invisible to anyone whose
/// layout was materialized by an earlier build.
///
/// Materialization is easy to trigger without ever dragging a card: picking a
/// width split or switching a page to Manual writes the whole arrangement the
/// page happened to be showing. So a saved layout is not proof of intent about
/// any *particular* card, and this file exists to move the cards a release
/// re-homed — but only where they are still sitting exactly where the previous
/// default put them.
///
/// The rules every migration here follows:
///
/// - **The whole arrangement, not two endpoints.** A layout is touched only
///   when *every* card on the page is still exactly where the old default put
///   it, and the page carries no segmentation or width choice of its own. Two
///   cards happening to sit in their old places prove nothing about the ones
///   between them.
/// - **Once.** Each migration has an identifier recorded in
///   `AppSettings.appliedLayoutMigrations`, so a user who deliberately drags a
///   card back is not corrected again on the next launch.
/// - **Never destructive.** Nothing is removed from a layout, nothing is
///   reordered beyond the named modules, and a page with no saved entry is not
///   given one.
public enum PageLayoutDefaultsMigration {
    /// 1.6.2: the provider pages' right column gained the reset-history table
    /// after the model ranking, and service status moved off the narrow left
    /// column to close the wide one.
    public static let providerRightColumnIdentifier = "provider-right-column-v2"

    /// Module family the reset-history table is registered under.
    static let resetHistoryFamily = "reset-history-compare"

    /// Apply every migration `applied` does not already list.
    ///
    /// Returns the new layouts and the identifiers to record. Pure, so the
    /// decision is testable without a settings file behind it.
    public static func migrate(
        layouts: [PageLayoutPageID: StoredPageLayout],
        applied: Set<String>
    ) -> (layouts: [PageLayoutPageID: StoredPageLayout], applied: Set<String>) {
        var layouts = layouts
        var applied = applied
        if applied.insert(providerRightColumnIdentifier).inserted {
            layouts = migratedProviderRightColumn(layouts)
        }
        return (layouts, applied)
    }

    /// Move `status` and `reset-history-compare:<tool>` to their new homes on
    /// every provider page whose whole arrangement is still 1.6.1's.
    ///
    /// See `matchesPreviousProviderDefault` for what that means. A page failing
    /// it in any respect — one analytics card reordered, an extra card, a
    /// chosen segmentation, a width split — is returned untouched.
    public static func migratedProviderRightColumn(
        _ layouts: [PageLayoutPageID: StoredPageLayout]
    ) -> [PageLayoutPageID: StoredPageLayout] {
        var result = layouts
        for (page, layout) in layouts {
            guard let tool = page.detailTool,
                  matchesPreviousProviderDefault(layout, tool: tool)
            else { continue }
            let resetHistory = resetHistoryID(tool)
            var left = layout.columns[0]
            var right = layout.columns[1]
            left.removeLast()
            right.removeFirst()
            // Back in after the model ranking, which is where the new default
            // puts it; at the end of what is left when the page has no cost
            // data and therefore no ranking.
            if let ranking = right.firstIndex(of: .modelBreakdown(tool: tool)) {
                right.insert(resetHistory, at: right.index(after: ranking))
            } else {
                right.append(resetHistory)
            }
            right.append(.status)

            var columns = layout.columns
            columns[0] = left
            columns[1] = right
            result[page] = StoredPageLayout(
                mode: layout.mode,
                ratio: layout.ratio,
                columns: columns,
                segments: layout.segments,
                hidden: layout.hidden
            )
        }
        return result
    }

    /// Is this saved layout, in full, the arrangement 1.6.1 shipped for a
    /// provider page?
    ///
    /// Checked as a shape rather than a literal list because the quota-group
    /// identifiers are discovered from live buckets and Core cannot know them
    /// — but the shape is exact everywhere it can be:
    ///
    /// - Two columns. The left is one or more `quota-group:…` cards, in any
    ///   order (they arrive in bucket order, which varies by account and by
    ///   which SubProviders a page combines), closed by `status`, and nothing
    ///   else. The right is the reset table followed by 1.6.1's cost tail,
    ///   verbatim and in order — either the full one or the no-cost-data one.
    /// - No segmentation. Choosing one is an explicit act on this page.
    /// - The provider default width split. Picking any other ratio is one of
    ///   the things that materializes a layout in the first place, so a page
    ///   whose ratio was chosen is a page somebody took over.
    ///
    /// `mode` and `hidden` are deliberately not consulted. Switching a page to
    /// Manual or Auto does not move a card, and hiding one says where nothing
    /// should go rather than where anything sits; both ride through the
    /// migration unchanged.
    static func matchesPreviousProviderDefault(
        _ layout: StoredPageLayout,
        tool: ToolType
    ) -> Bool {
        // No arrangement at all needs no repair: `PageLayoutResolver` places a
        // module the config has never seen at its current default anyway.
        guard !layout.isEmpty,
              layout.columns.count == 2,
              layout.segments.isEmpty,
              layout.ratio == previousProviderRatio
        else { return false }

        let left = layout.columns[0]
        guard left.count >= 2, left.last == .status else { return false }
        guard left.dropLast().allSatisfy({ $0.family == PageLayoutModuleID.Family.quotaGroup })
        else { return false }

        let right = layout.columns[1]
        guard right.first == resetHistoryID(tool) else { return false }
        let tail = Array(right.dropFirst())
        return tail == previousCostTail(tool) || tail == previousEmptyCostTail(tool)
    }

    /// The width split every provider page shipped with — `defaultRatio` for a
    /// non-overview page.
    static let previousProviderRatio = PageColumnRatio.narrowWide

    static func resetHistoryID(_ tool: ToolType) -> PageLayoutModuleID {
        PageLayoutModuleID(rawValue: "\(resetHistoryFamily):\(tool.rawValue)")
    }

    /// 1.6.1's right column below the reset table, when the provider had local
    /// session data.
    static func previousCostTail(_ tool: ToolType) -> [PageLayoutModuleID] {
        [
            .cost(tool: tool),
            PageLayoutModuleID(rawValue: "cost-history:\(tool.rawValue)"),
            .modelBreakdown(tool: tool),
            PageLayoutModuleID(rawValue: "heatmap-year:\(tool.rawValue)"),
            PageLayoutModuleID(rawValue: "heatmap-activity:\(tool.rawValue)")
        ]
    }

    /// …and when it had none.
    static func previousEmptyCostTail(_ tool: ToolType) -> [PageLayoutModuleID] {
        [PageLayoutModuleID(rawValue: "cost-empty:\(tool.rawValue)")]
    }
}
