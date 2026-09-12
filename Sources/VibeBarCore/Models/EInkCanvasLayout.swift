import CoreGraphics
import Foundation

/// A custom E-ink slide's free layout, stored under its own top-level
/// `einkCanvasLayouts` key for the same merge reason `miniCanvasLayouts` has
/// one.
///
/// Deliberately a near-copy of `MiniCanvasLayout`: the Studio drives both
/// through the same `normalized / moving / add / resize / duplicate / group /
/// ungroup / reorder` vocabulary. The differences are all consequences of the
/// panel: the canvas size is fixed by the device profile and orientation
/// rather than user-resizable, every coordinate is a whole device pixel, and
/// the major grid is 8 px ("main pixels") rather than 24.
public struct EInkCanvasLayout: Codable, Equatable, Hashable, Sendable {
    /// Fixed by `EInkDeviceProfile.frameSize(for:)`; stored so a layout still
    /// renders when its device is offline or has been removed.
    public var width: Double = 296
    public var height: Double = 152
    /// `true` snaps to the 8 px major grid, `false` to single pixels. Either
    /// way coordinates stay integral.
    public var snapToGrid = false
    public static let gridSpacing: Double = 8
    /// The device draws whole pixels; nothing is ever placed on a half pixel.
    public static let pixelSpacing: Double = 1
    /// Safe margin every preset and element keeps from the panel edge.
    public static let safeMargin: Double = 6
    public var elements: [EInkCanvasElement] = []

    public init() {}

    public init(profile: EInkDeviceProfile, orientation: EInkOrientation) {
        let size = profile.frameSize(for: orientation)
        width = Double(size.width)
        height = Double(size.height)
    }

    /// The snapping step currently in force.
    public var step: Double { snapToGrid ? Self.gridSpacing : Self.pixelSpacing }

    public func normalized() -> Self {
        var copy = self
        copy.width = Self.bound(width, 32...4096, fallback: 296).rounded()
        copy.height = Self.bound(height, 32...4096, fallback: 152).rounded()
        let grid = copy.step
        var seen = Set<UUID>()
        copy.elements = elements.filter { seen.insert($0.id).inserted }.map { element in
            var e = element
            e.width = Self.bound(e.width, 1...copy.width, fallback: 48)
            e.height = Self.bound(e.height, 1...copy.height, fallback: 12)
            e.width = min(copy.width, max(grid, (e.width / grid).rounded() * grid))
            e.height = min(copy.height, max(grid, (e.height / grid).rounded() * grid))
            e.x = Self.bound(e.x, 0...(copy.width - e.width), fallback: 0)
            e.y = Self.bound(e.y, 0...(copy.height - e.height), fallback: 0)
            e.x = min(copy.width - e.width, max(0, (e.x / grid).rounded() * grid))
            e.y = min(copy.height - e.height, max(0, (e.y / grid).rounded() * grid))
            e.font = e.font.normalized
            e.thickness = Self.bound(e.thickness, 1...32, fallback: 6).rounded()
            e.percentOverride = e.percentOverride.map { Self.bound($0, 0...100, fallback: 0).rounded() }
            var seenFields = Set<String>()
            e.fieldIDs = e.fieldIDs.filter { !$0.isEmpty && seenFields.insert($0).inserted }
            var seenPeriods = Set<EInkUsagePeriod>()
            e.periods = EInkUsagePeriod.allCases.filter { e.periods.contains($0) && seenPeriods.insert($0).inserted }
            return e
        }
        return copy
    }

    /// The same layout on a differently shaped panel.
    ///
    /// Turning a device is not a re-design: an element keeps the pixel it was
    /// placed on. What changes is the room around it, so `normalized` does the
    /// rest — an element wider or taller than the new panel is shrunk to it,
    /// and one whose far edge now falls outside is pulled back in by exactly
    /// the overhang, keeping its size. A portrait layout turned landscape
    /// therefore ends up with its lower rows stacked against the bottom edge
    /// rather than scattered, and the Studio's diagnostics say what collided.
    public func fitted(profile: EInkDeviceProfile, orientation: EInkOrientation) -> Self {
        let size = profile.frameSize(for: orientation)
        var copy = self
        copy.width = Double(size.width)
        copy.height = Double(size.height)
        return copy.normalized()
    }

    public func expandedSelection(_ ids: Set<UUID>) -> Set<UUID> {
        let groups = Set(elements.filter { ids.contains($0.id) }.compactMap(\.groupID))
        return ids.union(elements.filter { $0.groupID.map(groups.contains) ?? false }.map(\.id))
    }

