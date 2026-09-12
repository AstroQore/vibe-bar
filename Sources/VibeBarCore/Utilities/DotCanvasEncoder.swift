import Foundation

/// A JSON value in the shape the Canvas API accepts. Heterogeneous by
/// necessity: `style` mixes integers (`left: 6`) and strings
/// (`lineHeight: "12px"`), and the device rejects the wrong one.
public indirect enum DotCanvasValue: Encodable, Equatable, Sendable {
    case string(String)
    case int(Int)
    case bool(Bool)
    case null
    case array([DotCanvasValue])
    case object([String: DotCanvasValue])

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case let .string(value): try container.encode(value)
        case let .int(value): try container.encode(value)
        case let .bool(value): try container.encode(value)
        case .null: try container.encodeNil()
        case let .array(values): try container.encode(values)
        case let .object(values): try container.encode(values)
        }
    }

    /// Every string anywhere in the value, for the 4 000-character check.
    var allStrings: [String] {
        switch self {
        case let .string(value): [value]
        case .int, .bool, .null: []
        case let .array(values): values.flatMap(\.allStrings)
        case let .object(values): values.keys.map { $0 } + values.values.flatMap(\.allStrings)
        }
    }

    var elementCount: Int {
        switch self {
        case let .object(values):
            let isElement = values["type"] != nil && values["props"] != nil
            return (isElement ? 1 : 0) + values.values.reduce(0) { $0 + $1.elementCount }
        case let .array(values):
            return values.reduce(0) { $0 + $1.elementCount }
        default:
            return 0
        }
    }

    var elementDepth: Int {
        switch self {
        case let .object(values):
            let isElement = values["type"] != nil && values["props"] != nil
            let deepest = values.values.map(\.elementDepth).max() ?? 0
            return (isElement ? 1 : 0) + deepest
        case let .array(values):
            return values.map(\.elementDepth).max() ?? 0
        default:
            return 0
        }
    }
}

/// The exact body `POST /api/authV2/open/device/:deviceId/canvas` accepts.
public struct DotCanvasPayload: Encodable, Equatable, Sendable {
    public var refreshNow: Bool
    /// Which Canvas API task in the device loop to update. Omitted when the
    /// device has exactly one.
    public var taskKey: String?
    /// Human-readable task name. Omitted to keep whatever name is there.
    public var taskAlias: String?
    public var data: DotCanvasValue
    public var windowData: DotCanvasValue
    public var layoutFull: DotCanvasValue
    /// 0 = white screen border, 1 = black. Black is the alert state.
    public var border: Int
    /// Where a phone tapping the (NFC) panel is sent. Omitted when absent.
    public var link: String?

    public static let defaultLayoutFull = DotCanvasValue.object([
        "tw": .string("p-0 bg-white"),
        "style": .object(["padding": .int(0)])
    ])

    public init(
        refreshNow: Bool,
        taskKey: String? = nil,
        taskAlias: String? = nil,
        data: DotCanvasValue,
        windowData: DotCanvasValue,
        layoutFull: DotCanvasValue = DotCanvasPayload.defaultLayoutFull,
        border: Int = 0,
        link: String? = nil
    ) {
        self.refreshNow = refreshNow
        self.taskKey = taskKey
        self.taskAlias = taskAlias
        self.data = data
        self.windowData = windowData
        self.layoutFull = layoutFull
        self.border = border
        self.link = link
    }

    private enum CodingKeys: String, CodingKey {
        case refreshNow, taskKey, taskAlias, data, windowData, layoutFull, border, link
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(refreshNow, forKey: .refreshNow)
        try c.encodeIfPresent(taskKey, forKey: .taskKey)
        try c.encodeIfPresent(taskAlias, forKey: .taskAlias)
        try c.encode(data, forKey: .data)
        try c.encode(windowData, forKey: .windowData)
        try c.encode(layoutFull, forKey: .layoutFull)
        try c.encode(border, forKey: .border)
        try c.encodeIfPresent(link, forKey: .link)
    }

    /// Deterministic bytes: the sync engine compares digests to avoid a
    /// pointless e-ink refresh, so two equal payloads must encode identically.
    public static func jsonEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }

    public func jsonData() throws -> Data { try Self.jsonEncoder().encode(self) }
}

/// Turns a laid-out box tree into the device JSON.
public enum DotCanvasEncoder {
    /// The Canvas API's hard limits, as verified on a Dot. Quote/0.
    public enum Limits {
        public static let maxElements = 80
        public static let maxDepth = 16
        public static let maxStringLength = 4000
        public static let maxWindowDataBytes = 128 * 1024
        public static let maxDataBytes = 64 * 1024
    }

