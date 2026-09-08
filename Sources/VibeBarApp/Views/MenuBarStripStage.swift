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
    var groups: [UUID: CGRect] = [:]
    /// The bar under the strip that a block is dropped on to remove it.
    var well: CGRect = .null

    func report(_ frame: CGRect, token id: UUID) { tokens[id] = frame }
    func forget(token id: UUID) { tokens.removeValue(forKey: id) }
    func report(_ frame: CGRect, row: MenuBarComposition.RowAddress) { rows[row] = frame }
    func forget(row: MenuBarComposition.RowAddress) { rows.removeValue(forKey: row) }

    /// Hit testing follows the renderer's exact rectangles. Measuring an
    /// offset SwiftUI overlay can lag behind the pixels during reflow.
    func replaceNativeGeometry(tokens: [UUID: CGRect], rows: [MenuBarComposition.RowAddress: CGRect],
                               groups: [UUID: CGRect], emptyRows: Set<MenuBarComposition.RowAddress>) {
        self.tokens = tokens
        self.rows = self.rows.filter { emptyRows.contains($0.key) }.merging(rows) { _, new in new }
        self.groups = groups
    }

    /// The block under `point`. A little slack around each: a glyph is small,
    /// and the gap beside it is not something anyone means to press.
    func token(at point: CGPoint) -> UUID? {
        tokens.first { $0.value.insetBy(dx: -2, dy: -3).contains(point) }?.key
            ?? groups.first { $0.value.contains(point) }?.key
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
    ///
    /// `tokenFrames` are the frames to judge by — the live ones by default.
    /// A drag passes the frames of the strip *without* the carried run
    /// instead: the live ones move every time the placeholder is re-slotted,
    /// so judging by them made the slot flip back and forth under a pointer
    /// that had not moved.
    func target(
        at point: CGPoint,
        in composition: MenuBarComposition,
        moving: Set<UUID>,
        reach: CGFloat,
        tokenFrames: [UUID: CGRect]? = nil
    ) -> MenuBarStageTarget? {
        guard let address = row(near: point, reach: reach),
              let segment = composition.segmentIndex(of: address.segment)
        else { return nil }
        let judged = tokenFrames ?? tokens
        for token in composition.segments[segment][address.row] where !moving.contains(token.id) {
            guard let frame = judged[token.id] else { continue }
            if point.x < frame.midX { return .before(token.id) }
        }
        return .endOf(address)
    }

    /// The strip's frames as they would be with `run` lifted out of its row:
    /// everything after it in that row slides left by the room it took.
    /// Rows the run is not in are untouched. Judged against these, a slot
    /// depends only on where the pointer is.
    func framesCollapsing(_ run: [UUID], in composition: MenuBarComposition) -> [UUID: CGRect] {
        var collapsed = tokens
        guard let first = run.first, let at = composition.location(of: first),
              let box = run.compactMap({ tokens[$0] }).reduce(nil, { (acc: CGRect?, frame) in
                  acc.map { $0.union(frame) } ?? frame
              })
        else { return collapsed }
        let row = composition.segments[at.segment][at.row]
        let moving = Set(run)
        // The gap the run took with it: from its box to the next block.
        var vacated = box.width
        if let next = row.first(where: { !moving.contains($0.id) && (tokens[$0.id]?.minX ?? -1) > box.maxX }),
           let nextFrame = tokens[next.id] {
            vacated += max(0, nextFrame.minX - box.maxX)
        }
        for token in row where !moving.contains(token.id) {
            guard var frame = collapsed[token.id], frame.minX > box.maxX else { continue }
            frame.origin.x -= vacated
            collapsed[token.id] = frame
        }
        return collapsed
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

// MARK: - The run in flight

/// The picture carried under the pointer: the blocks being moved, drawn the
/// way the canvas draws them, lifted off the strip with a shadow.
struct MenuBarStageRunGhost: View {
    let tokens: [MenuBarToken]
    let template: MenuBarComposition.Template
    let plan: MenuBarRenderPlan
    let quotas: [MenuBarQuotaSnapshot]
    let displayMode: DisplayMode
    let scheme: ColorScheme
    let zoom: CGFloat

    var body: some View {
        let drawing = MenuBarNativeRenderer.render(
            plan: plan, quotas: quotas, template: template, displayMode: displayMode,
            appearance: NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)!, magnification: zoom
        )
        let union = tokens.compactMap { drawing.tokens[$0.id] }.reduce(CGRect.null) { $0.union($1) }
        let box = union.isNull ? CGRect(x: 0, y: 0, width: 1, height: 1) : union
        ZStack(alignment: .topLeading) {
            Image(nsImage: drawing.image)
                .offset(x: -box.minX * zoom, y: -box.minY * zoom)
        }
        .frame(width: box.width * zoom, height: box.height * zoom, alignment: .topLeading)
        .clipped()
        .background(scheme == .dark ? Color.black.opacity(0.85) : Color.white.opacity(0.95))
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .shadow(color: .black.opacity(0.25), radius: 8, y: 3)
        .allowsHitTesting(false)
    }
}

// MARK: - Palette drops

/// A block dragged out of the inspector's palette, landing wherever the
/// pointer is over the stage. `stage` is asked on every movement with the
/// pointer in the stage's coordinates and decides what, if anything,
/// changes; the delegate decides nothing about *where*.
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
