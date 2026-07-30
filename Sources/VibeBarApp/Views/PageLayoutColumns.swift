import SwiftUI
import VibeBarCore

/// Resolved pixel widths for a page's two columns.
///
/// The popover's content width is fixed by the shell, so the columns are
/// computed from it rather than negotiated: a flexible `HStack` child inside a
/// vertical `ScrollView` takes its intrinsic ideal width and would push the
/// right column past the popover's edge.
struct PageColumnWidths {
    let left: CGFloat
    let right: CGFloat
    let total: CGFloat

    init(density: Theme.Density, ratio: PageColumnRatio) {
        total = max(0, density.popoverWidth - density.popoverPaddingH * 2)
        let usable = max(0, total - density.interSectionSpacing)
        left = (usable * ratio.leftFraction).rounded()
        right = max(0, usable - left)
    }

    init(left: CGFloat, right: CGFloat, total: CGFloat) {
        self.left = left
        self.right = right
        self.total = total
    }
}

/// Renders a page as fixed-order columns straight out of a
/// `PageLayoutArrangement`.
///
/// Used whenever the page is not drawing itself with the live-measured
/// `ColumnMasonryLayout`, and on provider pages always — their built-in split is
/// itself a fixed two-column arrangement, so the default config reproduces it
/// exactly and there is no second code path to keep in sync. A module the user
/// switched off is simply absent from the arrangement, so nothing here has to
/// know about visibility.
///
/// A segmented page is drawn as one two-column `HStack`, not as a stack of
/// per-segment rows. Segments are an ordering constraint inside each column —
/// segment *k*'s cards above segment *k+1*'s — and the columns are never made to
/// line up at a boundary. Drawing them as bands made the shorter column wait for
/// the taller one, which is exactly the blank rectangle the user reported; the
/// arrangement's `flattened` columns are what the page has to render instead.
///
/// Every card reports its rendered height back to the model on the way past;
/// the layout editor draws its blocks from those measurements.
struct PageLayoutColumns<Content: View>: View {
    let page: PageLayoutPageID
    let descriptors: [PageModuleDescriptor]
    let arrangement: PageLayoutArrangement
    let widths: PageColumnWidths
    let spacing: CGFloat
    let model: PageLayoutModel
    @ViewBuilder let content: (PageModuleDescriptor) -> Content

    var body: some View {
        // The arrangement can name a module that went away between refreshes (a
        // quota group whose buckets emptied). Resolve through the live
        // descriptor set every pass and skip anything stale rather than
        // trusting the saved identifiers.
        let byID = Dictionary(descriptors.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let flowed = arrangement.flattened
        HStack(alignment: .top, spacing: spacing) {
            column(flowed.column(0), byID: byID)
                .frame(width: widths.left, alignment: .topLeading)
            column(flowed.column(1), byID: byID)
                .frame(width: widths.right, alignment: .topLeading)
        }
        .frame(width: widths.total, alignment: .topLeading)
    }

    @ViewBuilder
    private func column(
        _ moduleIDs: [PageLayoutModuleID],
        byID: [PageLayoutModuleID: PageModuleDescriptor]
    ) -> some View {
        VStack(alignment: .leading, spacing: spacing) {
            ForEach(moduleIDs, id: \.self) { moduleID in
                if let descriptor = byID[moduleID] {
                    content(descriptor)
                        .measuredPageModule(moduleID, page: page, model: model)
                }
            }
        }
    }
}