    public enum EncodeError: Error, Equatable, Sendable, CustomStringConvertible {
        public enum Violation: Equatable, Sendable, CustomStringConvertible {
            case elementCount(Int)
            case nestingDepth(Int)
            case stringTooLong(length: Int)
            case windowDataTooLarge(bytes: Int)
            case dataTooLarge(bytes: Int)
            /// A literal `{{` would be read as the device's template syntax.
            case templateMarker(String)

            public var description: String {
                switch self {
                case let .elementCount(count):
                    "element count \(count) exceeds \(Limits.maxElements)"
                case let .nestingDepth(depth):
                    "nesting depth \(depth) exceeds \(Limits.maxDepth)"
                case let .stringTooLong(length):
                    "string length \(length) exceeds \(Limits.maxStringLength)"
                case let .windowDataTooLarge(bytes):
                    "windowData \(bytes) bytes exceeds \(Limits.maxWindowDataBytes)"
                case let .dataTooLarge(bytes):
                    "data \(bytes) bytes exceeds \(Limits.maxDataBytes)"
                case let .templateMarker(context):
                    "literal '{{' in \(context)"
                }
            }
        }

        case limitsExceeded([Violation])
        case rasterizationFailed

        public var description: String {
            switch self {
            case let .limitsExceeded(violations):
                "Canvas payload rejected: " + violations.map(\.description).joined(separator: "; ")
            case .rasterizationFailed:
                "Canvas payload rejected: ring rasterization failed"
            }
        }
    }

    public static func encode(
        _ tree: EInkNode,
        orientation: EInkOrientation,
        profile: EInkDeviceProfile = .quote0,
        refreshNow: Bool = false,
        taskKey: String? = nil,
        taskAlias: String? = nil,
        generatedAtISO: String = "",
        border: Int = 0,
        link: String? = nil
    ) throws -> DotCanvasPayload {
        let frameSize = profile.frameSize(for: orientation)
        let frame = EInkRect(x: 0, y: 0, width: frameSize.width, height: frameSize.height)
        let boxes = EInkBoxLayout.resolve(tree, in: frame)
        return try encode(
            boxes: boxes,
            orientation: orientation,
            profile: profile,
            refreshNow: refreshNow,
            taskKey: taskKey,
            taskAlias: taskAlias,
            generatedAtISO: generatedAtISO,
            border: border,
            link: link
        )
    }

    public static func encode(
        boxes: [EInkDrawBox],
        orientation: EInkOrientation,
        profile: EInkDeviceProfile = .quote0,
        refreshNow: Bool = false,
        taskKey: String? = nil,
        taskAlias: String? = nil,
        generatedAtISO: String = "",
        border: Int = 0,
        link: String? = nil
    ) throws -> DotCanvasPayload {
        let elements = try boxes.map(element(for:))
        let root = rootElement(children: elements, orientation: orientation, profile: profile)
        let payload = DotCanvasPayload(
            refreshNow: refreshNow,
            taskKey: taskKey,
            taskAlias: taskAlias,
            data: .object(["generatedAt": .string(generatedAtISO)]),
            windowData: .object(["default": .array([root])]),
            border: border == 1 ? 1 : 0,
            link: link
        )
        try validate(payload)
        return payload
    }

    // MARK: - Root

    /// The 296 × 152 panel is always the outer frame. Portrait layouts are
    /// authored 152 × 296 and rotated into it: the verified offsets put the
    /// taller subtree at left 72 / top −72 and spin it about its centre.
    static func rootElement(
        children: [DotCanvasValue],
        orientation: EInkOrientation,
        profile: EInkDeviceProfile
    ) -> DotCanvasValue {
        let panelWidth = profile.width
        let panelHeight = profile.height
        var rootStyle: [String: DotCanvasValue] = [
            "position": .string("relative"),
            "width": .int(panelWidth),
            "height": .int(panelHeight)
        ]
        guard orientation != .degrees0 else {
            return .object([
                "type": .string("div"),
                "props": .object([
                    "tw": .string("flex bg-white text-black"),
                    "style": .object(rootStyle),
                    "children": .array(children)
                ])
            ])
        }
        let frameSize = profile.frameSize(for: orientation)
        let wrapper = DotCanvasValue.object([
            "type": .string("div"),
            "props": .object([
                "tw": .string("flex bg-white text-black"),
                "style": .object([
                    "position": .string("absolute"),
                    "left": .int((panelWidth - frameSize.width) / 2),
                    "top": .int((panelHeight - frameSize.height) / 2),
                    "width": .int(frameSize.width),
                    "height": .int(frameSize.height),
                    "transform": .string("rotate(\(orientation.cssDegrees)deg)"),
                    "transformOrigin": .string("center")
                ]),
                "children": .array(children)
            ])
        ])
        rootStyle["overflow"] = .string("hidden")
        return .object([
            "type": .string("div"),
            "props": .object([
                "tw": .string("flex bg-white text-black"),
                "style": .object(rootStyle),
                "children": .array([wrapper])
            ])
        ])
    }