    /// Clamp the selection as a unit, preserving relative positions at edges.
    public func moving(_ ids: Set<UUID>, dx: Double, dy: Double, majorGrid: Bool = false) -> Self {
        var copy = normalized()
        let ids = copy.expandedSelection(ids)
        let selected = copy.elements.filter { ids.contains($0.id) }
        guard !selected.isEmpty, dx.isFinite, dy.isFinite else { return copy }
        let minX = selected.map(\.x).min()!, minY = selected.map(\.y).min()!
        let maxX = selected.map { $0.x + $0.width }.max()!
        let maxY = selected.map { $0.y + $0.height }.max()!
        let grid = majorGrid ? Self.gridSpacing : copy.step
        let proposedX = (dx / grid).rounded() * grid
        let proposedY = (dy / grid).rounded() * grid
        let tx = min(max(proposedX, -minX), copy.width - maxX)
        let ty = min(max(proposedY, -minY), copy.height - maxY)
        for i in copy.elements.indices where ids.contains(copy.elements[i].id) {
            copy.elements[i].x += tx
            copy.elements[i].y += ty
        }
        return copy.normalized()
    }

    @discardableResult
    public mutating func add(
        _ kind: EInkCanvasElement.Kind,
        fieldID: String? = nil,
        x: Double? = nil,
        y: Double? = nil
    ) -> UUID {
        self = normalized()
        var e = EInkCanvasElement(kind: kind, fieldID: fieldID)
        e.x = x ?? Self.safeMargin
        e.y = y ?? Self.safeMargin
        if x == nil, y == nil {
            // Palette clicks land in the first free run of grid cells.
            let occupied = elements.map { CGRect(x: $0.x, y: $0.y, width: $0.width, height: $0.height) }
            let grid = Self.gridSpacing
            var position: CGPoint?
            for row in stride(from: Self.safeMargin, through: max(0, height - e.height), by: grid) {
                for column in stride(from: Self.safeMargin, through: max(0, width - e.width), by: grid) {
                    let rect = CGRect(x: column, y: row, width: e.width, height: e.height)
                    if !occupied.contains(where: { $0.intersects(rect) }) { position = rect.origin; break }
                }
                if position != nil { break }
            }
            e.x = position.map { Double($0.x) } ?? Self.safeMargin
            e.y = position.map { Double($0.y) } ?? Self.safeMargin
        }
        elements.append(e)
        self = normalized()
        return e.id
    }

    public mutating func resize(_ id: UUID, width: Double, height: Double) {
        guard width > 0, height > 0,
              let index = elements.firstIndex(where: { $0.id == id }) else { return }
        elements[index].width = width
        elements[index].height = height
        self = normalized()
    }

    @discardableResult
    public mutating func duplicate(_ ids: Set<UUID>) -> Set<UUID> {
        let ids = expandedSelection(ids)
        var groups: [UUID: UUID] = [:]
        let copies = elements.filter { ids.contains($0.id) }.map { original -> EInkCanvasElement in
            var e = original
            e.id = UUID()
            if let group = e.groupID {
                if groups[group] == nil { groups[group] = UUID() }
                e.groupID = groups[group]
            }
            return e
        }
        guard !copies.isEmpty else { return [] }
        elements.append(contentsOf: copies)
        let newIDs = Set(copies.map(\.id))
        self = moving(newIDs, dx: Self.gridSpacing, dy: Self.gridSpacing)
        return newIDs
    }

    public mutating func group(_ ids: Set<UUID>) {
        let ids = expandedSelection(ids)
        guard ids.count > 1 else { return }
        let selected = elements.filter { ids.contains($0.id) }
        if let existing = selected.first?.groupID, selected.allSatisfy({ $0.groupID == existing }) { return }
        guard let last = elements.lastIndex(where: { ids.contains($0.id) }) else { return }
        let insertion = elements.prefix(last).filter { !ids.contains($0.id) }.count
        let group = UUID()
        var members = selected
        for i in members.indices { members[i].groupID = group }
        elements.removeAll { ids.contains($0.id) }
        elements.insert(contentsOf: members, at: insertion)
    }

    public mutating func ungroup(_ ids: Set<UUID>) {
        let ids = expandedSelection(ids)
        for i in elements.indices where ids.contains(elements[i].id) { elements[i].groupID = nil }
    }

    /// Z-order is a list of complete layers, so crossing a group never puts an
    /// unrelated element between its children.
    public mutating func reorder(_ id: UUID, by delta: Int) {
        guard delta != 0, let element = elements.first(where: { $0.id == id }) else { return }
        var layers: [[EInkCanvasElement]] = []
        var indices: [UUID: Int] = [:]
        for child in elements {
            let layer = child.groupID ?? child.id
            if let index = indices[layer] { layers[index].append(child) }
            else { indices[layer] = layers.count; layers.append([child]) }
        }
        guard let source = indices[element.groupID ?? element.id] else { return }
        let target = source + (delta < 0 ? -1 : 1)
        guard layers.indices.contains(target) else { return }
        layers.swapAt(source, target)
        elements = layers.flatMap { $0 }
    }

