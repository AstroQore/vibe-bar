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

/// Renders a page as two fixed-order columns straight out of a
/// `PageLayoutConfig`.
///
/// Used whenever the user has arranged the page by hand, and on provider pages
/// always — their built-in split is itself a fixed two-column arrangement, so
/// the default config reproduces it exactly and there is no second code path
/// to keep in sync.
///
/// Every card reports its rendered height back to the model on the way past;
/// the layout editor draws its blocks from those measurements.
struct PageLayoutColumns<Content: View>: View {
    let page: PageLayoutPageID
    let descriptors: [PageModuleDescriptor]
    let config: PageLayoutConfig
    let widths: PageColumnWidths
    let spacing: CGFloat
    let model: PageLayoutModel
    @ViewBuilder let content: (PageModuleDescriptor) -> Content

    var body: some View {
        // The config can name a module that went away between refreshes (a
        // quota group whose buckets emptied). Resolve through the live
        // descriptor set every pass and skip anything stale rather than
        // trusting the saved identifiers.
        let byID = Dictionary(descriptors.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        HStack(alignment: .top, spacing: spacing) {
            column(0, byID: byID)
                .frame(width: widths.left, alignment: .topLeading)
            column(1, byID: byID)
                .frame(width: widths.right, alignment: .topLeading)
        }
        .frame(width: widths.total, alignment: .topLeading)
    }

    @ViewBuilder
    private func column(
        _ index: Int,
        byID: [PageLayoutModuleID: PageModuleDescriptor]
    ) -> some View {
        VStack(alignment: .leading, spacing: spacing) {
            ForEach(config.column(index), id: \.self) { moduleID in
                if let descriptor = byID[moduleID] {
                    content(descriptor)
                        .measuredPageModule(moduleID, page: page, model: model)
                }
            }
        }
    }
}
