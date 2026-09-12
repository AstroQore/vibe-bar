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
            let content = text(for: element, snapshot: snapshot, options: slide.options)
            guard !content.isEmpty else { return nil }
            return EInkNode(
                .text(content, font: element.font, alignment: element.alignment),
                width: element.autoWidth ? .auto : .points(width),
                height: .points(height),
                origin: origin,
                clipsText: element.autoWidth ? false : element.clipsOverflow
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
            return statTile(
                element,
                snapshot: snapshot,
                options: slide.options,
                width: width,
                height: height,
                origin: origin
            )
        case .image:
            guard !element.imageSource.isEmpty else { return nil }
            return EInkNode(
                .image(element.imageSource),
                width: .points(width),
                height: .points(height),
                origin: origin
            )
        case .fill:
            return EInkNode(
                .fill,
                width: .points(width),
                height: .points(height),
                origin: origin
            )
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
             .usageTiles, .usageSplit, .usageTable, .usageDual, .usageTrend,
             .briefing, .forecast, .resets, .heatmap, .topModels:
            return nil  // Handled above.
        }
    }

    private static func statTile(
        _ element: EInkCanvasElement,
        snapshot: EInkDataSnapshot,
        options: EInkSlideOptions,
        width: Int,
        height: Int,
        origin: EInkPoint
    ) -> EInkNode? {
        let value = statValue(for: element, snapshot: snapshot, options: options)
        let caption = caption(for: element, snapshot: snapshot, options: options)
        let sub = subValue(for: element, snapshot: snapshot, options: options)
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
        // One path through `EInkRenderer.presetTree` for the preset slide, the
        // whole-preset element and the exploder, so the three cannot drift.
        var node = EInkRenderer.presetTree(
            preset,
            slide: slide,
            orientation: orientation,
            snapshot: snapshot,
            frame: frame,
            fieldIDs: element.fieldIDs.isEmpty ? slide.orderedQuotaFieldIDs : element.fieldIDs,
            periods: resolvedPeriods(element: element, slide: slide, capacity: capacity)
        )
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

    /// A stat tile's big line.
    ///
    /// `text` is the tile's caption, so a tile bound to fixed text has
    /// nothing left to put on the big line — printing `text` there would draw
    /// the same string twice and tie the two controls together. A fixed
    /// string is what a text element is for; a tile's big line is a figure.
    public static func statValue(
        for element: EInkCanvasElement,
        snapshot: EInkDataSnapshot,
        options: EInkSlideOptions = .default
    ) -> String {
        element.textBinding == .custom ? "" : text(for: element, snapshot: snapshot, options: options)
    }

    /// A stat tile's top line: the author's, else the binding's own name.
    public static func caption(
        for element: EInkCanvasElement,
        snapshot: EInkDataSnapshot,
        options: EInkSlideOptions = .default
    ) -> String {
        element.text.isEmpty ? defaultCaption(for: element, snapshot: snapshot, options: options) : element.text
    }

    /// A stat tile's bottom line: the author's, else the binding's second
    /// figure.
    public static func subValue(
        for element: EInkCanvasElement,
        snapshot: EInkDataSnapshot,
        options: EInkSlideOptions = .default
    ) -> String {
        element.subText.isEmpty ? defaultSubValue(for: element, snapshot: snapshot, options: options) : element.subText
    }

    /// The bucket behind an element, wearing the name the slide gives it.
    ///
    /// `options` is not optional decoration: the slide editor and the Studio
    /// inspector both write a per-bucket name into `EInkSlideOptions`, and a
    /// custom layout that read the bucket's own name instead would accept the
    /// edit, store it, and keep drawing the old name on the panel.
    static func quotaRow(
        for element: EInkCanvasElement,
        snapshot: EInkDataSnapshot,
        options: EInkSlideOptions = .default
    ) -> EInkQuotaRow? {
        guard let fieldID = element.fieldID, !fieldID.isEmpty else { return nil }
        return snapshot.quota.first { $0.fieldID == fieldID }?.relabeled(with: options)
    }

    /// `nil` when nothing is bound — the caller then draws nothing at all.
    ///
    /// A bar with a bucket behind it reads that bucket, and reads nothing when
    /// the bucket is missing: a stand-in percentage on a glanceable surface is
    /// indistinguishable from a reading. An *unbound* bar falls back to its
    /// author's fixed percentage, which is what the exploded usage layouts
    /// carry — a "share of the biggest harness" bar is a real number, it is
    /// just not a quota bucket.
    public static func percent(for element: EInkCanvasElement, snapshot: EInkDataSnapshot) -> Int? {
        if let fieldID = element.fieldID, !fieldID.isEmpty {
            return snapshot.quota.first { $0.fieldID == fieldID }?.remainingPercent
        }

        guard let override = element.percentOverride else { return nil }
        return max(0, min(100, Int(override.rounded())))
    }

    /// What one text-carrying element prints. Empty means "draw no box".
    public static func text(
        for element: EInkCanvasElement,
        snapshot: EInkDataSnapshot,
        options: EInkSlideOptions = .default
    ) -> String {
        switch element.textBinding {
        case .percent:
            guard let row = quotaRow(for: element, snapshot: snapshot, options: options) else { return "" }
            return "\(row.remainingPercent)%"
        case .label:
            guard let row = quotaRow(for: element, snapshot: snapshot, options: options) else { return "" }
            // Written out, never abbreviated: the SubProvider, the quota group
            // and the window, because a panel read from a metre away has no
            // tooltip to expand a short form. A name too long for one line is
            // drawn as two boxes, and each one prints only its own part.
            return element.labelPart.text(of: row)
        case .countdown:
            guard let row = quotaRow(for: element, snapshot: snapshot, options: options) else { return "" }
            return row.countdown
        case .usageMetric:
            return usageFigure(element, snapshot: snapshot)
        case .clock:
            return snapshot.clockLabel
        case .date:
            return snapshot.dateLabel
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

    static func defaultCaption(
        for element: EInkCanvasElement,
        snapshot: EInkDataSnapshot,
        options: EInkSlideOptions = .default
    ) -> String {
        switch element.textBinding {
        case .usageMetric:
            return element.usagePeriod.caption
        case .custom, .clock, .date:
            return ""
        case .percent, .label, .countdown:
            return quotaRow(for: element, snapshot: snapshot, options: options)?.providerDisplayName ?? ""
        }
    }

    static func defaultSubValue(
        for element: EInkCanvasElement,
        snapshot: EInkDataSnapshot,
        options: EInkSlideOptions = .default
    ) -> String {
        switch element.textBinding {
        case .usageMetric:
            let totals = snapshot.usage[element.usagePeriod]
            return element.usageMetric == .cost
                ? "\(EInkFormat.tokens(totals.tokens)) tokens"
                : EInkFormat.money(totals.costUSD)
        case .custom, .clock, .date:
            return ""
        case .percent, .label, .countdown:
            return quotaRow(for: element, snapshot: snapshot, options: options)?.countdown ?? ""
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
    /// Every layout this slide has, across orientations.
    ///
    /// A custom slide carries up to four, keyed `"<layoutID>/<degrees>"`, and
    /// a scan that asks only for `layouts[layoutID]` finds none of them. That
    /// matters for more than tidiness: these scans decide whether the pass
    /// walks the ledger and which quota buckets it gathers, so missing them
    /// draws a bound element from data nobody fetched — `$0.00` on a panel, or
    /// a blank where a percentage should be.
    func allLayouts(in layouts: [String: EInkCanvasLayout]) -> [EInkCanvasLayout] {
        guard let layoutID = kind.layoutID, !layoutID.isEmpty else { return [] }
        let prefix = layoutID + "/"
        return layouts
            .filter { $0.key == layoutID || $0.key.hasPrefix(prefix) }
            .sorted { $0.key < $1.key }
            .map(\.value)
    }

    /// Whether this slide needs the usage ledger, custom layouts included.
    ///
    /// A custom slide that prints today's spend and is drawn from an empty
    /// ledger would print `$0.00` and be believed, which is the failure the
    /// preset path already refuses — so the answer has to look inside the
    /// layout, not only at the preset.
    func needsUsageData(layouts: [String: EInkCanvasLayout]) -> Bool {
        if let preset = kind.preset { return preset.needsUsageData }
        return allLayouts(in: layouts).contains { layout in
            layout.elements.contains { $0.readsUsage }
        }
    }
}

public extension EInkSyncSettings {
    /// `selectedQuotaFieldIDs` plus every bucket a custom layout names.
    ///
    /// The assembler only gathers the buckets it is asked for, so a bucket
    /// that exists only inside a Studio layout would arrive missing and the
    /// element bound to it would draw nothing at all.
    /// `referencedQuotaFieldIDs` plus every bucket a custom layout names.
    ///
    /// This is the *keep* set the quota registry is pruned against. A bucket
    /// chosen only inside a Studio layout has no mini window, no menu-bar
    /// block and no slide-level selection behind it, so without this a
    /// provider response that briefly omits it would drop it from the
    /// registry — and the element bound to it would lose its option while
    /// still pointing at it.
    func referencedQuotaFieldIDs(layouts: [String: EInkCanvasLayout]) -> Set<String> {
        var result = referencedQuotaFieldIDs
        for device in devices {
            for slide in device.slides {
                for layout in slide.allLayouts(in: layouts) {
                    for element in layout.elements {
                        result.formUnion(element.quotaFieldIDs)
                    }
                }
            }
        }
        return result
    }

    func selectedQuotaFieldIDs(layouts: [String: EInkCanvasLayout]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for fieldID in selectedQuotaFieldIDs where seen.insert(fieldID).inserted {
            result.append(fieldID)
        }
        for device in devices {
            for slide in device.slides {
                for layout in slide.allLayouts(in: layouts) {
                    for element in layout.elements {
                        for fieldID in element.quotaFieldIDs where seen.insert(fieldID).inserted {
                            result.append(fieldID)
                        }
                        // A quota block with no selection of its own draws the
                        // slide's buckets, and those are not in
                        // `selectedQuotaFieldIDs`, which only looks at preset
                        // slides. Without this, a slide converted from a preset
                        // keeps buckets the assembler is never asked for and the
                        // block silently drops those rows.
                        guard element.kind.preset?.isQuotaPreset == true, element.fieldIDs.isEmpty else { continue }
                        for fieldID in slide.quotaFieldIDs where seen.insert(fieldID).inserted {
                            result.append(fieldID)
                        }
                    }
                }
            }
        }
        return result
    }
}