    // MARK: - Elements

    static func element(for box: EInkDrawBox) throws -> DotCanvasValue {
        var style: [String: DotCanvasValue] = [
            "position": .string("absolute"),
            "left": .int(box.frame.x),
            "top": .int(box.frame.y),
            "width": .int(box.frame.width),
            "height": .int(box.frame.height)
        ]
        switch box.content {
        case let .text(content, font, alignment):
            style["whiteSpace"] = .string("nowrap")
            if box.clipsContent { style["overflow"] = .string("hidden") }
            style["textAlign"] = .string(alignment.cssValue)
            style["lineHeight"] = .string("\(max(box.frame.height, font.pointSize))px")
            return .object([
                "type": .string("span"),
                "props": .object([
                    "tw": .string(twClass(for: font) + " " + alignmentClass(for: alignment)),
                    "style": .object(style),
                    "children": .string(content)
                ])
            ])
        case let .image(source):
            return .object([
                "type": .string("img"),
                "props": .object([
                    "tw": .string(imageClass),
                    "style": .object(style),
                    "src": .string(source)
                ])
            ])
        case .fill:
            return .object([
                "type": .string("div"),
                "props": .object([
                    "tw": .string("flex bg-black"),
                    "style": .object(style)
                ])
            ])
        case .outline:
            style["borderWidth"] = .int(1)
            style["borderStyle"] = .string("solid")
            style["borderColor"] = .string("black")
            return .object([
                "type": .string("div"),
                "props": .object([
                    "tw": .string("flex bg-white"),
                    "style": .object(style)
                ])
            ])
        case let .ring(percent, stroke):
            let source: String
            do {
                source = try EInkRingRasterizer.dataURI(
                    percent: percent,
                    size: max(box.frame.width, box.frame.height),
                    stroke: stroke
                )
            } catch {
                throw EncodeError.rasterizationFailed
            }
            return .object([
                "type": .string("img"),
                "props": .object([
                    "tw": .string(imageClass),
                    "style": .object(style),
                    "src": .string(source)
                ])
            ])
        }
    }

    /// Dithering off and a hard threshold: the PNG is already 1-bit, and the
    /// panel's default kernel would smear the arc edge into grey noise.
    static let imageClass = "img-dither-none img-kernel-threshold"

    /// The renderer treats a `span` as a flex container, so `textAlign`
    /// alone leaves a right-aligned string sitting at the left edge of its
    /// box (observed on the device). Emitting the flex justification class
    /// beside it is what actually moves the run.
    public static func alignmentClass(for alignment: EInkTextAlignment) -> String {
        switch alignment {
        case .leading: "text-left justify-start"
        case .center: "text-center justify-center"
        case .trailing: "text-right justify-end"
        }
    }

    public static func twClass(for font: EInkFont) -> String {
        switch font {
        case let .pixel12(bold):
            "text-pixel-12 text-black" + (bold ? " font-bold" : "")
        case let .sans(size, bold):
            "text-[\(size)px]-chillduansans text-black" + (bold ? " font-bold" : "")
        }
    }

    // MARK: - Validation

    public static func validate(_ payload: DotCanvasPayload) throws {
        var violations: [EncodeError.Violation] = []
        let elementCount = payload.windowData.elementCount
        if elementCount > Limits.maxElements { violations.append(.elementCount(elementCount)) }
        let depth = payload.windowData.elementDepth
        if depth > Limits.maxDepth { violations.append(.nestingDepth(depth)) }
        for string in payload.windowData.allStrings + payload.data.allStrings
        where string.count > Limits.maxStringLength {
            violations.append(.stringTooLong(length: string.count))
        }
        let encoder = DotCanvasPayload.jsonEncoder()
        let windowBytes = (try? encoder.encode(payload.windowData).count) ?? 0
        if windowBytes > Limits.maxWindowDataBytes { violations.append(.windowDataTooLarge(bytes: windowBytes)) }
        let dataBytes = (try? encoder.encode(payload.data).count) ?? 0
        if dataBytes > Limits.maxDataBytes { violations.append(.dataTooLarge(bytes: dataBytes)) }
        for string in payload.windowData.allStrings where string.contains("{{") {
            violations.append(.templateMarker("windowData"))
            break
        }
        guard violations.isEmpty else { throw EncodeError.limitsExceeded(violations) }
    }
}
