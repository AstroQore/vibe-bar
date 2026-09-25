import Foundation

public enum EInkScreenGroupError: Error, CustomStringConvertible {
    case invalidArrangement
    case invalidAssignment
    public var description: String {
        switch self {
        case .invalidArrangement: "Screens must not overlap and the combined canvas must fit within 4096 × 4096 pixels."
        case .invalidAssignment: "Each region must name existing screens, and a screen may appear in only one region per frame."
        }
    }
}

public enum EInkScreenGroupRenderer {
    public static func validate(_ group: EInkScreenGroup, devices: [EInkDeviceConfig]) throws {
        let ids = group.screens.map(\.deviceID)
        guard ids.count >= 2, Set(ids).count == ids.count,
              let bounds = group.bounds(for: ids, devices: devices),
              bounds.width <= 4096, bounds.height <= 4096 else { throw EInkScreenGroupError.invalidArrangement }
        let rects = ids.compactMap { group.rect(for: $0, devices: devices) }
        for i in rects.indices {
            for j in rects.indices where j > i {
                if intersects(rects[i], rects[j]) { throw EInkScreenGroupError.invalidArrangement }
            }
        }
        for frame in group.frames {
            var assigned = Set<String>()
            for region in frame.regions {
                guard !region.deviceIDs.isEmpty else { throw EInkScreenGroupError.invalidAssignment }
                for id in region.deviceIDs {
                    guard ids.contains(id), assigned.insert(id).inserted else { throw EInkScreenGroupError.invalidAssignment }
                }
            }
        }
    }

    /// Resolve once on the region's combined canvas, then translate the
    /// boxes into each screen's viewport.
    ///
    /// A preset is laid out screen by screen on that canvas
    /// (`EInkGroupLayouts`), so every box it emits already sits on one
    /// screen and each screen keeps exactly the boxes inside it. A preset
    /// that is one picture across the screens has its text moved off the
    /// seams. A Studio layout is the author's own pixels: its boxes are kept
    /// whole across the seam, because shrinking them would reflow text and
    /// distort images.
    public static func boxes(group: EInkScreenGroup, frame: EInkScreenFrame,
                             devices: [EInkDeviceConfig], snapshot: EInkDataSnapshot,
                             layouts: [String: EInkCanvasLayout]) throws -> [String: [EInkDrawBox]] {
        try validate(group, devices: devices)
        var result = Dictionary(uniqueKeysWithValues: group.screens.map { ($0.deviceID, [EInkDrawBox]()) })
        for region in frame.regions {
            guard let bounds = group.bounds(for: region.deviceIDs, devices: devices),
                  let profile = group.canvasProfile(for: region.deviceIDs, devices: devices) else {
                throw EInkScreenGroupError.invalidAssignment
            }
            let tree = try EInkRenderer.tree(slide: region.slide, orientation: .degrees0,
                                            profile: profile, snapshot: snapshot, layouts: layouts)
            var boxes = EInkBoxLayout.resolve(tree, in: EInkRect(x: 0, y: 0, width: bounds.width, height: bounds.height))
            let preset = region.slide.kind.preset
            if let preset, !EInkGroupLayouts.isPaneAware(preset) {
                boxes = EInkGroupLayouts.keepingTextOffSeams(boxes, panes: profile.panes)
            }
            for id in region.deviceIDs {
                guard let screen = group.rect(for: id, devices: devices) else { continue }
                let viewport = EInkRect(x: screen.x - bounds.x, y: screen.y - bounds.y, width: screen.width, height: screen.height)
                result[id] = boxes.filter { box in
                    // Retain a Studio text box's small spill; the encoder
                    // clips the outer viewport.
                    intersects(box.frame, viewport) || (preset == nil && !box.clipsContent)
                }.map { box in
                    var copy = box
                    copy.frame.x -= viewport.x; copy.frame.y -= viewport.y
                    return copy
                }
            }
        }
        return result
    }

    /// Boxes resolved on a canvas, cut into the screens that show them, each
    /// in its own screen's coordinates. What pagination measures one panel's
    /// element budget against.
    public static func split(_ boxes: [EInkDrawBox], panes: [EInkRect]) -> [[EInkDrawBox]] {
        panes.map { pane in
            boxes.filter { intersects($0.frame, pane) }.map { box in
                var copy = box
                copy.frame.x -= pane.x; copy.frame.y -= pane.y
                return copy
            }
        }
    }

    private static func intersects(_ a: EInkRect, _ b: EInkRect) -> Bool {
        a.x < b.maxX && a.maxX > b.x && a.y < b.maxY && a.maxY > b.y
    }
}
