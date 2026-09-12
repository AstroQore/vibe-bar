import Foundation

/// Why a render can fail before it reaches the device's own limits.
///
/// It exists so the renderer never *substitutes* content. A panel is a
/// glanceable surface: someone reading "Claude 41%" across a desk has no way
/// to tell that the slide they configured was a custom layout and that the
/// quota ledger in front of them is a stand-in. Refusing to draw is the
/// honest failure, and it is the one the sync engine can surface.
public enum EInkRenderError: Error, Equatable, Sendable {
    /// The slide names a layout that is not in the passed table at all —
    /// deleted in the Studio, or a settings file edited by hand.
    case layoutMissing(layoutID: String)
}

/// Turns a configured slide plus a data snapshot into the exact JSON the
/// device accepts. Pure: same inputs always produce identical bytes, which is
/// what lets the sync engine skip a push that would change nothing.
public enum EInkRenderer {
    /// The layout tree, before it is flattened to absolute boxes. Exposed so
    /// the preview can reuse the same geometry the device gets.
    ///
    /// `layouts` is the Studio's layout table, keyed by layout id. A slide
    /// that names a custom layout throws rather than falling back to a
    /// preset — see `EInkRenderError`.
    public static func tree(
        slide: EInkSlide,
        orientation: EInkOrientation,
        profile: EInkDeviceProfile = .quote0,
        snapshot: EInkDataSnapshot,
        layouts: [String: EInkCanvasLayout] = [:]
    ) throws -> EInkNode {
        let size = profile.frameSize(for: orientation)
        let frame = EInkRect(x: 0, y: 0, width: size.width, height: size.height)
        guard let preset = slide.kind.preset else {
            let layoutID = slide.kind.layoutID ?? ""
            guard let layout = layouts[layoutID] else {
                throw EInkRenderError.layoutMissing(layoutID: layoutID)
            }
            return EInkCustomLayoutRenderer.tree(
                layout: layout,
                slide: slide,
                orientation: orientation,
                profile: profile,
                snapshot: snapshot
            )
        }
        let capacity = preset.capacity(for: orientation)
        let portrait = orientation.isPortrait

        switch preset {
        case .quotaLedger:
            let rows = snapshot.quotaRows(fieldIDs: slide.quotaFieldIDs, limit: capacity)
            return portrait
                ? EInkPresets.ledgerPortrait(rows, snapshot, frame: frame)
                : EInkPresets.ledgerLandscape(rows, snapshot, frame: frame)
        case .quotaRings:
            let rows = snapshot.quotaRows(fieldIDs: slide.quotaFieldIDs, limit: capacity)
            return portrait
                ? EInkPresets.ringsPortrait(rows, snapshot, frame: frame)
                : EInkPresets.ringsLandscape(rows, snapshot, frame: frame)
        case .quotaRail:
            let rows = snapshot.quotaRows(fieldIDs: slide.quotaFieldIDs, limit: capacity)
            return portrait
                ? EInkPresets.railPortrait(rows, snapshot, frame: frame)
                : EInkPresets.railLandscape(rows, snapshot, frame: frame)
        case .usageTiles:
            let periods = resolvedPeriods(slide, capacity: capacity)
            return portrait
                ? EInkPresets.tilesPortrait(periods, snapshot, frame: frame)
                : EInkPresets.tilesLandscape(periods, snapshot, frame: frame)
        case .usageSplit:
            let periods = resolvedPeriods(slide, capacity: capacity)
            return portrait
                ? EInkPresets.splitPortrait(periods, snapshot, frame: frame)
                : EInkPresets.splitLandscape(periods, snapshot, frame: frame)
        case .usageTable:
            return portrait
                ? EInkPresets.tablePortrait(capacity, snapshot, frame: frame)
                : EInkPresets.tableLandscape(capacity, snapshot, frame: frame)
        case .usageDual:
            return portrait
                ? EInkPresets.dualPortrait(capacity, snapshot, frame: frame)
                : EInkPresets.dualLandscape(capacity, snapshot, frame: frame)
        case .usageTrend:
            // `slide.usagePeriods` is deliberately not read here: trend has
            // `SelectionAxis.none` and always draws today plus the last seven
            // days. A slide carrying periods from an earlier preset choice is
            // ignored rather than half-honoured.
            return portrait
                ? EInkPresets.trendPortrait(snapshot, frame: frame)
                : EInkPresets.trendLandscape(snapshot, frame: frame)
        }
    }

    /// Selected periods in the canonical order, falling back to all four so a
    /// freshly created slide still draws something.
    static func resolvedPeriods(_ slide: EInkSlide, capacity: Int) -> [EInkUsagePeriod] {
        let selected = slide.usagePeriods.isEmpty ? EInkUsagePeriod.allCases : slide.usagePeriods
        let ordered = EInkUsagePeriod.allCases.filter(selected.contains)
        return Array(ordered.prefix(capacity))
    }

    public static func render(
        slide: EInkSlide,
        device: EInkDeviceConfig,
        snapshot: EInkDataSnapshot,
        refreshNow: Bool = false,
        taskKey: String? = nil,
        taskAlias: String? = nil,
        layouts: [String: EInkCanvasLayout] = [:]
    ) throws -> DotCanvasPayload {
        let node = try tree(
            slide: slide,
            orientation: device.orientation,
            profile: device.profile,
            snapshot: snapshot,
            layouts: layouts
        )
        return try DotCanvasEncoder.encode(
            node,
            orientation: device.orientation,
            profile: device.profile,
            refreshNow: refreshNow,
            taskKey: taskKey,
            taskAlias: taskAlias,
            generatedAtISO: snapshot.generatedAtISO
        )
    }

    /// The panel a surplus Canvas API task gets. See `EInkPresets.unusedSlot`
    /// for why a placeholder beats leaving the removed slide on screen.
    public static func renderUnusedSlot(
        device: EInkDeviceConfig,
        taskKey: String?,
        generatedAtISO: String = "",
        refreshNow: Bool = false
    ) throws -> DotCanvasPayload {
        let size = device.profile.frameSize(for: device.orientation)
        let frame = EInkRect(x: 0, y: 0, width: size.width, height: size.height)
        return try DotCanvasEncoder.encode(
            EInkPresets.unusedSlot(frame),
            orientation: device.orientation,
            profile: device.profile,
            refreshNow: refreshNow,
            taskKey: taskKey,
            taskAlias: unusedSlotTaskAlias,
            generatedAtISO: generatedAtISO
        )
    }

    public static let unusedSlotTaskAlias = "Vibe Bar · Unused slot"

    /// English task name for the device's task list. Not localized on purpose:
    /// it is remote metadata, not app UI.
    public static func defaultTaskAlias(slide: EInkSlide, orientation: EInkOrientation) -> String {
        let name = slide.kind.preset?.identifierName ?? (slide.title.isEmpty ? "Custom" : slide.title)
        return "Vibe Bar · \(name) · \(orientation.rawValue)°"
    }
}
