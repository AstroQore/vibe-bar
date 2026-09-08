import Foundation

/// A window's free layout. Stored separately from `miniWindow`: an older
/// client editing its window roster must not discard these newer elements.
public struct MiniCanvasLayout: Codable, Equatable, Sendable {
    public var width: Double = 288
    public var height: Double = 192
    public var snapToGrid = true
    public static let gridSpacing: Double = 24
    public struct Span: Hashable, Sendable {
        public let columns: Int
        public let rows: Int
        public init(_ columns: Int, _ rows: Int) { self.columns = columns; self.rows = rows }
        public static let presets = [Span(1, 1), Span(2, 2), Span(3, 2), Span(2, 3), Span(3, 3)]
    }
    /// Back to front, so drawing and hit testing share one layer order.
    public var elements: [MiniCanvasElement] = []

    public init() {}

    public func normalized() -> Self {
        var copy = self
        copy.width = Self.bound(width, snapToGrid ? 96...1152 : 160...1200, fallback: 288)
        copy.height = Self.bound(height, snapToGrid ? 96...864 : 100...900, fallback: 192)
        if snapToGrid {
            copy.width = (copy.width / Self.gridSpacing).rounded() * Self.gridSpacing
            copy.height = (copy.height / Self.gridSpacing).rounded() * Self.gridSpacing
        }
        var seen = Set<UUID>()
        copy.elements = elements.filter { seen.insert($0.id).inserted }.map { element in
            var e = element
            e.width = Self.bound(e.width, 16...copy.width, fallback: 80)
            e.height = Self.bound(e.height, 16...copy.height, fallback: 80)
            e.x = Self.bound(e.x, 0...(copy.width - e.width), fallback: 0)
            e.y = Self.bound(e.y, 0...(copy.height - e.height), fallback: 0)
            e.fontSize = Self.bound(e.fontSize, 8...96, fallback: 18)
            e.thickness = Self.bound(e.thickness, 1...40, fallback: 8)
            if snapToGrid {
                e.width = min(copy.width, max(Self.gridSpacing, (e.width / Self.gridSpacing).rounded() * Self.gridSpacing))
                e.height = min(copy.height, max(Self.gridSpacing, (e.height / Self.gridSpacing).rounded() * Self.gridSpacing))
                e.x = min(copy.width - e.width, (e.x / Self.gridSpacing).rounded() * Self.gridSpacing)
                e.y = min(copy.height - e.height, (e.y / Self.gridSpacing).rounded() * Self.gridSpacing)
            }
            return e
        }
        return copy
    }

    public func expandedSelection(_ ids: Set<UUID>) -> Set<UUID> {
        let groups = Set(elements.filter { ids.contains($0.id) }.compactMap(\.groupID))
        return ids.union(elements.filter { $0.groupID.map(groups.contains) ?? false }.map(\.id))
    }

    /// Clamp the selection as a unit, preserving relative positions at edges.
    public func moving(_ ids: Set<UUID>, dx: Double, dy: Double, magnetic: Bool = false) -> Self {
        var copy = normalized()
        let ids = copy.expandedSelection(ids)
        let selected = copy.elements.filter { ids.contains($0.id) }
        guard !selected.isEmpty, dx.isFinite, dy.isFinite else { return copy }
        let minX = selected.map(\.x).min()!, minY = selected.map(\.y).min()!
        let maxX = selected.map { $0.x + $0.width }.max()!
        let maxY = selected.map { $0.y + $0.height }.max()!
        let grid = Self.gridSpacing
        let proposedX = copy.snapToGrid ? (dx / grid).rounded() * grid : dx
        let proposedY = copy.snapToGrid ? (dy / grid).rounded() * grid : dy
        var tx = min(max(proposedX, -minX), copy.width - maxX)
        var ty = min(max(proposedY, -minY), copy.height - maxY)
        if magnetic && !copy.snapToGrid {
            let others = copy.elements.filter { !ids.contains($0.id) }
            let targetsX: [Double] = [0.0, copy.width / 2, copy.width] + others.flatMap { [$0.x, $0.x + $0.width / 2, $0.x + $0.width] }
            let targetsY: [Double] = [0.0, copy.height / 2, copy.height] + others.flatMap { [$0.y, $0.y + $0.height / 2, $0.y + $0.height] }
            func correction(_ edges: [Double], _ targets: [Double]) -> Double {
                targets.flatMap { target in edges.map { target - $0 } }
                    .filter { abs($0) <= 5 }.min(by: { abs($0) < abs($1) }) ?? 0
            }
            tx += correction([minX + tx, (minX + maxX) / 2 + tx, maxX + tx], targetsX)
            ty += correction([minY + ty, (minY + maxY) / 2 + ty, maxY + ty], targetsY)
            tx = min(max(tx, -minX), copy.width - maxX)
            ty = min(max(ty, -minY), copy.height - maxY)
        }
        for i in copy.elements.indices where ids.contains(copy.elements[i].id) {
            copy.elements[i].x += tx
            copy.elements[i].y += ty
        }
        return copy
    }

