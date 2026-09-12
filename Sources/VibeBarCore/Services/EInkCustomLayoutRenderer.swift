import Foundation

/// Turns a Studio layout into the same absolutely positioned box tree the
/// eight presets produce.
///
/// The point of going through `EInkNode` rather than emitting boxes directly
/// is that everything downstream — the encoder, the 1:1 preview, the digest
/// the sync engine compares — keeps working unchanged, and a whole preset can
/// be dropped into a custom layout as one element: the preset lays itself out
/// inside the rectangle the author gave it exactly as it would inside a panel
/// of that size. At the full panel rectangle the two are the same boxes, which
/// `EInkCustomLayoutRendererTests` asserts rather than assumes.
///
/// Unbound elements draw *nothing*. A ring with no bucket behind it could
/// easily be given a plausible-looking 50 %, and someone reading the panel
/// across a room has no way to tell a placeholder from a reading — the same
/// reason `EInkRenderError` refuses to substitute a preset. The Studio draws
/// its own marker for those elements on its stage, where there is a person to
/// read it.
public enum EInkCustomLayoutRenderer {
    /// The margin a whole-preset element keeps inside its own rectangle —
    /// the presets' own, so a preset at the panel's size is unchanged.
    static let presetMargin = Int(EInkCanvasLayout.safeMargin)

    public static func tree(
        layout: EInkCanvasLayout,
        slide: EInkSlide,
        orientation: EInkOrientation,
        profile: EInkDeviceProfile = .quote0,
        snapshot: EInkDataSnapshot
    ) -> EInkNode {
        let size = profile.frameSize(for: orientation)
        let frame = EInkRect(x: 0, y: 0, width: size.width, height: size.height)
        let normalized = layout.fitted(profile: profile, orientation: orientation)
        let children = normalized.elements.compactMap {
            node(for: $0, slide: slide, orientation: orientation, snapshot: snapshot)
        }
        return EInkNode(
            .stack,
            width: .points(frame.width),
            height: .points(frame.height),
            // The author placed elements at real pixels, including inside the
            // 6 px margin the presets keep. Clamping them to that margin would
            // move an element the Studio shows at the edge, so a custom
            // layout's only boundary is the panel itself.
            clampInset: 0,
            children: children
        )
    }

    // MARK: - Elements

    public static func node(
        for element: EInkCanvasElement,
        slide: EInkSlide,
        orientation: EInkOrientation,
        snapshot: EInkDataSnapshot
    ) -> EInkNode? {
        let width = Int(element.width.rounded())
        let height = Int(element.height.rounded())
        let x = Int(element.x.rounded())
        let y = Int(element.y.rounded())
        guard width > 0, height > 0 else { return nil }
        let origin = EInkPoint(x: x, y: y)

        if let preset = element.kind.preset {
            return presetNode(
                preset,
                element: element,
                slide: slide,
                orientation: orientation,
                snapshot: snapshot,
                frame: EInkRect(x: x, y: y, width: width, height: height)
            )
        }

        switch element.kind {
        case .text:
            let content = text(for: element, snapshot: snapshot)
            guard !content.isEmpty else { return nil }
            return EInkNode(
                .text(content, font: element.font, alignment: element.alignment),
                width: element.autoWidth ? .auto : .points(width),
                height: .points(height),
                origin: origin
            )
        case .ring:
            guard let percent = percent(for: element, snapshot: snapshot) else { return nil }
            // The rasterizer draws one circle, so a rectangle gets the square
            // it contains, centred — a stretched ring is not a ring.
            let side = min(width, height)
            let stroke = max(1, min(side / 2, Int(element.thickness.rounded())))
            return EInkNode(
                .ring(percent: percent, stroke: stroke, labelFont: element.font),
                width: .points(side),
                height: .points(side),
                origin: EInkPoint(x: x + (width - side) / 2, y: y + (height - side) / 2)
            )
        case .horizontalBar:
            guard let percent = percent(for: element, snapshot: snapshot) else { return nil }
            return EInkNode(
                .horizontalBar(percent: percent),
                width: .points(width),
                height: .points(height),
                origin: origin
            )
        case .verticalBar:
            guard let percent = percent(for: element, snapshot: snapshot) else { return nil }
            return EInkNode(
                .verticalBar(percent: percent),
                width: .points(width),
                height: .points(height),
                origin: origin
            )
        case .statTile:
            return statTile(element, snapshot: snapshot, width: width, height: height, origin: origin)
        case .divider:
            // One pixel of ink whatever the handle says: the box is the grab
            // target, the rule is the drawing, and it sits in the middle of
            // the box so a divider snapped to the 8 px grid still lands where
            // the Studio shows it.
            return EInkNode(
                .fill,
                width: .points(width),
                height: .points(1),
                origin: EInkPoint(x: x, y: y + (height - 1) / 2)
            )
        case .quotaLedger, .quotaRings, .quotaRail,
             .usageTiles, .usageSplit, .usageTable, .usageDual, .usageTrend:
            return nil  // Handled above.
        }
    }

