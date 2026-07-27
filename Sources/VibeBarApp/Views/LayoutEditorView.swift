import SwiftUI
import VibeBarCore

/// Settings → Layout: arrange each popover page's cards into two columns.
///
/// The blocks are drawn at the cards' *measured* heights, scaled down. A list
/// of equal-sized rows would make the two columns look balanced when the real
/// page is not, which is the one question this screen exists to answer.
///
/// Modules and their names come from `PageModuleCatalog` — the same registry
/// the popover pages render from — so a card that appears in the popover
/// appears here, with the same identity, without a second list to maintain.
struct LayoutEditorView: View {
    @EnvironmentObject private var environment: AppEnvironment
    @EnvironmentObject private var settingsStore: SettingsStore
    @EnvironmentObject private var layoutModel: PageLayoutModel

    @State private var selectedPage: PageLayoutPageID = .overview
    @State private var drag: DragState?
    /// Live frames of every block, keyed by page *and* module: switching pages
    /// must not let a module that exists on both (Service Status, say) keep the
    /// other page's position.
    @State private var blockFrames: [String: CGRect] = [:]
    @State private var zoneFrames: [Int: CGRect] = [:]

    private static let space = "vibebar.layout.editor"
    /// A card is never shorter than this in the editor, however short it is on
    /// the page — below it the label stops being readable and the block stops
    /// being a drag target.
    private static let minimumBlockHeight: CGFloat = 30
    /// Movement, in points, before a press turns into a drag. Without it every
    /// click on a block would nudge the arrangement.
    private static let dragThreshold: CGFloat = 5
    private static let blockSpacing: CGFloat = 5
    /// Height the taller column is scaled to fit.
    private static let editorColumnHeight: Double = 430
    private static let previewColumnHeight: Double = 132

    private struct DragState {
        let moduleID: PageLayoutModuleID
        let displayName: String
        let accent: Color
        let size: CGSize
        var location: CGPoint
        var engaged: Bool
    }

    /// One arranged card: its identity, what to call it, and how tall it
    /// actually rendered.
    private struct Block: Identifiable {
        let descriptor: PageModuleDescriptor
        let measured: Double?

        var id: PageLayoutModuleID { descriptor.id }
        /// Measured height, or the module family's stand-in until this page has
        /// been opened once.
        var height: Double { measured ?? descriptor.fallbackHeight }
        var heightLabel: String {
            guard let measured else { return "—pt" }
            return "\(Int(measured.rounded()))pt"
        }
    }

