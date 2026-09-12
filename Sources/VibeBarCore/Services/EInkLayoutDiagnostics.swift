import Foundation

/// What is wrong with a Studio layout before it reaches a device.
///
/// The panel gives no feedback at all: a pushed slide either looks right from
/// across the room or is quietly wrong, and the Canvas API answers an
/// over-budget payload with a rejection the user never sees. So the checks run
/// where there is a person to read them — the Studio marks the offending
/// element and lists the reason — and they are pure functions of the same
/// layout the renderer draws, not a second opinion about it.
public enum EInkLayoutDiagnostics {
    public enum Issue: Equatable, Sendable, Identifiable {
        /// A fixed-width text box is narrower than the string it draws, so
        /// the device clips it.
        case textOverflow(elementID: UUID)
        /// The element's rectangle leaves the panel.
        case outOfFrame(elementID: UUID)
        /// A whole-preset block was scaled below the panel it was drawn for.
        case presetClipped(elementID: UUID)
        /// A quota-bound element with no bucket picked. It draws nothing.
        case unbound(elementID: UUID)
        /// The layout asks the device for more elements than it accepts.
        case tooManyElements(count: Int, limit: Int)

        public var elementID: UUID? {
            switch self {
            case let .textOverflow(id), let .outOfFrame(id), let .presetClipped(id), let .unbound(id): id
            case .tooManyElements: nil
            }
        }

        public var id: String {
            switch self {
            case let .textOverflow(id): "overflow-\(id)"
            case let .outOfFrame(id): "frame-\(id)"
            case let .presetClipped(id): "preset-\(id)"
            case let .unbound(id): "unbound-\(id)"
            case let .tooManyElements(count, limit): "budget-\(count)-\(limit)"
            }
        }
    }

    public struct Report: Equatable, Sendable {
        public var issues: [Issue]
        /// How many elements the payload would carry, root wrappers included —
        /// the number the Canvas API counts, not the number of Studio items.
        public var elementCount: Int
        public var elementLimit: Int

        public init(issues: [Issue], elementCount: Int, elementLimit: Int) {
            self.issues = issues
            self.elementCount = elementCount
            self.elementLimit = elementLimit
        }

        public var isClear: Bool { issues.isEmpty }

        public func issues(for elementID: UUID) -> [Issue] {
            issues.filter { $0.elementID == elementID }
        }
    }

    public static func report(
        layout: EInkCanvasLayout,
        slide: EInkSlide,
        orientation: EInkOrientation,
        profile: EInkDeviceProfile = .quote0,
        snapshot: EInkDataSnapshot
    ) -> Report {
        let size = profile.frameSize(for: orientation)
        let frame = EInkRect(x: 0, y: 0, width: size.width, height: size.height)
        // Against the *unfitted* layout, so an element that an orientation
        // change pushed out of the panel is reported rather than silently
        // repaired — the repair is what `fitted` does on the way to a device,
        // and the Studio should say it happened.
        var issues: [Issue] = []
        for element in layout.elements {
            let rect = EInkRect(
                x: Int(element.x.rounded()),
                y: Int(element.y.rounded()),
                width: Int(element.width.rounded()),
                height: Int(element.height.rounded())
            )
            if !frame.contains(rect) { issues.append(.outOfFrame(elementID: element.id)) }

            if let preset = element.kind.preset {
                _ = preset
                if rect.width < frame.width || rect.height < frame.height {
                    issues.append(.presetClipped(elementID: element.id))
                }
                continue
            }

            switch element.kind {
            case .text, .statTile, .ring, .horizontalBar, .verticalBar:
                if isUnbound(element) { issues.append(.unbound(elementID: element.id)) }
            case .divider:
                break
            default:
                break
            }

            guard element.kind == .text || element.kind == .statTile else { continue }
            // A tile draws three fixed-width lines in two different faces, and
            // a caption clipped on the device is exactly as wrong as a value
            // clipped on it — so every line is measured in the face it is
            // drawn in, not just the big one.
            let lines: [(String, EInkFont)]
            if element.kind == .statTile {
                lines = [
                    (EInkCustomLayoutRenderer.statValue(for: element, snapshot: snapshot), element.font),
                    (EInkCustomLayoutRenderer.caption(for: element, snapshot: snapshot), .pixel12(bold: true)),
                    (EInkCustomLayoutRenderer.subValue(for: element, snapshot: snapshot), .pixel12(bold: false))
                ]
            } else if element.autoWidth {
                lines = []
            } else {
                lines = [(EInkCustomLayoutRenderer.text(for: element, snapshot: snapshot), element.font)]
            }
            if lines.contains(where: { !$0.0.isEmpty && EInkTextMetrics.width($0.0, font: $0.1) > rect.width }) {
                issues.append(.textOverflow(elementID: element.id))
            }
        }

        let boxes = EInkBoxLayout.resolve(
            EInkCustomLayoutRenderer.tree(
                layout: layout,
                slide: slide,
                orientation: orientation,
                profile: profile,
                snapshot: snapshot
            ),
            in: frame
        )
        let count = elementCount(boxes: boxes.count, orientation: orientation)
        if count > DotCanvasEncoder.Limits.maxElements {
            issues.append(.tooManyElements(count: count, limit: DotCanvasEncoder.Limits.maxElements))
        }
        return Report(issues: issues, elementCount: count, elementLimit: DotCanvasEncoder.Limits.maxElements)
    }

    /// The device counts the root `div` too, and a turned panel adds the
    /// rotation wrapper inside it.
    public static func elementCount(boxes: Int, orientation: EInkOrientation) -> Int {
        boxes + (orientation == .degrees0 ? 1 : 2)
    }

    /// A quota-shaped element with no bucket chosen. Usage bindings and fixed
    /// text need no bucket, so they are never unbound.
    static func isUnbound(_ element: EInkCanvasElement) -> Bool {
        switch element.kind {
        case .text, .statTile:
            switch element.textBinding {
            case .usageMetric, .custom: return false
            case .percent, .label, .countdown: break
            }
        case .ring, .horizontalBar, .verticalBar:
            break
        default:
            return false
        }
        return (element.fieldID ?? "").isEmpty
    }
}