    private static func statTile(
        _ element: EInkCanvasElement,
        snapshot: EInkDataSnapshot,
        width: Int,
        height: Int,
        origin: EInkPoint
    ) -> EInkNode? {
        let value = text(for: element, snapshot: snapshot)
        let caption = element.text.isEmpty ? defaultCaption(for: element, snapshot: snapshot) : element.text
        let sub = element.subText.isEmpty ? defaultSubValue(for: element, snapshot: snapshot) : element.subText
        guard !value.isEmpty || !caption.isEmpty else { return nil }
        var children: [EInkNode] = []
        if !caption.isEmpty {
            children.append(
                EInkNode(
                    .text(caption, font: .pixel12(bold: true), alignment: element.alignment),
                    width: .points(width),
                    height: .points(EInkFont.pixel12(bold: true).lineHeight)
                )
            )
        }
        if !value.isEmpty {
            children.append(
                EInkNode(
                    .text(value, font: element.font, alignment: element.alignment),
                    width: .points(width),
                    height: .points(element.font.lineHeight)
                )
            )
        }
        if !sub.isEmpty {
            children.append(
                EInkNode(
                    .text(sub, font: .pixel12(bold: false), alignment: element.alignment),
                    width: .points(width),
                    height: .points(EInkFont.pixel12(bold: false).lineHeight)
                )
            )
        }
        guard !children.isEmpty else { return nil }
        return EInkNode(
            .column,
            width: .points(width),
            height: .points(height),
            gap: 2,
            origin: origin,
            children: children
        )
    }

    private static func presetNode(
        _ preset: EInkPreset,
        element: EInkCanvasElement,
        slide: EInkSlide,
        orientation: EInkOrientation,
        snapshot: EInkDataSnapshot,
        frame: EInkRect
    ) -> EInkNode {
        let capacity = preset.capacity(for: orientation)
        let portrait = orientation.isPortrait
        let fieldIDs = element.fieldIDs.isEmpty ? slide.quotaFieldIDs : element.fieldIDs
        var node: EInkNode
        switch preset {
        case .quotaLedger:
            let rows = snapshot.quotaRows(fieldIDs: fieldIDs, limit: capacity)
            node = portrait
                ? EInkPresets.ledgerPortrait(rows, snapshot, frame: frame)
                : EInkPresets.ledgerLandscape(rows, snapshot, frame: frame)
        case .quotaRings:
            let rows = snapshot.quotaRows(fieldIDs: fieldIDs, limit: capacity)
            node = portrait
                ? EInkPresets.ringsPortrait(rows, snapshot, frame: frame)
                : EInkPresets.ringsLandscape(rows, snapshot, frame: frame)
        case .quotaRail:
            let rows = snapshot.quotaRows(fieldIDs: fieldIDs, limit: capacity)
            node = portrait
                ? EInkPresets.railPortrait(rows, snapshot, frame: frame)
                : EInkPresets.railLandscape(rows, snapshot, frame: frame)
        case .usageTiles:
            let periods = resolvedPeriods(element: element, slide: slide, capacity: capacity)
            node = portrait
                ? EInkPresets.tilesPortrait(periods, snapshot, frame: frame)
                : EInkPresets.tilesLandscape(periods, snapshot, frame: frame)
        case .usageSplit:
            let periods = resolvedPeriods(element: element, slide: slide, capacity: capacity)
            node = portrait
                ? EInkPresets.splitPortrait(periods, snapshot, frame: frame)
                : EInkPresets.splitLandscape(periods, snapshot, frame: frame)
        case .usageTable:
            node = portrait
                ? EInkPresets.tablePortrait(capacity, snapshot, frame: frame)
                : EInkPresets.tableLandscape(capacity, snapshot, frame: frame)
        case .usageDual:
            node = portrait
                ? EInkPresets.dualPortrait(capacity, snapshot, frame: frame)
                : EInkPresets.dualLandscape(capacity, snapshot, frame: frame)
        case .usageTrend:
            node = portrait
                ? EInkPresets.trendPortrait(snapshot, frame: frame)
                : EInkPresets.trendLandscape(snapshot, frame: frame)
        }
        node.origin = EInkPoint(x: frame.x, y: frame.y)
        node.clampInset = presetMargin
        return node
    }

    /// The windows a whole-preset element draws: its own choice, else the
    /// slide's, else all four — the reading `EInkRenderer` gives a preset
    /// slide, so the two paths cannot drift.
    static func resolvedPeriods(
        element: EInkCanvasElement,
        slide: EInkSlide,
        capacity: Int
    ) -> [EInkUsagePeriod] {
        var selected = element.periods
        if selected.isEmpty { selected = slide.usagePeriods }
        if selected.isEmpty { selected = EInkUsagePeriod.allCases }
        return Array(EInkUsagePeriod.allCases.filter(selected.contains).prefix(capacity))
    }

