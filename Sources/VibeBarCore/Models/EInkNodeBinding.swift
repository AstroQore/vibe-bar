import Foundation

/// Which part of a slot's name one box prints.
///
/// A slot label is three tiers — SubProvider, quota group, window — and a
/// panel 296 px wide cannot always print them on one line. When a preset
/// breaks a name across two boxes, each box says which half it holds, so the
/// Studio can explode the slide and still follow the bucket.
public enum EInkSlotLabelPart: String, Codable, CaseIterable, Hashable, Sendable {
    /// "ChatGPT Agentic · GPT-5.3 Codex Spark · Weekly".
    case whole
    /// The SubProvider alone: "ChatGPT Agentic".
    case name
    /// Everything after it: "GPT-5.3 Codex Spark · Weekly".
    case window
    /// The window word alone: "Weekly", "5 Hours". What a slot set to show
    /// its provider's mark and nothing else still needs to say.
    case period

    /// English, like every other string the panel itself draws.
    public var identifierName: String {
        switch self {
        case .whole: "Full Name"
        case .name: "Provider"
        case .window: "Group and Window"
        case .period: "Window"
        }
    }

    /// This part of one row's name.
    public func text(of row: EInkQuotaRow) -> String {
        switch self {
        case .whole: row.slotLabel
        case .name: row.providerDisplayName
        case .window: row.windowTitle
        case .period: row.windowTitle.components(separatedBy: EInkSlotLabel.separator).last ?? ""
        }
    }
}

/// What a preset node draws, in the same vocabulary a Studio element uses.
///
/// The two have to agree: `EInkPresetExploder` turns a preset's nodes into
/// canvas elements, and a binding that did not map onto one would come out the
/// far side as frozen text — a panel that stopped following the data without
/// saying so.
public struct EInkNodeBinding: Equatable, Hashable, Sendable {
    public var kind: EInkCanvasElement.TextBinding
    /// `MenuBarFieldCatalog` field id, for the quota bindings.
    public var fieldID: String?
    public var usagePeriod: EInkUsagePeriod
    public var usageMetric: EInkCanvasElement.UsageMetric
    /// Which half of the name a `label` binding draws.
    public var labelPart: EInkSlotLabelPart

    public init(
        kind: EInkCanvasElement.TextBinding,
        fieldID: String? = nil,
        usagePeriod: EInkUsagePeriod = .today,
        usageMetric: EInkCanvasElement.UsageMetric = .cost,
        labelPart: EInkSlotLabelPart = .whole
    ) {
        self.kind = kind
        self.fieldID = fieldID
        self.usagePeriod = usagePeriod
        self.usageMetric = usageMetric
        self.labelPart = labelPart
    }

    public static func quota(_ fieldID: String, _ kind: EInkCanvasElement.TextBinding) -> EInkNodeBinding {
        EInkNodeBinding(kind: kind, fieldID: fieldID)
    }

    /// One part of a slot's name — what a wrapped label's two boxes bind to.
    public static func slotLabel(_ fieldID: String, part: EInkSlotLabelPart) -> EInkNodeBinding {
        EInkNodeBinding(kind: .label, fieldID: fieldID, labelPart: part)
    }

    public static func usage(
        _ period: EInkUsagePeriod,
        _ metric: EInkCanvasElement.UsageMetric
    ) -> EInkNodeBinding {
        EInkNodeBinding(kind: .usageMetric, usagePeriod: period, usageMetric: metric)
    }

    public static let clock = EInkNodeBinding(kind: .clock)
    public static let date = EInkNodeBinding(kind: .date)
    /// Fixed text: the element keeps the string the preset printed.
    public static let staticText = EInkNodeBinding(kind: .custom)

    /// Applies this binding to an element, so the exploded element reads the
    /// same value the preset node did.
    public func apply(to element: inout EInkCanvasElement) {
        element.textBinding = kind
        element.fieldID = fieldID
        element.usagePeriod = usagePeriod
        element.usageMetric = usageMetric
        element.labelPart = labelPart
    }
}
