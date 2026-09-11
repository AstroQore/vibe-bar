import Foundation

/// Turns a configured slide plus a data snapshot into the exact JSON the
/// device accepts. Pure: same inputs always produce identical bytes, which is
/// what lets the sync engine skip a push that would change nothing.
public enum EInkRenderer {
    /// The layout tree, before it is flattened to absolute boxes. Exposed so
    /// the preview can reuse the same geometry the device gets.
    public static func tree(
        slide: EInkSlide,
        orientation: EInkOrientation,
        profile: EInkDeviceProfile = .quote0,
        snapshot: EInkDataSnapshot
    ) -> EInkNode {
        let size = profile.frameSize(for: orientation)
        let frame = EInkRect(x: 0, y: 0, width: size.width, height: size.height)
        let preset = slide.kind.preset ?? .quotaLedger
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
        taskAlias: String? = nil
    ) throws -> DotCanvasPayload {
        let node = tree(
            slide: slide,
            orientation: device.orientation,
            profile: device.profile,
            snapshot: snapshot
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

    /// English task name for the device's task list. Not localized on purpose:
    /// it is remote metadata, not app UI.
    public static func defaultTaskAlias(slide: EInkSlide, orientation: EInkOrientation) -> String {
        let name = slide.kind.preset?.identifierName ?? (slide.title.isEmpty ? "Custom" : slide.title)
        return "Vibe Bar · \(name) · \(orientation.rawValue)°"
    }
}
