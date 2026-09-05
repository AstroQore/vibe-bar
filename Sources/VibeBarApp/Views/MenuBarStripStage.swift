import AppKit
import SwiftUI
import VibeBarCore

// The composer arranges the strip on the strip itself. This file is the
// strip drawn large enough to take hold of: every block the composition
// holds — drawn the way the bar draws it, or as a ghost when the bar is not
// drawing it right now — laid out in its segments and rows, reporting where
// it is so the editor can ask what is under the pointer. The editor owns the
// gesture, the selection and the provisional order; this only draws.

// MARK: - Frames

/// Where the blocks and rows of the live strip are, as it last drew them, in
/// the canvas's own coordinate space.
///
/// A plain class, like `SurfaceItemFrames`: frames move on every pass of a
/// reflow animation, and nothing should re-render because of that. The editor
/// reads them when the pointer asks a question.
@MainActor
final class MenuBarStageFrames {
    private(set) var tokens: [UUID: CGRect] = [:]
    private(set) var rows: [MenuBarComposition.RowAddress: CGRect] = [:]
    /// The bar under the strip that a block is dropped on to remove it.
    var well: CGRect = .null

    func report(_ frame: CGRect, token id: UUID) { tokens[id] = frame }
    func forget(token id: UUID) { tokens.removeValue(forKey: id) }
    func report(_ frame: CGRect, row: MenuBarComposition.RowAddress) { rows[row] = frame }
    func forget(row: MenuBarComposition.RowAddress) { rows.removeValue(forKey: row) }

    /// The block under `point`. A little slack around each: a glyph is small,
    /// and the gap beside it is not something anyone means to press.
    func token(at point: CGPoint) -> UUID? {
        tokens.first { $0.value.insetBy(dx: -2, dy: -3).contains(point) }?.key
    }

    /// The row under `point`, or the nearest one within `reach` of it — a
    /// drag hovering just above a row still means that row.
    func row(near point: CGPoint, reach: CGFloat) -> MenuBarComposition.RowAddress? {
        if let hit = rows.first(where: { $0.value.contains(point) }) { return hit.key }
        guard let nearest = rows.min(by: { Self.distance($0.value, point) < Self.distance($1.value, point) }),
              Self.distance(nearest.value, point) <= reach
        else { return nil }
        return nearest.key
    }

    private static func distance(_ rect: CGRect, _ point: CGPoint) -> CGFloat {
        let dx = max(rect.minX - point.x, 0, point.x - rect.maxX)
        let dy = max(rect.minY - point.y, 0, point.y - rect.maxY)
        return hypot(dx, dy)
    }
}

/// Where a block in flight would land if it were dropped now.
enum MenuBarStageTarget: Equatable {
    case before(UUID)
    case endOf(MenuBarComposition.RowAddress)
    case removed
}

extension MenuBarStageFrames {
    /// The slot under `point`, by the same midpoint rule the Studio uses: in
    /// front of the first block whose middle the pointer has not passed, else
    /// at the end of the row. `moving` are the blocks being carried, which
    /// cannot be their own target.
    func target(
        at point: CGPoint,
        in composition: MenuBarComposition,
        moving: Set<UUID>,
        reach: CGFloat
    ) -> MenuBarStageTarget? {
        guard let address = row(near: point, reach: reach),
              let segment = composition.segmentIndex(of: address.segment)
        else { return nil }
        for token in composition.segments[segment][address.row] where !moving.contains(token.id) {
            guard let frame = tokens[token.id] else { continue }
            if point.x < frame.midX { return .before(token.id) }
        }
        return .endOf(address)
    }
}

// MARK: - Naming

/// What a block is called when the strip cannot say — the ghost of one the
/// bar is not drawing, a tooltip, the inspector's title.
struct MenuBarTokenNaming {
    var optionsById: [String: MenuBarFieldOption] = [:]

    func title(_ token: MenuBarToken) -> String {
        switch token.kind {
        case let .logo(tool):
            return tool.menuTitle
        case let .brandLogo(logo):
            return logo.name
        case let .text(text):
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? L10n.MenuBar.Composer.Block.emptyText : MenuBarToken.truncated(trimmed)
        case let .quota(fieldId, metric):
            // SubProvider first: a strip holding three "Weekly" blocks has to
            // say which is Codex's, which Claude's, which Grok Bot's. The
            // metric is spelled only when it is not the plain percentage,
            // which is what the "Shows" control says and what nearly every
            // block shows.
            let name = optionsById[fieldId].map(Self.fieldTitle) ?? fieldId
            return metric == .displayPercent ? name : "\(name) · \(metric.title)"
        case let .space(width):
            let width = MenuBarToken.clampedSpaceWidth(width)
            return width == MenuBarToken.defaultSpaceWidth
                ? L10n.MenuBar.Composer.Block.space
                : L10n.MenuBar.Composer.Space.widthValue(count: width)
        case let .separator(separator):
            let trimmed = separator.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? L10n.MenuBar.Composer.Block.gap : trimmed
        case .appIcon:
            return L10n.MenuBar.Composer.Block.appIcon
        case .unsupported:
            return L10n.MenuBar.Composer.Block.unsupported
        }
    }

