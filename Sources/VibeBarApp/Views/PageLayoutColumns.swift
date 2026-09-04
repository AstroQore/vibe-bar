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
/// A segmented page is drawn as one two-column arrangement, not as a stack of
/// per-segment rows. Segments are an ordering constraint inside each column —
/// segment *k*'s cards above segment *k+1*'s — and the columns are never made to
/// line up at a boundary. Drawing them as bands made the shorter column wait for
/// the taller one, which is exactly the blank rectangle the user reported; the
/// arrangement's `flattened` columns are what the page has to render instead.
///
/// Both columns live in **one** `PageColumnsLayout` rather than two stacks in
/// an `HStack`. The difference is invisible until a card changes column: in
/// two stacks that is a removal and an insertion, so the card — and the chart
/// inside it — is rebuilt from scratch; in one layout it is the same subview
/// placed somewhere else, which is what lets the Layout Studio slide a card
/// across the page while it is being dragged.
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
        PageColumnsLayout(
            columns: flowed.columns.map { $0.map(\.rawValue) },
            widths: [widths.left, widths.right],
            spacing: spacing
        ) {
            ForEach(flowed.moduleIDs, id: \.self) { moduleID in
                if let descriptor = byID[moduleID] {
                    content(descriptor)
                        .measuredPageModule(moduleID, page: page, model: model)
                        .surfaceItem(moduleID.rawValue)
                        .layoutValue(key: PageColumnItemKey.self, value: moduleID.rawValue)
                }
            }
        }
        .frame(width: widths.total, alignment: .topLeading)
    }
}

private struct PageColumnItemKey: LayoutValueKey {
    static let defaultValue = ""
}

/// Two fixed-width columns of top-aligned subviews, in one container.
///
/// Each subview names itself through `PageColumnItemKey`; `columns` says
/// which column it stacks in and in what order. A subview the columns do not
/// name is given no room. Placement is animatable like any layout's, so a
/// card that moves — down its column or across to the other one — travels
/// rather than reappears.
struct PageColumnsLayout: Layout {
    var columns: [[String]]
    var widths: [CGFloat]
    var spacing: CGFloat

    func sizeThatFits(
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) -> CGSize {
        let width = widths.reduce(0, +) + spacing * CGFloat(max(0, widths.count - 1))
        let heights = columnHeights(subviews)
        return CGSize(width: width, height: heights.max() ?? 0)
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) {
        let index = indexByID(subviews)
        var placed = Set<Int>()
        var x = bounds.minX
        for (column, members) in columns.enumerated() where column < widths.count {
            let width = widths[column]
            var y = bounds.minY
            for id in members {
                guard let position = index[id] else { continue }
                let size = subviews[position].sizeThatFits(ProposedViewSize(width: width, height: nil))
                subviews[position].place(
                    at: CGPoint(x: x, y: y),
                    anchor: .topLeading,
                    proposal: ProposedViewSize(width: width, height: size.height)
                )
                placed.insert(position)
                y += size.height + spacing
            }
            x += width + spacing
        }
        for position in subviews.indices where !placed.contains(position) {
            subviews[position].place(at: bounds.origin, anchor: .topLeading, proposal: .zero)
        }
    }

    private func columnHeights(_ subviews: Subviews) -> [CGFloat] {
        let index = indexByID(subviews)
        return columns.enumerated().map { column, members in
            guard column < widths.count else { return 0 }
            var height: CGFloat = 0
            var count = 0
            for id in members {
                guard let position = index[id] else { continue }
                height += subviews[position].sizeThatFits(ProposedViewSize(width: widths[column], height: nil)).height
                count += 1
            }
            return height + spacing * CGFloat(max(0, count - 1))
        }
    }

    private func indexByID(_ subviews: Subviews) -> [String: Int] {
        var result: [String: Int] = [:]
        for (position, subview) in subviews.enumerated() {
            let id = subview[PageColumnItemKey.self]
            if !id.isEmpty, result[id] == nil { result[id] = position }
        }
        return result
    }
}
