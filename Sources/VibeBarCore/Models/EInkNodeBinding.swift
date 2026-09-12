import Foundation

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

    public init(
        kind: EInkCanvasElement.TextBinding,
        fieldID: String? = nil,
        usagePeriod: EInkUsagePeriod = .today,
        usageMetric: EInkCanvasElement.UsageMetric = .cost
    ) {
        self.kind = kind
        self.fieldID = fieldID
        self.usagePeriod = usagePeriod
        self.usageMetric = usageMetric
    }

    public static func quota(_ fieldID: String, _ kind: EInkCanvasElement.TextBinding) -> EInkNodeBinding {
        EInkNodeBinding(kind: kind, fieldID: fieldID)
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
    }
}