    static func bound(_ value: Double, _ range: ClosedRange<Double>, fallback: Double) -> Double {
        value.isFinite ? min(range.upperBound, max(range.lowerBound, value)) : fallback
    }

    private enum CodingKeys: String, CodingKey { case width, height, snapToGrid, elements }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init()
        width = c.lenient(Double.self, .width, 296)
        height = c.lenient(Double.self, .height, 152)
        snapToGrid = c.lenient(Bool.self, .snapToGrid, false)
        elements = c.lenient([EInkCanvasElement].self, .elements, [])
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(width, forKey: .width)
        try c.encode(height, forKey: .height)
        try c.encode(snapToGrid, forKey: .snapToGrid)
        try c.encode(elements, forKey: .elements)
    }
}

/// The two type families the panel can draw text in.
///
/// `pixel12` is the device's 12 px pixel font (`text-pixel-12`, verified to
/// be Fusion Pixel 12 px), the smallest legible size and the only one with
/// CJK coverage. `sans` is
/// ChillDuanSans at an explicit pixel size, reserved for numbers, which the
/// layout rules require to be at least 13 px and bold.
public enum EInkFont: Codable, Equatable, Hashable, Sendable {
    case pixel12(bold: Bool)
    case sans(size: Int, bold: Bool)

    public static let minimumPixelSize = 12
    public static let minimumSansSize = 13
    public static let maximumSansSize = 96

    public var pointSize: Int {
        switch self {
        case .pixel12: Self.minimumPixelSize
        case let .sans(size, _): size
        }
    }

    public var isBold: Bool {
        switch self {
        case let .pixel12(bold): bold
        case let .sans(_, bold): bold
        }
    }

    /// The device line box. Pixel text needs a little leading to avoid the
    /// renderer clipping descenders; numbers sit on their own box exactly.
    public var lineHeight: Int {
        switch self {
        case .pixel12: 12
        case let .sans(size, _): size
        }
    }

    public var normalized: EInkFont {
        switch self {
        case let .pixel12(bold): .pixel12(bold: bold)
        case let .sans(size, bold): .sans(size: min(Self.maximumSansSize, max(Self.minimumSansSize, size)), bold: bold)
        }
    }

    private enum Family: String, Codable { case pixel12, sans }
    private enum CodingKeys: String, CodingKey { case family, size, bold }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let family = c.lenient(Family.self, .family, .pixel12)
        let bold = c.lenient(Bool.self, .bold, false)
        switch family {
        case .pixel12: self = .pixel12(bold: bold)
        case .sans: self = EInkFont.sans(size: c.lenient(Int.self, .size, 14), bold: bold).normalized
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch normalized {
        case let .pixel12(bold):
            try c.encode(Family.pixel12, forKey: .family)
            try c.encode(bold, forKey: .bold)
        case let .sans(size, bold):
            try c.encode(Family.sans, forKey: .family)
            try c.encode(size, forKey: .size)
            try c.encode(bold, forKey: .bold)
        }
    }
}

public enum EInkTextAlignment: String, Codable, CaseIterable, Hashable, Sendable {
    case leading, center, trailing

    public var cssValue: String {
        switch self {
        case .leading: "left"
        case .center: "center"
        case .trailing: "right"
        }
    }
}

public struct EInkCanvasElement: Codable, Equatable, Hashable, Identifiable, Sendable {
    public enum Kind: String, Codable, CaseIterable, Hashable, Sendable {
        case text, ring, horizontalBar, verticalBar, statTile, divider
        case quotaLedger, quotaRings, quotaRail
        case usageTiles, usageSplit, usageTable, usageDual, usageTrend

        /// Whole-preset blocks the Studio can drop in and scale, the E-ink
        /// counterpart of `MiniCanvasElement.Kind.presetMode`.
        public var preset: EInkPreset? {
            switch self {
            case .quotaLedger: .quotaLedger
            case .quotaRings: .quotaRings
            case .quotaRail: .quotaRail
            case .usageTiles: .usageTiles
            case .usageSplit: .usageSplit
            case .usageTable: .usageTable
            case .usageDual: .usageDual
            case .usageTrend: .usageTrend
            default: nil
            }
        }
    }

    /// What a `text` element is bound to.
    public enum TextBinding: String, Codable, CaseIterable, Hashable, Sendable {
        case percent, label, countdown, usageMetric, custom
    }

    /// Which number a `usageMetric` text (or a `statTile`) reads.
    public enum UsageMetric: String, Codable, CaseIterable, Hashable, Sendable {
        case cost, tokens, requests
    }

