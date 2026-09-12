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
    /// How a custom slide's layouts are keyed in `einkCanvasLayouts`.
    ///
    /// Round 1 stored one layout per slide, which meant rotating the panel
    /// showed a landscape design turned on its side. A custom slide now
    /// carries up to four, one per orientation, under `"<layoutID>/<degrees>"`
    /// — `EInkCanvasLayoutMigration` moves a round 1 entry onto the device's
    /// current orientation.
    public static func layoutKey(_ layoutID: String, orientation: EInkOrientation) -> String {
        "\(layoutID)/\(orientation.rawValue)"
    }

    /// The layout to draw, in order of preference: this orientation's, then a
    /// round 1 key that has not been migrated yet.
    public static func layout(
        _ layoutID: String,
        orientation: EInkOrientation,
        layouts: [String: EInkCanvasLayout]
    ) -> EInkCanvasLayout? {
        layouts[layoutKey(layoutID, orientation: orientation)] ?? layouts[layoutID]
    }

    /// The layout tree, before it is flattened to absolute boxes. Exposed so
    /// the preview can reuse the same geometry the device gets.
    ///
    /// `layouts` is the Studio's layout table. A slide that names a custom
    /// layout with nothing stored for *this* orientation is re-exploded from
    /// its preset rather than refused: the alternative is a blank panel after
    /// a rotation, and the exploded layout is the same picture the preset
    /// would have drawn. A slide whose layout is missing entirely still
    /// throws — see `EInkRenderError`.
    public static func tree(
        slide: EInkSlide,
        orientation: EInkOrientation,
        profile: EInkDeviceProfile = .quote0,
        snapshot: EInkDataSnapshot,
        layouts: [String: EInkCanvasLayout] = [:],
        calendar: Calendar = .current
    ) throws -> EInkNode {
        let size = profile.frameSize(for: orientation)
        let frame = EInkRect(x: 0, y: 0, width: size.width, height: size.height)
        guard let preset = slide.kind.preset else {
            let layoutID = slide.kind.layoutID ?? ""
            guard let layout = layout(layoutID, orientation: orientation, layouts: layouts) else {
                guard layouts.keys.contains(where: { $0 == layoutID || $0.hasPrefix(layoutID + "/") }) else {
                    throw EInkRenderError.layoutMissing(layoutID: layoutID)
                }
                return EInkCustomLayoutRenderer.tree(
                    layout: EInkPresetExploder.explode(
                        slide: slide,
                        orientation: orientation,
                        profile: profile,
                        snapshot: snapshot,
                        calendar: calendar
                    ),
                    slide: slide,
                    orientation: orientation,
                    profile: profile,
                    snapshot: snapshot
                )
            }
            return EInkCustomLayoutRenderer.tree(
                layout: layout,
                slide: slide,
                orientation: orientation,
                profile: profile,
                snapshot: snapshot
            )
        }
        return presetTree(
            preset,
            slide: slide,
            orientation: orientation,
            snapshot: snapshot,
            frame: frame,
            calendar: calendar
        )
    }

    /// One preset laid out inside `frame`, honouring the slide's composition
    /// options. Shared with the Studio's whole-preset element and with the
    /// exploder, so the three cannot drift.
    public static func presetTree(
        _ preset: EInkPreset,
        slide: EInkSlide,
        orientation: EInkOrientation,
        snapshot: EInkDataSnapshot,
        frame: EInkRect,
        calendar: Calendar = .current,
        fieldIDs: [String]? = nil,
        periods: [EInkUsagePeriod]? = nil
    ) -> EInkNode {
        let capacity = preset.capacity(for: orientation)
        let portrait = orientation.isPortrait
        let options = slide.options
        let selected = fieldIDs ?? slide.orderedQuotaFieldIDs
        func quotaRows() -> [EInkQuotaRow] {
            snapshot.quotaRows(fieldIDs: selected, limit: capacity).map { $0.relabeled(with: options) }
        }
        func resolved() -> [EInkUsagePeriod] {
            periods ?? resolvedPeriods(slide, capacity: capacity)
        }

        switch preset {
        case .quotaLedger:
            let rows = quotaRows()
            return portrait
                ? EInkPresets.ledgerPortrait(rows, snapshot, frame: frame, options: options)
                : EInkPresets.ledgerLandscape(rows, snapshot, frame: frame, options: options)
        case .quotaRings:
            let rows = quotaRows()
            return portrait
                ? EInkPresets.ringsPortrait(rows, snapshot, frame: frame, options: options)
                : EInkPresets.ringsLandscape(rows, snapshot, frame: frame, options: options)
        case .quotaRail:
            let rows = quotaRows()
            return portrait
                ? EInkPresets.railPortrait(rows, snapshot, frame: frame, options: options)
                : EInkPresets.railLandscape(rows, snapshot, frame: frame, options: options)
        case .usageTiles:
            return portrait
                ? EInkPresets.tilesPortrait(resolved(), snapshot, frame: frame, options: options)
                : EInkPresets.tilesLandscape(resolved(), snapshot, frame: frame, options: options)
        case .usageSplit:
            return portrait
                ? EInkPresets.splitPortrait(resolved(), snapshot, frame: frame, options: options)
                : EInkPresets.splitLandscape(resolved(), snapshot, frame: frame, options: options)
        case .usageTable:
            return portrait
                ? EInkPresets.tablePortrait(capacity, snapshot, frame: frame, options: options)
                : EInkPresets.tableLandscape(capacity, snapshot, frame: frame, options: options)
        case .usageDual:
            return portrait
                ? EInkPresets.dualPortrait(capacity, snapshot, frame: frame, options: options)
                : EInkPresets.dualLandscape(capacity, snapshot, frame: frame, options: options)
        case .usageTrend:
            // `slide.usagePeriods` is deliberately not read here: trend has
            // `SelectionAxis.none` and always draws today plus the last seven
            // days. A slide carrying periods from an earlier preset choice is
            // ignored rather than half-honoured.
            return portrait
                ? EInkPresets.trendPortrait(snapshot, frame: frame, options: options)
                : EInkPresets.trendLandscape(snapshot, frame: frame, options: options)
        case .briefing:
            return EInkPresets.briefing(quotaRows(), snapshot, frame: frame, portrait: portrait, options: options)
        case .forecast:
            return EInkPresets.forecast(
                quotaRows(),
                snapshot,
                frame: frame,
                portrait: portrait,
                calendar: calendar,
                options: options
            )
        case .resets:
            return EInkPresets.resets(quotaRows(), snapshot, frame: frame, portrait: portrait, options: options)
        case .heatmap:
            return EInkPresets.heatmap(snapshot, frame: frame, portrait: portrait, options: options)
        case .topModels:
            return EInkPresets.topModels(
                snapshot,
                frame: frame,
                portrait: portrait,
                limit: preset.rowCount(for: orientation),
                options: options
            )
        case .alert:
            // The slide names the bucket that tripped; the engine builds it.
            let row = selected.first.flatMap { fieldID in
                snapshot.quota.first { $0.fieldID == fieldID }
            } ?? snapshot.quota.min { $0.remainingPercent < $1.remainingPercent }
            return EInkPresets.alert(row, snapshot, frame: frame, portrait: portrait, calendar: calendar)
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
        layouts: [String: EInkCanvasLayout] = [:],
        border: Int = 0,
        link: String? = nil,
        calendar: Calendar = .current
    ) throws -> DotCanvasPayload {
        let node = try tree(
            slide: slide,
            orientation: device.orientation,
            profile: device.profile,
            snapshot: snapshot,
            layouts: layouts,
            calendar: calendar
        )
        return try DotCanvasEncoder.encode(
            node,
            orientation: device.orientation,
            profile: device.profile,
            refreshNow: refreshNow,
            taskKey: taskKey,
            taskAlias: taskAlias,
            generatedAtISO: snapshot.generatedAtISO,
            border: border,
            link: link
        )
    }

    /// The panel a surplus Canvas API task gets. See `EInkPresets.unusedSlot`
    /// for why a placeholder beats leaving the removed slide on screen.
    public static func renderUnusedSlot(
        device: EInkDeviceConfig,
        taskKey: String?,
        generatedAtISO: String = "",
        refreshNow: Bool = false,
        link: String? = nil
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
            generatedAtISO: generatedAtISO,
            link: link
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