    // MARK: - Bindings

    static func quotaRow(for element: EInkCanvasElement, snapshot: EInkDataSnapshot) -> EInkQuotaRow? {
        guard let fieldID = element.fieldID, !fieldID.isEmpty else { return nil }
        return snapshot.quota.first { $0.fieldID == fieldID }
    }

    /// `nil` when nothing is bound — the caller then draws nothing at all.
    public static func percent(for element: EInkCanvasElement, snapshot: EInkDataSnapshot) -> Int? {
        quotaRow(for: element, snapshot: snapshot)?.remainingPercent
    }

    /// What one text-carrying element prints. Empty means "draw no box".
    public static func text(for element: EInkCanvasElement, snapshot: EInkDataSnapshot) -> String {
        switch element.textBinding {
        case .percent:
            guard let row = quotaRow(for: element, snapshot: snapshot) else { return "" }
            return "\(row.remainingPercent)%"
        case .label:
            guard let row = quotaRow(for: element, snapshot: snapshot) else { return "" }
            // Written out, never abbreviated: "Claude · Weekly", the same two
            // parts the ledger prints, because a panel read from a metre away
            // has no tooltip to expand a short form.
            return "\(row.providerDisplayName) · \(row.windowTitle)"
        case .countdown:
            guard let row = quotaRow(for: element, snapshot: snapshot) else { return "" }
            return row.countdown
        case .usageMetric:
            return usageFigure(element, snapshot: snapshot)
        case .custom:
            return element.text
        }
    }

    static func usageFigure(_ element: EInkCanvasElement, snapshot: EInkDataSnapshot) -> String {
        let totals = snapshot.usage[element.usagePeriod]
        switch element.usageMetric {
        case .cost: return EInkFormat.money(totals.costUSD)
        case .tokens: return EInkFormat.tokens(totals.tokens)
        case .requests: return EInkFormat.int(totals.requests)
        }
    }

    static func defaultCaption(for element: EInkCanvasElement, snapshot: EInkDataSnapshot) -> String {
        switch element.textBinding {
        case .usageMetric:
            return element.usagePeriod.caption
        case .custom:
            return ""
        case .percent, .label, .countdown:
            return quotaRow(for: element, snapshot: snapshot)?.providerDisplayName ?? ""
        }
    }

    static func defaultSubValue(for element: EInkCanvasElement, snapshot: EInkDataSnapshot) -> String {
        switch element.textBinding {
        case .usageMetric:
            let totals = snapshot.usage[element.usagePeriod]
            return element.usageMetric == .cost
                ? "\(EInkFormat.tokens(totals.tokens)) tokens"
                : EInkFormat.money(totals.costUSD)
        case .custom:
            return ""
        case .percent, .label, .countdown:
            return quotaRow(for: element, snapshot: snapshot)?.countdown ?? ""
        }
    }
}

// MARK: - What a custom slide needs

public extension EInkCanvasElement {
    /// Whether drawing this element walks the usage ledger.
    var readsUsage: Bool {
        if let preset = kind.preset { return preset.needsUsageData }
        switch kind {
        case .text, .statTile: return textBinding == .usageMetric
        default: return false
        }
    }

    /// Every quota bucket this element names, its own and its preset's.
    var quotaFieldIDs: [String] {
        var result: [String] = []
        if let fieldID, !fieldID.isEmpty { result.append(fieldID) }
        result.append(contentsOf: fieldIDs.filter { !$0.isEmpty })
        return result
    }
}

public extension EInkSlide {
    /// Whether this slide needs the usage ledger, custom layouts included.
    ///
    /// A custom slide that prints today's spend and is drawn from an empty
    /// ledger would print `$0.00` and be believed, which is the failure the
    /// preset path already refuses — so the answer has to look inside the
    /// layout, not only at the preset.
    func needsUsageData(layouts: [String: EInkCanvasLayout]) -> Bool {
        if let preset = kind.preset { return preset.needsUsageData }
        guard let layoutID = kind.layoutID, let layout = layouts[layoutID] else { return false }
        return layout.elements.contains { $0.readsUsage }
    }
}

public extension EInkSyncSettings {
    /// `selectedQuotaFieldIDs` plus every bucket a custom layout names.
    ///
    /// The assembler only gathers the buckets it is asked for, so a bucket
    /// that exists only inside a Studio layout would arrive missing and the
    /// element bound to it would draw nothing at all.
    func selectedQuotaFieldIDs(layouts: [String: EInkCanvasLayout]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for fieldID in selectedQuotaFieldIDs where seen.insert(fieldID).inserted {
            result.append(fieldID)
        }
        for device in devices {
            for slide in device.slides {
                guard let layoutID = slide.kind.layoutID, let layout = layouts[layoutID] else { continue }
                for element in layout.elements {
                    for fieldID in element.quotaFieldIDs where seen.insert(fieldID).inserted {
                        result.append(fieldID)
                    }
                }
            }
        }
        return result
    }
}