    var body: some View {
        let pages = PageModuleCatalog.editablePages(settings: settingsStore.settings)
        let page = pages.contains { $0.page == selectedPage } ? selectedPage : .overview
        let descriptors = PageModuleCatalog.descriptors(
            for: page,
            environment: environment,
            settings: settingsStore.settings
        )
        let config = resolvedConfig(for: page, descriptors: descriptors)
        let blocks = Dictionary(
            descriptors.map { descriptor in
                (descriptor.id, Block(descriptor: descriptor, measured: config.measuredHeight(for: descriptor.id)))
            },
            uniquingKeysWith: { first, _ in first }
        )

        VStack(alignment: .leading, spacing: 12) {
            pagePicker(pages: pages, selected: page)
            controlRow(page: page, config: config)
            if descriptors.isEmpty {
                Text("This page has no arrangeable cards yet. Open it in the popover once so Vibe Bar can measure them.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                HStack(alignment: .top, spacing: 14) {
                    zones(page: page, config: config, blocks: blocks)
                    preview(config: config, blocks: blocks)
                }
            }
            Text(footnote(page: page))
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        // Overlay rather than a ZStack sibling: the floating ghost is
        // positioned absolutely, and a `.position` sibling would accept the
        // full proposed height and make the whole section jump while dragging.
        .overlay(alignment: .topLeading) {
            if let drag, drag.engaged {
                ghost(drag)
            }
        }
        .coordinateSpace(.named(Self.space))
        .onChange(of: page) { _, newValue in
            // A provider hidden from the popover takes its page with it.
            if selectedPage != newValue { selectedPage = newValue }
            drag = nil
        }
    }

    // MARK: - Page picker

    private func pagePicker(
        pages: [(page: PageLayoutPageID, title: String)],
        selected: PageLayoutPageID
    ) -> some View {
        HStack(spacing: 4) {
            ForEach(pages, id: \.page.rawValue) { entry in
                let isSelected = entry.page == selected
                Button {
                    selectedPage = entry.page
                } label: {
                    HStack(spacing: 5) {
                        Text(entry.title)
                            .font(.system(size: 11.5, weight: .semibold, design: .rounded))
                        if layoutModel.isCustomized(entry.page) {
                            Circle()
                                .fill(Color.accentColor)
                                .frame(width: 5, height: 5)
                        }
                    }
                    .foregroundStyle(isSelected ? Color.primary : Color.secondary)
                    .padding(.horizontal, 11)
                    .frame(height: 24)
                    .background {
                        if isSelected {
                            Capsule(style: .continuous)
                                .fill(Color.accentColor.opacity(0.20))
                                .overlay(
                                    Capsule(style: .continuous)
                                        .stroke(Color.accentColor.opacity(0.34), lineWidth: 0.7)
                                )
                        }
                    }
                    .contentShape(Capsule(style: .continuous))
                }
                .buttonStyle(.plain)
                .focusable(false)
                .help(layoutModel.isCustomized(entry.page) ? "\(entry.title) — customized" : entry.title)
            }
            Spacer(minLength: 0)
        }
        .padding(3)
        .background(
            Capsule(style: .continuous)
                .fill(Color.primary.opacity(0.045))
        )
    }

    // MARK: - Ratio + reset

    private func controlRow(page: PageLayoutPageID, config: PageLayoutConfig) -> some View {
        HStack(spacing: 10) {
            ForEach(PageColumnRatio.allCases, id: \.self) { ratio in
                ratioButton(ratio, page: page, config: config)
            }
            Spacer(minLength: 8)
            if layoutModel.isCustomized(page) {
                Text("Customized")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
            } else {
                Text("Default")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
            Button {
                layoutModel.reset(for: page)
            } label: {
                Label("Restore Defaults", systemImage: "arrow.uturn.backward")
                    .font(.system(size: 11))
            }
            .disabled(!layoutModel.isCustomized(page))
        }
    }

    private func ratioButton(
        _ ratio: PageColumnRatio,
        page: PageLayoutPageID,
        config: PageLayoutConfig
    ) -> some View {
        let isSelected = config.ratio == ratio
        return Button {
            layoutModel.setRatio(ratio, for: page, resolved: config)
        } label: {
            HStack(spacing: 6) {
                ratioIcon(ratio)
                Text(ratioLabel(ratio))
                    .font(.system(size: 11, weight: .medium))
            }
            .foregroundStyle(isSelected ? Color.primary : Color.secondary)
            .padding(.horizontal, 9)
            .frame(height: 26)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(isSelected ? Color.accentColor.opacity(0.18) : Color.primary.opacity(0.04))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .stroke(
                        isSelected ? Color.accentColor.opacity(0.34) : Color.primary.opacity(0.08),
                        lineWidth: 0.7
                    )
            )
            .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        }
        .buttonStyle(.plain)
        .focusable(false)
    }

    private func ratioIcon(_ ratio: PageColumnRatio) -> some View {
        let width: CGFloat = 20
        let gap: CGFloat = 2
        let left = (width - gap) * ratio.leftFraction
        return HStack(spacing: gap) {
            RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                .frame(width: left, height: 12)
            RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                .frame(width: max(0, width - gap - left), height: 12)
        }
        .foregroundStyle(.secondary)
        .frame(width: width, height: 12)
    }

    private func ratioLabel(_ ratio: PageColumnRatio) -> String {
        switch ratio {
        case .narrowWide: "Narrow · Wide"
        case .equal: "Equal"
        case .wideNarrow: "Wide · Narrow"
        }
    }

    // MARK: - Column zones

    private func zones(
        page: PageLayoutPageID,
        config: PageLayoutConfig,
        blocks: [PageLayoutModuleID: Block]
    ) -> some View {
        let totals = (0..<PageLayoutConfig.columnCount).map { index in
            config.column(index).reduce(0.0) { $0 + (blocks[$1]?.height ?? 0) }
        }
        let scale = min(0.4, Self.editorColumnHeight / max(1, totals.max() ?? 1))
        let target = dropTarget(page: page, config: config)
        return HStack(alignment: .top, spacing: 10) {
            ForEach(0..<PageLayoutConfig.columnCount, id: \.self) { index in
                zone(
                    index,
                    page: page,
                    config: config,
                    blocks: blocks,
                    total: totals[index],
                    scale: scale,
                    insertionIndex: target?.column == index ? target?.index : nil
                )
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
        }
    }

    private func zone(
        _ index: Int,
        page: PageLayoutPageID,
        config: PageLayoutConfig,
        blocks: [PageLayoutModuleID: Block],
        total: Double,
        scale: Double,
        insertionIndex: Int?
    ) -> some View {
        let moduleIDs = config.column(index)
        let others = moduleIDs.filter { $0 != drag?.moduleID }
        return VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 6) {
                Text(index == 0 ? "Left column" : "Right column")
                    .font(.system(size: 11, weight: .semibold))
                Spacer(minLength: 4)
                Text("\(moduleIDs.count) card\(moduleIDs.count == 1 ? "" : "s") · \(Int(total.rounded()))pt")
                    .font(.system(size: 10, design: .rounded).monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            VStack(spacing: Self.blockSpacing) {
                ForEach(moduleIDs, id: \.self) { moduleID in
                    if let block = blocks[moduleID] {
                        blockView(block, page: page, config: config, scale: scale)
                            // The card stays where it is, dimmed, while its
                            // ghost floats: pulling it out of the stack would
                            // shift every block below it, moving the very
                            // frames the drop target is computed from.
                            .opacity(drag?.engaged == true && drag?.moduleID == moduleID ? 0.25 : 1)
                    }
                }
                if moduleIDs.isEmpty {
                    Text("Empty")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                        .frame(maxWidth: .infinity, minHeight: 44)
                }
            }
            .frame(maxWidth: .infinity, alignment: .top)
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(Color.primary.opacity(0.035))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .stroke(
                    insertionIndex == nil ? Color.primary.opacity(0.07) : Color.accentColor.opacity(0.45),
                    lineWidth: 0.8
                )
        )
        // Drawn as an overlay, not inserted into the stack, for the same
        // reason: an inline 2.5 pt line would nudge every block below it.
        .overlay(alignment: .top) {
            if let insertionIndex,
               let offset = insertionOffset(page: page, column: index, at: insertionIndex, others: others) {
                Capsule(style: .continuous)
                    .fill(Color.accentColor)
                    .frame(height: 2.5)
                    .padding(.horizontal, 8)
                    .offset(y: offset)
            }
        }
        .onGeometryChange(for: CGRect.self) { proxy in
            proxy.frame(in: .named(Self.space))
        } action: { frame in
            zoneFrames[index] = frame
        }
    }

    /// Vertical position of the insertion line, measured from the top of the
    /// column zone, from the frames the blocks actually occupy.
    private func insertionOffset(
        page: PageLayoutPageID,
        column: Int,
        at index: Int,
        others: [PageLayoutModuleID]
    ) -> CGFloat? {
        guard let zone = zoneFrames[column] else { return nil }
        guard !others.isEmpty else { return 34 }
        if index >= others.count {
            guard let last = blockFrames[frameKey(page, others[others.count - 1])] else { return nil }
            return last.maxY - zone.minY + Self.blockSpacing / 2
        }
        guard let frame = blockFrames[frameKey(page, others[index])] else { return nil }
        return frame.minY - zone.minY - Self.blockSpacing / 2
    }

    private func blockView(
        _ block: Block,
        page: PageLayoutPageID,
        config: PageLayoutConfig,
        scale: Double
    ) -> some View {
        let height = max(Self.minimumBlockHeight, CGFloat(block.height * scale))
        return blockBody(block, height: height)
            .onGeometryChange(for: CGRect.self) { proxy in
                proxy.frame(in: .named(Self.space))
            } action: { frame in
                blockFrames[frameKey(page, block.id)] = frame
            }
            .gesture(dragGesture(block: block, page: page, config: config, height: height))
            .help("\(block.descriptor.displayName) · \(block.heightLabel)")
    }

    private func blockBody(_ block: Block, height: CGFloat) -> some View {
        let accent = block.descriptor.accent.color
        return HStack(alignment: .top, spacing: 7) {
            RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                .fill(accent.opacity(0.85))
                .frame(width: 3)
                .frame(maxHeight: .infinity)
            VStack(alignment: .leading, spacing: 1) {
                Text(block.descriptor.displayName)
                    .font(.system(size: 11, weight: .semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                Text(block.heightLabel)
                    .font(.system(size: 9, design: .rounded).monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            Image(systemName: "line.3.horizontal")
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 5)
        .frame(height: height, alignment: .top)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(accent.opacity(0.11))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .stroke(accent.opacity(0.30), lineWidth: 0.7)
        )
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
    }

    // MARK: - Dragging

    private func dragGesture(
        block: Block,
        page: PageLayoutPageID,
        config: PageLayoutConfig,
        height: CGFloat
    ) -> some Gesture {
        // `minimumDistance: 0` so the press is captured immediately — the
        // gesture then owns the pointer until release, the way a pointer
        // capture would — but nothing moves until the 5 pt threshold below is
        // crossed, so a plain click can never reorder the page.
        DragGesture(minimumDistance: 0, coordinateSpace: .named(Self.space))
            .onChanged { value in
                let width = blockFrames[frameKey(page, block.id)]?.width ?? 180
                var state = drag ?? DragState(
                    moduleID: block.id,
                    displayName: block.descriptor.displayName,
                    accent: block.descriptor.accent.color,
                    size: CGSize(width: width, height: height),
                    location: value.location,
                    engaged: false
                )
                guard state.moduleID == block.id else { return }
                state.location = value.location
                if !state.engaged,
                   hypot(value.translation.width, value.translation.height) >= Self.dragThreshold {
                    state.engaged = true
                }
                drag = state
            }
            .onEnded { _ in
                defer { drag = nil }
                guard let state = drag, state.moduleID == block.id, state.engaged else { return }
                guard let target = dropTarget(page: page, config: config) else { return }
                let moved = config.moving(block.id, toColumn: target.column, at: target.index)
                guard moved.columns != config.columns || !layoutModel.isCustomized(page) else { return }
                layoutModel.apply(moved, for: page)
            }
    }

    /// Where the dragged block would land if the pointer were released now.
    private func dropTarget(page: PageLayoutPageID, config: PageLayoutConfig) -> (column: Int, index: Int)? {
        guard let drag, drag.engaged else { return nil }
        let point = drag.location
        let column = nearestColumn(to: point)
        let others = config.column(column).filter { $0 != drag.moduleID }
        var index = others.count
        for (offset, moduleID) in others.enumerated() {
            guard let frame = blockFrames[frameKey(page, moduleID)] else { continue }
            if point.y < frame.midY {
                index = offset
                break
            }
        }
        return (column, index)
    }

    private func frameKey(_ page: PageLayoutPageID, _ moduleID: PageLayoutModuleID) -> String {
        "\(page.rawValue)|\(moduleID.rawValue)"
    }

    private func nearestColumn(to point: CGPoint) -> Int {
        var best = 0
        var bestDistance = Double.greatestFiniteMagnitude
        for index in 0..<PageLayoutConfig.columnCount {
            guard let frame = zoneFrames[index] else { continue }
            if frame.minX <= point.x, point.x <= frame.maxX { return index }
            let distance = Double(min(abs(point.x - frame.minX), abs(point.x - frame.maxX)))
            if distance < bestDistance {
                bestDistance = distance
                best = index
            }
        }
        return best
    }

    private func ghost(_ state: DragState) -> some View {
        HStack(spacing: 7) {
            RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                .fill(state.accent)
                .frame(width: 3, height: 16)
            Text(state.displayName)
                .font(.system(size: 11, weight: .semibold))
                .lineLimit(1)
        }
        .padding(.horizontal, 8)
        .frame(width: max(120, state.size.width), height: max(28, min(state.size.height, 60)), alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(.background.secondary)
                .shadow(color: .black.opacity(0.28), radius: 8, y: 3)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .stroke(state.accent.opacity(0.6), lineWidth: 1)
        )
        .position(x: state.location.x, y: state.location.y)
        .allowsHitTesting(false)
    }

    // MARK: - Preview

    private func preview(
        config: PageLayoutConfig,
        blocks: [PageLayoutModuleID: Block]
    ) -> some View {
        let totals = (0..<PageLayoutConfig.columnCount).map { index in
            config.column(index).reduce(0.0) { $0 + (blocks[$1]?.height ?? 0) }
        }
        let scale = min(0.12, Self.previewColumnHeight / max(1, totals.max() ?? 1))
        let width: CGFloat = 150
        let gap: CGFloat = 4
        let leftWidth = (width - gap) * ratioFraction(config.ratio)
        return VStack(alignment: .leading, spacing: 6) {
            Text("Preview")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 5) {
                // Stand-in for the popover's title band, so the preview reads
                // as the popover rather than as two loose stacks.
                RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .fill(Color.primary.opacity(0.14))
                    .frame(height: 7)
                HStack(alignment: .top, spacing: gap) {
                    previewColumn(config.column(0), blocks: blocks, scale: scale)
                        .frame(width: leftWidth)
                    previewColumn(config.column(1), blocks: blocks, scale: scale)
                        .frame(width: max(0, width - gap - leftWidth))
                }
            }
            .padding(7)
            .frame(width: width + 14, alignment: .topLeading)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.primary.opacity(0.05))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(Color.primary.opacity(0.10), lineWidth: 0.7)
            )
        }
    }

    private func previewColumn(
        _ moduleIDs: [PageLayoutModuleID],
        blocks: [PageLayoutModuleID: Block],
        scale: Double
    ) -> some View {
        VStack(spacing: 2) {
            ForEach(moduleIDs, id: \.self) { moduleID in
                if let block = blocks[moduleID] {
                    RoundedRectangle(cornerRadius: 2, style: .continuous)
                        .fill(block.descriptor.accent.color.opacity(0.55))
                        .frame(height: max(3, CGFloat(block.height * scale)))
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .top)
    }

    private func ratioFraction(_ ratio: PageColumnRatio) -> CGFloat {
        CGFloat(ratio.leftFraction)
    }

    // MARK: - Helpers

    private func resolvedConfig(
        for page: PageLayoutPageID,
        descriptors: [PageModuleDescriptor]
    ) -> PageLayoutConfig {
        let defaults = PageModuleCatalog.defaultConfig(
            for: page,
            descriptors: descriptors,
            measuredHeights: layoutModel.measuredHeights(for: page),
            // The popover's own card gap, so the Overview default the editor
            // shows is the column split the balancer actually produced.
            spacing: Double(
                Theme.overviewDensity(for: settingsStore.settings.popoverDensity).interSectionSpacing
            )
        )
        return layoutModel.resolvedConfig(
            for: page,
            available: descriptors.map(\.id),
            default: defaults
        )
    }

    private func footnote(page: PageLayoutPageID) -> String {
        if layoutModel.isCustomized(page) {
            return "Drag a card to reorder it or move it between columns. Cards are drawn at their measured height, so the taller column here is the taller column in the popover. A card with no measurement yet shows “—pt”."
        }
        if page.isOverview {
            return "The Overview balances its columns automatically until you move a card. Blocks below show what that balance currently produces."
        }
        return "This page uses its built-in arrangement. Drag a card, or pick a width split, to take it over."
    }
}
