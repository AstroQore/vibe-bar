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
/// - **Signature, not guesswork.** A layout is touched only when the modules in
///   question are still in the precise positions the old default gave them. One
///   card moved by hand and the whole page is left alone.
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
    /// every provider page still holding them where 1.6.1 put them.
    ///
    /// The 1.6.1 signature is exact: status was the last card in the narrow
    /// column and the reset table the first in the wide one. Anything else —
    /// status moved up, another card dragged below it, the table pushed down —
    /// is a layout somebody arranged, and it is returned untouched.
    public static func migratedProviderRightColumn(
        _ layouts: [PageLayoutPageID: StoredPageLayout]
    ) -> [PageLayoutPageID: StoredPageLayout] {
        var result = layouts
        for (page, layout) in layouts {
            guard let tool = page.detailTool else { continue }
            // An entry with no columns has no arrangement to correct: the
            // resolver will place both cards at their new defaults already.
            guard !layout.isEmpty, layout.columns.count >= 2 else { continue }
            let resetHistory = PageLayoutModuleID(rawValue: "\(resetHistoryFamily):\(tool.rawValue)")
            var left = layout.columns[0]
            var right = layout.columns[1]
            guard left.last == .status, right.first == resetHistory else { continue }

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
}
