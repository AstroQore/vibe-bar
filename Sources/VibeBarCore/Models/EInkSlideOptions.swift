import Foundation

/// What one side of a header bar prints.
///
/// `presetDefault` is the important case: it means "whatever this preset has
/// always printed here", which is how a slide that nobody has configured
/// reproduces the shipped layout byte for byte. Everything else is a
/// deliberate choice the slide editor made.
public enum EInkBarContent: Codable, Equatable, Hashable, Sendable {
    case presetDefault
    case none
    case text(String)
    /// `HH:mm` at assembly time.
    case clock
    /// `MM-dd` at assembly time.
    case date
    /// `MM-dd HH:mm`, the label every shipped header carries.
    case dateClock
    /// One line from `ServiceStatusClient`: "Anthropic: degraded" or
    /// "All providers operational".
    case providerStatus

    private enum Tag: String, Codable {
        case presetDefault, none, text, clock, date, dateClock, providerStatus
    }

    private enum CodingKeys: String, CodingKey { case kind, text }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch c.lenient(Tag.self, .kind, .presetDefault) {
        case .presetDefault: self = .presetDefault
        case .none: self = .none
        case .text: self = .text(EInkCanvasLayout.panelText(c.lenient(String.self, .text, "")))
        case .clock: self = .clock
        case .date: self = .date
        case .dateClock: self = .dateClock
        case .providerStatus: self = .providerStatus
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .presetDefault: try c.encode(Tag.presetDefault, forKey: .kind)
        case .none: try c.encode(Tag.none, forKey: .kind)
        case let .text(value):
            try c.encode(Tag.text, forKey: .kind)
            try c.encode(EInkCanvasLayout.panelText(value), forKey: .text)
        case .clock: try c.encode(Tag.clock, forKey: .kind)
        case .date: try c.encode(Tag.date, forKey: .kind)
        case .dateClock: try c.encode(Tag.dateClock, forKey: .kind)
        case .providerStatus: try c.encode(Tag.providerStatus, forKey: .kind)
        }
    }
}

/// The optional bar at the top (or bottom) of every preset.
public struct EInkBarConfig: Codable, Equatable, Hashable, Sendable {
    public enum Position: String, Codable, CaseIterable, Sendable {
        case top
        case bottom
    }

    public var position: Position
    public var left: EInkBarContent
    public var right: EInkBarContent

    public init(
        position: Position = .top,
        left: EInkBarContent = .presetDefault,
        right: EInkBarContent = .presetDefault
    ) {
        self.position = position
        self.left = left
        self.right = right
    }

    private enum CodingKeys: String, CodingKey { case position, left, right }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            position: c.lenient(Position.self, .position, .top),
            left: c.lenient(EInkBarContent.self, .left, .presetDefault),
            right: c.lenient(EInkBarContent.self, .right, .presetDefault)
        )
    }
}

/// What the optional footer prints.
public enum EInkFooterContent: Codable, Equatable, Hashable, Sendable {
    case presetDefault
    case usageSummary(periods: [EInkUsagePeriod])
    case clock
    case text(String)

    private enum Tag: String, Codable { case presetDefault, usageSummary, clock, text }
    private enum CodingKeys: String, CodingKey { case kind, periods, text }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch c.lenient(Tag.self, .kind, .presetDefault) {
        case .presetDefault:
            self = .presetDefault
        case .usageSummary:
            let raw = c.lenient([String].self, .periods, [])
            let periods = raw.compactMap(EInkUsagePeriod.init(rawValue:))
            self = .usageSummary(periods: periods.isEmpty ? [.today, .week] : periods)
        case .clock:
            self = .clock
        case .text:
            self = .text(EInkCanvasLayout.panelText(c.lenient(String.self, .text, "")))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .presetDefault:
            try c.encode(Tag.presetDefault, forKey: .kind)
        case let .usageSummary(periods):
            try c.encode(Tag.usageSummary, forKey: .kind)
            try c.encode(periods.map(\.rawValue), forKey: .periods)
        case .clock:
            try c.encode(Tag.clock, forKey: .kind)
        case let .text(value):
            try c.encode(Tag.text, forKey: .kind)
            try c.encode(EInkCanvasLayout.panelText(value), forKey: .text)
        }
    }
}

public struct EInkFooterConfig: Codable, Equatable, Hashable, Sendable {
    public var content: EInkFooterContent

    public init(content: EInkFooterContent = .presetDefault) {
        self.content = content
    }

    private enum CodingKeys: String, CodingKey { case content }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(content: c.lenient(EInkFooterContent.self, .content, .presetDefault))
    }
}

