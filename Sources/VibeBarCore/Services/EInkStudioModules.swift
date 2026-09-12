import Foundation

/// What the Studio's palette is allowed to put on the paper, and what each
/// entry drops.
///
/// Two things went wrong in round 1 and both are fixed here.
///
/// The palette was `Kind.allCases` minus the preset blocks, which quietly
/// included `.fill` — a solid black rectangle with no binding, no inspector
/// controls and the generic name "Element". Clicking it put an unexplained
/// black block on the panel, which is exactly the block the owner's review
/// reported. `.image` came through the same hole: it is the container an
/// exploded heatmap's raster lives in, not something an author can draw, and
/// an empty one draws nothing at all. Neither is authorable, so neither is in
/// `authorPlaceable` — and `EInkStudioModuleTests` holds that list so the next
/// `Kind` case cannot leak into the palette by existing.
///
/// The second thing is that an author had primitives and nothing else: to get
/// a quota row they placed four elements and bound each one. A module drops
/// the finished group with its bindings already made, which is the same shape
/// `EInkPresetExploder` produces — so a dropped module and an exploded preset
/// are the same kind of object, and Ungroup splits either one.
public enum EInkStudioModule: String, CaseIterable, Identifiable, Sendable {
    /// The bar every preset draws at the top: a fixed title and the date.
    case headerBar
    /// One quota bucket: name, bar, percentage, countdown.
    case quotaSlot
    /// One usage window: caption and figure.
    case usageSlot
    /// The rule and the two spend lines a preset prints underneath.
    case footer

    public var id: String { rawValue }

    /// The module id the dropped group carries, so the Studio can say what a
    /// group is and "Re-layout" can tell a module from a hand-drawn element.
    public func moduleID(fieldID: String?) -> String {
        switch self {
        case .headerBar: EInkPresets.headerModule
        case .footer: EInkPresets.footerModule
        case .quotaSlot: EInkPresets.slotModule(fieldID ?? "")
        case .usageSlot: "usage"
        }
    }
}

public enum EInkStudioModules {
    /// Every element kind an author can place by hand.
    ///
    /// Deliberately a written list rather than a filter over `allCases`: the
    /// two kinds that are *not* on it exist only as the far side of an
    /// explode, and a filter is how they reached the palette in the first
    /// place.
    public static let authorPlaceable: [EInkCanvasElement.Kind] = [
        .text, .ring, .horizontalBar, .verticalBar, .statTile, .divider
    ]

    /// The whole-preset blocks, in the order the settings picker groups them.
    public static var presetBlocks: [EInkCanvasElement.Kind] {
        EInkPreset.userSelectable.compactMap { preset in
            EInkCanvasElement.Kind.allCases.first { $0.preset == preset }
        }
    }

    // MARK: - Dropping a module

