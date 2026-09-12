import Foundation

/// Turns a preset into the Studio layout that draws it.
///
/// "Edit in Studio" on a preset slide runs this: the preset's box tree becomes
/// grouped canvas elements — the header bar one group, each quota slot one,
/// the footer one — with their bindings preserved, so a slot's percentage
/// still follows its bucket after the author has moved it. That last part is
/// the whole point. Exploding into fixed text would hand the user a picture of
/// one refresh and call it a layout.
///
/// The contract `EInkPresetExploderTests` holds it to: for every preset and
/// every orientation, drawing the exploded layout produces the *same boxes*
/// the preset produces. Anything else is a layout that silently changed the
/// panel the moment the user pressed a button.
public enum EInkPresetExploder {
    /// The exploded layout for one slide at one orientation.
    public static func explode(
        slide: EInkSlide,
        orientation: EInkOrientation,
        profile: EInkDeviceProfile = .quote0,
        snapshot: EInkDataSnapshot,
        calendar: Calendar = .current
    ) -> EInkCanvasLayout {
        let preset = slide.kind.preset ?? .quotaLedger
        let size = profile.frameSize(for: orientation)
        let frame = EInkRect(x: 0, y: 0, width: size.width, height: size.height)
        let tree = EInkRenderer.presetTree(
            preset,
            slide: slide,
            orientation: orientation,
            snapshot: snapshot,
            frame: frame,
            calendar: calendar
        )
        return layout(
            from: EInkBoxLayout.resolveAnnotated(tree, in: frame),
            profile: profile,
            orientation: orientation,
            snapshot: snapshot
        )
    }

    /// "Re-layout": the preset's own arrangement again, at this orientation.
    ///
    /// Identical to `explode` and named for what the Studio button does, so a
    /// call site reads as the intent rather than as the mechanism.
    public static func reflow(
        slide: EInkSlide,
        orientation: EInkOrientation,
        profile: EInkDeviceProfile = .quote0,
        snapshot: EInkDataSnapshot,
        calendar: Calendar = .current
    ) -> EInkCanvasLayout {
        explode(
            slide: slide,
            orientation: orientation,
            profile: profile,
            snapshot: snapshot,
            calendar: calendar
        )
    }

    // MARK: - Boxes to elements

    static func layout(
        from placed: [EInkPlacedBox],
        profile: EInkDeviceProfile,
        orientation: EInkOrientation,
        snapshot: EInkDataSnapshot
    ) -> EInkCanvasLayout {
        var layout = EInkCanvasLayout(profile: profile, orientation: orientation)
        // Single-pixel snapping: the boxes are already whole device pixels and
        // rounding them onto the 8 px grid would move every one of them.
        layout.snapToGrid = false
        var groups: [String: UUID] = [:]
        var elements: [EInkCanvasElement] = []

        var index = 0
        while index < placed.count {
            let entry = placed[index]
            index += 1
            switch entry.source {
            case .barFill, .ringLabel:
                // Drawn by the element the box before it produced.
                continue
            case .plain, .barTrack, .ringArc:
                break
            }
            guard var element = element(for: entry, snapshot: snapshot) else { continue }
            if let moduleID = entry.moduleID {
                let group = groups[moduleID] ?? UUID()
                groups[moduleID] = group
                element.groupID = group
                element.moduleID = moduleID
            }
            elements.append(element)
        }
        layout.elements = elements
        return layout.normalized()
    }