/// How one slide composes the preset it draws.
///
/// Every field has a default that means "unchanged", so a slide written by
/// round 1 decodes into options that reproduce its old panel exactly — the
/// property `EInkPresetGoldenTests` asserts rather than assumes.
public struct EInkSlideOptions: Codable, Equatable, Hashable, Sendable {
    /// `nil` draws no header bar at all and hands the height to the body.
    public var header: EInkBarConfig?
    /// `nil` draws no footer.
    public var footer: EInkFooterConfig?
    /// Field ids / period raw values in display order. Empty keeps the
    /// slide's own order.
    public var slotOrder: [String]
    /// Field id → the label this slide prints for that slot. Empty string or
    /// missing key means `EInkSlotLabel.default`.
    public var customLabels: [String: String]
    /// Tighter rows so a slide with no header and no footer fills the panel.
    public var compact: Bool
    /// Whether this slide's slots name their provider in words or with its
    /// mark. `.text` is what every slide drew before the marks existed.
    public var labelStyle: EInkSlotLabelStyle
    /// Field id → that one slot's style, overriding `labelStyle`. A panel is
    /// allowed to be mixed: the two buckets with three-tier names are the
    /// ones that need the pixels, and the others can stay in words.
    public var labelStyles: [String: EInkSlotLabelStyle]
    /// The preset this slide drew before "Edit in Studio" exploded it.
    ///
    /// `nil` on a slide that was never converted. It exists so "Reset to
    /// preset" restores the layout the author actually left: the conversion
    /// replaces `kind` with `.custom`, and without this the only honest answer
    /// afterwards is "some preset", which meant a Briefing came back as a
    /// ledger.
    public var sourcePreset: EInkPreset?

    public init(
        header: EInkBarConfig? = EInkBarConfig(),
        footer: EInkFooterConfig? = EInkFooterConfig(),
        slotOrder: [String] = [],
        customLabels: [String: String] = [:],
        compact: Bool = false,
        labelStyle: EInkSlotLabelStyle = .text,
        labelStyles: [String: EInkSlotLabelStyle] = [:],
        sourcePreset: EInkPreset? = nil
    ) {
        self.header = header
        self.footer = footer
        self.slotOrder = slotOrder
        self.customLabels = customLabels
        self.compact = compact
        self.labelStyle = labelStyle
        self.labelStyles = labelStyles
        self.sourcePreset = sourcePreset
    }

    /// Exactly what round 1 drew: a top header and the preset's own footer.
    public static let `default` = EInkSlideOptions()

    public var sanitized: EInkSlideOptions {
        var copy = self
        var seen = Set<String>()
        copy.slotOrder = slotOrder.filter { !$0.isEmpty && seen.insert($0).inserted }
        copy.labelStyles = labelStyles.filter { !$0.key.isEmpty }
        copy.customLabels = customLabels.reduce(into: [:]) { result, entry in
            let trimmed = entry.value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !entry.key.isEmpty, !trimmed.isEmpty else { return }
            result[entry.key] = EInkCanvasLayout.panelText(String(trimmed.prefix(96)))
        }
        return copy
    }

    /// How this slide names one slot: the slot's own style, else the
    /// slide's.
    public func labelStyle(for fieldID: String) -> EInkSlotLabelStyle {
        labelStyles[fieldID] ?? labelStyle
    }

    /// The label this slide prints for a slot, or `nil` for the default.
    public func customLabel(for fieldID: String) -> String? {
        guard let raw = customLabels[fieldID] else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// `ids` in the slide's configured order: everything `slotOrder` names
    /// that is actually present, then whatever `slotOrder` did not mention.
    ///
    /// Reordering must never *drop* a slot: a saved order predates the
    /// bucket the user ticked a moment ago, and silently hiding it would read
    /// as the picker not working.
    public func ordered(_ ids: [String]) -> [String] {
        guard !slotOrder.isEmpty else { return ids }
        let available = Set(ids)
        var seen = Set<String>()
        var result = slotOrder.filter { available.contains($0) && seen.insert($0).inserted }
        result += ids.filter { seen.insert($0).inserted }
        return result
    }

    private enum CodingKeys: String, CodingKey {
        case header, footer, hasHeader, hasFooter, slotOrder, customLabels, compact
        case labelStyle, labelStyles, sourcePreset
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // `hasHeader` is written beside the config so "off" survives a
        // round trip: an absent `header` key is also what a round 1 file
        // looks like, and those must decode as "on".
        let hasHeader = c.lenient(Bool.self, .hasHeader, true)
        let hasFooter = c.lenient(Bool.self, .hasFooter, true)
        self.init(
            header: hasHeader ? c.lenient(EInkBarConfig.self, .header, EInkBarConfig()) : nil,
            footer: hasFooter ? c.lenient(EInkFooterConfig.self, .footer, EInkFooterConfig()) : nil,
            slotOrder: c.lenient([String].self, .slotOrder, []),
            customLabels: c.lenient([String: String].self, .customLabels, [:]),
            compact: c.lenient(Bool.self, .compact, false),
            labelStyle: c.lenient(EInkSlotLabelStyle.self, .labelStyle, .text),
            labelStyles: c.lenient([String: EInkSlotLabelStyle].self, .labelStyles, [:]),
            sourcePreset: c.lenientOptional(EInkPreset.self, .sourcePreset)
        )
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(header != nil, forKey: .hasHeader)
        try c.encodeIfPresent(header, forKey: .header)
        try c.encode(footer != nil, forKey: .hasFooter)
        try c.encodeIfPresent(footer, forKey: .footer)
        try c.encode(slotOrder, forKey: .slotOrder)
        try c.encode(customLabels, forKey: .customLabels)
        try c.encode(compact, forKey: .compact)
        try c.encode(labelStyle, forKey: .labelStyle)
        try c.encode(labelStyles, forKey: .labelStyles)
        try c.encodeIfPresent(sourcePreset, forKey: .sourcePreset)
    }
}
