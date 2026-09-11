import Foundation

/// One device as `GET /api/authV2/open/devices` reports it.
public struct DotDevice: Sendable, Equatable {
    public var id: String
    public var alias: String
    public var model: String
    public var series: String
    public var edition: Int?

    public init(id: String, alias: String = "", model: String = "", series: String = "", edition: Int? = nil) {
        self.id = id
        self.alias = alias
        self.model = model
        self.series = series
        self.edition = edition
    }

    /// The panel profile, when the model is one Vibe Bar knows.
    public var profile: EInkDeviceProfile? {
        EInkDeviceModel(rawValue: model).map { EInkDeviceProfile(model: $0, width: $0.pixelWidth, height: $0.pixelHeight) }
    }
}

/// `GET /api/authV2/open/device/:id/status`, reduced to what the UI shows.
///
/// The status strings are whatever the service returns in the account's
/// language; they are displayed verbatim and never parsed for meaning.
public struct DotDeviceStatus: Sendable, Equatable {
    public var deviceID: String
    public var alias: String
    public var firmwareVersion: String
    public var current: String
    public var battery: String
    public var wifi: String
    /// The render the device is showing now — used as a read-back thumbnail.
    public var currentImageURL: URL?
    public var lastRenderedLabel: String
    public var nextPowerRefreshLabel: String
    public var nextBatteryRefreshLabel: String

    public init(
        deviceID: String,
        alias: String = "",
        firmwareVersion: String = "",
        current: String = "",
        battery: String = "",
        wifi: String = "",
        currentImageURL: URL? = nil,
        lastRenderedLabel: String = "",
        nextPowerRefreshLabel: String = "",
        nextBatteryRefreshLabel: String = ""
    ) {
        self.deviceID = deviceID
        self.alias = alias
        self.firmwareVersion = firmwareVersion
        self.current = current
        self.battery = battery
        self.wifi = wifi
        self.currentImageURL = currentImageURL
        self.lastRenderedLabel = lastRenderedLabel
        self.nextPowerRefreshLabel = nextPowerRefreshLabel
        self.nextBatteryRefreshLabel = nextBatteryRefreshLabel
    }
}

/// One entry of `GET /api/authV2/open/device/:id/:taskType/list`.
public struct DotTask: Sendable, Equatable {
    public var key: String
    public var type: String
    public var alias: String

    public init(key: String, type: String = "", alias: String = "") {
        self.key = key
        self.type = type
        self.alias = alias
    }

    /// Only Canvas API tasks can receive a rendered slide.
    public var isCanvasAPI: Bool { type.uppercased() == "CANVAS_API" }
}

public enum DotTaskType: String, Sendable, CaseIterable {
    case loop
    case fixed
}

/// Pure JSON → model translation, kept out of the client so it can be tested
/// offline against captured fixtures.
public enum DotResponseParser {
    public enum ParseError: Error, Equatable, Sendable {
        case notJSON
        case unexpectedShape
    }

    static func json(_ data: Data) throws -> Any {
        guard let value = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) else {
            throw ParseError.notJSON
        }
        return value
    }

    /// The service has shipped both a bare array and several envelope keys;
    /// accept all of them rather than break on a shape change.
    static func list(_ value: Any) -> [[String: Any]]? {
        if let array = value as? [[String: Any]] { return array }
        guard let object = value as? [String: Any] else { return nil }
        for key in ["devices", "result", "data", "items", "tasks", "list"] {
            if let array = object[key] as? [[String: Any]] { return array }
        }
        return nil
    }

    static func string(_ object: [String: Any], _ keys: [String]) -> String {
        for key in keys {
            if let value = object[key] as? String { return value }
            if let value = object[key] as? NSNumber { return value.stringValue }
        }
        return ""
    }

    public static func devices(_ data: Data) throws -> [DotDevice] {
        guard let array = list(try json(data)) else { throw ParseError.unexpectedShape }
        return array.compactMap { entry in
            let id = string(entry, ["id", "deviceId", "deviceID"])
            guard !id.isEmpty else { return nil }
            return DotDevice(
                id: id,
                alias: string(entry, ["alias", "name"]),
                model: string(entry, ["model"]),
                series: string(entry, ["series"]),
                edition: (entry["edition"] as? NSNumber)?.intValue
            )
        }
    }

    public static func status(_ data: Data, deviceID: String) throws -> DotDeviceStatus {
        guard let object = try json(data) as? [String: Any] else { throw ParseError.unexpectedShape }
        let status = object["status"] as? [String: Any] ?? [:]
        let renderInfo = object["renderInfo"] as? [String: Any] ?? [:]
        let current = renderInfo["current"] as? [String: Any] ?? [:]
        let next = renderInfo["next"] as? [String: Any] ?? [:]
        let images = current["image"] as? [String] ?? []
        return DotDeviceStatus(
            deviceID: string(object, ["deviceId", "deviceID", "id"]).isEmpty
                ? deviceID
                : string(object, ["deviceId", "deviceID", "id"]),
            alias: string(object, ["alias", "name"]),
            firmwareVersion: string(status, ["version"]),
            current: string(status, ["current"]),
            battery: string(status, ["battery"]),
            wifi: string(status, ["wifi"]),
            currentImageURL: images.first.flatMap { URL(string: $0) },
            lastRenderedLabel: string(renderInfo, ["last"]),
            nextPowerRefreshLabel: string(next, ["power"]),
            nextBatteryRefreshLabel: string(next, ["battery"])
        )
    }

    public static func tasks(_ data: Data) throws -> [DotTask] {
        guard let array = list(try json(data)) else { throw ParseError.unexpectedShape }
        return array.compactMap { entry in
            let key = string(entry, ["key", "taskKey"])
            guard !key.isEmpty else { return nil }
            return DotTask(
                key: key,
                type: string(entry, ["type", "taskType"]),
                alias: string(entry, ["taskAlias", "alias", "title", "name"])
            )
        }
    }

    /// Successful control endpoints answer with a top-level `message`.
    public static func message(_ data: Data) -> String {
        guard let object = try? json(data) as? [String: Any] else { return "" }
        return string(object, ["message", "msg"])
    }
}