    public var id = UUID()
    public var kind: Kind
    /// `MenuBarFieldCatalog` field ID for quota-bound elements.
    public var fieldID: String?
    /// A whole-preset element's own bucket selection. Empty means "whatever
    /// the slide picked, else Vibe Bar's own order" — the same reading the
    /// preset slides give an empty selection.
    public var fieldIDs: [String] = []
    /// A whole-preset element's own usage windows, read the same way.
    public var periods: [EInkUsagePeriod] = []
    public var x: Double = 6
    public var y: Double = 6
    public var width: Double = 48
    public var height: Double = 12
    public var font: EInkFont = .pixel12(bold: false)
    public var alignment: EInkTextAlignment = .leading
    public var textBinding: TextBinding = .percent
    public var text = ""
    /// A stat tile's bottom line. Empty draws the binding's own second
    /// figure — a quota countdown, or the tokens behind a cost.
    public var subText = ""
    /// Whether the drawn box is measured from the text (`true`) or kept at
    /// the author's `width`, clipping anything longer (`false`).
    ///
    /// Measured is the default because a text element dropped on the paper
    /// arrives at a width nobody chose, and clipping it there would read as
    /// the Studio losing characters. Fixing the width is the deliberate act —
    /// it is what a column needs, and the Studio says so.
    public var autoWidth = true
    public var usagePeriod: EInkUsagePeriod = .today
    public var usageMetric: UsageMetric = .cost
    /// Ring / bar stroke in device pixels.
    public var thickness: Double = 6
    /// Studio preview value when no live field is bound yet.
    public var percentOverride: Double?
    public var groupID: UUID?

    public init(kind: Kind, fieldID: String? = nil) {
        self.kind = kind
        self.fieldID = fieldID
        switch kind {
        case .text: width = 72; height = 12
        case .ring: width = 48; height = 48
        case .horizontalBar: width = 72; height = 10
        case .verticalBar: width = 22; height = 60
        case .statTile: width = 96; height = 48; font = .sans(size: 18, bold: true)
        case .divider: width = 96; height = 1
        case .quotaLedger, .quotaRail, .usageTiles, .usageSplit, .usageTable, .usageDual, .usageTrend:
            width = 284; height = 140
        case .quotaRings:
            width = 284; height = 140
        }
    }

    private enum CodingKeys: String, CodingKey {
        case id, kind, fieldID, fieldIDs, periods, x, y, width, height, font, alignment
        case textBinding, text, subText, autoWidth, usagePeriod, usageMetric, thickness, percentOverride, groupID
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(kind: c.lenient(Kind.self, .kind, .text), fieldID: c.lenientOptional(String.self, .fieldID))
        id = c.lenient(UUID.self, .id, UUID())
        fieldIDs = c.lenient([String].self, .fieldIDs, [])
        periods = c.lenient([EInkUsagePeriod].self, .periods, [])
        x = c.lenient(Double.self, .x, x)
        y = c.lenient(Double.self, .y, y)
        width = c.lenient(Double.self, .width, width)
        height = c.lenient(Double.self, .height, height)
        font = c.lenient(EInkFont.self, .font, font)
        alignment = c.lenient(EInkTextAlignment.self, .alignment, .leading)
        textBinding = c.lenient(TextBinding.self, .textBinding, .percent)
        text = c.lenient(String.self, .text, "")
        subText = c.lenient(String.self, .subText, "")
        autoWidth = c.lenient(Bool.self, .autoWidth, true)
        usagePeriod = c.lenient(EInkUsagePeriod.self, .usagePeriod, .today)
        usageMetric = c.lenient(UsageMetric.self, .usageMetric, .cost)
        thickness = c.lenient(Double.self, .thickness, thickness)
        percentOverride = c.lenientOptional(Double.self, .percentOverride)
        groupID = c.lenientOptional(UUID.self, .groupID)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(kind, forKey: .kind)
        try c.encodeIfPresent(fieldID, forKey: .fieldID)
        try c.encode(fieldIDs, forKey: .fieldIDs)
        try c.encode(periods, forKey: .periods)
        try c.encode(x, forKey: .x)
        try c.encode(y, forKey: .y)
        try c.encode(width, forKey: .width)
        try c.encode(height, forKey: .height)
        try c.encode(font, forKey: .font)
        try c.encode(alignment, forKey: .alignment)
        try c.encode(textBinding, forKey: .textBinding)
        try c.encode(text, forKey: .text)
        try c.encode(subText, forKey: .subText)
        try c.encode(autoWidth, forKey: .autoWidth)
        try c.encode(usagePeriod, forKey: .usagePeriod)
        try c.encode(usageMetric, forKey: .usageMetric)
        try c.encode(thickness, forKey: .thickness)
        try c.encodeIfPresent(percentOverride, forKey: .percentOverride)
        try c.encodeIfPresent(groupID, forKey: .groupID)
    }
}