    public mutating func add(_ kind: MiniCanvasElement.Kind, fieldID: String?, x: Double? = nil, y: Double? = nil) -> UUID {
        self = normalized()
        var e = MiniCanvasElement(kind: kind, fieldID: fieldID)
        e.x = x ?? 24; e.y = y ?? 24
        if snapToGrid, x == nil, y == nil {
            // Palette clicks use the first empty group of cells. Explicit
            // drops may overlap, so text can be placed inside a gauge.
            let occupied = elements.map { CGRect(x: $0.x, y: $0.y, width: $0.width, height: $0.height) }
            var position: CGPoint?
            while position == nil {
                for row in stride(from: 0.0, through: max(0, height - e.height), by: Self.gridSpacing) {
                    for column in stride(from: 0.0, through: max(0, width - e.width), by: Self.gridSpacing) {
                        let rect = CGRect(x: column, y: row, width: e.width, height: e.height)
                        if !occupied.contains(where: { $0.intersects(rect) }) { position = rect.origin; break }
                    }
                    if position != nil { break }
                }
                if position != nil || height >= 864 { break }
                height += Self.gridSpacing
            }
            e.x = Double(position?.x ?? 0); e.y = Double(position?.y ?? 0)
        }
        elements.append(e)
        self = normalized()
        return e.id
    }

    public mutating func resize(_ id: UUID, to span: Span) {
        guard span.columns > 0, span.rows > 0,
              let index = elements.firstIndex(where: { $0.id == id }) else { return }
        elements[index].width = Double(span.columns) * Self.gridSpacing
        elements[index].height = Double(span.rows) * Self.gridSpacing
        self = normalized()
    }

    public mutating func duplicate(_ ids: Set<UUID>) -> Set<UUID> {
        let ids = expandedSelection(ids)
        var groups: [UUID: UUID] = [:]
        let copies = elements.filter { ids.contains($0.id) }.map { original in
            var e = original
            e.id = UUID()
            if let group = e.groupID {
                if groups[group] == nil { groups[group] = UUID() }
                e.groupID = groups[group]
            }
            return e
        }
        elements.append(contentsOf: copies)
        let newIDs = Set(copies.map(\.id))
        self = moving(newIDs, dx: snapToGrid ? Self.gridSpacing : 12, dy: snapToGrid ? Self.gridSpacing : 12)
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

    /// Z-order is a list of complete layers. Crossing a group must never put
    /// an unrelated element between its children.
    public mutating func reorder(_ id: UUID, by delta: Int) {
        guard delta != 0, let element = elements.first(where: { $0.id == id }) else { return }
        var layers: [[MiniCanvasElement]] = []
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
}

public struct MiniCanvasElement: Codable, Equatable, Identifiable, Sendable {
    public enum Kind: String, Codable, CaseIterable, Sendable {
        case ring, horizontalBar, verticalBar, sector, text
        case quotaRing, quotaBar, ledger, strip, tile, focus, rail

        public var presetMode: MiniWindowDisplayMode? {
            switch self {
            case .quotaRing: .regular
            case .quotaBar: .compact
            case .ledger: .ledger
            case .strip: .strip
            case .tile: .tile
            case .focus: .focus
            case .rail: .rail
            default: nil
            }
        }
    }
    public enum TextContent: String, Codable, CaseIterable, Sendable {
        case percent, label, countdown, pace, custom
    }
    public enum Colour: String, Codable, CaseIterable, Sendable {
        case quota, provider, primary, custom
    }
    public var id = UUID()
    public var kind: Kind
    public var fieldID: String?
    public var x: Double = 24
    public var y: Double = 24
    public var width: Double = 48
    public var height: Double = 48
    public var fontSize: Double = 18
    public var thickness: Double = 6
    public var textContent: TextContent = .percent
    public var text = ""
    public var colour: Colour = .quota
    public var hexColour = "4D9FFF"
    public var groupID: UUID?

    public init(kind: Kind, fieldID: String? = nil) {
        self.kind = kind
        self.fieldID = fieldID
        switch kind {
        case .horizontalBar: width = 72; height = 24
        case .verticalBar: width = 24; height = 72
        case .text: width = 72; height = 24
        case .ring, .sector: break
        case .quotaRing: width = 72; height = 120
        case .quotaBar: width = 96; height = 120
        case .ledger: width = 288; height = 144
        case .strip: width = 192; height = 96
        case .tile: width = 144; height = 144
        case .focus: width = 240; height = 192
        case .rail: width = 288; height = 144
        }
    }
}