    /// "Grok Bot · Weekly", "ChatGPT · GPT-5.3 Codex Spark · 5 Hours": the L2
    /// SubProvider the bucket bills against, then the field's own title.
    /// Every list of fields in the composer spells them this way, because a
    /// bare "Weekly" is exactly the ambiguity the naming axis exists to end.
    static func fieldTitle(_ option: MenuBarFieldOption) -> String {
        let subProvider = option.tool.quotaSubProviderName(bucketID: option.bucketId)
        let title = option.displayTitle
        // A legacy catalog title can already lead with the SubProvider
        // ("Grok Bot · Weekly"); saying it twice would be worse than the
        // ambiguity this fixes.
        let prefix = "\(subProvider) · "
        if title.lowercased().hasPrefix(prefix.lowercased()) {
            return "\(subProvider) · \(title.dropFirst(prefix.count))"
        }
        return "\(subProvider) · \(title)"
    }

    static func symbol(for kind: MenuBarToken.Kind) -> String {
        switch kind {
        case .logo, .brandLogo: return "app.badge"
        case .text: return "textformat"
        case .quota: return "percent"
        case .space: return "space"
        case .separator: return "line.diagonal"
        case .appIcon: return "menubar.rectangle"
        case .unsupported: return "questionmark.square.dashed"
        }
    }
}

// MARK: - Canvas

/// The coordinate space the canvas, its well and the editor's gesture share.
enum MenuBarStageSpace {
    static let name = "vibebar.menubar.canvas"
}

/// The strip, drawn large on a menu-bar ground, every block in its place.
///
/// Laid out from the composition rather than from the render plan, so a
/// block the bar is not drawing right now — a quota that is not answering, a
/// rule that is not met — still has a place to be picked up from. Blocks the
/// plan did render are drawn exactly as the bar draws them; the rest are
/// ghosts that say their name.
struct MenuBarStripStage<TokenMenu: View, SegmentMenu: View>: View {
    /// The order being drawn — provisional while a drag is in flight.
    let composition: MenuBarComposition
    let plan: MenuBarRenderPlan
    let template: MenuBarComposition.Template
    let quotas: [MenuBarQuotaSnapshot]
    let displayMode: DisplayMode
    let availability: MenuBarComposition.Availability
    /// Group ids that bind more than one block — see `boundGroupIDs`.
    let bound: Set<UUID>
    let selection: Set<UUID>
    /// Blocks being carried: drawn in place as a dimmed placeholder.
    let lifted: Set<UUID>
    let scheme: ColorScheme
    /// How much larger than the bar the strip is drawn.
    let zoom: CGFloat
    let frames: MenuBarStageFrames
    let naming: MenuBarTokenNaming
    @ViewBuilder let tokenMenu: (MenuBarToken) -> TokenMenu
    @ViewBuilder let segmentMenu: (MenuBarSegment, Int) -> SegmentMenu

    /// Rows the bar draws for this template, which sets its face and its
    /// glyph box — the same count the preview and the status item use.
    private var rowCount: Int { plan.isTwoRow || template == .twoColumn ? 2 : 1 }

    /// The face the bar would draw this strip at, times the zoom.
    private var base: CGFloat {
        let face = MenuBarStripMetrics.baseFontSize(template: template, rowCount: rowCount)
        let fit = MenuBarStripMetrics.estimatedFitScale(plan: plan, baseFontSize: face)
        return face * fit * zoom
    }

    private var gap: CGFloat { base * plan.tokenSpacing * 0.28 }

    var body: some View {
        let rendered = renderedByID
        HStack(alignment: .center, spacing: 0) {
            ForEach(Array(composition.segments.enumerated()), id: \.element.id) { index, segment in
                if index > 0 { boundary }
                segmentBox(segment, index: index, rendered: rendered)
            }
        }
        .environment(\.colorScheme, scheme)
    }

    private var renderedByID: [UUID: MenuBarRenderedToken] {
        var out: [UUID: MenuBarRenderedToken] = [:]
        for column in plan.columns {
            for token in column.top.tokens { out[token.id] = token }
            for token in column.bottom?.tokens ?? [] { out[token.id] = token }
        }
        return out
    }

    /// What the bar puts between two segments: the template's divider with a
    /// gap each side, or the two-row column gap.
    @ViewBuilder
    private var boundary: some View {
        if let separator = plan.columnSeparator, rowCount == 1 {
            Text(separator)
                .font(.system(size: base, weight: .regular))
                .foregroundStyle(Color.primary.opacity(0.45))
                .fixedSize()
                .padding(.horizontal, gap + 6)
        } else {
            Color.clear.frame(width: MenuBarStripMetrics.twoRowColumnSpacing * zoom + 8, height: 0)
        }
    }