    /// The elements one module drops, already grouped and bound.
    ///
    /// `fieldID` is the bucket a quota slot binds to; `period` the window a
    /// usage slot reads. `origin` is where the group's top-left lands.
    public static func elements(
        _ module: EInkStudioModule,
        fieldID: String? = nil,
        period: EInkUsagePeriod = .today,
        width: Double,
        origin: EInkPoint
    ) -> [EInkCanvasElement] {
        let group = UUID()
        let moduleID = module.moduleID(fieldID: fieldID)
        let x = Double(origin.x)
        let y = Double(origin.y)
        var result: [EInkCanvasElement] = []

        func make(
            _ kind: EInkCanvasElement.Kind,
            _ binding: EInkCanvasElement.TextBinding,
            dx: Double,
            dy: Double,
            w: Double,
            h: Double,
            align: EInkTextAlignment = .leading,
            text: String = "",
            bold: Bool = false
        ) {
            var element = EInkCanvasElement(kind: kind)
            element.x = x + dx
            element.y = y + dy
            element.width = w
            element.height = h
            element.font = .pixel12(bold: bold)
            element.alignment = align
            element.textBinding = binding
            element.text = text
            element.autoWidth = false
            element.clipsOverflow = false
            if binding == .percent || binding == .label || binding == .countdown || kind != .text {
                element.fieldID = fieldID
            }
            if binding == .usageMetric { element.usagePeriod = period }
            element.groupID = group
            element.moduleID = moduleID
            result.append(element)
        }

        switch module {
        case .headerBar:
            make(.text, .custom, dx: 0, dy: 0, w: width / 2, h: 12, text: "VIBE BAR", bold: true)
            make(.text, .date, dx: width / 2, dy: 0, w: width / 2, h: 12, align: .trailing)
        case .quotaSlot:
            make(.text, .label, dx: 0, dy: 0, w: width, h: 12, bold: true)
            make(.horizontalBar, .percent, dx: 0, dy: 13, w: width - 76, h: 10)
            make(.text, .percent, dx: width - 72, dy: 12, w: 32, h: 12, align: .trailing)
            make(.text, .countdown, dx: width - 38, dy: 12, w: 38, h: 12, align: .trailing)
        case .usageSlot:
            make(.text, .custom, dx: 0, dy: 0, w: width, h: 12, text: period.caption, bold: true)
            var figure = EInkCanvasElement(kind: .text)
            figure.x = x
            figure.y = y + 13
            figure.width = width
            figure.height = 18
            figure.font = .sans(size: 18, bold: true)
            figure.textBinding = .usageMetric
            figure.usagePeriod = period
            figure.usageMetric = .cost
            figure.autoWidth = false
            figure.clipsOverflow = false
            figure.groupID = group
            figure.moduleID = moduleID
            result.append(figure)
        case .footer:
            var rule = EInkCanvasElement(kind: .divider)
            rule.x = x
            rule.y = y
            rule.width = width
            rule.height = 1
            rule.groupID = group
            rule.moduleID = moduleID
            result.append(rule)
            // A caption beside each figure, as `EInkPresets.usageSummaryFooter`
            // prints them. Two bare amounts on a panel read from across a room
            // are two numbers nobody can tell apart.
            let half = width / 2
            make(.text, .custom, dx: 0, dy: 3, w: 46, h: 12, text: EInkUsagePeriod.today.caption, bold: true)
            make(.text, .usageMetric, dx: 48, dy: 3, w: half - 52, h: 12)
            make(.text, .custom, dx: half, dy: 3, w: 48, h: 12, text: EInkUsagePeriod.week.caption, bold: true)
            make(.text, .usageMetric, dx: half + 50, dy: 3, w: half - 50, h: 12, align: .trailing)
            result[2].usagePeriod = .today
            result[4].usagePeriod = .week
        }
        return result
    }

    /// A whole preset dropped as the groups it is made of.
    ///
    /// The exploder, not a second arrangement of the same boxes: a preset
    /// module and "Edit in Studio" on that preset have to produce identical
    /// paper, or the palette is teaching a layout the device does not draw.
    public static func presetElements(
        _ preset: EInkPreset,
        slide: EInkSlide,
        orientation: EInkOrientation,
        profile: EInkDeviceProfile = .quote0,
        snapshot: EInkDataSnapshot,
        calendar: Calendar = .current
    ) -> [EInkCanvasElement] {
        var presetSlide = slide
        presetSlide.kind = .preset(preset)
        return EInkPresetExploder.explode(
            slide: presetSlide.fitted(to: orientation),
            orientation: orientation,
            profile: profile,
            snapshot: snapshot,
            calendar: calendar
        ).elements
    }
}

public extension EInkCanvasLayout {
    /// Adds a finished group to the layout and returns what to select.
    ///
    /// Separate from `add(_:)` because that one invents a position for a
    /// single element; a module arrives already arranged and must not have its
    /// members re-placed one at a time.
    @discardableResult
    mutating func insert(_ incoming: [EInkCanvasElement]) -> Set<UUID> {
        guard !incoming.isEmpty else { return [] }
        elements.append(contentsOf: incoming)
        self = normalized()
        return Set(incoming.map(\.id))
    }

    /// Where the next module should land: below everything already placed, or
    /// at the safe margin on an empty panel.
    var nextModuleOrigin: EInkPoint {
        let bottom = elements.map { $0.y + $0.height }.max() ?? 0
        let y = bottom <= 0 ? Self.safeMargin : bottom + 4
        return EInkPoint(x: Int(Self.safeMargin), y: Int(min(max(0, height - 12), y)))
    }
}
