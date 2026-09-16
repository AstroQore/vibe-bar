import Foundation

/// Pixel-space dragging shared by the visual arranger and its tests.
public enum EInkScreenArrangement {
    public struct Move: Equatable, Sendable {
        public var x: Int
        public var y: Int
        public var verticalGuide: Int?
        public var horizontalGuide: Int?
    }

    public static func move(_ id: String, to point: EInkPoint, group: EInkScreenGroup,
                            devices: [EInkDeviceConfig], threshold: Int = 12) -> Move {
        guard let screen = group.rect(for: id, devices: devices) else {
            return Move(x: point.x, y: point.y)
        }
        let others = group.screens.filter { $0.id != id }.compactMap { group.rect(for: $0.id, devices: devices) }
        var x = point.x, y = point.y
        var xDistance = threshold + 1, yDistance = threshold + 1
        var vertical: Int?, horizontal: Int?
        for other in others {
            let xs = [(other.x, other.x), (other.maxX, other.maxX),
                      (other.x - screen.width, other.x), (other.maxX - screen.width, other.maxX),
                      (other.x + (other.width - screen.width) / 2, other.x + other.width / 2)]
            let ys = [(other.y, other.y), (other.maxY, other.maxY),
                      (other.y - screen.height, other.y), (other.maxY - screen.height, other.maxY),
                      (other.y + (other.height - screen.height) / 2, other.y + other.height / 2)]
            for (candidate, edge) in xs {
                let distance = abs(candidate - point.x)
                if distance < xDistance { x = candidate; xDistance = distance; vertical = edge }
            }
            for (candidate, edge) in ys {
                let distance = abs(candidate - point.y)
                if distance < yDistance { y = candidate; yDistance = distance; horizontal = edge }
            }

        }
        return Move(x: x, y: y, verticalGuide: vertical, horizontalGuide: horizontal)
    }

    /// A drop inside another panel settles against the nearest free edge.
    /// No content or device orientation is changed by arranging hardware.
    public static func dropping(_ id: String, move: Move, group: EInkScreenGroup,
                                devices: [EInkDeviceConfig]) -> EInkScreenGroup {
        guard let index = group.screens.firstIndex(where: { $0.id == id }),
              let rect = group.rect(for: id, devices: devices) else { return group }
        let others = group.screens.filter { $0.id != id }.compactMap { group.rect(for: $0.id, devices: devices) }
        func free(_ point: EInkPoint) -> Bool {
            let candidate = EInkRect(x: point.x, y: point.y, width: rect.width, height: rect.height)
            return others.allSatisfy { other in
                candidate.maxX <= other.x || candidate.x >= other.maxX || candidate.maxY <= other.y || candidate.y >= other.maxY
            }
        }
        let proposed = EInkPoint(x: move.x, y: move.y)
        var candidates = [proposed]
        for other in others {
            candidates += [
                EInkPoint(x: other.x - rect.width, y: move.y), EInkPoint(x: other.maxX, y: move.y),
                EInkPoint(x: move.x, y: other.y - rect.height), EInkPoint(x: move.x, y: other.maxY)
            ]
        }
        let target = candidates.filter(free).min {
            hypot(Double($0.x - move.x), Double($0.y - move.y)) < hypot(Double($1.x - move.x), Double($1.y - move.y))
        }
        guard let target else { return group }
        var copy = group
        copy.screens[index].x = target.x
        copy.screens[index].y = target.y
        // Keep the authored-canvas size limit consistent with the renderer.
        guard let bounds = copy.bounds(for: copy.screens.map(\.id), devices: devices),
              bounds.width <= 4096, bounds.height <= 4096 else { return group }
        return copy
    }
}