    private func segmentBox(
        _ segment: MenuBarSegment,
        index: Int,
        rendered: [UUID: MenuBarRenderedToken]
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            rowView(segment, row: .top, rendered: rendered)
            if segment.isStacked {
                Rectangle()
                    .fill(Color.primary.opacity(0.10))
                    .frame(height: 0.5)
                rowView(segment, row: .bottom, rendered: rendered)
            }
        }
        .padding(.horizontal, 10)
        .padding(.top, 14)
        .padding(.bottom, 8)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.primary.opacity(0.045))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5)
        )
        // The segment's number and its menu ride the box's top edge, small,
        // so the strip itself stays the thing being looked at.
        .overlay(alignment: .topLeading) {
            Text(L10n.MenuBar.Composer.Segment.title(index: index + 1))
                .font(.system(size: 8, weight: .semibold))
                .foregroundStyle(.tertiary)
                .textCase(.uppercase)
                .padding(.leading, 8)
                .padding(.top, 3)
        }
        .overlay(alignment: .topTrailing) {
            segmentMenu(segment, index)
                .padding(.trailing, 4)
        }
    }

    private func rowView(
        _ segment: MenuBarSegment,
        row: MenuBarSegment.Row,
        rendered: [UUID: MenuBarRenderedToken]
    ) -> some View {
        let address = MenuBarComposition.RowAddress(segment: segment.id, row: row)
        let tokens = segment[row]
        return Group {
            if tokens.isEmpty {
                Text(L10n.MenuBar.Composer.Row.empty)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 4)
            } else {
                HStack(spacing: gap) {
                    ForEach(chunks(tokens), id: \.first!.id) { chunk in
                        chunkView(chunk, rendered: rendered)
                    }
                }
            }
        }
        .frame(minWidth: 48, minHeight: base * MenuBarStripMetrics.lineHeightRatio + 8, alignment: .leading)
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(MenuBarStageSpace.name)) } action: { frame in
            frames.report(frame, row: address)
        }
        .onDisappear { frames.forget(row: address) }
    }

    /// A row as runs: blocks bound together become one chunk, everything
    /// else a chunk of one — so a group can be drawn around, and carried, as
    /// the single thing it is.
    private func chunks(_ tokens: [MenuBarToken]) -> [[MenuBarToken]] {
        var out: [[MenuBarToken]] = []
        for token in tokens {
            if let group = token.groupID, bound.contains(group),
               let last = out.last?.last, last.groupID == group {
                out[out.count - 1].append(token)
            } else {
                out.append([token])
            }
        }
        return out
    }

    @ViewBuilder
    private func chunkView(_ chunk: [MenuBarToken], rendered: [UUID: MenuBarRenderedToken]) -> some View {
        let isGroup = chunk.count > 1
        HStack(spacing: gap) {
            ForEach(chunk) { token in
                cell(token, rendered: rendered[token.id])
            }
        }
        .padding(.horizontal, isGroup ? 5 : 0)
        .padding(.vertical, isGroup ? 3 : 0)
        .background {
            if isGroup {
                Capsule(style: .continuous)
                    .fill(Color.accentColor.opacity(0.12))
            }
        }
        .overlay {
            if isGroup {
                Capsule(style: .continuous)
                    .strokeBorder(Color.accentColor.opacity(0.42), lineWidth: 0.7)
            }
        }
    }

    private func cell(_ token: MenuBarToken, rendered: MenuBarRenderedToken?) -> some View {
        let isSelected = selection.contains(token.id)
        let isSilent = availability.silentTokenIds.contains(token.id)
        let isDegraded = availability.degradedTokenIds.contains(token.id)
        let isSpace: Bool = { if case .space = token.kind { return true }; return false }()
        return Group {
            if let rendered {
                MenuBarStripTokenView(
                    token: rendered,
                    baseFontSize: base,
                    rowCount: rowCount,
                    quotas: quotas,
                    displayMode: displayMode
                )
                // A space draws nothing, and nothing cannot be picked up:
                // the canvas shows it as the width it takes.
                .background {
                    if isSpace {
                        RoundedRectangle(cornerRadius: 2, style: .continuous)
                            .fill(Color.primary.opacity(0.10))
                    }
                }
            } else {
                ghost(token)
            }
        }
        .padding(.horizontal, 3)
        .padding(.vertical, 2)
        .background(
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .fill(Color.accentColor.opacity(isSelected ? 0.22 : 0))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .strokeBorder(Color.accentColor.opacity(isSelected ? 0.9 : 0), lineWidth: 1)
        )
        .overlay(alignment: .topTrailing) {
            if isSilent || isDegraded {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 7, weight: .semibold))
                    .foregroundStyle(isSilent ? Color.orange : Color.secondary)
                    .offset(x: 4, y: -5)
            }
        }
        .opacity(lifted.contains(token.id) ? 0.28 : 1)
        .contentShape(Rectangle())
        .contextMenu { tokenMenu(token) }
        .help(help(token, rendered: rendered != nil, isSilent: isSilent, isDegraded: isDegraded))
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(MenuBarStageSpace.name)) } action: { frame in
            frames.report(frame, token: token.id)
        }
        .onDisappear { frames.forget(token: token.id) }
    }

    /// A block the bar is not drawing right now, by name, so it can still be
    /// picked up, grouped or removed.
    private func ghost(_ token: MenuBarToken) -> some View {
        let size = max(9, min(12, base * 0.82))
        return HStack(spacing: 4) {
            Image(systemName: MenuBarTokenNaming.symbol(for: token.kind))
                .font(.system(size: size * 0.85, weight: .semibold))
            Text(naming.title(token))
                .font(.system(size: size, weight: .medium))
                .lineLimit(1)
        }
        .foregroundStyle(.tertiary)
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .overlay(
            Capsule(style: .continuous)
                .strokeBorder(
                    Color.primary.opacity(0.32),
                    style: StrokeStyle(lineWidth: 0.7, dash: [3, 2])
                )
        )
    }

    private func help(_ token: MenuBarToken, rendered: Bool, isSilent: Bool, isDegraded: Bool) -> String {
        if isSilent { return L10n.MenuBar.Composer.Warning.silent }
        if isDegraded { return L10n.MenuBar.Composer.Warning.degraded }
        if !rendered {
            if case let .text(text) = token.kind,
               text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return L10n.MenuBar.Composer.Text.empty
            }
            return L10n.MenuBar.Composer.Canvas.hiddenByRule
        }
        return naming.title(token)
    }
}