    static func element(for placed: EInkPlacedBox, snapshot: EInkDataSnapshot) -> EInkCanvasElement? {
        let frame = placed.box.frame
        guard frame.width > 0, frame.height > 0 else { return nil }

        func positioned(_ kind: EInkCanvasElement.Kind) -> EInkCanvasElement {
            var element = EInkCanvasElement(kind: kind)
            element.x = Double(frame.x)
            element.y = Double(frame.y)
            element.width = Double(frame.width)
            element.height = Double(frame.height)
            placed.binding?.apply(to: &element)
            return element
        }

        switch placed.source {
        case let .barTrack(percent, vertical):
            var element = positioned(vertical ? .verticalBar : .horizontalBar)
            // A bar with no bucket behind it — the usage layouts' "share of
            // the biggest harness" — keeps the figure it was drawn with, which
            // is a real measurement rather than a placeholder.
            if element.fieldID?.isEmpty ?? true { element.percentOverride = Double(percent) }
            return element
        case let .ringArc(percent, stroke, labelFont):
            var element = positioned(.ring)
            element.thickness = Double(stroke)
            element.font = labelFont
            if element.fieldID?.isEmpty ?? true { element.percentOverride = Double(percent) }
            return element
        case .barFill, .ringLabel:
            return nil
        case .plain:
            switch placed.box.content {
            case let .text(content, font, alignment):
                var element = positioned(.text)
                element.font = font
                element.alignment = alignment
                // A measured box keeps measuring; a fixed one keeps its width
                // and says whether that width clips.
                element.autoWidth = false
                element.clipsOverflow = placed.box.clipsContent
                // A binding is only kept when it prints exactly what the
                // preset printed. Several layouts decorate their value — "in
                // 3h 00m", a bare "62" beside a bar, an uppercased alert
                // headline — and a binding there would quietly redraw the cell
                // as the undecorated figure the moment the layout was edited.
                // Those become fixed text, which is honest: the author can
                // rebind them in the inspector and see what they get.
                let rendered = EInkCustomLayoutRenderer.text(for: element, snapshot: snapshot)
                if placed.binding == nil || rendered != content {
                    element.textBinding = .custom
                    element.fieldID = nil
                    element.text = content
                }
                return element
            case .fill:
                return positioned(.fill)
            case .outline:
                // Only a bar's track draws an outline, and that arrives as
                // `barTrack`. An outline with no bar behind it would be a new
                // primitive nobody can edit, so it is drawn as its own bar at
                // zero rather than invented.
                var element = positioned(.horizontalBar)
                element.percentOverride = 0
                return element
            case let .image(source):
                var element = positioned(.image)
                element.imageSource = source
                return element
            case let .ring(percent, stroke):
                var element = positioned(.ring)
                element.thickness = Double(stroke)
                element.percentOverride = Double(percent)
                return element
            }
        }
    }
}

// MARK: - Layout table migration

/// Moves round 1's `einkCanvasLayouts` entries onto the new per-orientation
/// keys.
///
/// A round 1 file has one layout per slide and no orientation anywhere in the
/// key, so the only honest place to put it is the orientation the device was
/// actually showing when it was authored. The other three are generated on
/// demand by "Re-layout", which is what the Studio's button does.
public enum EInkCanvasLayoutMigration {
    public static func migrated(
        _ layouts: [String: EInkCanvasLayout],
        devices: [EInkDeviceConfig]
    ) -> [String: EInkCanvasLayout] {
        var orientationByLayoutID: [String: EInkOrientation] = [:]
        for device in devices {
            for slide in device.slides {
                guard let layoutID = slide.kind.layoutID else { continue }
                orientationByLayoutID[layoutID] = device.orientation
            }
        }
        var result: [String: EInkCanvasLayout] = [:]
        for (key, layout) in layouts {
            guard !key.contains("/") else {
                result[key] = layout
                continue
            }
            let orientation = orientationByLayoutID[key] ?? .degrees0
            result[EInkRenderer.layoutKey(key, orientation: orientation)] = layout
        }
        return result
    }

    /// True when anything still sits under a round 1 key.
    public static func needsMigration(_ layouts: [String: EInkCanvasLayout]) -> Bool {
        layouts.keys.contains { !$0.contains("/") }
    }
}


public extension EInkCanvasLayout {
    /// "Re-layout": this slide's preset, arranged for this orientation.
    ///
    /// Spelled on the layout because that is where the Studio's button lives,
    /// and because it reads as what it replaces: a layout, re-derived. The
    /// caller decides whether to confirm first — re-laying out discards
    /// whatever the author moved.
    static func reflow(
        from slide: EInkSlide,
        orientation: EInkOrientation,
        profile: EInkDeviceProfile = .quote0,
        snapshot: EInkDataSnapshot,
        calendar: Calendar = .current
    ) -> EInkCanvasLayout {
        EInkPresetExploder.reflow(
            slide: slide,
            orientation: orientation,
            profile: profile,
            snapshot: snapshot,
            calendar: calendar
        )
    }
}