// MARK: - The run in flight

/// The picture carried under the pointer: the blocks being moved, drawn the
/// way the canvas draws them, lifted off the strip with a shadow.
struct MenuBarStageRunGhost: View {
    let tokens: [MenuBarToken]
    let rendered: [UUID: MenuBarRenderedToken]
    let template: MenuBarComposition.Template
    let plan: MenuBarRenderPlan
    let quotas: [MenuBarQuotaSnapshot]
    let displayMode: DisplayMode
    let scheme: ColorScheme
    let zoom: CGFloat
    let naming: MenuBarTokenNaming

    private var rowCount: Int { plan.isTwoRow || template == .twoColumn ? 2 : 1 }

    private var base: CGFloat {
        let face = MenuBarStripMetrics.baseFontSize(template: template, rowCount: rowCount)
        let fit = MenuBarStripMetrics.estimatedFitScale(plan: plan, baseFontSize: face)
        return face * fit * zoom
    }

    var body: some View {
        let gap = base * plan.tokenSpacing * 0.28
        let isGroup = tokens.count > 1
        HStack(spacing: gap) {
            ForEach(tokens) { token in
                Group {
                    if let drawn = rendered[token.id] {
                        MenuBarStripTokenView(
                            token: drawn,
                            baseFontSize: base,
                            rowCount: rowCount,
                            quotas: quotas,
                            displayMode: displayMode
                        )
                    } else {
                        Text(naming.title(token))
                            .font(.system(size: max(9, min(12, base * 0.82)), weight: .medium))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                .padding(.horizontal, 3)
                .padding(.vertical, 2)
            }
        }
        .padding(.horizontal, isGroup ? 5 : 2)
        .padding(.vertical, isGroup ? 3 : 1)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(scheme == .dark ? Color.black.opacity(0.86) : Color.white.opacity(0.96))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .strokeBorder(Color.accentColor.opacity(isGroup ? 0.6 : 0.35), lineWidth: 0.8)
        )
        .shadow(color: .black.opacity(0.32), radius: 12, y: 6)
        .environment(\.colorScheme, scheme)
        .allowsHitTesting(false)
    }
}

// MARK: - Palette drops

/// A block dragged out of the palette, landing wherever the pointer is over
/// the canvas. `stage` is asked on every movement with the pointer in canvas
/// coordinates and decides what, if anything, changes; the delegate decides
/// nothing about *where*.
struct MenuBarStageDropDelegate: DropDelegate {
    let stage: (CGPoint) -> Void
    let entered: () -> Void
    let exited: () -> Void
    let commit: () -> Void

    func dropEntered(info: DropInfo) {
        entered()
        stage(info.location)
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        stage(info.location)
        return DropProposal(operation: .move)
    }

    func dropExited(info: DropInfo) { exited() }

    func performDrop(info: DropInfo) -> Bool {
        commit()
        return true
    }
}
